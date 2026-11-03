package server

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

var compactContextParent = envOr("HTTP_CONTEXT_PARENT", "server")

// Experimental HTTP/1 backend for this API's complete, single-Write responses.
// ReadRequest retains the standard request parser. Streaming, upgrades and
// disconnect cancellation during handler execution are not implemented here.
func serveCompactHTTP(ctx context.Context, address string, handler http.Handler) error {
	listener, err := net.Listen("tcp", address)
	if err != nil {
		return err
	}
	return serveCompactListener(ctx, listener, handler)
}

func serveCompactListener(parent context.Context, listener net.Listener, handler http.Handler) error {
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	var requestParents [32]context.Context
	if compactContextParent == "sharded" {
		var cancelParents [32]context.CancelFunc
		for i := range requestParents {
			requestParents[i], cancelParents[i] = context.WithCancel(ctx)
		}
		defer func() {
			for _, stop := range cancelParents {
				stop()
			}
		}()
	}
	var nextParent uint32
	var mutex sync.Mutex
	connections := make(map[net.Conn]struct{})
	var workers sync.WaitGroup
	closed := make(chan struct{})
	go func() {
		defer close(closed)
		<-ctx.Done()
		listener.Close()
		mutex.Lock()
		for connection := range connections {
			connection.Close()
		}
		mutex.Unlock()
	}()
	for {
		connection, err := acceptCompact(ctx, listener)
		if err != nil {
			cancel()
			<-closed
			workers.Wait()
			if parent.Err() != nil || errors.Is(err, net.ErrClosed) {
				return http.ErrServerClosed
			}
			return err
		}
		mutex.Lock()
		if ctx.Err() != nil {
			mutex.Unlock()
			connection.Close()
			continue
		}
		connections[connection] = struct{}{}
		workers.Add(1)
		mutex.Unlock()
		requestParent := ctx
		if compactContextParent == "sharded" {
			requestParent = requestParents[nextParent%uint32(len(requestParents))]
			nextParent++
		}
		go func(requestParent context.Context) {
			defer workers.Done()
			defer func() {
				connection.Close()
				mutex.Lock()
				delete(connections, connection)
				mutex.Unlock()
				if failure := recover(); failure != nil {
					log.Printf("compact HTTP handler panic: %v", failure)
				}
			}()
			serveCompactConnection(requestParent, connection, handler)
		}(requestParent)
	}
}

func serveCompactConnection(ctx context.Context, connection net.Conn, handler http.Handler) {
	if compactContextParent == "connection" {
		// Keep request cancellation local to its connection. Otherwise every
		// keep-alive request adds/removes a child under the server-wide mutex.
		connectionContext, cancelConnection := context.WithCancel(ctx)
		defer cancelConnection()
		ctx = connectionContext
	}
	session := newCompactSession(connection)
	for ctx.Err() == nil && session.serveOne(ctx, handler) {
	}
}

type compactSession struct {
	connection net.Conn
	limited    io.LimitedReader
	reader     *bufio.Reader
	remote     string
	writer     compactResponse
}

func newCompactSession(connection net.Conn) *compactSession {
	s := &compactSession{connection: connection, limited: io.LimitedReader{R: connection}, remote: connection.RemoteAddr().String()}
	s.reader = bufio.NewReaderSize(&s.limited, 1024)
	s.writer = compactResponse{connection: connection, header: make(http.Header), wire: make([]byte, 0, 512)}
	return s
}

// The connection goroutine owns all session fields throughout each request.
func (s *compactSession) serveOne(ctx context.Context, handler http.Handler) bool {
	connection, limited, reader, writer := s.connection, &s.limited, s.reader, &s.writer
	limited.N = (1 << 20) + 4096
	connection.SetReadDeadline(time.Now().Add(75 * time.Second))
	if _, err := reader.Peek(1); err != nil {
		return false
	}
	var request *http.Request
	var err error
	if compactHTTPHotPath {
		buffered, _ := reader.Peek(reader.Buffered())
		if spec, ok := parseBufferedGET(buffered); ok {
			if api, ok := handler.(*apiRoutes); compactAPIReads && ok {
				// Own request strings before discarding or reusing reader bytes.
				owned := string(buffered[:spec.end+4])
				if plan, ok := api.app.planCompactRead(owned[4:spec.uriEnd]); ok {
					_, err = reader.Discard(spec.end + 4)
					if err != nil {
						return false
					}
					limited.N = 1<<63 - 1
					auth := ""
					if spec.seen&(1<<1) != 0 {
						auth = owned[spec.spans[1][0]:spec.spans[1][1]]
					}
					s.respondRead(ctx, api.app, plan, auth, spec.closeConnection)
					return writer.err == nil && !writer.close
				}
			}
			request = spec.request(buffered)
			_, err = reader.Discard(spec.end + 4)
		}
	}
	fast := request != nil
	if !fast {
		connection.SetReadDeadline(time.Now().Add(10 * time.Second))
		request, err = http.ReadRequest(reader)
	}
	if err != nil {
		if limited.N <= 0 {
			_, _ = io.WriteString(connection, "HTTP/1.1 431 Request Header Fields Too Large\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
		} else {
			_, _ = io.WriteString(connection, "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
		}
		return false
	}
	if len(request.TransferEncoding) != 0 && reader.Size() < 4096 {
		// Chunked trailer parsing needs the previous 4 KiB lookahead.
		// Keep the reader's address: the parsed body already refers to it.
		// Its unread prefix owns the old buffer until replay completes.
		unread, _ := reader.Peek(reader.Buffered())
		*reader = *bufio.NewReaderSize(io.MultiReader(bytes.NewReader(unread), limited), 4096)
	}
	if !fast {
		connection.SetReadDeadline(time.Time{})
	}
	limited.N = 1<<63 - 1
	request.RemoteAddr = s.remote
	s.respond(ctx, request, handler)
	if writer.err != nil || writer.close {
		return false
	}
	if request.Body == http.NoBody {
		return true
	}
	// Complete bodies have already been consumed by API handlers. Bound
	// draining when authentication or validation rejected an unread body.
	n, err := io.CopyN(io.Discard, request.Body, (256<<10)+1)
	if n > 256<<10 || (err != nil && err != io.EOF) {
		return false
	}
	if err := request.Body.Close(); err != nil {
		return false
	}
	return true
}

func (s *compactSession) respond(ctx context.Context, request *http.Request, handler http.Handler) {
	connection, writer := s.connection, &s.writer
	requestContext, cancel := context.WithCancel(ctx)
	defer cancel()
	// ReadRequest gave this goroutine sole ownership. Copying back into
	// that object lets WithContext's temporary stay off the heap.
	*request = *request.WithContext(requestContext)
	writer.reset(request)
	if expectation := request.Header.Get("Expect"); expectation != "" {
		if !strings.EqualFold(expectation, "100-continue") {
			writer.close = true
			writer.WriteHeader(http.StatusExpectationFailed)
		} else if request.ContentLength != 0 {
			if _, err := io.WriteString(connection, "HTTP/1.1 100 Continue\r\n\r\n"); err != nil {
				writer.err = err
				return
			}
		}
	}
	if writer.status == 0 {
		handler.ServeHTTP(writer, request)
	}
	if !writer.sent {
		_, _ = writer.Write(nil)
	}
}

type compactResponse struct {
	connection net.Conn
	header     http.Header
	wire       compactHeaderBytes
	buffers    [2][]byte
	status     int
	head       bool
	close      bool
	sent       bool
	err        error
}

func (w *compactResponse) reset(request *http.Request) {
	clear(w.header)
	w.status, w.head, w.close, w.sent, w.err = 0, request.Method == http.MethodHead, request.Close, false, nil
}

func (w *compactResponse) Header() http.Header { return w.header }
func (w *compactResponse) WriteHeader(status int) {
	if w.status == 0 {
		w.status = status
	}
}

func (w *compactResponse) Write(body []byte) (int, error) {
	if err := w.prepare(body); err != nil {
		return 0, err
	}
	return w.writeVector(body)
}

func (w *compactResponse) prepare(body []byte) error {
	if w.sent {
		w.err = http.ErrContentLength
		return w.err
	}
	w.sent = true
	if w.status == 0 {
		w.status = http.StatusOK
	}
	if len(body) > 0 && w.header.Get("Content-Type") == "" {
		w.header.Set("Content-Type", http.DetectContentType(body))
	}
	w.wire = append(w.wire[:0], "HTTP/1.1 "...)
	w.wire = strconv.AppendInt(w.wire, int64(w.status), 10)
	w.wire = append(w.wire, ' ')
	w.wire = append(w.wire, http.StatusText(w.status)...)
	w.wire = append(w.wire, "\r\nDate: "...)
	w.wire = time.Now().UTC().AppendFormat(w.wire, http.TimeFormat)
	w.wire = append(w.wire, "\r\n"...)
	if w.close {
		w.wire = append(w.wire, "Connection: close\r\n"...)
	}
	if w.status != http.StatusNoContent && w.status != http.StatusNotModified {
		w.wire = append(w.wire, "Content-Length: "...)
		w.wire = strconv.AppendInt(w.wire, int64(len(body)), 10)
		w.wire = append(w.wire, "\r\n"...)
	}
	delete(w.header, "Content-Length")
	if compactHTTPHotPath && len(w.header) == 1 && len(w.header["Content-Type"]) == 1 && w.header["Content-Type"][0] == "application/json" {
		w.wire = append(w.wire, "Content-Type: application/json\r\n"...)
	} else {
		if err := w.header.Write(&w.wire); err != nil {
			w.err = err
			return err
		}
	}
	w.wire = append(w.wire, "\r\n"...)
	return nil
}

func (w *compactResponse) writeVector(body []byte) (int, error) {
	w.buffers[0] = w.wire
	w.buffers[1] = body
	if w.head || w.status == http.StatusNoContent || w.status == http.StatusNotModified {
		w.buffers[1] = nil
	}
	buffers := net.Buffers(w.buffers[:])
	n, err := buffers.WriteTo(w.connection)
	clear(w.buffers[:])
	w.err = err
	if w.head && err == nil {
		return len(body), nil
	}
	return max(0, int(n)-len(w.wire)), err
}

type compactHeaderBytes []byte

func (b *compactHeaderBytes) Write(p []byte) (int, error) {
	*b = append(*b, p...)
	return len(p), nil
}

func (b *compactHeaderBytes) WriteString(s string) (int, error) {
	*b = append(*b, s...)
	return len(s), nil
}
