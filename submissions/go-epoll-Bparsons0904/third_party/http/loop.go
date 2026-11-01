package http

import (
	"fmt"
	"log"
	"math/bits"
	"os"
	"runtime"
	"runtime/debug"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

const (
	scratchSize = 64 << 10 // per-loop read buffer
	maxSegs     = 64       // response segments coalesced into one send
	maxReads    = 8        // reads per connection per turn before others get theirs
	maxInBytes  = 32 << 20 // input buffer bytes per loop past which partial requests may not grow (503)
	acceptBatch = 64       // accepts per listener event
	tickMillis  = 1000     // epoll_wait timeout: the timing wheel's resolution
	lingerSec   = 1        // lingering after an error response: at most this long (plus up to a second)
	lingerBytes = 64 << 10 // and at most this much input discarded

	// Special epoll data values; connections use their slot (>= 0).
	evWake   = -1
	evListen = -2

	connEvents = unix.EPOLLIN | unix.EPOLLOUT | unix.EPOLLRDHUP | unix.EPOLLET
)

// loop is one event loop: a listener, an epoll instance, the connections it
// accepted and the Ops of their deferred requests. Only its goroutine touches
// it, except the completion queue, sleeping and the stats snapshot.
type loop struct {
	s        *Server
	id       int
	handler  Handler
	handback Handback
	epfd     int
	lfd      int
	efd      int // eventfd that wakes epoll_wait; edge-triggered, so never read
	events   [256]unix.EpollEvent

	// WaitNetpoll: epfd registered with Go's netpoller, and the poll that
	// RawConn.Read retries each time the netpoller reports epfd readable.
	epFile  *os.File
	epRaw   syscall.RawConn
	poll    func(uintptr) bool
	polled  int
	pollErr error

	// Connections, by slot. The table grows by chunks and holds no pointers.
	chunks    [][]conn
	freeSlots []int32
	pool      pool

	// Time in whole seconds since the loop started (from 1), and timeouts.
	start             time.Time
	now, ticked       uint32
	idleSec, firstSec uint32
	readSec, writeSec uint32
	wheel             [wheelSize]int32

	// Per-turn scratch: reads land in scratch, and responses rendered into hdrs
	// and body wait in segs until the connection's data is processed.
	scratch []byte
	inBytes int // held by input buffers: bounded by maxInBytes for growth
	req     Request
	resp    Response
	hdrs    []byte
	body    []byte
	segs    [maxSegs][]byte
	nseg    int
	iov     [maxSegs]unix.Iovec
	msg     unix.Msghdr

	ops     []Op
	freeOps []int32
	batch   []*Op // deferred this turn, for the Batcher
	parked  fifo  // connections whose request waits for a free Op
	ready   fifo  // connections with work left after their turn
	// Connections let go from parked and not yet driven: each may take an Op,
	// so no more are let go than there are free Ops.
	unparking int

	acceptPaused bool
	stopping     bool
	stopAt       uint32

	// Counters, plain: only the loop writes them. Stats asks the loop to
	// publish a copy (see publishStats).
	count    counters
	snapSeen uint64

	// Shared with other goroutines.
	done     atomic.Pointer[Op] // completion queue (see push)
	sleeping atomic.Bool        // in or about to enter epoll_wait
	parkWait atomic.Bool        // connections are parked: a freed Op must reach the loop soon
	closed   atomic.Bool        // efd is closed
	shared   sharedStats
}

type counters struct {
	requests, timeouts, opsInFlight          uint64
	epollWaits, events, reads, sends, panics uint64
	parks                                    uint64
	parkWait                                 [ParkWaitBuckets]uint64
}

// sharedStats is what other goroutines read or write: the published counters,
// and the counts that completers make themselves.
type sharedStats struct {
	_           [64]byte // off the cache line of the loop's own fields
	snapReq     atomic.Uint64
	snapDone    atomic.Uint64
	snap        [unsafe.Sizeof(counters{}) / 8]atomic.Uint64
	wakes       atomic.Uint64 // eventfd writes, by completers
	directSends atomic.Uint64 // sends by completers under HandbackDirect
	signalling  atomic.Int32  // eventfd writes under way (see signal)
}

// publishStats copies the counters for Stats when it asked for them.
func (l *loop) publishStats(force bool) {
	r := l.shared.snapReq.Load()
	if r == l.snapSeen && !force {
		return
	}
	l.count.opsInFlight = uint64(len(l.ops) - len(l.freeOps))
	src := (*[len(l.shared.snap)]uint64)(unsafe.Pointer(&l.count))
	for i := range src {
		l.shared.snap[i].Store(src[i])
	}
	l.snapSeen = r
	l.shared.snapDone.Store(r)
}

func newLoop(s *Server, id, lfd int) (*loop, error) {
	cfg := &s.cfg
	l := &loop{
		s: s, id: id, handler: cfg.Handler, handback: cfg.Handback,
		epfd: -1, lfd: lfd, efd: -1,
		start: time.Now(), now: 1, ticked: 1,
		idleSec:  seconds(cfg.IdleTimeout),
		firstSec: seconds(cfg.FirstRequestTimeout),
		readSec:  seconds(cfg.ReadTimeout),
		writeSec: seconds(cfg.WriteTimeout),
		scratch:  make([]byte, scratchSize),
		hdrs:     make([]byte, 0, maxSegs/2*hdrMax),
		body:     make([]byte, 0, 64<<10),
		ops:      make([]Op, cfg.OpsPerLoop),
		batch:    make([]*Op, 0, cfg.OpsPerLoop),
	}
	for i := range l.wheel {
		l.wheel[i] = -1
	}
	l.freeOps = make([]int32, 0, len(l.ops))
	slab := make([]byte, len(l.ops)*cfg.KeepBytes)
	for i := len(l.ops) - 1; i >= 0; i-- {
		op := &l.ops[i]
		op.l, op.idx = l, int32(i)
		op.slab = slab[i*cfg.KeepBytes : i*cfg.KeepBytes : (i+1)*cfg.KeepBytes]
		l.freeOps = append(l.freeOps, int32(i))
	}
	var err error
	if l.epfd, err = unix.EpollCreate1(unix.EPOLL_CLOEXEC); err != nil {
		return l, err
	}
	if l.efd, err = unix.Eventfd(0, unix.EFD_NONBLOCK|unix.EFD_CLOEXEC); err != nil {
		return l, err
	}
	if err = unix.EpollCtl(l.epfd, unix.EPOLL_CTL_ADD, l.efd, &unix.EpollEvent{Events: unix.EPOLLIN | unix.EPOLLET, Fd: evWake}); err != nil {
		return l, err
	}
	if err = unix.EpollCtl(l.epfd, unix.EPOLL_CTL_ADD, l.lfd, &unix.EpollEvent{Events: unix.EPOLLIN, Fd: evListen}); err != nil {
		return l, err
	}
	if cfg.Wait == WaitNetpoll {
		err = l.initNetpoll()
	}
	return l, err
}

// initNetpoll hands epfd to Go's netpoller: an epoll instance is readable
// while it has events ready, so the runtime's own epoll can wait on it.
func (l *loop) initNetpoll() error {
	// os.NewFile registers a descriptor with the netpoller only if it is
	// non-blocking.
	if err := unix.SetNonblock(l.epfd, true); err != nil {
		return err
	}
	f := os.NewFile(uintptr(l.epfd), "epoll")
	raw, err := f.SyscallConn()
	if err == nil {
		err = f.SetReadDeadline(time.Time{}) // fails unless the netpoller took it
	}
	if err != nil {
		_ = f.Close()
		l.epfd = -1
		return fmt.Errorf("http: netpoll wait: %w", err)
	}
	l.epFile, l.epRaw = f, raw
	l.poll = func(uintptr) bool {
		l.polled, l.pollErr = unix.EpollWait(l.epfd, l.events[:], 0)
		return l.polled != 0 || l.pollErr != nil
	}
	return nil
}

func seconds(d time.Duration) uint32 { return uint32((d + time.Second - 1) / time.Second) }

func (l *loop) conn(s int32) *conn { return &l.chunks[s>>chunkBits][s&(chunkSize-1)] }

func (l *loop) run() error {
	if l.epFile == nil {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
	}
	for {
		n, err := l.wait()
		if err != nil && err != unix.EINTR {
			return err
		}
		l.now = uint32(time.Since(l.start)/time.Second) + 1
		for i := range n {
			l.event(&l.events[i])
		}
		l.drainDone()
		l.runReady()
		l.unpark()
		if l.ticked < l.now {
			l.expire()
			if l.acceptPaused && !l.stopping {
				l.resumeAccept()
			}
		}
		l.submit()
		l.publishStats(false)
		if l.s.stopping.Load() && l.shutdown() {
			l.publishStats(true)
			return nil
		}
	}
}

// wait blocks in epoll_wait until a socket is ready, a completion is queued or
// a tick passes. All of the loop's waiting goes through here.
func (l *loop) wait() (int, error) {
	timeout := tickMillis
	if l.ready.len() > 0 {
		timeout = 0
	} else {
		// Announce sleep, then recheck: a completer that pushed before seeing
		// the flag is found here, and one that pushes after it sees the flag.
		l.sleeping.Store(true)
		if l.done.Load() != nil {
			timeout = 0
		}
	}
	var n int
	var err error
	if l.epFile == nil {
		n, err = unix.EpollWait(l.epfd, l.events[:], timeout)
	} else {
		n, err = l.park(timeout)
	}
	l.sleeping.Store(false)
	l.count.epollWaits++
	l.count.events += uint64(max(n, 0))
	return n, err
}

// park is wait for WaitNetpoll: epoll_wait without blocking and, if nothing is
// ready, park the goroutine until the netpoller finds epfd readable or the
// timeout passes. An eventfd wake makes epfd readable like any other event.
func (l *loop) park(timeout int) (int, error) {
	n, err := unix.EpollWait(l.epfd, l.events[:], 0)
	if n != 0 || err != nil || timeout == 0 {
		return n, err
	}
	if err = l.epFile.SetReadDeadline(time.Now().Add(time.Duration(timeout) * time.Millisecond)); err != nil {
		return 0, err
	}
	l.polled, l.pollErr = 0, nil
	if err = l.epRaw.Read(l.poll); err != nil && err != os.ErrDeadlineExceeded {
		return 0, err
	}
	return l.polled, l.pollErr
}

func (l *loop) event(ev *unix.EpollEvent) {
	switch ev.Fd {
	case evWake:
		return // drainDone runs after the events
	case evListen:
		l.accept()
		return
	}
	s := ev.Fd
	if int(s>>chunkBits) >= len(l.chunks) {
		return
	}
	c := l.conn(s)
	if c.gen != uint32(ev.Pad) || c.flags&(fOpen|fClosing) != fOpen {
		return
	}
	if c.flags&fLingering != 0 {
		l.linger(s, c)
		return
	}
	e := ev.Events
	if e&unix.EPOLLERR != 0 || e&(unix.EPOLLHUP|unix.EPOLLIN|unix.EPOLLRDHUP) == unix.EPOLLHUP {
		c.flags |= fBroken
		l.afterIO(s, c)
		return
	}
	run := e&(unix.EPOLLIN|unix.EPOLLRDHUP) != 0
	if e&unix.EPOLLRDHUP != 0 {
		c.flags |= fRDHUP
	}
	if run {
		c.flags |= fMayRead
		if c.op >= 0 && l.handback == HandbackDirect {
			l.ops[c.op].wantWake.Store(true)
		}
	}
	if e&unix.EPOLLOUT != 0 && c.out >= 0 {
		l.writeOut(c)
		run = run || c.out < 0 || c.flags&fBroken != 0
	}
	if run {
		l.drive(s, c)
	} else {
		l.afterIO(s, c) // re-arms the write deadline if the send made progress
	}
}

// ---------- connections ----------

func (l *loop) accept() {
	for range acceptBatch {
		if l.s.conns.Load() >= l.s.maxConns {
			l.pauseAccept()
			return
		}
		fd, e := sysAccept(l.lfd)
		switch e {
		case 0:
		case unix.EINTR, unix.ECONNABORTED:
			continue
		case unix.EMFILE, unix.ENFILE:
			l.pauseAccept() // retried on the next tick
			return
		default:
			return
		}
		l.s.conns.Add(1)
		_ = unix.SetsockoptInt(fd, unix.IPPROTO_TCP, unix.TCP_NODELAY, 1)
		s := l.allocSlot()
		c := l.conn(s)
		*c = conn{fd: int32(fd), gen: c.gen, flags: fOpen | fFresh, op: -1, in: -1, out: -1, wprev: -1, wnext: -1}
		// One registration for the connection's life: edge-triggered, both
		// directions. Not reading or writing needs no epoll_ctl.
		ev := unix.EpollEvent{Events: connEvents, Fd: s, Pad: int32(c.gen)}
		if unix.EpollCtl(l.epfd, unix.EPOLL_CTL_ADD, fd, &ev) != nil {
			l.closeConn(s, c)
			continue
		}
		l.setDeadline(s, c, l.after(l.firstSec))
	}
}

func (l *loop) pauseAccept() {
	if !l.acceptPaused {
		l.acceptPaused = true
		_ = unix.EpollCtl(l.epfd, unix.EPOLL_CTL_MOD, l.lfd, &unix.EpollEvent{Fd: evListen})
	}
}

func (l *loop) resumeAccept() {
	if l.s.conns.Load() < l.s.maxConns {
		l.acceptPaused = false
		_ = unix.EpollCtl(l.epfd, unix.EPOLL_CTL_MOD, l.lfd, &unix.EpollEvent{Events: unix.EPOLLIN, Fd: evListen})
	}
}

func (l *loop) allocSlot() int32 {
	if len(l.freeSlots) == 0 {
		base := int32(len(l.chunks)) << chunkBits
		l.chunks = append(l.chunks, make([]conn, chunkSize))
		for i := int32(chunkSize - 1); i >= 0; i-- {
			l.freeSlots = append(l.freeSlots, base+i)
		}
	}
	s := l.freeSlots[len(l.freeSlots)-1]
	l.freeSlots = l.freeSlots[:len(l.freeSlots)-1]
	return s
}

// closeConn closes a connection, or, while an Op is in flight, marks it to be
// closed when the Op returns: under HandbackDirect the completer may be
// writing to the descriptor, which must not be reused meanwhile.
func (l *loop) closeConn(s int32, c *conn) {
	if c.op >= 0 {
		c.flags |= fClosing
		return
	}
	l.settleUnparked(c)
	_ = unix.Close(int(c.fd))
	l.dropIn(c)
	if c.out >= 0 {
		l.pool.put(c.out)
	}
	l.wheelUnlink(c)
	*c = conn{fd: -1, gen: c.gen + 1, op: -1, in: -1, out: -1, wprev: -1, wnext: -1}
	l.freeSlots = append(l.freeSlots, s)
	l.s.conns.Add(-1)
	if l.acceptPaused && !l.stopping {
		l.resumeAccept()
	}
}

// ---------- reading and serving ----------

// drive does all the connection can do now: serve the requests it has
// buffered, read and serve more while the socket may have bytes, then send the
// responses in one go and settle its deadline.
func (l *loop) drive(s int32, c *conn) {
	l.settleUnparked(c)
	for reads := 0; ; {
		if c.blocked() {
			break
		}
		if c.inLen > 0 {
			used := l.handle(s, c, l.pool.bufs[c.in][:c.inLen])
			l.consumeIn(c, used)
			if c.blocked() {
				break
			}
		}
		if c.flags&fMayRead == 0 {
			break
		}
		if reads == maxReads {
			l.pushReady(s, c)
			break
		}
		reads++
		dst := l.scratch
		if c.in >= 0 {
			if int(c.inLen) == len(l.pool.bufs[c.in]) {
				if st := l.growIn(c); st != 0 {
					l.reject(s, c, st)
					break
				}
			}
			dst = l.pool.bufs[c.in][c.inLen:]
		}
		l.count.reads++
		n, e := sysRead(c.fd, dst)
		if e != 0 {
			if e == unix.EINTR {
				continue
			}
			c.flags &^= fMayRead
			if e != unix.EAGAIN {
				c.flags |= fBroken
			}
			break
		}
		if n == 0 {
			c.flags = c.flags&^fMayRead | fEOF
			break
		}
		c.flags &^= fFresh
		if n < len(dst) && c.flags&fRDHUP == 0 {
			c.flags &^= fMayRead // edge-triggered: a later arrival raises a new edge
		}
		if c.in >= 0 {
			c.inLen += int32(n)
			continue
		}
		// The common case: whole requests straight from the scratch buffer.
		if used := l.handle(s, c, l.scratch[:n]); used < n && c.flags&(fBroken|fCloseWhen) == 0 {
			l.stash(c, l.scratch[used:n])
		}
	}
	l.flush(s, c)
	l.afterIO(s, c)
}

// handle serves the complete requests at the start of b and returns how many
// bytes they used. It stops early when the connection blocks.
func (l *loop) handle(s int32, c *conn, b []byte) int {
	used := 0
	for used < len(b) && !c.blocked() {
		rest := b[used:]
		if c.need > 0 && len(rest) < int(c.need) {
			break // the body is still arriving
		}
		req := &l.req
		n, need, status := parseRequest(rest, req, int(c.scan))
		if status != 0 {
			l.reject(s, c, status)
			return len(b)
		}
		if n == 0 {
			c.need, c.scan = int32(need), 0
			if need == 0 { // the headers are not all in: resume the search there
				c.scan = int32(len(rest))
			}
			if need > 0 && req.expect && c.flags&fContSent == 0 {
				c.flags |= fContSent
				l.reserveSegs(s, c, 1)
				l.addSeg(continueResponse)
			}
			break
		}
		if !l.serve(s, c, req) {
			break // parked: the request is parsed and served again when it continues
		}
		used += n
		c.need, c.scan = 0, 0
		c.flags &^= fContSent | fReadDL
	}
	return used
}

// serve runs the handler on one request and queues its response. It reports
// false if the handler wanted to defer and no Op was free: then nothing is
// answered, and the connection is parked with the request left unread.
func (l *loop) serve(s int32, c *conn, req *Request) bool {
	l.reserveSegs(s, c, 2)
	req.l, req.slot, req.op, req.refused = l, s, nil, false
	resp := &l.resp
	start := len(l.body)
	resp.Status, resp.Body = 200, l.body[start:start]
	l.count.requests++
	if l.callHandler(req, resp) {
		l.count.panics++
		if op := req.op; op != nil {
			// Deferred before panicking: take the Op back from this turn's batch.
			last := len(l.batch) - 1
			l.batch[last] = nil
			l.batch = l.batch[:last]
			l.freeOp(op)
		}
		l.reject(s, c, 500)
		return true
	}
	if req.refused {
		// Whatever the handler put in resp is dropped: it is not counted or sent.
		l.count.requests--
		resp.Body = nil
		l.parkConn(s, c)
		return false
	}
	if !req.keepAlive {
		c.flags |= fCloseWhen
	}
	if op := req.op; op != nil {
		c.op = op.idx
		return true
	}
	body := resp.Body
	if len(body) > 0 {
		if start < cap(l.body) && unsafe.SliceData(body) == &l.body[start:cap(l.body)][0] {
			l.body = l.body[:start+len(body)]
		} else {
			// The handler outgrew the buffer or set its own slice: copy it, so
			// the bytes stay put until sent and the buffer grows for next time.
			l.body = append(l.body[:start], body...)
			body = l.body[start:]
		}
	}
	h := len(l.hdrs)
	l.hdrs = appendHeader(l.hdrs, resp.Status, len(body), req.keepAlive, req.http10)
	l.addSeg(l.hdrs[h:])
	if sendsBody(resp.Status, req.head) {
		l.addSeg(body)
	}
	resp.Body = nil
	return true
}

// callHandler runs the handler and reports whether it panicked. The deferred
// closure lives on the stack: no allocation unless a panic happens.
func (l *loop) callHandler(req *Request, resp *Response) (panicked bool) {
	defer func() {
		if p := recover(); p != nil {
			panicked = true
			log.Printf("http: handler panic serving %s %s: %v\n%s", req.Method, req.Path, p, debug.Stack())
		}
	}()
	l.handler(req, resp)
	return false
}

// reject answers a protocol error and closes the connection once it is sent,
// lingering first (see linger).
func (l *loop) reject(s int32, c *conn, status int) {
	l.reserveSegs(s, c, 1)
	l.addSeg(errorResponses[status])
	c.flags |= fCloseWhen | fLinger
	l.dropIn(c)
}

// startLinger closes a connection whose error response is sent, the peer
// perhaps still sending. Closing with unread input makes the kernel send a
// reset, which can destroy the response before the peer reads it; so shut
// down for writing (the peer sees the end of the response) and discard input
// until the peer closes too, lingerBytes have come, or lingerSec pass.
func (l *loop) startLinger(s int32, c *conn) {
	if c.flags&fEOF != 0 || unix.Shutdown(int(c.fd), unix.SHUT_WR) != nil {
		l.closeConn(s, c)
		return
	}
	c.flags |= fLingering
	c.need = 0
	l.setDeadline(s, c, l.after(lingerSec))
	l.linger(s, c)
}

// linger discards a lingering connection's input, closing it at EOF.
func (l *loop) linger(s int32, c *conn) {
	for {
		l.count.reads++
		n, e := sysRead(c.fd, l.scratch)
		switch {
		case e == unix.EINTR:
			continue
		case e == unix.EAGAIN:
			return
		case e != 0 || n == 0:
			l.closeConn(s, c)
			return
		}
		if c.need += int32(n); c.need >= lingerBytes {
			l.closeConn(s, c)
			return
		}
	}
}

// stash keeps the unprocessed bytes after a read in a pool buffer sized by
// them: growIn enlarges it as more arrive.
func (l *loop) stash(c *conn, b []byte) {
	c.in = l.pool.get(len(b))
	l.inBytes += len(l.pool.bufs[c.in])
	c.inLen = int32(copy(l.pool.bufs[c.in], b))
}

// dropIn returns the connection's input buffer to the pool.
func (l *loop) dropIn(c *conn) {
	if c.in >= 0 {
		l.inBytes -= len(l.pool.bufs[c.in])
		l.pool.put(c.in)
		c.in, c.inLen = -1, 0
	}
	c.need, c.scan = 0, 0
}

// consumeIn drops the first used bytes of the connection's input buffer,
// returning the buffer to the pool once empty.
func (l *loop) consumeIn(c *conn, used int) {
	if c.in < 0 || used == 0 {
		return
	}
	if used >= int(c.inLen) {
		l.dropIn(c)
		return
	}
	b := l.pool.bufs[c.in]
	c.inLen = int32(copy(b, b[used:c.inLen]))
}

// growIn moves a full input buffer to one at least twice as large, but no
// larger than the request needs. It returns the status to reject the request
// with if it cannot: 431 past the largest request (the headers are not in, or
// parseRequest would have rejected it), 503 when the loop's input buffers
// would pass maxInBytes.
func (l *loop) growIn(c *conn) int {
	cur := l.pool.bufs[c.in][:c.inLen]
	want := 2 * len(cur)
	if c.need > 0 {
		want = min(want, int(c.need))
	}
	want = min(want, bufSizes[len(bufSizes)-1])
	if want <= len(cur) {
		return 431
	}
	i := l.pool.get(want)
	grown := len(l.pool.bufs[i]) - len(cur)
	if l.inBytes+grown > maxInBytes {
		l.pool.put(i)
		return 503
	}
	l.inBytes += grown
	copy(l.pool.bufs[i], cur)
	l.pool.put(c.in)
	c.in = i
	return 0
}

// ---------- writing ----------

// reserveSegs makes room for k more segments, sending the ones queued so far
// if needed. Called only between responses, so no handler is mid-way through
// the buffers that flush resets.
func (l *loop) reserveSegs(s int32, c *conn, k int) {
	if l.nseg+k > maxSegs {
		l.flush(s, c)
	}
}

func (l *loop) addSeg(b []byte) {
	if len(b) > 0 {
		l.segs[l.nseg] = b
		l.nseg++
	}
}

// flush sends the queued segments with one system call. What the socket does
// not take is copied to the connection's output buffer, sent when it is
// writable again; while that buffer exists, new output is appended to it.
func (l *loop) flush(s int32, c *conn) {
	if l.nseg == 0 {
		return
	}
	segs := l.segs[:l.nseg]
	switch {
	case c.flags&fBroken != 0:
	case c.out >= 0:
		l.appendOut(c, segs, 0)
	default:
		l.count.sends++
		n, ok := sendAll(c.fd, segs, l.iov[:], &l.msg)
		if !ok {
			c.flags |= fBroken
			break
		}
		l.appendOut(c, segs, n)
	}
	clear(segs)
	l.nseg = 0
	l.hdrs = l.hdrs[:0]
	l.body = l.body[:0]
}

// appendOut copies segs, minus their first skip bytes, to the output buffer.
func (l *loop) appendOut(c *conn, segs [][]byte, skip int) {
	total := -skip
	for _, b := range segs {
		total += len(b)
	}
	if total <= 0 {
		return
	}
	pending := int(c.outLen - c.outOff)
	if c.out < 0 || int(c.outLen)+total > len(l.pool.bufs[c.out]) {
		i := l.pool.get(pending + total)
		if c.out >= 0 {
			copy(l.pool.bufs[i], l.pool.bufs[c.out][c.outOff:c.outLen])
			l.pool.put(c.out)
		}
		c.out, c.outOff, c.outLen = i, 0, int32(pending)
	}
	dst := l.pool.bufs[c.out]
	for _, b := range segs {
		if skip >= len(b) {
			skip -= len(b)
			continue
		}
		c.outLen += int32(copy(dst[c.outLen:], b[skip:]))
		skip = 0
	}
}

// writeOut sends from the output buffer.
func (l *loop) writeOut(c *conn) {
	for {
		l.count.sends++
		n, e := sysSend(c.fd, l.pool.bufs[c.out][c.outOff:c.outLen])
		switch e {
		case 0:
			if n > 0 {
				c.flags &^= fWriteDL // progress: afterIO arms a fresh deadline
			}
			c.outOff += int32(n)
			if c.outOff == c.outLen {
				l.pool.put(c.out)
				c.out, c.outOff, c.outLen = -1, 0, 0
			}
		case unix.EINTR:
			continue
		case unix.EAGAIN:
		default:
			c.flags |= fBroken
		}
		return
	}
}

// afterIO settles a connection after a turn: closes it if it is done, hands a
// deferred request's socket to its completer (HandbackDirect), or sets the
// deadline for what it waits for.
func (l *loop) afterIO(s int32, c *conn) {
	switch {
	case c.flags&fBroken != 0:
		l.closeConn(s, c)
	case c.op >= 0:
		if l.handback == HandbackDirect && c.out < 0 {
			l.release(c)
		}
	case c.out >= 0:
		// Armed when output is first queued and after each send that makes
		// progress, not on every event: a peer that never reads cannot keep
		// the connection alive by trickling bytes in.
		if c.flags&fWriteDL == 0 {
			c.flags |= fWriteDL
			l.setDeadline(s, c, l.after(l.writeSec))
		}
	case c.flags&fLingering != 0:
	case c.flags&fCloseWhen != 0:
		if c.flags&fLinger != 0 {
			l.startLinger(s, c)
		} else {
			l.closeConn(s, c)
		}
	case c.flags&fParked != 0:
	case c.flags&fEOF != 0:
		l.closeConn(s, c)
	case c.inLen > 0:
		if c.flags&fReadDL == 0 {
			c.flags |= fReadDL
			l.setDeadline(s, c, l.after(l.readSec))
		}
	case c.flags&fFresh != 0:
		// Nothing received yet: the deadline set at accept stands.
	default:
		l.setDeadline(s, c, l.after(l.idleSec))
	}
}

// release lets a deferred request's completer write to the socket: the loop
// has sent everything queued ahead of its response.
func (l *loop) release(c *conn) {
	op := &l.ops[c.op]
	if op.state.Load() != opHeld {
		return
	}
	if c.inLen > 0 || c.flags&fMayRead != 0 {
		op.wantWake.Store(true) // the loop has more to do once the response is out
	}
	op.state.CompareAndSwap(opHeld, opReleased) // fails only if Done queued the Op meanwhile
}

// ---------- scheduling ----------

func (l *loop) pushReady(s int32, c *conn) {
	if c.flags&fReady == 0 {
		c.flags |= fReady
		l.ready.push(connRef{s, c.gen})
	}
}

// runReady gives a turn to the connections queued before this call.
func (l *loop) runReady() {
	for n := l.ready.len(); n > 0; n-- {
		r := l.ready.pop()
		c := l.conn(r.slot)
		if c.gen != r.gen || c.flags&fReady == 0 {
			continue
		}
		c.flags &^= fReady
		l.drive(r.slot, c)
	}
}

// submit hands the Ops deferred this turn to the Batcher in one call.
func (l *loop) submit() {
	if len(l.batch) == 0 {
		return
	}
	l.s.cfg.Batcher.SubmitBatch(l.batch)
	clear(l.batch)
	l.batch = l.batch[:0]
}

// parkConn stops serving a connection whose request found no free Op, until
// unpark lets it go.
func (l *loop) parkConn(s int32, c *conn) {
	c.flags |= fParked
	l.count.parks++
	if c.parkedAt == 0 {
		c.parkedAt = l.millis() + 1
	}
	l.parked.push(connRef{s, c.gen})
	if !l.parkWait.Load() {
		l.parkWait.Store(true)
	}
}

func (l *loop) millis() uint32 { return uint32(time.Since(l.start) / time.Millisecond) }

// parkServed records how long a request waited for its Op.
func (l *loop) parkServed(c *conn) {
	w := l.millis() + 1 - c.parkedAt
	c.parkedAt = 0
	l.count.parkWait[min(bits.Len32(w), ParkWaitBuckets-1)]++
}

// opAvailable reports whether a request may take an Op now, beyond those the
// connections already let go may take.
func (l *loop) opAvailable() bool { return len(l.freeOps) > l.unparking }

// settleUnparked ends a let-go connection's claim on an Op: it is being
// driven, or closed.
func (l *loop) settleUnparked(c *conn) {
	if c.flags&fUnparked != 0 {
		c.flags &^= fUnparked
		l.unparking--
	}
}

// unpark lets parked connections continue, oldest first, while there are free
// Ops for them. Each one let go may take an Op when driven; one that does not
// (it closed, say) leaves the Op to the next, let go after the turn's ready
// connections ran.
func (l *loop) unpark() {
	for l.parked.len() > 0 && len(l.freeOps) > l.unparking {
		r := l.parked.pop()
		c := l.conn(r.slot)
		if c.gen == r.gen && c.flags&fParked != 0 {
			c.flags = c.flags&^fParked | fUnparked
			l.unparking++
			l.pushReady(r.slot, c)
		}
	}
	if l.parked.len() == 0 && l.parkWait.Load() {
		l.parkWait.Store(false)
	}
}

// shutdown stops accepting and closes connections as their requests finish.
// It reports true when the loop may return.
func (l *loop) shutdown() bool {
	if !l.stopping {
		l.stopping = true
		l.stopAt = l.now + 5
		_ = unix.Close(l.lfd)
		l.forEachConn(func(s int32, c *conn) { l.closeConn(s, c) })
	}
	if len(l.freeOps) < len(l.ops) && l.now < l.stopAt {
		return false
	}
	// Ops still out after the grace period are orphaned: their connections
	// stay open, since a completer may be writing to them, and Done closes
	// them. An Op whose Done has already begun is waited for instead.
	orphans := 0
	l.forEachConn(func(s int32, c *conn) {
		if c.op >= 0 && l.ops[c.op].fin.CompareAndSwap(finOut, finOrphan) {
			orphans++
		}
	})
	for len(l.freeOps)+orphans < len(l.ops) {
		runtime.Gosched()
		l.drainDone()
	}
	return true
}

func (l *loop) forEachConn(f func(s int32, c *conn)) {
	for i, chunk := range l.chunks {
		for j := range chunk {
			if c := &chunk[j]; c.flags&fOpen != 0 {
				f(int32(i<<chunkBits|j), c)
			}
		}
	}
}
