//go:build linux

package main

// reactor_linux.go is the HTTP server: a few event loops built directly on
// epoll, serving every client connection without a goroutine per connection.
//
// Threads. EPOLL_LOOPS event loops each own a listening socket (the kernel
// spreads new connections between them with SO_REUSEPORT), an epoll instance,
// and every connection they accepted. Database workers (db.go) run the
// requests. Nothing else touches a loop's state; workers hand finished
// requests back through the loop's completed channel and wake it up with an
// eventfd.
//
// A request's life on one connection:
//
//	accept    The connection joins the loop's table (indexed by fd).
//	read      Bytes arrive. parseWire (wire_http.go) finds a complete request.
//	          A partial one stays buffered on the connection (c.in) until the
//	          rest arrives.
//	frame     The request takes a free slot (reactorJob): its bytes are copied
//	          into the slot, it is classified as a read or a write (api.go),
//	          and it is queued for the database workers (submit).
//	finish    A worker answers it (db.go, api.go) and calls finish, which
//	          renders the response header and hands the slot back to the loop.
//	flush     The loop writes header and body with one sendmsg, continuing
//	          when the socket is writable again if the client reads slowly.
//	next      The slot is freed. The connection goes back to reading: a
//	          request already buffered behind this one (HTTP pipelining) is
//	          served next turn, otherwise it waits until the idle timeout.
//
// Fixed resources. Each loop preallocates its request slots (MAX_INFLIGHT +
// MAX_QUEUED, split between loops), a 4 KB inline buffer per slot, and small
// and large input buffers for requests that arrive in pieces. None of these
// grow with load.
//
// Backpressure. When every slot is busy, a connection is parked instead of
// read: its request waits in the kernel socket buffer until a slot frees, so
// overload shows up as latency rather than errors.
//
// Timeouts. Each connection has one deadline (reading a request, writing a
// response, idling or parked). Every tick the loop closes connections past it.
//
// Shutdown. On SIGTERM the loops stop accepting and close idle connections,
// finish the requests in progress (up to shutdownTimeout), and return.

import (
	"context"
	"encoding/binary"
	"errors"
	"log"
	"net"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/sys/unix"
)

// ---------- configuration and state ----------

// reactorConfig sizes the reactor. All counts are fixed at startup.
type reactorConfig struct {
	host    string
	port    int
	loops   int // event loops (EPOLL_LOOPS)
	workers int // handler goroutines; only the test dispatcher uses them
	active  int // request slots being worked on (MAX_INFLIGHT)
	queued  int // request slots waiting in queues (MAX_QUEUED)
	sockets int // most open client connections
	fdSlots int // size of the per-loop connection tables (indexed by fd)

	readTimeout     time.Duration // to receive a whole request
	writeTimeout    time.Duration // to send a whole response
	idleTimeout     time.Duration // keep-alive between requests
	shutdownTimeout time.Duration // to finish in-flight requests on SIGTERM
}

func reactorConfigFromEnv(cores, active, queued, sockets, fdSlots int) (reactorConfig, error) {
	c := reactorConfig{
		host:            envOr("HOST", "0.0.0.0"),
		active:          active,
		queued:          queued,
		sockets:         sockets,
		fdSlots:         fdSlots,
		readTimeout:     15 * time.Second,
		writeTimeout:    15 * time.Second,
		idleTimeout:     75 * time.Second,
		shutdownTimeout: 10 * time.Second,
	}
	var err error
	c.port, err = envInt("PORT", 3000, 1, 65535)
	if err != nil {
		return c, err
	}
	c.loops, err = envInt("EPOLL_LOOPS", min(4, max(1, cores/4)), 1, 16)
	if err != nil {
		return c, err
	}
	c.loops = min(c.loops, active+queued)
	c.workers, err = envInt("HTTP_WORKERS", min(256, max(32, cores*8)), 1, 1024)
	return c, err
}

// reactorServer is the whole HTTP side: the event loops plus the dispatcher
// they hand requests to.
type reactorServer struct {
	config      reactorConfig
	disp        dispatcher
	loops       []*eventLoop
	active      chan struct{} // slots for requests being worked on (test dispatcher)
	sockets     atomic.Int64  // open client connections, across loops
	outputBytes atomic.Int64  // finished response bytes not yet sent, across loops
	addr        string
}

// dispatcher runs jobs off the event loops. submit must not block; it reports
// false when the job cannot be queued. Every accepted job is eventually passed
// to reactorServer.finish exactly once.
type dispatcher interface {
	start()
	submit(j *reactorJob) bool
	stop()
}

// eventLoop owns a listening socket, an epoll instance, and every connection
// it accepted. Only its own goroutine touches its fields, except completed and
// notified, which workers use to hand finished requests back.
type eventLoop struct {
	server             *reactorServer
	ep, listen, wakeFD int // epoll, listening socket, eventfd for wake-ups
	events             [512]unix.EpollEvent

	// Connections, indexed by file descriptor.
	conns []reactorConn

	// Request slots: a fixed array of jobs and the indexes of the free ones.
	jobs        []reactorJob
	freeJobs    []int
	outstanding int              // slots in use
	completed   chan *reactorJob // finished by workers, waiting to be sent
	notified    atomic.Bool      // a wake-up is already pending on wakeFD

	// Input buffers for requests that arrive in pieces: small ones (smallInputBytes)
	// and a few large ones (maxWireBytes), shared by this loop's connections.
	inputArena, largeArena []byte
	freeInput, freeLarge   []int
	readbuf                [smallInputBytes]byte // scratch for each read

	// Connections with buffered input to read next turn (FIFO ring).
	ready                            []resumeRead
	readyHead, readyTail, readyCount int
	// Connections parked until a request slot frees (FIFO ring).
	waiting                       []resumeRead
	waitHead, waitTail, waitCount int

	// Time, in ms since the loop started.
	started        time.Time
	now, nextSweep int64
	tick           time.Duration // how often deadlines are checked
	stopping       bool
	stopAt         int64
	paused         bool // accepting is paused (socket limit or out of descriptors)
	acceptRetryAt  int64
	listenerClosed bool
	errorFrames    map[int][3][]byte // cached error responses (see error)
	errorSecond    int64
}

// reactorConn is one client connection. A connection holds at most one
// request at a time (c.job); pipelined requests wait in c.in until it is sent.
type reactorConn struct {
	open       bool
	generation uint32 // bumped on every accept, so stale events and jobs are ignored
	events     uint32 // the epoll interest currently set
	deadline   int64  // close the connection at this time (ms)

	in               []byte // received bytes not yet framed into a request
	inputID, largeID int32  // which arena buffer c.in uses, or -1

	job *reactorJob // the request in progress, if any

	out  []byte // a fixed frame to send instead of a job (errors, 100 Continue)
	sent int32  // bytes of out already sent

	closing   bool // close after the current response
	interim   bool // out is a 100 Continue; keep reading the body afterwards
	continued bool // a 100 Continue was already sent for this request
	peerEOF   bool // the client shut down its sending side
	resume    bool // queued in the ready ring
	parked    bool // queued in the waiting ring (no free request slot)
}

// reactorJob is one request slot: the request bytes, its parsed form, its
// database state and its response. Slots are preallocated per event loop.
type reactorJob struct {
	owner      *eventLoop
	slot       int
	fd         int
	generation uint32 // the connection's generation when the request arrived

	input   []byte // this slot's inline copy buffer (jobInputBytes)
	frame   []byte // the complete request bytes (in input, a large buffer, or the heap)
	largeID int    // the large arena buffer frame lives in, or -1
	wire    wireRequest
	req     request
	class   jobClass // read or write queue

	db        dbJob
	enqueued  int64  // monoNow when queued
	abandoned uint32 // atomic: the connection closed before the response

	response    response
	header      [256]byte // the rendered response header
	headerN     int
	sent        int   // bytes of header+body already sent
	completed   bool  // the response is ready to send
	outputBytes int64 // counted against the server-wide output budget

	// Test dispatcher only.
	ctx    context.Context
	cancel context.CancelFunc
	active bool
}

// jobInputBytes is each job's inline request copy; larger frames use the
// connection's large buffer or, rarely, a heap copy.
const jobInputBytes = 4 << 10

// resumeRead names a connection in the ready or waiting ring. The generation
// tells whether the descriptor still belongs to the same connection.
type resumeRead struct {
	fd         int32
	generation uint32
}

var clockStart = time.Now()

func monoNow() int64 { return int64(time.Since(clockStart)) }

// ---------- startup and shutdown ----------

// newReactorServer serves a plain handler (tests).
func newReactorServer(h handler, c reactorConfig) (*reactorServer, error) {
	return newReactorServerWith(c, func(s *reactorServer) dispatcher {
		return &handlerDispatcher{s: s, handler: h, work: make(chan *reactorJob, c.queued)}
	})
}

func newReactorServerWith(c reactorConfig, makeDispatcher func(*reactorServer) dispatcher) (*reactorServer, error) {
	if c.loops < 1 || c.workers < 1 || c.active < 1 || c.queued < 1 || c.sockets < 1 ||
		c.fdSlots < c.sockets || c.readTimeout <= 0 || c.writeTimeout <= 0 || c.idleTimeout <= 0 {
		return nil, errors.New("invalid reactor bounds")
	}
	c.loops = min(c.loops, c.active+c.queued)
	s := &reactorServer{config: c, active: make(chan struct{}, c.active)}
	s.disp = makeDispatcher(s)
	cleanup := func() {
		for _, r := range s.loops {
			r.dispose()
		}
	}
	for i := 0; i < c.loops; i++ {
		fd, port, err := listenSocket(c.host, c.port, c.loops > 1)
		if err != nil {
			cleanup()
			return nil, err
		}
		c.port = port
		r := &eventLoop{server: s, listen: fd, ep: -1, wakeFD: -1, started: time.Now()}
		s.loops = append(s.loops, r)
		r.ep, err = unix.EpollCreate1(unix.EPOLL_CLOEXEC)
		if err != nil {
			cleanup()
			return nil, err
		}
		r.wakeFD, err = unix.Eventfd(0, unix.EFD_NONBLOCK|unix.EFD_CLOEXEC)
		if err != nil {
			cleanup()
			return nil, err
		}
		for _, fd := range []int{r.listen, r.wakeFD} {
			ev := unix.EpollEvent{Events: unix.EPOLLIN, Fd: int32(fd)}
			if err = unix.EpollCtl(r.ep, unix.EPOLL_CTL_ADD, fd, &ev); err != nil {
				cleanup()
				return nil, err
			}
		}
		// Split the request slots evenly between loops, and preallocate
		// everything a loop needs: connection table, rings, slots and buffers.
		jobs := (c.active + c.queued) / c.loops
		if i < (c.active+c.queued)%c.loops {
			jobs++
		}
		r.conns = make([]reactorConn, c.fdSlots)
		r.ready = make([]resumeRead, c.fdSlots*2)
		r.waiting = make([]resumeRead, c.fdSlots*2)
		r.jobs = make([]reactorJob, jobs)
		r.freeJobs = make([]int, jobs)
		r.completed = make(chan *reactorJob, jobs)
		inputCount := max(16, 1024/c.loops)
		largeCount := max(1, 32/c.loops)
		r.inputArena = make([]byte, inputCount*smallInputBytes)
		r.largeArena = make([]byte, largeCount*maxWireBytes)
		r.freeInput = make([]int, inputCount)
		r.freeLarge = make([]int, largeCount)
		for j := range r.freeInput {
			r.freeInput[j] = j
		}
		for j := range r.freeLarge {
			r.freeLarge[j] = j
		}
		arena := make([]byte, jobs*jobInputBytes)
		for j := range r.jobs {
			r.freeJobs[j] = j
			r.jobs[j].owner = r
			r.jobs[j].slot = j
			r.jobs[j].input = arena[j*jobInputBytes : (j+1)*jobInputBytes]
		}
		r.tick = min(time.Second, min(c.readTimeout, min(c.writeTimeout, c.idleTimeout))/2)
		r.tick = max(time.Millisecond, r.tick)
	}
	s.addr = net.JoinHostPort(c.host, strconv.Itoa(c.port))
	return s, nil
}

// Addr is the address the server listens on.
func (s *reactorServer) Addr() string { return s.addr }

// listenSocket opens a non-blocking listening socket, returning its descriptor
// and port (useful when port 0 asked for any free port).
func listenSocket(host string, port int, reuse bool) (int, int, error) {
	addr, err := net.ResolveTCPAddr("tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	if err != nil {
		return -1, 0, err
	}
	family := unix.AF_INET
	var sa unix.Sockaddr
	if ip := addr.IP.To4(); ip != nil {
		a := &unix.SockaddrInet4{Port: port}
		copy(a.Addr[:], ip)
		sa = a
	} else {
		family = unix.AF_INET6
		a := &unix.SockaddrInet6{Port: port}
		copy(a.Addr[:], addr.IP.To16())
		if addr.Zone != "" {
			iface, e := net.InterfaceByName(addr.Zone)
			if e != nil {
				return -1, 0, e
			}
			a.ZoneId = uint32(iface.Index)
		}
		sa = a
	}
	fd, err := unix.Socket(family, unix.SOCK_STREAM|unix.SOCK_NONBLOCK|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return -1, 0, err
	}
	fail := func(e error) (int, int, error) { unix.Close(fd); return -1, 0, e }
	if err = unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_REUSEADDR, 1); err != nil {
		return fail(err)
	}
	if reuse {
		if err = unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_REUSEPORT, 1); err != nil {
			return fail(err)
		}
	}
	if err = unix.Bind(fd, sa); err != nil {
		return fail(err)
	}
	if err = unix.Listen(fd, 65535); err != nil {
		return fail(err)
	}
	if port == 0 {
		bound, e := unix.Getsockname(fd)
		if e != nil {
			return fail(e)
		}
		switch a := bound.(type) {
		case *unix.SockaddrInet4:
			port = a.Port
		case *unix.SockaddrInet6:
			port = a.Port
		}
	}
	return fd, port, nil
}

// Serve runs the event loops and the dispatcher until ctx is cancelled, then
// shuts down: the loops stop accepting, finish in-flight requests (up to
// shutdownTimeout) and return; then the dispatcher stops.
func (s *reactorServer) Serve(ctx context.Context) error {
	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	s.disp.start()
	done := make(chan error, len(s.loops))
	wakeDone := make(chan struct{})
	wakeExited := make(chan struct{})
	go func() {
		defer close(wakeExited)
		select {
		case <-runCtx.Done():
			for _, r := range s.loops {
				r.wake()
			}
		case <-wakeDone:
		}
	}()
	for _, r := range s.loops {
		go func() { done <- r.run(runCtx) }()
	}
	var result error
	for range s.loops {
		if err := <-done; err != nil && result == nil {
			result = err
			cancel()
		}
	}
	s.disp.stop()
	close(wakeDone)
	<-wakeExited
	// A worker may write eventfd just after publishing its final completion. Keep
	// all notification descriptors alive until every worker has actually returned.
	for _, r := range s.loops {
		r.dispose()
	}
	return result
}

// wake interrupts the loop's epoll_wait through its eventfd.
func (r *eventLoop) wake() {
	var b [8]byte
	binary.NativeEndian.PutUint64(b[:], 1)
	for {
		_, e := unix.Write(r.wakeFD, b[:])
		if e == unix.EINTR {
			continue
		}
		return
	}
}

// dispose closes the loop's descriptors once it has stopped.
func (r *eventLoop) dispose() {
	if !r.listenerClosed && r.listen >= 0 {
		unix.Close(r.listen)
		r.listenerClosed = true
	}
	if r.ep >= 0 {
		unix.Close(r.ep)
	}
	if r.wakeFD >= 0 {
		unix.Close(r.wakeFD)
	}
}

// ---------- the event loop ----------

func (r *eventLoop) run(ctx context.Context) error {
	var fatal error
	for {
		if fatal != nil {
			if r.outstanding == 0 {
				return fatal
			}
			j := <-r.completed
			r.complete(j)
			continue
		}
		// Wait for events; don't wait if there is already work to do.
		timeout := int(r.tick / time.Millisecond)
		if len(r.completed) > 0 || r.readyCount > 0 {
			timeout = 0
		}
		n, err := unix.EpollWait(r.ep, r.events[:], timeout)
		if err == unix.EINTR {
			continue
		}
		r.now = time.Since(r.started).Milliseconds()
		if err != nil {
			fatal = err
			r.beginStop(true)
			continue
		}
		if ctx.Err() != nil && !r.stopping {
			r.beginStop(false)
		}
		for i := 0; i < n; i++ {
			ev := r.events[i]
			fd := int(ev.Fd)
			// A worker finished requests: collect them.
			if fd == r.wakeFD {
				var b [8]byte
				for {
					_, e := unix.Read(fd, b[:])
					if e == unix.EINTR {
						continue
					}
					break
				}
				r.notified.Store(false)
				r.drain()
				continue
			}
			// New connections.
			if fd == r.listen {
				if !r.stopping {
					r.accept()
				}
				continue
			}
			if fd < 0 || fd >= len(r.conns) {
				continue
			}
			c := &r.conns[fd]
			if !c.open || c.generation != uint32(ev.Pad) {
				continue
			}
			// A client connection: error, half-close, writable, or readable.
			if ev.Events&(unix.EPOLLERR|unix.EPOLLHUP) != 0 {
				r.close(fd)
				continue
			}
			if c.job != nil && !c.job.completed && ev.Events&unix.EPOLLIN != 0 {
				r.arm(fd, unix.EPOLLRDHUP)
			}
			if ev.Events&unix.EPOLLRDHUP != 0 {
				c.peerEOF = true
				if c.job != nil && !c.job.completed {
					r.arm(fd, 0)
				} else if c.out != nil || c.job != nil {
					r.arm(fd, unix.EPOLLOUT)
				}
			}
			if ev.Events&unix.EPOLLOUT != 0 && (c.out != nil || c.job != nil && c.job.completed) {
				r.flush(fd)
				continue
			}
			if c.open && c.job == nil && c.out == nil && ev.Events&(unix.EPOLLIN|unix.EPOLLRDHUP) != 0 {
				r.read(fd)
			}
		}
		// After the events: send finished responses, serve buffered requests,
		// close connections past their deadline, and handle shutdown.
		r.drain()
		r.resumeReads()
		if r.now >= r.nextSweep {
			r.nextSweep = r.now + r.tick.Milliseconds()
			r.expire()
		}
		if r.stopping {
			if r.outstanding == 0 {
				return nil
			}
			if r.now >= r.stopAt {
				for fd := range r.conns {
					if r.conns[fd].open {
						r.close(fd)
					}
				}
			}
		} else if r.paused && r.now >= r.acceptRetryAt && r.server.sockets.Load() < int64(r.server.config.sockets) {
			r.paused = false
			r.listenEvents(unix.EPOLLIN)
		}
	}
}

// beginStop closes the listener and every idle connection. With force (an
// epoll error) it closes busy connections too.
func (r *eventLoop) beginStop(force bool) {
	if !r.stopping {
		r.stopping = true
		r.stopAt = r.now + r.server.config.shutdownTimeout.Milliseconds()
		r.listenerClosed = true
		unix.EpollCtl(r.ep, unix.EPOLL_CTL_DEL, r.listen, nil)
		unix.Close(r.listen)
	}
	for fd := range r.conns {
		c := &r.conns[fd]
		if c.open && (force || c.job == nil) {
			r.close(fd)
		}
	}
}

// listenEvents sets the epoll interest of the listening socket (0 pauses accepting).
func (r *eventLoop) listenEvents(events uint32) {
	_ = unix.EpollCtl(r.ep, unix.EPOLL_CTL_MOD, r.listen, &unix.EpollEvent{Events: events, Fd: int32(r.listen)})
}

func (r *eventLoop) arm(fd int, events uint32) {
	c := &r.conns[fd]
	if !c.open {
		return
	}
	if c.peerEOF {
		events &^= unix.EPOLLRDHUP
	}
	if c.events == events {
		return
	}
	ev := unix.EpollEvent{Events: events, Fd: int32(fd), Pad: int32(c.generation)}
	if err := unix.EpollCtl(r.ep, unix.EPOLL_CTL_MOD, fd, &ev); err != nil {
		r.close(fd)
	} else {
		c.events = events
	}
}

// ---------- accepting connections ----------

func (r *eventLoop) accept() {
	for range 256 {
		for {
			n := r.server.sockets.Load()
			if n >= int64(r.server.config.sockets) {
				r.paused = true
				r.listenEvents(0)
				return
			}
			if r.server.sockets.CompareAndSwap(n, n+1) {
				break
			}
		}
		fd, _, err := unix.Accept4(r.listen, unix.SOCK_NONBLOCK|unix.SOCK_CLOEXEC)
		if err != nil {
			r.server.sockets.Add(-1)
			if err == unix.EINTR || err == unix.ECONNABORTED {
				continue
			}
			if err == unix.EMFILE || err == unix.ENFILE {
				r.paused = true
				r.acceptRetryAt = r.now + 1000
				r.listenEvents(0)
			}
			return
		}
		if fd >= len(r.conns) {
			unix.Close(fd)
			r.server.sockets.Add(-1)
			continue
		}
		_ = unix.SetsockoptInt(fd, unix.IPPROTO_TCP, unix.TCP_NODELAY, 1)
		_ = unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_KEEPALIVE, 1)
		_ = unix.SetsockoptInt(fd, unix.IPPROTO_TCP, unix.TCP_KEEPIDLE, 60)
		_ = unix.SetsockoptInt(fd, unix.IPPROTO_TCP, unix.TCP_KEEPINTVL, 30)
		_ = unix.SetsockoptInt(fd, unix.IPPROTO_TCP, unix.TCP_KEEPCNT, 3)
		c := &r.conns[fd]
		generation := c.generation + 1
		*c = reactorConn{
			open: true, generation: generation, inputID: -1, largeID: -1,
			deadline: r.now + r.server.config.readTimeout.Milliseconds(),
		}
		c.events = unix.EPOLLIN | unix.EPOLLRDHUP
		ev := unix.EpollEvent{Events: c.events, Fd: int32(fd), Pad: int32(generation)}
		if unix.EpollCtl(r.ep, unix.EPOLL_CTL_ADD, fd, &ev) != nil {
			r.close(fd)
		}
	}
}

// ---------- reading and framing requests ----------

func (r *eventLoop) read(fd int) {
	c := &r.conns[fd]
	if !c.open || c.job != nil || c.out != nil {
		return
	}
	if len(r.freeJobs) == 0 {
		// Every request slot is busy: leave this request in the socket until
		// one frees, so overload becomes latency instead of 503s.
		r.park(fd)
		return
	}
	// A complete request may already be buffered (HTTP pipelining).
	var b []byte
	if len(c.in) > 0 {
		b = c.in
		var wire wireRequest
		n := parseWire(b, &wire)
		if n != 0 {
			r.frame(fd, b, n, wire)
			return
		}
	}
	// Read what the socket has. The common case is a whole request in one read,
	// framed straight from readbuf without buffering.
	n, err := unix.Read(fd, r.readbuf[:])
	if err == unix.EINTR {
		return
	}
	if err == unix.EAGAIN || err == unix.EWOULDBLOCK {
		r.arm(fd, unix.EPOLLIN|unix.EPOLLRDHUP)
		return
	}
	if err != nil {
		r.close(fd)
		return
	}
	if n == 0 {
		if len(c.in) > 0 {
			r.error(fd, 400, true, false)
		} else {
			r.close(fd)
		}
		return
	}
	if len(c.in) == 0 {
		c.deadline = r.now + r.server.config.readTimeout.Milliseconds()
		b = r.readbuf[:n]
	} else {
		if !r.buffer(c, r.readbuf[:n]) {
			r.error(fd, 503, true, false)
			return
		}
		b = c.in
	}
	// Frame a complete request, or keep the partial one buffered and wait.
	var wire wireRequest
	size := parseWire(b, &wire)
	if size != 0 {
		r.frame(fd, b, size, wire)
		return
	}
	if len(c.in) == 0 && !r.buffer(c, b) {
		r.error(fd, 503, true, false)
		return
	}
	if wire.headerReady && wire.expect && !c.continued {
		c.continued = true
		c.interim = true
		c.out = continueFrame
		r.flush(fd)
		return
	}
	r.arm(fd, unix.EPOLLIN|unix.EPOLLRDHUP)
}

func (r *eventLoop) frame(fd int, b []byte, n int, wire wireRequest) {
	c := &r.conns[fd]
	if n < 0 {
		r.error(fd, -n, true, wire.head)
		return
	}
	if len(r.freeJobs) == 0 {
		if !r.consume(c, b, n) {
			r.error(fd, 503, true, wire.head)
			return
		}
		r.error(fd, 503, wire.close, wire.head)
		return
	}
	slot := r.freeJobs[len(r.freeJobs)-1]
	r.freeJobs = r.freeJobs[:len(r.freeJobs)-1]
	j := &r.jobs[slot]
	j.db.reset()
	// Reset the slot but keep its fixed buffers.
	owner, input, db := j.owner, j.input, j.db
	*j = reactorJob{
		owner: owner, input: input, db: db, slot: slot,
		fd: fd, generation: c.generation, largeID: -1, wire: wire,
	}
	j.class = classify(wire.method, wire.target)
	if n <= len(j.input) {
		j.frame = j.input[:n]
		copy(j.frame, b[:n])
		if !r.consume(c, b, n) {
			r.freeJobs = append(r.freeJobs, slot)
			r.error(fd, 503, true, wire.head)
			return
		}
	} else {
		if c.largeID < 0 {
			// A complete frame larger than the inline copy arrived in one read.
			j.frame = append([]byte(nil), b[:n]...)
			if !r.consume(c, b, n) {
				r.freeJobs = append(r.freeJobs, slot)
				r.error(fd, 503, true, wire.head)
				return
			}
			goto queued
		}
		j.largeID = int(c.largeID)
		j.frame = b[:n]
		tail := b[n:]
		c.in = nil
		c.largeID = -1
		c.inputID = -1
		if len(tail) > 0 && !r.buffer(c, tail) {
			r.freeLarge = append(r.freeLarge, j.largeID)
			r.freeJobs = append(r.freeJobs, slot)
			r.error(fd, 503, true, wire.head)
			return
		}
	}
queued:
	j.enqueued = monoNow()
	c.job = j
	c.continued = false
	c.deadline = r.now + 23000
	r.outstanding++
	// Retain existing read interest; disable it only if pipelined bytes arrive
	// while the job runs. Common requests avoid two epoll_ctl syscalls.
	if !r.server.disp.submit(j) {
		j.completed = true
		writeError(&j.response, 503, "server busy")
		j.headerN = len(appendResponseHeader(j.header[:0], &j.response, j.wire.close, j.wire.http10))
		r.flush(fd)
	}
}

// consume drops the first n bytes (the framed request) from the connection's
// input, keeping what follows. false means the remainder could not be buffered.
func (r *eventLoop) consume(c *reactorConn, b []byte, n int) bool {
	tail := b[n:]
	if len(tail) == 0 {
		r.releaseInput(c)
		return true
	}
	if len(c.in) > 0 {
		copy(c.in, tail)
		c.in = c.in[:len(tail)]
		return true
	}
	return r.buffer(c, tail)
}

// buffer appends b to the connection's input, moving it to a small or large
// arena buffer as it grows. false means no buffer was free or the request is too big.
func (r *eventLoop) buffer(c *reactorConn, b []byte) bool {
	if len(b) > maxWireBytes-len(c.in) {
		return false
	}
	if cap(c.in)-len(c.in) < len(b) {
		var next []byte
		id := -1
		large := -1
		if len(c.in)+len(b) <= smallInputBytes && len(r.freeInput) > 0 {
			id = r.freeInput[len(r.freeInput)-1]
			r.freeInput = r.freeInput[:len(r.freeInput)-1]
			next = r.inputArena[id*smallInputBytes : (id+1)*smallInputBytes]
		}
		if next == nil && len(r.freeLarge) > 0 {
			large = r.freeLarge[len(r.freeLarge)-1]
			r.freeLarge = r.freeLarge[:len(r.freeLarge)-1]
			next = r.largeArena[large*maxWireBytes : (large+1)*maxWireBytes]
		}
		if next == nil {
			return false
		}
		n := copy(next, c.in)
		r.releaseInput(c)
		c.in = next[:n]
		c.inputID = int32(id)
		c.largeID = int32(large)
	}
	c.in = append(c.in, b...)
	return true
}

// releaseInput returns a connection's input buffer to the arena.
func (r *eventLoop) releaseInput(c *reactorConn) {
	if c.inputID >= 0 {
		r.freeInput = append(r.freeInput, int(c.inputID))
	}
	if c.largeID >= 0 {
		r.freeLarge = append(r.freeLarge, int(c.largeID))
	}
	c.in = nil
	c.inputID = -1
	c.largeID = -1
}

// parseJob fills j.req from the job's frame, or sets a 400 response.
func parseJob(j *reactorJob) bool {
	var wire wireRequest
	if parseWire(j.frame, &wire) <= 0 {
		writeError(&j.response, 400, "invalid request")
		j.wire.close = true
		return false
	}
	j.req = request{authHeader: wire.auth, authCount: wire.authCount, body: wire.body}
	j.req.setTarget(wire.method, wire.target)
	if wire.chunked {
		j.req.body = decodeChunks(wire.body)
	}
	return true
}

// ---------- request slots and backpressure ----------
//
// A request needs a free slot. When every slot is busy, read parks the
// connection: it is not read (the request waits in the kernel socket buffer)
// until releaseJob frees a slot and unparks the oldest parked connection.

// releaseJob frees a request slot once its response is sent (or abandoned) and
// hands the slot to the longest-parked connection.
func (r *eventLoop) releaseJob(j *reactorJob) {
	if j.largeID >= 0 {
		r.freeLarge = append(r.freeLarge, j.largeID)
		j.largeID = -1
	}
	if j.active {
		<-r.server.active
		j.active = false
	}
	if j.outputBytes != 0 {
		r.server.outputBytes.Add(-j.outputBytes)
		j.outputBytes = 0
	}
	j.response = response{}
	j.req = request{}
	j.frame = nil
	j.ctx = nil
	j.cancel = nil
	r.freeJobs = append(r.freeJobs, j.slot)
	r.outstanding--
	r.unparkOne()
}

// parkTimeout bounds how long a parked connection may wait for a request slot,
// matching the database queue timeout.
const parkTimeout = 30 * time.Second

// park stops reading fd until unparkOne hands it a free request slot.
func (r *eventLoop) park(fd int) {
	c := &r.conns[fd]
	if c.parked {
		return
	}
	if r.waitCount == len(r.waiting) {
		r.close(fd)
		return
	}
	c.parked = true
	r.arm(fd, 0) // errors and hangups are still reported
	c.deadline = max(c.deadline, r.now+parkTimeout.Milliseconds())
	r.waiting[r.waitTail] = resumeRead{int32(fd), c.generation}
	r.waitTail = (r.waitTail + 1) % len(r.waiting)
	r.waitCount++
}

// unparkOne schedules the longest-waiting parked connection, oldest first.
func (r *eventLoop) unparkOne() {
	for r.waitCount > 0 {
		e := r.waiting[r.waitHead]
		r.waitHead = (r.waitHead + 1) % len(r.waiting)
		r.waitCount--
		c := &r.conns[e.fd]
		if !c.open || c.generation != e.generation || !c.parked {
			continue // closed while parked
		}
		c.parked = false
		r.scheduleRead(int(e.fd))
		return
	}
}

// ---------- responses ----------
//
// Workers call finish from their own goroutines. The loop picks finished
// requests up in drain/complete and writes them out in flush.

// finish accounts the response, renders its header and hands the job back to
// its event loop. Called exactly once per accepted job, from any goroutine.
func (s *reactorServer) finish(j *reactorJob) {
	// Bound completed response bytes held by slow peers independently of sockets.
	size := int64(len(j.response.body))
	for {
		n := s.outputBytes.Load()
		if size > 16<<20 || n+size > 256<<20 {
			writeError(&j.response, 503, "server busy")
			size = int64(len(j.response.body))
		}
		if s.outputBytes.CompareAndSwap(n, n+size) {
			j.outputBytes = size
			break
		}
	}
	header := appendResponseHeader(j.header[:0], &j.response, j.wire.close, j.wire.http10)
	j.headerN = len(header)
	owner := j.owner
	owner.completed <- j
	if owner.notified.CompareAndSwap(false, true) {
		owner.wake()
	}
}

// drain completes requests that workers have finished, up to 512 per turn.
func (r *eventLoop) drain() {
	for range 512 {
		select {
		case j := <-r.completed:
			r.complete(j)
		default:
			return
		}
	}
}

// complete starts sending a finished request's response, or frees its slot if
// the connection went away meanwhile.
func (r *eventLoop) complete(j *reactorJob) {
	j.completed = true
	if j.largeID >= 0 {
		r.freeLarge = append(r.freeLarge, j.largeID)
		j.largeID = -1
	}
	j.frame = nil
	j.req = request{}
	c := &r.conns[j.fd]
	if !c.open || c.generation != j.generation || c.job != j {
		r.releaseJob(j)
		return
	}
	c.deadline = r.now + r.server.config.writeTimeout.Milliseconds()
	r.flush(j.fd)
}

// flush sends as much of the current response (a job's, or a fixed frame) as
// the socket takes. When done it frees the slot and goes back to reading: the
// next buffered request, or waiting for one until the idle timeout.
func (r *eventLoop) flush(fd int) {
	c := &r.conns[fd]
	if !c.open {
		return
	}
	var parts [2][]byte
	var nTotal, sent int
	if c.out != nil {
		parts[0] = c.out[int(c.sent):]
		nTotal = len(c.out)
		sent = int(c.sent)
	} else {
		j := c.job
		if j == nil || !j.completed {
			return
		}
		sent = j.sent
		body := j.response.body
		if j.wire.head {
			body = nil
		}
		nTotal = j.headerN + len(body)
		if sent < j.headerN {
			parts[0] = j.header[sent:j.headerN]
			parts[1] = body
		} else {
			parts[0] = body[sent-j.headerN:]
		}
	}
	var n int
	var err error
	for {
		n, err = unix.SendmsgBuffers(fd, parts[:], nil, nil, unix.MSG_NOSIGNAL)
		if err == unix.EINTR {
			continue
		}
		break
	}
	if n > 0 {
		sent += n
	}
	if c.out != nil {
		c.sent = int32(sent)
	} else {
		c.job.sent = sent
	}
	if err != nil && err != unix.EAGAIN && err != unix.EWOULDBLOCK {
		r.close(fd)
		return
	}
	if sent < nTotal {
		r.arm(fd, unix.EPOLLOUT|unix.EPOLLRDHUP)
		return
	}
	if c.out != nil {
		c.out = nil
		c.sent = 0
		if c.interim {
			c.interim = false
			r.arm(fd, unix.EPOLLIN|unix.EPOLLRDHUP)
			return
		}
	} else {
		j := c.job
		c.closing = j.wire.close
		c.job = nil
		r.releaseJob(j)
	}
	if c.closing || r.stopping {
		r.close(fd)
		return
	}
	if len(c.in) > 0 || c.peerEOF {
		c.deadline = r.now + r.server.config.readTimeout.Milliseconds()
		r.scheduleRead(fd)
	} else {
		c.deadline = r.now + r.server.config.idleTimeout.Milliseconds()
		r.arm(fd, unix.EPOLLIN|unix.EPOLLRDHUP)
	}
}

var continueFrame = []byte("HTTP/1.1 100 Continue\r\n\r\n")

// buildErrorFrames renders the fixed error responses, each in three forms:
// keep-alive, closing, and closing without a body (HEAD).
func buildErrorFrames() map[int][3][]byte {
	m := make(map[int][3][]byte)
	for _, status := range []int{400, 413, 417, 503} {
		var a [3][]byte
		for i := range a {
			w := response{}
			msg := "invalid request"
			if status == 503 {
				msg = "server busy"
			}
			writeError(&w, status, msg)
			a[i] = appendResponseHeader(nil, &w, i != 0, false)
			if i != 2 {
				a[i] = append(a[i], w.body...)
			}
		}
		m[status] = a
	}
	return m
}

// error sends a fixed error response on a connection, closing it if asked.
func (r *eventLoop) error(fd, status int, close, head bool) {
	c := &r.conns[fd]
	if close || head {
		r.releaseInput(c)
	}
	c.interim = false
	c.continued = false
	c.closing = close
	c.sent = 0
	i := 0
	if close {
		i = 1
	}
	if head {
		i = 2
		c.closing = true
	}
	// Cached frames stay immutable while slow peers may still reference them.
	// Refresh Date at most once per second, allocating only on this error path.
	if r.errorFrames == nil || r.errorSecond != r.now/1000 {
		r.errorFrames = buildErrorFrames()
		r.errorSecond = r.now / 1000
	}
	c.out = r.errorFrames[status][i]
	c.deadline = r.now + r.server.config.writeTimeout.Milliseconds()
	r.flush(fd)
}

// ---------- serving buffered requests ----------

// Buffered pipeline tails do not imply kernel readability. Schedule them
// explicitly, with a per-turn budget, instead of recursively serving pipelines.
func (r *eventLoop) scheduleRead(fd int) {
	c := &r.conns[fd]
	if c.resume {
		return
	}
	if r.readyCount == len(r.ready) {
		r.close(fd)
		return
	}
	c.resume = true
	r.ready[r.readyTail] = resumeRead{int32(fd), c.generation}
	r.readyTail = (r.readyTail + 1) % len(r.ready)
	r.readyCount++
}

// resumeReads serves up to 64 connections from the ready ring per turn.
func (r *eventLoop) resumeReads() {
	for range min(64, r.readyCount) {
		e := r.ready[r.readyHead]
		r.readyHead = (r.readyHead + 1) % len(r.ready)
		r.readyCount--
		c := &r.conns[e.fd]
		if !c.open || c.generation != e.generation {
			continue
		}
		c.resume = false
		if c.job == nil && c.out == nil {
			r.read(int(e.fd))
		}
	}
}

// ---------- closing and timeouts ----------

// close closes a connection. A request still being worked on is marked
// abandoned; its slot is freed when the worker hands it back.
func (r *eventLoop) close(fd int) {
	c := &r.conns[fd]
	if !c.open {
		return
	}
	unix.EpollCtl(r.ep, unix.EPOLL_CTL_DEL, fd, nil)
	unix.Close(fd)
	r.releaseInput(c)
	if j := c.job; j != nil {
		atomic.StoreUint32(&j.abandoned, 1)
		if j.cancel != nil {
			j.cancel()
		}
		if j.completed {
			r.releaseJob(j)
		}
	}
	generation := c.generation
	*c = reactorConn{generation: generation}
	r.server.sockets.Add(-1)
}

// expire closes every connection past its deadline (read, write, idle or parked).
func (r *eventLoop) expire() {
	for fd := range r.conns {
		c := &r.conns[fd]
		if c.open && r.now >= c.deadline {
			r.close(fd)
		}
	}
}

// ---------- test dispatcher ----------

// handlerDispatcher runs a synchronous handler on a fixed worker pool with one
// shared queue. Tests use it; production uses the database dispatcher.
type handlerDispatcher struct {
	s       *reactorServer
	handler handler
	work    chan *reactorJob
	workers sync.WaitGroup
}

// Test dispatcher: start, stop, submit and execute run a plain handler on a
// fixed pool of goroutines with one queue.
func (d *handlerDispatcher) start() {
	for range d.s.config.workers {
		d.workers.Go(func() {
			for j := range d.work {
				d.execute(j)
				d.s.finish(j)
			}
		})
	}
}

func (d *handlerDispatcher) stop() { close(d.work); d.workers.Wait() }

func (d *handlerDispatcher) submit(j *reactorJob) bool {
	j.ctx, j.cancel = context.WithTimeout(context.Background(), 7*time.Second)
	select {
	case d.work <- j:
		return true
	default:
		j.cancel()
		return false
	}
}

func (d *handlerDispatcher) execute(j *reactorJob) {
	defer j.cancel()
	defer func() {
		if p := recover(); p != nil {
			log.Printf("handler panic: %v", p)
			writeError(&j.response, 500, "internal error")
		}
	}()
	if j.ctx.Err() != nil {
		writeError(&j.response, 503, "server busy")
		return
	}
	select {
	case d.s.active <- struct{}{}:
		j.active = true
	case <-j.ctx.Done():
		writeError(&j.response, 503, "server busy")
		return
	}
	if !parseJob(j) {
		return
	}
	j.req.ctx = j.ctx
	d.handler(&j.response, &j.req)
}
