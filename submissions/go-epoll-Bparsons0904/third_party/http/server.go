// Package http is an HTTP/1.1 server built directly on epoll, for many mostly
// idle keep-alive connections and near-zero work and allocations per request.
//
// The server runs a fixed number of event loops, each with its own
// SO_REUSEPORT listener, epoll instance and eventfd, on goroutines locked to
// their threads. A loop reads every ready connection into one scratch buffer,
// parses the requests in place and calls the Handler, which appends the
// response body to a reused buffer. The responses of one connection's
// requests go out in one send. A connection holds no buffer while idle: only a
// partial request or a partly sent response borrows one from the loop's pool.
//
// A handler that must wait (for the database) calls Request.Defer, copies
// what the work needs into the Op, and returns. Once per turn each loop hands
// the Ops deferred during it to Config.Batcher; any goroutine later fills
// in each Op and calls Op.Done. The connection takes no further requests until
// then, so responses stay in order. Config.Handback chooses who writes the
// deferred response.
package http

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
	"runtime"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

// Handler serves one request. Unless it calls req.Defer, it sets resp.Status
// (200 if left alone) and appends the body to resp.Body before returning.
// Every byte slice in req, and resp itself, is valid only during the call.
type Handler func(req *Request, resp *Response)

// Request is a parsed request. Its slices point into the loop's buffers.
type Request struct {
	Method []byte
	Path   []byte // the target before '?', still percent-encoded
	Query  []byte // the target after '?', nil if none
	Auth   []byte // the first Authorization header's value, nil if none
	Body   []byte

	keepAlive bool
	http10    bool
	head      bool
	expect    bool

	l       *loop
	slot    int32
	op      *Op
	refused bool // Defer found no free Op
}

// KeepAlive reports whether the connection stays open after this request.
func (r *Request) KeepAlive() bool { return r.keepAlive }

// Response is a synchronous response. Body starts empty with reusable
// capacity; a handler may also set it to its own slice, which is then copied.
type Response struct {
	Status int
	Body   []byte
}

// Handback selects how a deferred response gets back to its connection.
type Handback uint8

const (
	// HandbackQueue: Done queues the Op to its loop, waking it only if it
	// sleeps, and the loop sends the response.
	HandbackQueue Handback = iota
	// HandbackDirect: Done sends the response itself from the caller's
	// goroutine when nothing is queued ahead of it on the connection, then
	// tells the loop without waking it, unless the connection has more to do.
	HandbackDirect
)

func (h Handback) String() string {
	if h == HandbackDirect {
		return "direct"
	}
	return "queue"
}

// Wait selects how a loop with nothing to do waits for work.
type Wait uint8

const (
	// WaitEpoll: the loop goroutine is locked to its thread and blocks in
	// epoll_wait, holding that thread while idle.
	WaitEpoll Wait = iota
	// WaitNetpoll: the loop checks its epoll instance without blocking and,
	// when nothing is ready, parks on it through Go's netpoller, so an idle
	// loop holds no thread and its P runs other goroutines.
	WaitNetpoll
)

func (w Wait) String() string {
	if w == WaitNetpoll {
		return "netpoll"
	}
	return "epoll"
}

// ParkWaitBuckets is the number of Stats.ParkWait buckets: up to 2^15 ms.
const ParkWaitBuckets = 16

// DefaultIdleTimeout is Config.IdleTimeout's default.
const DefaultIdleTimeout = 120 * time.Second

// Config configures a Server. Zero fields take the defaults shown.
type Config struct {
	Addr       string // host:port with a literal IP; "" or no host means all interfaces
	Loops      int    // event loops; min(2, GOMAXPROCS): fewer loops cost less per request at load
	MaxConns   int    // open connections across loops; RLIMIT_NOFILE minus 256
	OpsPerLoop int    // deferred requests in flight per loop; 1024
	KeepBytes  int    // preallocated Op.Keep space per Op; 1024
	Handback   Handback
	Wait       Wait

	IdleTimeout         time.Duration // between requests; 120 s (idle keep-alive clients may pause over a minute)
	FirstRequestTimeout time.Duration // from accept to the first byte; 15 s (clients normally send at once)
	ReadTimeout         time.Duration // to receive the rest of a partial request; 15 s
	WriteTimeout        time.Duration // to send the rest of a response; 15 s

	Handler Handler

	// Batcher receives the Ops deferred during each loop turn. Required if
	// the handler defers.
	Batcher Batcher
}

// Batcher takes deferred requests to whatever completes them.
type Batcher interface {
	// SubmitBatch receives the Ops deferred during one loop turn, in one call
	// at the end of the turn, on the loop's goroutine. It must not block. The
	// slice is valid only during the call; the Ops are the callee's until it
	// calls Done on each, in any order, from any goroutine.
	SubmitBatch(ops []*Op)
}

// Server is an HTTP/1.1 server. Create it with New, run it with Serve, stop it
// with Close.
type Server struct {
	cfg      Config
	addr     string
	loops    []*loop
	maxConns int64
	conns    atomic.Int64
	stopping atomic.Bool
	serving  atomic.Bool
}

// New validates cfg, opens the listeners and prepares the loops.
func New(cfg Config) (*Server, error) {
	if cfg.Handler == nil {
		return nil, errors.New("http: no handler")
	}
	if cfg.Loops <= 0 {
		cfg.Loops = min(2, runtime.GOMAXPROCS(0))
	}
	if cfg.OpsPerLoop <= 0 {
		cfg.OpsPerLoop = 1024
	}
	if cfg.KeepBytes <= 0 {
		cfg.KeepBytes = 1024
	}
	if cfg.IdleTimeout <= 0 {
		cfg.IdleTimeout = DefaultIdleTimeout
	}
	if cfg.FirstRequestTimeout <= 0 {
		cfg.FirstRequestTimeout = 15 * time.Second
	}
	if cfg.ReadTimeout <= 0 {
		cfg.ReadTimeout = 15 * time.Second
	}
	if cfg.WriteTimeout <= 0 {
		cfg.WriteTimeout = 15 * time.Second
	}
	for _, d := range []time.Duration{cfg.IdleTimeout, cfg.FirstRequestTimeout, cfg.ReadTimeout, cfg.WriteTimeout} {
		if d > maxTimeout*time.Second {
			return nil, fmt.Errorf("http: timeouts must be at most %d s", maxTimeout)
		}
	}
	var lim unix.Rlimit
	if err := unix.Getrlimit(unix.RLIMIT_NOFILE, &lim); err != nil {
		return nil, err
	}
	fdLimit := int(min(lim.Cur, 1<<30)) - 256
	if cfg.MaxConns <= 0 || cfg.MaxConns > fdLimit {
		cfg.MaxConns = max(fdLimit, 1)
	}

	s := &Server{cfg: cfg, maxConns: int64(cfg.MaxConns)}
	sa, err := resolve(cfg.Addr)
	if err != nil {
		return nil, err
	}
	fds, err := listenAll(sa, cfg.Loops)
	if err != nil {
		return nil, err
	}
	for i, fd := range fds {
		l, err := newLoop(s, i, fd)
		s.loops = append(s.loops, l)
		if err != nil {
			for _, l := range s.loops {
				l.closeFDs()
			}
			for _, fd := range fds {
				_ = unix.Close(fd)
			}
			return nil, err
		}
	}
	s.addr = net.JoinHostPort(sa.Addr().String(), strconv.Itoa(int(sa.Port())))
	return s, nil
}

// Addr is the address the server listens on.
func (s *Server) Addr() string { return s.addr }

// Config returns the configuration in effect, defaults filled in.
func (s *Server) Config() Config { return s.cfg }

// Ops is the number of Ops across loops; Op.ID is below it.
func (s *Server) Ops() int { return s.cfg.Loops * s.cfg.OpsPerLoop }

// Serve runs the loops until Close, then returns once they have finished their
// requests (or after 5 s). An Op still out then is orphaned: its
// Done closes the connection instead of answering.
func (s *Server) Serve() error {
	if !s.serving.CompareAndSwap(false, true) {
		return errors.New("http: Serve called twice")
	}
	var wg sync.WaitGroup
	errs := make([]error, len(s.loops))
	for i, l := range s.loops {
		wg.Go(func() {
			errs[i] = l.run()
			if errs[i] != nil {
				s.Close()
			}
		})
	}
	wg.Wait()
	for _, l := range s.loops {
		l.closeFDs()
	}
	return errors.Join(errs...)
}

// Close makes Serve stop accepting, finish the requests in flight and return.
func (s *Server) Close() {
	if s.stopping.CompareAndSwap(false, true) {
		for _, l := range s.loops {
			l.signal()
		}
	}
}

// Stats is a snapshot of the server's counters, summed over loops.
type Stats struct {
	Requests    uint64 // requests served (handlers called)
	Conns       int64  // open connections
	OpsInFlight uint64 // deferred requests not yet finished
	Timeouts    uint64 // connections closed by a timeout
	Panics      uint64 // handler panics (answered 500)
	Parks       uint64 // times a request found every Op in flight and waited (it is parsed again for each)
	// ParkWait[i] counts requests that waited for an Op under 2^i ms (i = 0:
	// under 1 ms), the last bucket also everything longer.
	ParkWait [ParkWaitBuckets]uint64

	EpollWaits uint64 // epoll_wait calls
	Events     uint64 // events they returned (wake-ups and listeners included)
	Wakes      uint64 // eventfd writes by completers to wake a sleeping loop
	Sends      uint64 // send/sendmsg calls, the loops' and completers' (HandbackDirect)
	Reads      uint64 // read calls, EAGAIN included
}

// Stats collects the loops' counters. Loops count in plain fields, so Stats
// wakes each one to publish a copy and waits for it (up to 100 ms; a loop
// that does not answer in time contributes its previous copy).
func (s *Server) Stats() Stats {
	running := s.serving.Load() && !s.stopping.Load()
	want := make([]uint64, len(s.loops))
	for i, l := range s.loops {
		want[i] = l.shared.snapReq.Add(1)
		if running {
			l.signal()
		}
	}
	deadline := time.Now().Add(100 * time.Millisecond)
	st := Stats{Conns: s.conns.Load()}
	for i, l := range s.loops {
		for running && l.shared.snapDone.Load() < want[i] && time.Now().Before(deadline) {
			time.Sleep(50 * time.Microsecond)
		}
		var c counters
		dst := (*[len(l.shared.snap)]uint64)(unsafe.Pointer(&c))
		for j := range dst {
			dst[j] = l.shared.snap[j].Load()
		}
		st.Requests += c.requests
		st.OpsInFlight += c.opsInFlight
		st.Timeouts += c.timeouts
		st.Panics += c.panics
		st.Parks += c.parks
		for i, n := range c.parkWait {
			st.ParkWait[i] += n
		}
		st.EpollWaits += c.epollWaits
		st.Events += c.events
		st.Reads += c.reads
		st.Sends += c.sends + l.shared.directSends.Load()
		st.Wakes += l.shared.wakes.Load()
	}
	return st
}

// closeFDs closes the loop's epoll and eventfd descriptors, once. Other
// goroutines read efd, so the fields keep their values.
func (l *loop) closeFDs() {
	if l.closed.Swap(true) {
		return
	}
	// A signal that saw closed still false may be about to write efd: wait it
	// out, so the write never lands in a reused descriptor. Signals that start
	// now see closed and skip the write.
	for l.shared.signalling.Load() != 0 {
		runtime.Gosched()
	}
	if l.epFile != nil {
		_ = l.epFile.Close() // the netpoller's registration goes with it
	} else if l.epfd >= 0 {
		_ = unix.Close(l.epfd)
	}
	if l.efd >= 0 {
		_ = unix.Close(l.efd)
	}
}

func resolve(addr string) (netip.AddrPort, error) {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return netip.AddrPort{}, err
	}
	p, err := strconv.ParseUint(port, 10, 16)
	if err != nil {
		return netip.AddrPort{}, fmt.Errorf("http: bad port in %q", addr)
	}
	ip := netip.IPv4Unspecified()
	if host != "" {
		if ip, err = netip.ParseAddr(host); err != nil {
			return netip.AddrPort{}, fmt.Errorf("http: host must be a literal IP: %w", err)
		}
	}
	return netip.AddrPortFrom(ip.Unmap(), uint16(p)), nil
}

// listenAll opens n listeners on addr sharing the port with SO_REUSEPORT, so
// the kernel spreads connections between loops. SO_REUSEPORT would also let
// them join another process's listeners on that port, so a probe socket
// without it first checks that the port is free (and picks one for port 0).
func listenAll(addr netip.AddrPort, n int) ([]int, error) {
	probe, port, err := listenSocket(addr, false, false)
	if err != nil {
		return nil, err
	}
	addr = netip.AddrPortFrom(addr.Addr(), port)
	_ = unix.Close(probe)
	fds := make([]int, 0, n)
	for range n {
		fd, _, err := listenSocket(addr, true, true)
		if err != nil {
			for _, fd := range fds {
				_ = unix.Close(fd)
			}
			return nil, err
		}
		fds = append(fds, fd)
	}
	return fds, nil
}

func listenSocket(addr netip.AddrPort, reusePort, listen bool) (int, uint16, error) {
	family := unix.AF_INET
	var sa unix.Sockaddr = &unix.SockaddrInet4{Port: int(addr.Port()), Addr: addr.Addr().As4()}
	if addr.Addr().Is6() {
		family = unix.AF_INET6
		sa = &unix.SockaddrInet6{Port: int(addr.Port()), Addr: addr.Addr().As16()}
	}
	fd, err := unix.Socket(family, unix.SOCK_STREAM|unix.SOCK_NONBLOCK|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return -1, 0, err
	}
	fail := func(op string, err error) (int, uint16, error) {
		_ = unix.Close(fd)
		return -1, 0, fmt.Errorf("http: %s %s: %w", op, addr, err)
	}
	if err = unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_REUSEADDR, 1); err != nil {
		return fail("SO_REUSEADDR", err)
	}
	if reusePort {
		if err = unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_REUSEPORT, 1); err != nil {
			return fail("SO_REUSEPORT", err)
		}
	}
	if err = unix.Bind(fd, sa); err != nil {
		return fail("bind", err)
	}
	if listen {
		if err = unix.Listen(fd, 65535); err != nil {
			return fail("listen", err)
		}
	}
	bound, err := unix.Getsockname(fd)
	if err != nil {
		return fail("getsockname", err)
	}
	var port int
	switch a := bound.(type) {
	case *unix.SockaddrInet4:
		port = a.Port
	case *unix.SockaddrInet6:
		port = a.Port
	}
	return fd, uint16(port), nil
}
