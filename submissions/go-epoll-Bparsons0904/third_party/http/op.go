package http

import (
	"sync/atomic"
	"unsafe"

	"golang.org/x/sys/unix"
)

// Op is a deferred request: its handler called Request.Defer and returned. At
// the end of its turn the loop passes the turn's Ops to Config.Batcher,
// and any goroutine later fills in each response and calls Done, in any order.
// Ops come from a fixed slab per loop. A request that finds every Op in flight
// waits, its connection unread, and is served again when one frees (see
// Defer); requests that do not defer are answered meanwhile.
//
// Between Defer and Done the Op belongs to the caller; after Done it must not
// be touched. An Op outlives the loop pass that read its request, so it must
// not point into request bytes: copy what the deferred work needs (path
// parameters, query values, token, body) with Keep, into the Op's own slab
// space, and keep typed fields in the caller's per-Op state indexed by ID.
type Op struct {
	// Resp is the response body. It starts empty with reusable capacity: append
	// to it. It must stay unchanged after Done.
	Resp []byte
	// Status is the response status, 200 unless set.
	Status int

	fin atomic.Int32 // finOut until Done, or the loop orphans it at shutdown

	l    *loop
	next *Op // completion queue link
	buf  []byte
	slab []byte // this Op's share of the loop's keep slab
	keep []byte // Keep's storage: slab, or the heap past it
	idx  int32

	// The request's connection and how to answer it.
	slot, fd  int32
	gen       uint32
	keepAlive bool
	http10    bool
	head      bool

	// HandbackDirect only. state says who may write to the socket; wantWake
	// asks the completer to wake the loop because the connection has more to do.
	state    atomic.Int32
	wantWake atomic.Bool
	direct   bool // the completer wrote the response itself
	sent     int  // bytes it sent, -1 on a socket error
	total    int  // bytes it had to send

	hdrLen int
	hdr    [hdrMax]byte
	iov    [2]unix.Iovec
	msg    unix.Msghdr
}

// Op states under HandbackDirect.
const (
	opHeld     = iota // the loop may still have output queued ahead of this response
	opReleased        // the loop sent everything before it: Done may write to the socket
	opWriting         // Done is writing to the socket
	opQueued          // Done handed the Op back to the loop to write
)

// maxRetain bounds the response buffer capacity an Op keeps between uses.
const maxRetain = 1 << 20

// ID identifies the Op among all of the server's Ops: 0 <= ID < Server.Ops().
// Callers can keep typed per-Op state in a slice indexed by it.
func (op *Op) ID() int { return op.l.id*len(op.l.ops) + int(op.idx) }

// Keep copies b into storage owned by the Op and returns the copy, valid until
// Done. The first Config.KeepBytes bytes kept come from a preallocated slab;
// more spill to the heap.
func (op *Op) Keep(b []byte) []byte {
	start := len(op.keep)
	op.keep = append(op.keep, b...)
	return op.keep[start:len(op.keep):len(op.keep)]
}

// Alloc returns n bytes of the same storage as Keep, for the caller to fill
// (with an unescaped copy, say).
func (op *Op) Alloc(n int) []byte {
	start := len(op.keep)
	op.keep = append(op.keep, make([]byte, n)...)
	return op.keep[start:len(op.keep):len(op.keep)]
}

// Op.fin values.
const (
	finOut    = iota // with the caller
	finOrphan        // left behind by a forced shutdown: Done closes the connection
	finDone          // Done called
)

// Done hands the response back. It may be called from any goroutine, once.
// After a forced shutdown (Serve gave up waiting) it closes the connection
// instead, without a response.
func (op *Op) Done() {
	if !op.fin.CompareAndSwap(finOut, finDone) {
		_ = unix.Close(int(op.fd)) // orphaned: the loop left it open for us
		return
	}
	l := op.l
	wake := op.finish(l)
	l.push(op)
	// Read after the push: the loop may already have recycled the Op, which
	// at worst costs a spurious wake.
	if wake || op.wantWake.Load() {
		l.wake()
	}
}

// DoneBatch is Done on each of ops, in order, with one hand-back per loop: the
// Ops of a loop join its completion queue together, and the loop is woken at
// most once. Ops of different loops may be mixed. ops may be reused as soon
// as it returns.
func DoneBatch(ops []*Op) {
	var gs [batchLoops]doneGroup
	n, from := 0, 0
	for i, op := range ops {
		if !op.fin.CompareAndSwap(finOut, finDone) {
			_ = unix.Close(int(op.fd))
			continue
		}
		l := op.l
		var g *doneGroup
		if n > 0 && gs[n-1].l == l {
			g = &gs[n-1] // the common case: one loop's Ops in a row
		} else {
			for j := range n {
				if gs[j].l == l {
					g = &gs[j]
					break
				}
			}
		}
		if g == nil {
			if n == len(gs) {
				handBack(gs[:n], ops[from:i])
				n, from = 0, i
			}
			gs[n] = doneGroup{l: l}
			g = &gs[n]
			n++
		}
		g.wake = op.finish(l) || g.wake
		// The queue is a stack the loop reverses: link newest first.
		op.next = g.head
		g.head = op
		if g.tail == nil {
			g.tail = op
		}
	}
	handBack(gs[:n], ops[from:])
}

// batchLoops bounds the loops DoneBatch groups at once; past that it hands
// back what it has and starts over.
const batchLoops = 8

// doneGroup is one loop's share of a DoneBatch: its Ops linked newest first.
type doneGroup struct {
	l          *loop
	head, tail *Op
	wake       bool
}

// handBack splices each group onto its loop's completion queue and wakes the
// loops that need it. ops are those the groups were built from.
func handBack(gs []doneGroup, ops []*Op) {
	for i := range gs {
		g := &gs[i]
		g.l.pushChain(g.head, g.tail)
		// As in Done, wantWake is read after the push: an Op may already be
		// recycled, which at worst costs a spurious wake. op.l never changes.
		wake := g.wake
		for _, op := range ops {
			if wake {
				break
			}
			wake = op.l == g.l && op.wantWake.Load()
		}
		if wake {
			g.l.wake()
		}
	}
}

// finish does what completing op takes before it is queued to its loop: under
// HandbackDirect, the write from the completer when the loop has released the
// socket. It reports whether the loop must act soon (wake it if it sleeps).
func (op *Op) finish(l *loop) bool {
	if l.handback != HandbackDirect {
		return true
	}
	keepAlive := op.keepAlive // read before the push hands the Op back
	for {
		if op.state.CompareAndSwap(opReleased, opWriting) {
			op.writeDirect()
			// The loop must act soon if the rest of the response is its to
			// send, if it closes the connection after it, or if connections
			// wait for the freed Op.
			return op.sent < op.total || !keepAlive || l.parkWait.Load()
		}
		if op.state.CompareAndSwap(opHeld, opQueued) {
			return true
		}
	}
}

// writeDirect sends the response from the completer's goroutine, never
// blocking (MSG_DONTWAIT). On EAGAIN or a partial send the loop takes over and
// sends the rest, as under HandbackQueue.
func (op *Op) writeDirect() {
	h := appendHeader(op.hdr[:0], op.Status, len(op.Resp), op.keepAlive, op.http10)
	op.hdrLen = len(h)
	var segs [2][]byte
	segs[0] = h
	n := 1
	if sendsBody(op.Status, op.head) && len(op.Resp) > 0 {
		segs[1] = op.Resp
		n = 2
	}
	op.total = len(h) + len(segs[1])
	op.direct = true
	op.l.shared.directSends.Add(1)
	sent, ok := sendAll(op.fd, segs[:n], op.iov[:], &op.msg)
	if !ok {
		sent = -1
	}
	op.sent = sent
}

// push adds op to the loop's completion queue: a lock-free stack the loop
// takes whole and reverses.
func (l *loop) push(op *Op) { l.pushChain(op, op) }

// pushChain adds the Ops linked from head through next to tail, newest first,
// with one CAS.
func (l *loop) pushChain(head, tail *Op) {
	for {
		old := l.done.Load()
		tail.next = old
		if l.done.CompareAndSwap(old, head) {
			return
		}
	}
}

// wake interrupts the loop's epoll_wait, but only when it is asleep or about to
// be: it rechecks the queue after announcing sleep, so a completion pushed
// while it is awake is collected without a system call.
func (l *loop) wake() {
	if l.sleeping.Load() && l.sleeping.CompareAndSwap(true, false) {
		l.shared.wakes.Add(1)
		l.signal()
	}
}

// signal writes the loop's eventfd unless it is closed: every write goes
// through here, counted in signalling, so that closeFDs can wait them out.
func (l *loop) signal() {
	l.shared.signalling.Add(1)
	if !l.closed.Load() {
		sysWake(l.efd)
	}
	l.shared.signalling.Add(-1)
}

// drainDone finishes every queued completion, oldest first.
func (l *loop) drainDone() {
	head := l.done.Swap(nil)
	var fifo *Op
	for head != nil {
		next := head.next
		head.next = fifo
		fifo, head = head, next
	}
	for op := fifo; op != nil; {
		next := op.next
		op.next = nil
		l.finishOp(op)
		op = next
	}
}

// Defer turns the request into an Op whose response is sent when Done is
// called. The handler then returns without filling its Response. Calling
// Defer again returns the same Op.
//
// It returns nil when every Op is in flight. The handler must then return at
// once: the loop drops anything it set in the Response, stops reading the
// connection, and when an Op frees, parses the request again and calls the
// handler again. Connections wait for Ops oldest first.
func (r *Request) Defer() *Op {
	if r.op != nil {
		return r.op
	}
	l := r.l
	if l.s.cfg.Batcher == nil {
		panic("http: Request.Defer needs Config.Batcher")
	}
	if !l.opAvailable() {
		r.refused = true
		return nil
	}
	idx := l.freeOps[len(l.freeOps)-1]
	l.freeOps = l.freeOps[:len(l.freeOps)-1]
	op := &l.ops[idx]
	c := l.conn(r.slot)
	if c.parkedAt != 0 {
		l.parkServed(c)
	}
	op.Status = 200
	op.Resp = op.buf[:0]
	op.keep = op.slab[:0]
	op.slot, op.fd, op.gen = r.slot, c.fd, c.gen
	op.keepAlive, op.http10, op.head = r.keepAlive, r.http10, r.head
	op.direct, op.sent, op.total = false, 0, 0
	op.state.Store(opHeld)
	op.wantWake.Store(false)
	op.fin.Store(finOut)
	r.op = op
	l.batch = append(l.batch, op)
	return op
}

// freeOp recycles op and lets the longest-parked connections continue.
func (l *loop) freeOp(op *Op) {
	// Keep a grown body buffer for next time, but never adopt the caller's slice.
	if c := cap(op.Resp); c > cap(op.buf) && c <= maxRetain &&
		unsafe.SliceData(op.Resp) != unsafe.SliceData(op.buf) {
		op.buf = make([]byte, 0, c)
	}
	op.Resp = nil
	op.keep = nil
	l.freeOps = append(l.freeOps, op.idx)
	l.unpark()
}

// finishOp sends a completed Op's response, or what remains of it, and lets the
// connection continue.
func (l *loop) finishOp(op *Op) {
	s := op.slot
	c := l.conn(s)
	if c.gen != op.gen || c.op != op.idx {
		panic("http: completed Op does not match its connection")
	}
	c.op = -1
	if !op.keepAlive {
		c.flags |= fCloseWhen
	}
	if c.flags&fClosing != 0 {
		l.freeOp(op)
		l.closeConn(s, c)
		return
	}
	if op.direct {
		if op.sent < 0 {
			c.flags |= fBroken
		}
		if op.sent < 0 || op.sent == op.total {
			l.freeOp(op)
			l.drive(s, c)
			return
		}
		// The socket was full: queue the rest for the loop.
		l.reserveSegs(s, c, 2)
		skip := op.sent
		if skip < op.hdrLen {
			l.addSeg(op.hdr[skip:op.hdrLen])
			skip = 0
		} else {
			skip -= op.hdrLen
		}
		if body := op.total - op.hdrLen; skip < body {
			l.addSeg(op.Resp[skip:body])
		}
	} else {
		l.reserveSegs(s, c, 2)
		h := appendHeader(op.hdr[:0], op.Status, len(op.Resp), op.keepAlive, op.http10)
		l.addSeg(h)
		if sendsBody(op.Status, op.head) {
			l.addSeg(op.Resp)
		}
	}
	// drive coalesces this response with those of requests pipelined behind it.
	// The segments point into op, so it is freed only after drive sent them.
	l.drive(s, c)
	l.freeOp(op)
}
