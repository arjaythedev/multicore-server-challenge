// This writev prototype is test-only. Full-workload comparisons did not show a
// repeatable CPU benefit, so production keeps the standard HTTP transport.
package server

import (
	"bytes"
	"context"
	"net"
	"net/http"
	"strconv"
	"sync"
)

var responsePrefixes = sync.Pool{New: func() any { b := make([]byte, 0, 4096); return &b }}

type responseConnectionKey struct{}

type responseListener struct{ net.Listener }

func (l responseListener) Accept() (net.Conn, error) {
	c, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	r := &responseConnection{Conn: c}
	r.writer.connection = r
	return r, nil
}

// Only complete, already-encoded responses opt in. net/http retains ownership
// of parsing, framing, keep-alive, deadlines and connection shutdown.
type responseConnection struct {
	net.Conn
	writer responseWriter
	body   int
	prefix *[]byte
}

type responseWriter struct {
	http.ResponseWriter
	connection *responseConnection
	head       bool
}

func (w *responseWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func configureResponseWrites(s *http.Server) {
	previousContext := s.ConnContext
	s.ConnContext = func(ctx context.Context, c net.Conn) context.Context {
		if previousContext != nil {
			ctx = previousContext(ctx, c)
		}
		return context.WithValue(ctx, responseConnectionKey{}, c.(*responseConnection))
	}
	handler := s.Handler
	s.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c := r.Context().Value(responseConnectionKey{}).(*responseConnection)
		c.writer.ResponseWriter = w
		c.writer.head = r.Method == http.MethodHead
		defer func() { c.writer.ResponseWriter = nil }()
		handler.ServeHTTP(&c.writer, r)
	})
}

func (c *responseConnection) Write(p []byte) (int, error) {
	if c.prefix != nil {
		prefix := c.prefix
		c.prefix = nil
		staged := len(*prefix)
		// TCP implements net.Buffers with writev. The large body stays in its
		// original JSON buffer; only the first buffered HTTP write is copied.
		buffers := net.Buffers{*prefix, p}
		n, err := buffers.WriteTo(c.Conn)
		*prefix = (*prefix)[:0]
		responsePrefixes.Put(prefix)
		written := max(0, int(n)-staged)
		return written, err
	}
	if body := c.body; body > 0 {
		c.body = 0
		end := bytes.Index(p, []byte("\r\n\r\n"))
		if end >= 0 && end+4+body > len(p) && len(p) <= 4096 {
			prefix := responsePrefixes.Get().(*[]byte)
			*prefix = append((*prefix)[:0], p...)
			c.prefix = prefix
			return len(p), nil
		}
	}
	return c.Conn.Write(p)
}

func writeFramedJSON(w http.ResponseWriter, status int, body []byte) {
	w.Header().Set("Content-Type", "application/json")
	if len(body) > 2048 {
		w.Header().Set("Content-Length", strconv.Itoa(len(body)))
		if complete, ok := w.(*responseWriter); ok && !complete.head {
			complete.connection.body = len(body)
		}
	}
	w.WriteHeader(status)
	_, _ = w.Write(body)
}
