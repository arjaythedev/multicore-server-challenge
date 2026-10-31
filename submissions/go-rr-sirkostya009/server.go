package main

import (
	"bytes"
	"errors"
	"net/http"
	"net/netip"
	"net/url"
	"runtime"
	"strconv"
	"sync"
	"sync/atomic"
	"unsafe"

	"golang.org/x/sys/unix"
)

const (
	readBufSize = 64 << 10
	maxHeader   = 16 << 10
	maxBody     = 1 << 20
)

// conn is everything an idle keep-alive connection holds: no goroutine, no buffers.
type conn struct {
	mu              sync.Mutex
	fd              int
	loop            *loop
	busy            bool // a request is being served, input waits in pending
	closed          bool // peer is gone, the fd closes once the request in flight is done
	pending         []byte
	out             []byte // response bytes the socket did not take yet
	closeAfterWrite bool
}

type server struct {
	handler http.Handler
	conns   []atomic.Pointer[conn]
}

type loop struct {
	srv    *server
	epfd   int
	lfd    int
	buf    []byte
	events []unix.EpollEvent
}

func listen(addr netip.AddrPort) (int, error) {
	fd, err := unix.Socket(unix.AF_INET, unix.SOCK_STREAM|unix.SOCK_NONBLOCK|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return -1, err
	}
	_ = unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_REUSEADDR, 1)
	_ = unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_REUSEPORT, 1)
	sa := &unix.SockaddrInet4{Port: int(addr.Port()), Addr: addr.Addr().As4()}
	if err = unix.Bind(fd, sa); err != nil {
		_ = unix.Close(fd)
		return -1, err
	}
	if err = unix.Listen(fd, 65535); err != nil {
		_ = unix.Close(fd)
		return -1, err
	}
	return fd, nil
}

func serve(addr netip.AddrPort, loops int, h http.Handler) error {
	var lim unix.Rlimit
	if err := unix.Getrlimit(unix.RLIMIT_NOFILE, &lim); err != nil {
		return err
	}
	lim.Cur = lim.Max
	_ = unix.Setrlimit(unix.RLIMIT_NOFILE, &lim)
	_ = unix.Getrlimit(unix.RLIMIT_NOFILE, &lim)
	s := &server{handler: h, conns: make([]atomic.Pointer[conn], lim.Cur)}

	errc := make(chan error, loops)
	for range loops {
		lfd, err := listen(addr)
		if err != nil {
			return err
		}
		epfd, err := unix.EpollCreate1(unix.EPOLL_CLOEXEC)
		if err != nil {
			return err
		}
		if err = unix.EpollCtl(epfd, unix.EPOLL_CTL_ADD, lfd, &unix.EpollEvent{Events: unix.EPOLLIN, Fd: int32(lfd)}); err != nil {
			return err
		}
		l := &loop{srv: s, epfd: epfd, lfd: lfd, buf: make([]byte, readBufSize), events: make([]unix.EpollEvent, 1024)}
		go func() { errc <- l.run() }()
	}
	return <-errc
}

func (l *loop) run() error {
	runtime.LockOSThread()
	for {
		n, err := unix.EpollWait(l.epfd, l.events, -1)
		if err != nil {
			if err == unix.EINTR {
				continue
			}
			return err
		}
		for i := range n {
			ev := &l.events[i]
			fd := int(ev.Fd)
			if fd == l.lfd {
				l.accept()
				continue
			}
			c := l.srv.conns[fd].Load()
			if c == nil {
				continue
			}
			if ev.Events&unix.EPOLLOUT != 0 {
				c.flush()
			}
			if ev.Events&(unix.EPOLLIN|unix.EPOLLRDHUP|unix.EPOLLHUP|unix.EPOLLERR) != 0 {
				l.read(c)
			}
		}
	}
}

func (l *loop) accept() {
	for {
		fd, _, err := unix.Accept4(l.lfd, unix.SOCK_NONBLOCK|unix.SOCK_CLOEXEC)
		if err != nil {
			return
		}
		if fd >= len(l.srv.conns) {
			_ = unix.Close(fd)
			continue
		}
		_ = unix.SetsockoptInt(fd, unix.IPPROTO_TCP, unix.TCP_NODELAY, 1)
		c := &conn{fd: fd, loop: l}
		l.srv.conns[fd].Store(c)
		if err = unix.EpollCtl(l.epfd, unix.EPOLL_CTL_ADD, fd, &unix.EpollEvent{Events: unix.EPOLLIN | unix.EPOLLRDHUP, Fd: int32(fd)}); err != nil {
			l.srv.conns[fd].Store(nil)
			_ = unix.Close(fd)
		}
	}
}

func (l *loop) read(c *conn) {
	n, err := unix.Read(c.fd, l.buf)
	if n <= 0 {
		if err == unix.EAGAIN || err == unix.EINTR {
			return
		}
		c.mu.Lock()
		c.shutdown()
		c.mu.Unlock()
		return
	}
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	if c.busy || len(c.pending) > 0 {
		c.pending = append(c.pending, l.buf[:n]...)
		if !c.busy {
			c.next()
		}
	} else {
		c.dispatch(l.buf[:n])
	}
	c.mu.Unlock()
}

// shutdown drops the conn from epoll and closes it, or leaves the close to the request in flight.
// Callers hold c.mu.
func (c *conn) shutdown() {
	if c.closed {
		return
	}
	c.closed = true
	_ = unix.EpollCtl(c.loop.epfd, unix.EPOLL_CTL_DEL, c.fd, nil)
	if !c.busy {
		c.release()
	}
}

func (c *conn) release() {
	c.loop.srv.conns[c.fd].Store(nil)
	_ = unix.Close(c.fd)
	c.pending = nil
	c.out = nil
}

// next serves the request buffered in pending, if a whole one is there. Callers hold c.mu.
func (c *conn) next() {
	rest := c.pending
	c.pending = nil
	c.dispatch(rest)
}

// dispatch parses one request out of data and hands it to a goroutine. Whatever follows it waits in
// pending until the response is out, so responses keep request order. Callers hold c.mu.
func (c *conn) dispatch(data []byte) {
	req := reqPool.Get().(*request)
	used, err := req.parse(data)
	switch {
	case err == errIncomplete:
		reqPool.Put(req)
		if len(data) > maxHeader+maxBody {
			c.writeRaw(resp400)
			c.shutdown()
			return
		}
		c.pending = append(c.pending[:0], data...)
		return
	case err != nil:
		reqPool.Put(req)
		c.writeRaw(resp400)
		c.shutdown()
		return
	}
	if used < len(data) {
		c.pending = append(c.pending[:0], data[used:]...)
	}
	c.busy = true
	go c.serve(req)
}

func (c *conn) serve(req *request) {
	for {
		c.loop.srv.handler.ServeHTTP(&req.w, &req.Request)
		closeAfter := req.close
		out := req.w.finish(req.out[:0])
		req.out = out

		c.mu.Lock()
		if c.closed {
			c.busy = false
			c.release()
			c.mu.Unlock()
			req.reset()
			reqPool.Put(req)
			return
		}
		c.closeAfterWrite = closeAfter
		if !c.write(out) {
			// the socket is full, flush finishes the job from the loop
			c.mu.Unlock()
			req.reset()
			reqPool.Put(req)
			return
		}
		if closeAfter {
			c.busy = false
			c.shutdown()
			c.mu.Unlock()
			req.reset()
			reqPool.Put(req)
			return
		}
		req.reset()
		if len(c.pending) == 0 {
			c.busy = false
			c.mu.Unlock()
			reqPool.Put(req)
			return
		}
		used, err := req.parse(c.pending)
		if err == errIncomplete {
			c.busy = false
			c.mu.Unlock()
			reqPool.Put(req)
			return
		}
		if err != nil {
			c.busy = false
			c.writeRaw(resp400)
			c.shutdown()
			c.mu.Unlock()
			reqPool.Put(req)
			return
		}
		c.pending = append(c.pending[:0], c.pending[used:]...)
		c.mu.Unlock()
	}
}

// write sends b, keeping what the socket did not take in c.out. It reports whether everything went out.
// Callers hold c.mu.
func (c *conn) write(b []byte) bool {
	for len(b) > 0 {
		n, err := unix.Write(c.fd, b)
		if err != nil {
			if err == unix.EINTR {
				continue
			}
			if err == unix.EAGAIN {
				c.out = append(c.out[:0], b...)
				_ = unix.EpollCtl(c.loop.epfd, unix.EPOLL_CTL_MOD, c.fd, &unix.EpollEvent{Events: unix.EPOLLIN | unix.EPOLLOUT | unix.EPOLLRDHUP, Fd: int32(c.fd)})
				return false
			}
			c.busy = false
			c.shutdown()
			return false
		}
		b = b[n:]
	}
	return true
}

func (c *conn) writeRaw(b []byte) {
	_, _ = unix.Write(c.fd, b)
}

func (c *conn) flush() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed || len(c.out) == 0 {
		return
	}
	out := c.out
	c.out = nil
	if !c.write(out) {
		return
	}
	_ = unix.EpollCtl(c.loop.epfd, unix.EPOLL_CTL_MOD, c.fd, &unix.EpollEvent{Events: unix.EPOLLIN | unix.EPOLLRDHUP, Fd: int32(c.fd)})
	c.busy = false
	if c.closeAfterWrite {
		c.shutdown()
		return
	}
	if len(c.pending) > 0 {
		c.next()
	}
}

var (
	errIncomplete = errors.New("incomplete request")
	errBadRequest = errors.New("bad request")
	resp400       = []byte("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
)

type request struct {
	http.Request
	url   url.URL
	hdr   http.Header
	auth  [1]string
	body  bytes.Reader
	raw   []byte
	out   []byte
	w     responseWriter
	close bool
}

var reqPool = sync.Pool{New: func() any {
	r := &request{hdr: make(http.Header, 1), raw: make([]byte, 0, 1024), out: make([]byte, 0, 4096)}
	r.w.hdr = make(http.Header, 2)
	r.w.body = make([]byte, 0, 4096)
	return r
}}

func (r *request) reset() {
	r.Request = http.Request{}
	clear(r.hdr)
	r.auth[0] = ""
	r.close = false
	r.w.reset()
}

// parse reads one request from data into r, copying it so data can be reused. It returns the bytes consumed.
func (r *request) parse(data []byte) (int, error) {
	end := bytes.Index(data, crlfcrlf)
	if end < 0 {
		if len(data) > maxHeader {
			return 0, errBadRequest
		}
		return 0, errIncomplete
	}
	head := data[:end+2]
	sp1 := bytes.IndexByte(head, ' ')
	if sp1 <= 0 {
		return 0, errBadRequest
	}
	lineEnd := bytes.IndexByte(head, '\r')
	sp2 := bytes.LastIndexByte(head[:lineEnd], ' ')
	if sp2 <= sp1 {
		return 0, errBadRequest
	}
	proto := head[sp2+1 : lineEnd]
	if len(proto) != 8 || string(proto[:7]) != "HTTP/1." {
		return 0, errBadRequest
	}
	http10 := proto[7] == '0'

	contentLength := 0
	keepAlive10 := false
	var authStart, authEnd int
	for line := head[lineEnd+2:]; len(line) > 0; {
		i := bytes.IndexByte(line, '\r')
		h := line[:i]
		line = line[i+2:]
		colon := bytes.IndexByte(h, ':')
		if colon <= 0 {
			return 0, errBadRequest
		}
		name, val := h[:colon], trimOWS(h[colon+1:])
		switch len(name) {
		case 13:
			if asciiEqualFold(name, "authorization") {
				authStart = int(uintptr(unsafe.Pointer(unsafe.SliceData(val))) - uintptr(unsafe.Pointer(unsafe.SliceData(data))))
				authEnd = authStart + len(val)
			}
		case 14:
			if asciiEqualFold(name, "content-length") {
				n, err := strconv.Atoi(string(val))
				if err != nil || n < 0 || n > maxBody {
					return 0, errBadRequest
				}
				contentLength = n
			}
		case 10:
			if asciiEqualFold(name, "connection") {
				if asciiEqualFold(val, "close") {
					r.close = true
				} else if asciiEqualFold(val, "keep-alive") {
					keepAlive10 = true
				}
			}
		case 17:
			if asciiEqualFold(name, "transfer-encoding") {
				return 0, errBadRequest
			}
		}
	}
	if http10 && !keepAlive10 {
		r.close = true
	}
	total := end + 4 + contentLength
	if len(data) < total {
		return 0, errIncomplete
	}

	r.raw = append(r.raw[:0], data[:total]...)
	raw := r.raw
	r.Method = method(raw[:sp1])
	target := raw[sp1+1 : sp2]
	r.url = url.URL{}
	if q := bytes.IndexByte(target, '?'); q >= 0 {
		r.url.RawQuery = unsafe.String(unsafe.SliceData(target[q+1:]), len(target)-q-1)
		target = target[:q]
	}
	r.url.Path = unsafe.String(unsafe.SliceData(target), len(target))
	r.URL = &r.url
	r.Proto = "HTTP/1.1"
	r.ProtoMajor, r.ProtoMinor = 1, 1
	if authEnd > 0 {
		r.auth[0] = unsafe.String(&raw[authStart], authEnd-authStart)
		r.hdr["Authorization"] = r.auth[:]
	}
	r.Header = r.hdr
	r.ContentLength = int64(contentLength)
	r.body.Reset(raw[end+4 : total])
	r.Body = bodyReader{&r.body}
	return total, nil
}

var crlfcrlf = []byte("\r\n\r\n")

func method(b []byte) string {
	switch string(b) {
	case "GET":
		return http.MethodGet
	case "POST":
		return http.MethodPost
	case "PUT":
		return http.MethodPut
	case "DELETE":
		return http.MethodDelete
	}
	return string(b)
}

func trimOWS(b []byte) []byte {
	for len(b) > 0 && (b[0] == ' ' || b[0] == '\t') {
		b = b[1:]
	}
	for len(b) > 0 && (b[len(b)-1] == ' ' || b[len(b)-1] == '\t') {
		b = b[:len(b)-1]
	}
	return b
}

func asciiEqualFold(b []byte, lower string) bool {
	if len(b) != len(lower) {
		return false
	}
	for i := range len(b) {
		c := b[i]
		if 'A' <= c && c <= 'Z' {
			c += 'a' - 'A'
		}
		if c != lower[i] {
			return false
		}
	}
	return true
}

type bodyReader struct{ *bytes.Reader }

func (bodyReader) Close() error { return nil }

type responseWriter struct {
	hdr    http.Header
	status int
	body   []byte
}

func (w *responseWriter) Header() http.Header { return w.hdr }

func (w *responseWriter) WriteHeader(code int) {
	if w.status == 0 {
		w.status = code
	}
}

func (w *responseWriter) Write(b []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	w.body = append(w.body, b...)
	return len(b), nil
}

func (w *responseWriter) reset() {
	clear(w.hdr)
	w.status = 0
	w.body = w.body[:0]
}

// finish appends the whole response to dst.
func (w *responseWriter) finish(dst []byte) []byte {
	status := w.status
	if status == 0 {
		status = http.StatusOK
	}
	dst = append(dst, statusLine(status)...)
	for k, vs := range w.hdr {
		for _, v := range vs {
			dst = append(dst, k...)
			dst = append(dst, ": "...)
			dst = append(dst, v...)
			dst = append(dst, "\r\n"...)
		}
	}
	dst = append(dst, "Content-Length: "...)
	dst = strconv.AppendInt(dst, int64(len(w.body)), 10)
	dst = append(dst, "\r\n\r\n"...)
	return append(dst, w.body...)
}

func statusLine(code int) string {
	switch code {
	case 200:
		return "HTTP/1.1 200 OK\r\n"
	case 201:
		return "HTTP/1.1 201 Created\r\n"
	case 204:
		return "HTTP/1.1 204 No Content\r\n"
	case 401:
		return "HTTP/1.1 401 Unauthorized\r\n"
	case 403:
		return "HTTP/1.1 403 Forbidden\r\n"
	case 404:
		return "HTTP/1.1 404 Not Found\r\n"
	case 405:
		return "HTTP/1.1 405 Method Not Allowed\r\n"
	case 422:
		return "HTTP/1.1 422 Unprocessable Entity\r\n"
	case 500:
		return "HTTP/1.1 500 Internal Server Error\r\n"
	}
	return "HTTP/1.1 " + strconv.Itoa(code) + " " + http.StatusText(code) + "\r\n"
}
