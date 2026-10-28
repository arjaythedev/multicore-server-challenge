package main

// loop.go: one epoll event loop per listening socket (SO_REUSEPORT), HTTP/1.1 framing, keep-alive.
// A loop never blocks on anything but epoll_wait: a parsed request is served on its own goroutine,
// which hands the finished response back through an eventfd. Idle connections hold no buffers.

import (
	"bytes"
	"log"
	"net"
	"strconv"
	"sync"

	"golang.org/x/sys/unix"
)

const (
	maxHead = 64 << 10
	maxBody = 1 << 20
)

type request struct {
	method, path, query, auth string
	body                      []byte
	close                     bool
}

type conn struct {
	fd      int
	l       *loop
	in, out []byte
	busy    bool // a request is being served; later pipelined requests wait in `in`
	eof     bool // close once the pending response is written
	closed  bool

	resp      []byte // handed over under l.mu
	respClose bool
}

type loop struct {
	ep, lfd, efd int
	conns        map[int]*conn
	buf          []byte

	mu         sync.Mutex
	done, idle []*conn
}

func newLoop(host string, port int) *loop {
	ip := net.ParseIP(host).To4()
	if ip == nil {
		log.Fatalf("HOST %q is not an IPv4 address", host)
	}
	lfd, err := unix.Socket(unix.AF_INET, unix.SOCK_STREAM|unix.SOCK_NONBLOCK|unix.SOCK_CLOEXEC, 0)
	must(err)
	must(unix.SetsockoptInt(lfd, unix.SOL_SOCKET, unix.SO_REUSEADDR, 1))
	must(unix.SetsockoptInt(lfd, unix.SOL_SOCKET, unix.SO_REUSEPORT, 1))
	sa := &unix.SockaddrInet4{Port: port}
	copy(sa.Addr[:], ip)
	must(unix.Bind(lfd, sa))
	must(unix.Listen(lfd, 65535))
	efd, err := unix.Eventfd(0, unix.EFD_NONBLOCK|unix.EFD_CLOEXEC)
	must(err)
	ep, err := unix.EpollCreate1(unix.EPOLL_CLOEXEC)
	must(err)
	l := &loop{ep: ep, lfd: lfd, efd: efd, conns: map[int]*conn{}, buf: make([]byte, 64<<10)}
	must(unix.EpollCtl(ep, unix.EPOLL_CTL_ADD, lfd, &unix.EpollEvent{Events: unix.EPOLLIN, Fd: int32(lfd)}))
	must(unix.EpollCtl(ep, unix.EPOLL_CTL_ADD, efd, &unix.EpollEvent{Events: unix.EPOLLIN, Fd: int32(efd)}))
	return l
}

func must(err error) {
	if err != nil {
		log.Fatal(err)
	}
}

func (l *loop) run() {
	events := make([]unix.EpollEvent, 1024)
	for {
		n, err := unix.EpollWait(l.ep, events, -1)
		if err != nil {
			if err == unix.EINTR {
				continue
			}
			log.Fatal(err)
		}
		for _, ev := range events[:n] {
			switch fd := int(ev.Fd); fd {
			case l.lfd:
				l.accept()
			case l.efd:
				l.finish()
			default:
				if c := l.conns[fd]; c != nil {
					l.event(c, ev.Events)
				}
			}
		}
	}
}

func (l *loop) accept() {
	for {
		fd, _, err := unix.Accept4(l.lfd, unix.SOCK_NONBLOCK|unix.SOCK_CLOEXEC)
		if err != nil {
			return // EAGAIN; on EMFILE the next connection retries
		}
		unix.SetsockoptInt(fd, unix.IPPROTO_TCP, unix.TCP_NODELAY, 1)
		ev := unix.EpollEvent{Events: unix.EPOLLIN | unix.EPOLLOUT | unix.EPOLLRDHUP | unix.EPOLLET, Fd: int32(fd)}
		if unix.EpollCtl(l.ep, unix.EPOLL_CTL_ADD, fd, &ev) != nil {
			unix.Close(fd)
			continue
		}
		l.conns[fd] = &conn{fd: fd, l: l}
	}
}

func (l *loop) event(c *conn, ev uint32) {
	if ev&unix.EPOLLERR != 0 {
		l.close(c)
		return
	}
	if ev&unix.EPOLLOUT != 0 && len(c.out) > 0 && !l.flush(c) {
		return
	}
	if ev&(unix.EPOLLIN|unix.EPOLLRDHUP|unix.EPOLLHUP) == 0 {
		return
	}
	for {
		n, err := unix.Read(c.fd, l.buf)
		if err == unix.EINTR {
			continue
		}
		if err == unix.EAGAIN {
			break
		}
		if err != nil {
			l.close(c)
			return
		}
		if n == 0 {
			c.eof = true
			break
		}
		c.in = append(c.in, l.buf[:n]...)
		if len(c.in) > maxHead+maxBody {
			l.close(c)
			return
		}
		if n < len(l.buf) {
			break
		}
	}
	l.serve(c)
}

// serve starts the next buffered request, unless one is in flight.
func (l *loop) serve(c *conn) {
	for !c.busy && !c.closed && len(c.in) > 0 {
		rq, n, bad := parseRequest(c.in)
		if bad {
			c.in, c.eof = nil, true
			c.out = append(c.out, response(400, errJSON("bad request"), true)...)
			if !l.flush(c) {
				return
			}
			break
		}
		if n == 0 {
			break
		}
		c.in = c.in[n:]
		c.busy = true
		go handle(c, rq)
	}
	if len(c.in) == 0 {
		c.in = nil
	}
	if c.eof && !c.busy && len(c.out) == 0 {
		l.close(c)
	}
}

// complete runs on the handler goroutine.
func (c *conn) complete(resp []byte, closeAfter bool) {
	l := c.l
	l.mu.Lock()
	c.resp, c.respClose = resp, closeAfter
	l.done = append(l.done, c)
	wake := len(l.done) == 1
	l.mu.Unlock()
	if wake {
		unix.Write(l.efd, []byte{1, 0, 0, 0, 0, 0, 0, 0})
	}
}

func (l *loop) finish() {
	var b [8]byte
	unix.Read(l.efd, b[:])
	l.mu.Lock()
	done := l.done
	l.done, l.idle = l.idle[:0], done
	l.mu.Unlock()
	for i, c := range done {
		done[i] = nil
		if c.closed {
			continue
		}
		c.busy = false
		if c.respClose {
			c.in, c.eof = nil, true
		}
		if len(c.out) == 0 {
			c.out = c.resp
		} else {
			c.out = append(c.out, c.resp...)
		}
		c.resp = nil
		if l.flush(c) {
			l.serve(c)
		}
	}
}

// flush writes what it can; false means the connection was closed.
func (l *loop) flush(c *conn) bool {
	for len(c.out) > 0 {
		n, err := unix.Write(c.fd, c.out)
		if err == unix.EINTR {
			continue
		}
		if err == unix.EAGAIN {
			return true // EPOLLOUT resumes
		}
		if err != nil {
			l.close(c)
			return false
		}
		c.out = c.out[n:]
	}
	c.out = nil
	if c.eof && !c.busy && len(c.in) == 0 {
		l.close(c)
		return false
	}
	return true
}

func (l *loop) close(c *conn) {
	if c.closed {
		return
	}
	c.closed = true
	delete(l.conns, c.fd)
	unix.Close(c.fd)
	c.in, c.out = nil, nil
}

var crlf, crlf2 = []byte("\r\n"), []byte("\r\n\r\n")

// parseRequest returns n = 0 while the request is incomplete.
func parseRequest(b []byte) (rq *request, n int, bad bool) {
	for bytes.HasPrefix(b[n:], crlf) { // tolerated empty lines before a request
		n += 2
	}
	b = b[n:]
	end := bytes.Index(b, crlf2)
	if end < 0 {
		return nil, 0, len(b) > maxHead
	}
	line, rest, _ := bytes.Cut(b[:end], crlf)
	sp1, sp2 := bytes.IndexByte(line, ' '), bytes.LastIndexByte(line, ' ')
	if sp1 <= 0 || sp2 <= sp1 || !bytes.HasPrefix(line[sp2+1:], []byte("HTTP/1.")) {
		return nil, 0, true
	}
	rq = &request{method: string(line[:sp1]), close: string(line[sp2+1:]) == "HTTP/1.0"}
	path, query, _ := bytes.Cut(line[sp1+1:sp2], []byte{'?'})
	rq.path, rq.query = string(path), string(query)
	clen := 0
	for len(rest) > 0 {
		var h []byte
		h, rest, _ = bytes.Cut(rest, crlf)
		k, v, ok := bytes.Cut(h, []byte{':'})
		if !ok {
			return nil, 0, true
		}
		v = bytes.TrimSpace(v)
		switch {
		case bytes.EqualFold(k, []byte("Content-Length")):
			var err error
			if clen, err = strconv.Atoi(string(v)); err != nil || clen < 0 || clen > maxBody {
				return nil, 0, true
			}
		case bytes.EqualFold(k, []byte("Authorization")):
			rq.auth = string(v)
		case bytes.EqualFold(k, []byte("Connection")):
			if bytes.EqualFold(v, []byte("close")) {
				rq.close = true
			} else if bytes.EqualFold(v, []byte("keep-alive")) {
				rq.close = false
			}
		case bytes.EqualFold(k, []byte("Transfer-Encoding")):
			return nil, 0, true // only Content-Length bodies
		}
	}
	total := end + 4 + clen
	if len(b) < total {
		return nil, 0, false
	}
	rq.body = append([]byte(nil), b[end+4:total]...)
	return rq, n + total, false
}

var statusLine = map[int]string{
	200: "200 OK", 201: "201 Created", 204: "204 No Content", 400: "400 Bad Request", 401: "401 Unauthorized",
	403: "403 Forbidden", 404: "404 Not Found", 422: "422 Unprocessable Entity", 500: "500 Internal Server Error",
}

func response(status int, body []byte, closeAfter bool) []byte {
	b := make([]byte, 0, 100+len(body))
	b = append(b, "HTTP/1.1 "...)
	b = append(b, statusLine[status]...)
	if closeAfter {
		b = append(b, "\r\nConnection: close"...)
	}
	if status == 204 {
		return append(b, "\r\n\r\n"...)
	}
	b = append(b, "\r\nContent-Type: application/json\r\nContent-Length: "...)
	b = strconv.AppendInt(b, int64(len(body)), 10)
	b = append(b, "\r\n\r\n"...)
	return append(b, body...)
}
