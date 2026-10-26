package main

// http.go: a small HTTP/1.1 server. One goroutine per connection (the Go runtime multiplexes them
// over epoll); each connection owns one small read buffer. Responses are one write each.

import (
	"bytes"
	"errors"
	"io"
	"log"
	"net"
	"strconv"
	"sync/atomic"
	"time"
)

const (
	readBufSize    = 2048
	maxRequestSize = 1 << 20
)

type request struct {
	method  string
	path    string // without the query string
	query   string
	auth    []byte // Authorization header value, nil if absent
	body    []byte
	close   bool
	chunked bool
}

type server struct {
	app   *app
	conns atomic.Int64
}

func (s *server) serve(ln net.Listener) error {
	for {
		c, err := ln.Accept()
		if err != nil {
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				continue
			}
			return err
		}
		go s.handleConn(c)
	}
}

func (s *server) handleConn(c net.Conn) {
	s.conns.Add(1)
	defer s.conns.Add(-1)
	if tc, ok := c.(*net.TCPConn); ok {
		tc.SetNoDelay(true)
	}
	defer c.Close()
	buf := make([]byte, readBufSize)
	used := 0
	var req request
	cs := &connState{done: make(chan struct{}, 1)}
	for {
		// Parse as many complete requests as the buffer holds.
		for {
			n, ok, err := parseRequest(buf[:used], &req)
			if err != nil {
				writeSimple(c, 400, `{"errors":{"body":["bad request"]}}`, true)
				return
			}
			if !ok {
				break
			}
			if req.chunked {
				writeSimple(c, 411, `{"errors":{"body":["length required"]}}`, true)
				return
			}
			keep := s.app.handle(c, cs, &req)
			if !keep || req.close {
				return
			}
			copy(buf, buf[n:used])
			used -= n
			if used == 0 {
				break
			}
		}
		if used == len(buf) {
			if len(buf) >= maxRequestSize {
				writeSimple(c, 413, `{"errors":{"body":["too large"]}}`, true)
				return
			}
			nb := make([]byte, len(buf)*2)
			copy(nb, buf[:used])
			buf = nb
		}
		if used == 0 && len(buf) > readBufSize {
			buf = make([]byte, readBufSize) // drop a buffer grown for a large body
		}
		n, err := c.Read(buf[used:])
		if n > 0 {
			used += n
		}
		if err != nil {
			return
		}
	}
}

var errBadRequest = errors.New("bad request")

// parseRequest parses one request from b. It returns the number of bytes consumed and ok=true when
// a complete request (headers and body) is present. The request's slices alias b.
func parseRequest(b []byte, r *request) (int, bool, error) {
	// Empty lines before the request line are ignored (RFC 9112 2.2).
	skip := 0
	for skip < len(b) && (b[skip] == '\r' || b[skip] == '\n') {
		skip++
	}
	end := bytes.Index(b[skip:], []byte("\r\n\r\n"))
	if end < 0 {
		if len(b) > 64<<10 {
			return 0, false, errBadRequest
		}
		return 0, false, nil
	}
	b = b[skip:]
	head := b[:end]
	// Request line.
	nl := bytes.IndexByte(head, '\n')
	if nl < 0 {
		nl = len(head) // no headers at all
	}
	line := head[:nl]
	if n := len(line); n > 0 && line[n-1] == '\r' {
		line = line[:n-1]
	}
	sp1 := bytes.IndexByte(line, ' ')
	if sp1 <= 0 {
		return 0, false, errBadRequest
	}
	sp2 := bytes.IndexByte(line[sp1+1:], ' ')
	if sp2 <= 0 {
		return 0, false, errBadRequest
	}
	sp2 += sp1 + 1
	target := line[sp1+1 : sp2]
	version := line[sp2+1:]
	if !bytes.HasPrefix(version, []byte("HTTP/1.")) {
		return 0, false, errBadRequest
	}
	*r = request{method: string(line[:sp1])}
	r.close = len(version) == 8 && version[7] == '0'
	if q := bytes.IndexByte(target, '?'); q >= 0 {
		r.path = string(target[:q])
		r.query = string(target[q+1:])
	} else {
		r.path = string(target)
	}
	// Headers.
	contentLength := 0
	var rest []byte
	if nl < len(head) {
		rest = head[nl+1:]
	}
	for len(rest) > 0 {
		nl = bytes.IndexByte(rest, '\n')
		var hl []byte
		if nl < 0 {
			hl, rest = rest, nil
		} else {
			hl, rest = rest[:nl], rest[nl+1:]
		}
		if n := len(hl); n > 0 && hl[n-1] == '\r' {
			hl = hl[:n-1]
		}
		colon := bytes.IndexByte(hl, ':')
		if colon <= 0 {
			continue
		}
		name := hl[:colon]
		val := bytes.TrimSpace(hl[colon+1:])
		switch len(name) {
		case 13:
			if bytes.EqualFold(name, []byte("Authorization")) {
				r.auth = val
				if r.auth == nil {
					r.auth = []byte{} // present but empty: invalid, not absent
				}
			}
		case 14:
			if bytes.EqualFold(name, []byte("Content-Length")) {
				n, err := strconv.Atoi(string(val))
				if err != nil || n < 0 || n > maxRequestSize {
					return 0, false, errBadRequest
				}
				contentLength = n
			}
		case 10:
			if bytes.EqualFold(name, []byte("Connection")) {
				if bytes.EqualFold(val, []byte("close")) {
					r.close = true
				} else if bytes.EqualFold(val, []byte("keep-alive")) {
					r.close = false
				}
			}
		case 17:
			if bytes.EqualFold(name, []byte("Transfer-Encoding")) && !bytes.EqualFold(val, []byte("identity")) {
				r.chunked = true
			}
		}
	}
	total := end + 4 + contentLength
	if len(b) < total {
		return 0, false, nil
	}
	r.body = b[end+4 : total]
	return skip + total, true, nil
}

// Cached Date header, refreshed once a second.
var dateHeader atomic.Pointer[string]

func init() {
	refreshDate()
	go func() {
		for range time.Tick(time.Second) {
			refreshDate()
		}
	}()
}

func refreshDate() {
	s := time.Now().UTC().Format("Mon, 02 Jan 2006 15:04:05 GMT")
	dateHeader.Store(&s)
}

var statusLines = map[int]string{
	200: "200 OK", 201: "201 Created", 204: "204 No Content",
	400: "400 Bad Request", 401: "401 Unauthorized", 403: "403 Forbidden", 404: "404 Not Found",
	411: "411 Length Required", 413: "413 Payload Too Large", 422: "422 Unprocessable Entity",
	500: "500 Internal Server Error", 503: "503 Service Unavailable",
}

// writeResponse sends status with the JSON body stored in *bp after headerRoom bytes of slack,
// writing the header into that slack so the whole response is one write.
func writeResponse(c net.Conn, status int, bp *[]byte, closing bool) bool {
	body := (*bp)[headerRoom:]
	var hdr [headerRoom]byte
	h := hdr[:0]
	h = append(h, "HTTP/1.1 "...)
	h = append(h, statusLines[status]...)
	h = append(h, "\r\nDate: "...)
	h = append(h, *dateHeader.Load()...)
	if status == 204 {
		h = append(h, "\r\nContent-Length: 0"...)
	} else {
		h = append(h, "\r\nContent-Type: application/json\r\nContent-Length: "...)
		h = strconv.AppendInt(h, int64(len(body)), 10)
	}
	if closing {
		h = append(h, "\r\nConnection: close"...)
	}
	h = append(h, "\r\n\r\n"...)
	start := headerRoom - len(h)
	copy((*bp)[start:], h)
	out := (*bp)[start:]
	if status == 204 {
		out = (*bp)[start:headerRoom]
	}
	_, err := c.Write(out)
	return err == nil
}

func writeSimple(c net.Conn, status int, body string, closing bool) {
	bp := getBuf()
	*bp = append(*bp, body...)
	writeResponse(c, status, bp, closing)
	putBuf(bp)
}

var _ = io.EOF
var _ = log.Printf
