package main

import (
	"bytes"
	"errors"
	"io"
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
	bufSize   = 4 << 10
	maxHeader = 16 << 10
	maxBody   = 1 << 20
)

// conn is everything an idle keep-alive connection holds: no goroutine, no buffers.
type conn struct {
	mu              sync.Mutex
	fd              int
	loop            *loop
	events          uint32 // what epoll watches on fd
	busy            bool   // a request is being served, input waits in pending
	reading         bool   // the request in flight reads the rest of its body off the socket
	masked          bool   // input is unwatched until the body reader waits for it
	served          bool   // the handler returned, flush finishes the request
	closed          bool   // peer is gone, the fd closes once the request in flight is done
	closeAfterWrite bool
	wake            chan struct{} // tells the body reader the socket has input
	pending         []byte
	out             []byte // response bytes the socket did not take yet
}

type server struct {
	handler http.Handler
	conns   []atomic.Pointer[conn]
}

type loop struct {
	srv    *server
	epfd   int
	lfd    int
	buf    *[bufSize]byte
	events []unix.EpollEvent
}

// bufPool holds the buffers requests are read into. A request with a body keeps the one its head came
// in until the body is read.
var bufPool = sync.Pool{New: func() any { return new([bufSize]byte) }}

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
		l := &loop{srv: s, epfd: epfd, lfd: lfd, buf: bufPool.Get().(*[bufSize]byte), events: make([]unix.EpollEvent, 1024)}
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
				l.read(c, ev.Events)
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
		c := &conn{fd: fd, loop: l, events: unix.EPOLLIN | unix.EPOLLRDHUP}
		l.srv.conns[fd].Store(c)
		if err = unix.EpollCtl(l.epfd, unix.EPOLL_CTL_ADD, fd, &unix.EpollEvent{Events: c.events, Fd: int32(fd)}); err != nil {
			l.srv.conns[fd].Store(nil)
			_ = unix.Close(fd)
		}
	}
}

func (l *loop) read(c *conn, events uint32) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return
	}
	if c.reading {
		if events&(unix.EPOLLHUP|unix.EPOLLERR) != 0 {
			c.shutdown()
			return
		}
		c.masked = true
		c.arm()
		c.signal()
		return
	}
	n, err := unix.Read(c.fd, l.buf[:])
	if n <= 0 {
		if err != unix.EAGAIN && err != unix.EINTR {
			c.shutdown()
		}
		return
	}
	if c.busy || len(c.pending) > 0 {
		c.pending = append(c.pending, l.buf[:n]...)
		if !c.busy {
			c.next()
		}
		return
	}
	c.dispatch(l.buf[:n], l)
}

// shutdown drops the conn from epoll and closes it, or leaves the close to the request in flight.
// Callers hold c.mu.
func (c *conn) shutdown() {
	if c.closed {
		return
	}
	c.closed = true
	_ = unix.EpollCtl(c.loop.epfd, unix.EPOLL_CTL_DEL, c.fd, nil)
	c.signal()
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

func (c *conn) signal() {
	select {
	case c.wake <- struct{}{}:
	default:
	}
}

// arm makes epoll watch what c waits for. Callers hold c.mu.
func (c *conn) arm() {
	ev := uint32(unix.EPOLLIN | unix.EPOLLRDHUP)
	if c.masked {
		ev = 0
	}
	if len(c.out) > 0 {
		ev |= unix.EPOLLOUT
	}
	if ev == c.events || c.closed {
		return
	}
	c.events = ev
	_ = unix.EpollCtl(c.loop.epfd, unix.EPOLL_CTL_MOD, c.fd, &unix.EpollEvent{Events: ev, Fd: int32(c.fd)})
}

// next serves the request buffered in pending, if a whole head is there. Callers hold c.mu.
func (c *conn) next() {
	rest := c.pending
	c.pending = nil
	c.dispatch(rest, nil)
}

// dispatch parses one request out of data and hands it to a goroutine. Whatever follows it waits in
// pending until the response is out, so responses keep request order. A body that starts in l's
// buffer takes it over, and l gets another. Callers hold c.mu.
func (c *conn) dispatch(data []byte, l *loop) {
	req := reqPool.Get().(*request)
	used, err := req.parse(data)
	if err != nil {
		reqPool.Put(req)
		if err == errIncomplete {
			c.pending = append(c.pending[:0], data...)
			return
		}
		c.reject(err)
		return
	}
	if l != nil && len(req.body.buf) > 0 {
		req.body.owned, l.buf = l.buf, bufPool.Get().(*[bufSize]byte)
	}
	if used < len(data) {
		c.pending = append(c.pending[:0], data[used:]...)
	}
	c.busy = true
	c.start(req)
	go c.serve(req)
}

// start hands the socket to req's body reader when the body is not all in. Callers hold c.mu.
func (c *conn) start(req *request) {
	req.w.c = c
	req.body.c = c
	if req.body.left > 0 {
		c.reading = true
		if c.wake == nil {
			c.wake = make(chan struct{}, 1)
		}
	}
}

func (c *conn) serve(req *request) {
	for {
		c.loop.srv.handler.ServeHTTP(&req.w, &req.Request)
		if !req.w.sent {
			_, _ = req.w.Write(nil)
		}
		closeAfter := req.close
		if req.body.left > 0 && !req.body.discard() {
			closeAfter = true
		}

		c.mu.Lock()
		if c.closed {
			c.busy = false
			c.release()
			c.mu.Unlock()
			req.reset()
			reqPool.Put(req)
			return
		}
		if len(c.out) > 0 {
			// the socket is full, flush finishes the job from the loop
			c.served = true
			c.closeAfterWrite = closeAfter
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
			c.reject(err)
			c.mu.Unlock()
			reqPool.Put(req)
			return
		}
		if rest := c.pending[used:]; len(req.body.buf) == 0 {
			c.pending = append(c.pending[:0], rest...)
		} else {
			// the body starts in pending, so what follows it moves out
			c.pending = nil
			if len(rest) > 0 {
				c.pending = append(c.pending, rest...)
			}
		}
		c.start(req)
		c.mu.Unlock()
	}
}

// send writes h and b, keeping what the socket did not take in c.out. It reports whether the conn
// is still open. Callers hold c.mu.
func (c *conn) send(h, b []byte) bool {
	for len(h)+len(b) > 0 {
		n, err := writev(c.fd, h, b)
		switch err {
		case nil:
		case unix.EINTR:
			continue
		case unix.EAGAIN:
			c.out = append(append(c.out[:0], h...), b...)
			c.arm()
			return true
		default:
			if c.served {
				c.served = false
				c.busy = false
			}
			c.shutdown()
			return false
		}
		if n < len(h) {
			h = h[n:]
			continue
		}
		b = b[n-len(h):]
		h = nil
	}
	return true
}

func writev(fd int, h, b []byte) (int, error) {
	if len(b) == 0 {
		return unix.Write(fd, h)
	}
	if len(h) == 0 {
		return unix.Write(fd, b)
	}
	iov := [2]unix.Iovec{{Base: &h[0]}, {Base: &b[0]}}
	iov[0].SetLen(len(h))
	iov[1].SetLen(len(b))
	n, _, e := unix.Syscall(unix.SYS_WRITEV, uintptr(fd), uintptr(unsafe.Pointer(&iov[0])), uintptr(len(iov)))
	if e != 0 {
		return 0, e
	}
	return int(n), nil
}

// reject answers a request that cannot be served and closes the conn. Callers hold c.mu.
func (c *conn) reject(err error) {
	resp := resp400
	if err == errLengthRequired {
		resp = resp411
	}
	_, _ = unix.Write(c.fd, resp)
	c.shutdown()
}

func (c *conn) flush() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed || len(c.out) == 0 {
		return
	}
	out := c.out
	c.out = c.out[:0]
	if !c.send(out, nil) || len(c.out) > 0 {
		return
	}
	c.out = nil
	c.arm()
	if !c.served {
		return
	}
	c.served = false
	c.busy = false
	if c.closeAfterWrite {
		c.shutdown()
		return
	}
	if len(c.pending) > 0 {
		c.next()
	}
}

// readBody reads body bytes off the socket into p, waiting for the loop to see input when there is none.
func (c *conn) readBody(p []byte) (int, error) {
	for {
		n, err := unix.Read(c.fd, p)
		switch {
		case err == nil && n > 0:
			return n, nil
		case err == nil:
			return 0, io.ErrUnexpectedEOF
		case err == unix.EINTR:
			continue
		case err != unix.EAGAIN:
			return 0, err
		}
		c.mu.Lock()
		if c.closed {
			c.mu.Unlock()
			return 0, io.ErrUnexpectedEOF
		}
		c.masked = false
		c.arm()
		c.mu.Unlock()
		<-c.wake
	}
}

// endBody gives the socket back to the loop.
func (c *conn) endBody() {
	c.mu.Lock()
	c.reading = false
	c.masked = false
	c.arm()
	select {
	case <-c.wake:
	default:
	}
	c.mu.Unlock()
}

var (
	errIncomplete     = errors.New("incomplete request")
	errBadRequest     = errors.New("bad request")
	errLengthRequired = errors.New("length required")
	errWritten        = errors.New("response already written")
	errClosed         = errors.New("connection closed")
	resp400           = []byte("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
	resp411           = []byte("HTTP/1.1 411 Length Required\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
)

type request struct {
	http.Request
	url   url.URL
	hdr   http.Header
	auth  [1]string
	body  body
	head  []byte // the target and Authorization, copied out of the buffer the head was read into
	w     responseWriter
	close bool
}

var reqPool = sync.Pool{New: func() any {
	r := &request{hdr: make(http.Header, 1), head: make([]byte, 0, 512)}
	r.w.hdr = make(http.Header, 2)
	r.w.head = make([]byte, 0, 256)
	return r
}}

func (r *request) reset() {
	r.Request = http.Request{}
	clear(r.hdr)
	r.auth[0] = ""
	r.body.drop()
	r.body.left = 0
	r.close = false
	r.w.reset()
}

// parse reads one request head from data into r, with as much of the body as data holds. The body
// points into data. It returns the bytes consumed.
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
	closeConn, keepAlive10 := false, false
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
					closeConn = true
				} else if asciiEqualFold(val, "keep-alive") {
					keepAlive10 = true
				}
			}
		case 17:
			if asciiEqualFold(name, "transfer-encoding") {
				return 0, errLengthRequired
			}
		}
	}
	total := end + 4 + contentLength
	used := min(len(data), total)
	r.Method = method(data[:sp1])
	r.head = append(append(r.head[:0], data[sp1+1:sp2]...), data[authStart:authEnd]...)
	target, auth := r.head[:sp2-sp1-1], r.head[sp2-sp1-1:]
	r.url = url.URL{}
	if q := bytes.IndexByte(target, '?'); q >= 0 {
		r.url.RawQuery = str(target[q+1:])
		target = target[:q]
	}
	r.url.Path = str(target)
	r.URL = &r.url
	r.close = closeConn || http10 && !keepAlive10
	r.Proto = "HTTP/1.1"
	r.ProtoMajor, r.ProtoMinor = 1, 1
	if authEnd > 0 {
		r.auth[0] = str(auth)
		r.hdr["Authorization"] = r.auth[:]
	}
	r.Header = r.hdr
	r.ContentLength = int64(contentLength)
	r.body.buf = data[end+4 : used]
	r.body.left = total - used
	r.Body = &r.body
	return used, nil
}

var crlfcrlf = []byte("\r\n\r\n")

func str(b []byte) string { return unsafe.String(unsafe.SliceData(b), len(b)) }

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

// body reads a request body: first the part read with the head, then the rest straight off the socket.
type body struct {
	c     *conn
	buf   []byte
	owned *[bufSize]byte // the read buffer buf is in, pooled again once buf is read
	left  int            // bytes still on the socket
}

func (b *body) Read(p []byte) (int, error) {
	if len(b.buf) > 0 {
		n := copy(p, b.buf)
		b.buf = b.buf[n:]
		if len(b.buf) == 0 {
			b.drop()
		}
		return n, nil
	}
	if b.left == 0 {
		return 0, io.EOF
	}
	if len(p) == 0 {
		return 0, nil
	}
	n, err := b.c.readBody(p[:min(len(p), b.left)])
	b.left -= n
	if b.left == 0 {
		b.c.endBody()
	}
	return n, err
}

func (*body) Close() error { return nil }

func (b *body) drop() {
	b.buf = nil
	if b.owned != nil {
		bufPool.Put(b.owned)
		b.owned = nil
	}
}

// discard reads the rest of the body off the socket, so the next request starts at its head.
func (b *body) discard() bool {
	b.drop()
	scratch := bufPool.Get().(*[bufSize]byte)
	defer bufPool.Put(scratch)
	for b.left > 0 {
		if _, err := b.Read(scratch[:]); err != nil {
			return false
		}
	}
	return true
}

// responseWriter sends the whole response from Write, the body straight from the caller's buffer, so
// a handler writes its body in one call.
type responseWriter struct {
	c      *conn
	hdr    http.Header
	head   []byte
	status int
	sent   bool
}

func (w *responseWriter) Header() http.Header { return w.hdr }

func (w *responseWriter) WriteHeader(code int) {
	if w.status == 0 {
		w.status = code
	}
}

func (w *responseWriter) Write(b []byte) (int, error) {
	if w.sent {
		return 0, errWritten
	}
	w.sent = true
	w.head = w.appendHead(w.head[:0], len(b))
	c := w.c
	c.mu.Lock()
	ok := !c.closed && c.send(w.head, b)
	c.mu.Unlock()
	if !ok {
		return 0, errClosed
	}
	return len(b), nil
}

func (w *responseWriter) reset() {
	clear(w.hdr)
	w.status = 0
	w.sent = false
}

func (w *responseWriter) appendHead(dst []byte, n int) []byte {
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
	dst = strconv.AppendInt(dst, int64(n), 10)
	return append(dst, "\r\n\r\n"...)
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
