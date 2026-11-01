package http

// conn is one client connection. It holds no pointers, so a loop's table of
// connections costs the garbage collector nothing to scan, and an idle
// connection owns no buffer: input and output bytes live in the loop's pool
// only while a request is partial or a response is partly sent.
type conn struct {
	fd    int32
	gen   uint32 // bumped on close, so stale events and queue entries are ignored
	flags uint32
	op    int32 // the Op of the deferred request in flight, or -1

	in    int32 // pool buffer holding unprocessed input, or -1
	inLen int32
	// The partial request at the start of the input: its full length once its
	// headers are in, else how far they were searched for their end. While
	// lingering, need counts the bytes discarded.
	need, scan int32

	out            int32 // pool buffer holding unsent output, or -1
	outOff, outLen int32

	deadline     uint32 // in loop seconds; see wheel.go
	wsec         uint32 // the wheel second the conn is filed under, 0 if none
	wprev, wnext int32  // neighbours in that wheel bucket

	parkedAt uint32 // loop milliseconds + 1 when its request first waited for an Op, 0 if not waiting
}

const (
	fOpen      = 1 << iota
	fMayRead   // the socket may have unread bytes (edge-triggered: an edge arrived, no EAGAIN since)
	fEOF       // read returned 0: the peer shut down its side
	fRDHUP     // epoll reported the shutdown: read on until 0, as no edge follows
	fBroken    // socket error: close as soon as no Op is in flight
	fCloseWhen // close once the responses so far are sent (Connection: close, protocol error)
	fClosing   // closed while an Op was in flight: finish closing when it returns
	fParked    // its request waits in the parked FIFO for a free Op
	fReady     // queued in the ready FIFO
	fContSent  // 100 Continue already sent for the current request
	fReadDL    // the read deadline for the current partial request is set
	fWriteDL   // the write deadline for the pending output is set (re-armed on progress)
	fUnparked  // let go from the parked FIFO, counted in loop.unparking until driven
	fFresh     // nothing received since accept: the first-request timeout applies
	fLinger    // after the error response is sent, linger before closing
	fLingering // shut down for writing, discarding input until EOF (see linger)
)

const (
	chunkBits = 12
	chunkSize = 1 << chunkBits
)

// blocked reports whether the connection must not take new requests now.
func (c *conn) blocked() bool {
	return c.op >= 0 || c.out >= 0 || c.flags&(fBroken|fCloseWhen|fParked) != 0
}

// connRef names a connection in a FIFO; a stale gen means it closed since.
type connRef struct {
	slot int32
	gen  uint32
}

// fifo is a growable queue of connections.
type fifo struct {
	q    []connRef
	head int
}

func (f *fifo) len() int { return len(f.q) - f.head }

func (f *fifo) push(r connRef) {
	if f.head == len(f.q) {
		f.q, f.head = f.q[:0], 0
	} else if f.head >= 1024 && f.head*2 >= len(f.q) {
		n := copy(f.q, f.q[f.head:])
		f.q, f.head = f.q[:n], 0
	}
	f.q = append(f.q, r)
}

func (f *fifo) pop() connRef {
	r := f.q[f.head]
	f.head++
	return r
}

// Buffer pool. Buffers come in sizes growing by four, up to the largest
// request allowed; a partial request's buffer grows with the bytes received,
// not with the length it announces. Larger output is allocated exactly and
// dropped when done. A bounded number of free buffers per size is kept for
// reuse.
var (
	bufSizes = [...]int{1 << 10, 4 << 10, 16 << 10, MaxHeaderBytes, 256 << 10, MaxHeaderBytes + MaxBodyBytes}
	bufKeep  = [...]int{1024, 512, 128, 32, 8, 2}
)

type pool struct {
	bufs  [][]byte
	size  []int8 // index into bufSizes, or -1 for an exact allocation
	free  [len(bufSizes)][]int32
	spare []int32 // unused indexes into bufs
}

// get returns a buffer of at least n bytes.
func (p *pool) get(n int) int32 {
	k := int8(-1)
	for i, size := range bufSizes {
		if n <= size {
			k, n = int8(i), size
			break
		}
	}
	if k >= 0 {
		if f := p.free[k]; len(f) > 0 {
			p.free[k] = f[:len(f)-1]
			return f[len(f)-1]
		}
	}
	var i int32
	if len(p.spare) > 0 {
		i = p.spare[len(p.spare)-1]
		p.spare = p.spare[:len(p.spare)-1]
	} else {
		i = int32(len(p.bufs))
		p.bufs = append(p.bufs, nil)
		p.size = append(p.size, 0)
	}
	p.bufs[i] = make([]byte, n)
	p.size[i] = k
	return i
}

func (p *pool) put(i int32) {
	if k := p.size[i]; k >= 0 && len(p.free[k]) < bufKeep[k] {
		p.free[k] = append(p.free[k], i)
		return
	}
	p.bufs[i] = nil
	p.spare = append(p.spare, i)
}
