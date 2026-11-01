package main

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"golang.org/x/sys/cpu"

	http "multicorelab/http"
	"multicorelab/http/conduit"
)

// worker owns one Postgres connection and a queue of requests. Whenever the
// connection is free it takes everything queued (up to flushCap) and serves it
// in one write round trip and one read round trip.
type worker struct {
	db       *DB
	id       int
	conn     *pgconn.PgConn
	stmts    map[string]*prepared
	psBuf    []*prepared
	comms    []commRow // the comments of the current flush, all slugs
	ar       arena     // text of the rows decoded in the current flush
	tab      artTab    // the articles of the current flush, dense by slot
	flat     []int32   // page positions as slots of tab
	favRef   []int32
	favHit   []bool
	dict     tagDict // the tag dictionary of the current flush
	wantDict bool
	tagPairs []tagPair
	tcnt     []int32
	trank    []int32
	groups   [conduitEndpoints][]*opState // readPhase: this flush's reads by endpoint
	fins     []func()
	favOps   []*opState   // readPhase: the committed favorites and unfavorites of this flush
	sbs      [2]stmtBatch // readPhase: the first round and the second
	writes   []*opState
	reads    []*opState
	pend     []*http.Op // answered requests not yet handed back
	enc      [][]byte
	vals     [][]byte
	dsn      string

	q *queue

	share bool

	grp int // read group, -1 for a writer
	rd  int // index among the readers, -1 for a writer

	labWorker // lab builds count busy time and flushes here
}

func newWorker(db *DB, id int, q *queue) *worker {
	return &worker{db: db, id: id, q: q, share: db.sharing}
}

// queue is shared by a pool of workers: whichever worker's connection is free takes everything queued, so no
// worker is hot, a slow statement holds up only its own batch, and a batch still holds every key for sharing.
type queue struct {
	_    cpu.CacheLinePad // the queues are written by the HTTP loop and by their readers: keep them off each other's lines
	mu   sync.Mutex
	cond *sync.Cond
	q    []*opState

	// With wait > 0 a worker that finds fewer than fill items queued waits up to wait for more before it takes
	// them, so batches grow without fewer connections. Off by default.
	wait time.Duration
	fill int

	// Read groups (CONDUIT_READ_GROUPS): a worker with nothing queued for its own group may take what is queued for
	// another. waiting counts the workers asleep on this queue, hint is a queue a pusher found busy, and peers are
	// the other groups' queues.
	waiting int
	filling int // workers in their fill wait: their queue is not busy, so nobody steals from it meanwhile
	hint    *queue
	peers   []*queue
	_       cpu.CacheLinePad
}

func newQueue(wait time.Duration, fill int) *queue {
	q := &queue{wait: wait, fill: fill}
	q.cond = sync.NewCond(&q.mu)
	return q
}

func (q *queue) push(s *opState) {
	q.mu.Lock()
	q.q = append(q.q, s)
	idle := q.waiting > 0 || q.filling > 0
	q.mu.Unlock()
	q.wakeFor(idle)
}

// wakeFor wakes a worker for newly queued work: one of this queue's, or when all of them are busy, an idle worker
// of another group, which takes the work instead.
func (q *queue) wakeFor(idle bool) {
	if idle || len(q.peers) == 0 {
		q.cond.Signal()
		return
	}
	for _, p := range q.peers {
		p.mu.Lock()
		if p.waiting > 0 && p.hint == nil {
			p.hint = q
			p.mu.Unlock()
			p.cond.Signal()
			return
		}
		p.mu.Unlock()
	}
	q.cond.Signal()
}

// steal removes up to flushCap items for a worker of another group.
func (q *queue) steal(buf []*opState, grp int) []*opState {
	q.mu.Lock()
	n := min(len(q.q), flushCap)
	if n == 0 {
		q.mu.Unlock()
		return nil
	}
	buf = append(buf[:0], q.q[:n]...)
	q.q = append(q.q[:0], q.q[n:]...)
	q.mu.Unlock()
	if grp >= 0 {
		statSteal(grp)
	}
	return buf
}

// pushAll queues items in order under one lock and one signal.
func (q *queue) pushAll(items []*opState) {
	if len(items) == 0 {
		return
	}
	q.mu.Lock()
	q.q = append(q.q, items...)
	idle := q.waiting > 0 || q.filling > 0
	q.mu.Unlock()
	q.wakeFor(idle)
}

func (q *queue) len() int {
	q.mu.Lock()
	defer q.mu.Unlock()
	return len(q.q)
}

// take blocks until something is queued, then removes up to flushCap items.
func (q *queue) take(buf []*opState, grp int) []*opState {
	q.mu.Lock()
	for len(q.q) == 0 {
		if h := q.hint; h != nil {
			q.hint = nil
			q.mu.Unlock()
			if got := h.steal(buf, grp); len(got) > 0 {
				return got
			}
			q.mu.Lock()
			continue
		}
		q.waiting++
		q.cond.Wait()
		q.waiting--
	}
	if q.wait > 0 && len(q.q) < min(q.fill, flushCap) {
		q.filling++
		deadline := time.Now().Add(q.wait)
		for len(q.q) < min(q.fill, flushCap) && time.Now().Before(deadline) {
			q.mu.Unlock()
			time.Sleep(50 * time.Microsecond)
			q.mu.Lock()
		}
		q.filling--
		for len(q.q) == 0 { // another worker took them while this one slept
			q.waiting++
			q.cond.Wait()
			q.waiting--
		}
	}
	n := min(len(q.q), flushCap)
	buf = append(buf[:0], q.q[:n]...)
	q.q = append(q.q[:0], q.q[n:]...)
	more := len(q.q) > 0
	q.mu.Unlock()
	if more {
		q.cond.Signal() // another worker may be asleep while work remains
	}
	return buf
}

func (w *worker) connect(dsn string) error {
	w.dsn = dsn
	return w.reconnect()
}

func (w *worker) reconnect() error {
	cfg, err := pgconn.ParseConfig(w.dsn)
	if err != nil {
		return err
	}
	cfg.TLSConfig, cfg.Fallbacks = nil, nil // sslmode=disable
	cfg.RuntimeParams["plan_cache_mode"] = "force_generic_plan"
	cfg.RuntimeParams["jit"] = "off"
	var last error
	for try := 0; try < 60; try++ {
		var c *pgconn.PgConn
		if c, last = pgconn.ConnectConfig(context.Background(), cfg); last == nil {
			w.conn = c
			w.stmts = map[string]*prepared{}
			return nil
		}
		time.Sleep(time.Second)
	}
	return last
}

func (w *worker) run() {
	var buf []*opState
	for {
		buf = w.q.take(buf, w.rd)
		w.flush(buf)
	}
}

// flush serves one batch: the writes in one transaction, then every read,
// including the reads that answer the writes.
func (w *worker) flush(items []*opState) {
	t0 := statNow()
	for _, s := range items {
		s.w = w
	}
	w.ar.reset()
	w.dict.reset()
	statFlush(len(items))
	if w.rd >= 0 {
		statReaderFlush(w.rd, len(items))
	}
	writes, reads := w.writes[:0], w.reads[:0]
	for _, s := range items {
		switch {
		case isWrite(s.c.Endpoint):
			writes = append(writes, s)
		default:
			reads = append(reads, s)
		}
	}
	if len(writes) > 0 {
		statCommit(len(writes))
		reads = append(reads, w.writePhase(writes)...)
		w.complete()
	}
	if len(reads) > 0 {
		p0 := statNow()
		w.readPhase(reads)
		if len(writes) > 0 {
			statPostRead(p0)
		}
	}
	w.complete()
	w.writes, w.reads = writes[:0], reads[:0]
	statFlushEnd(w, t0)
}

// stmtBatch is one pipelined round trip: its statements are sent back to back and answered in one Sync.
type stmtBatch struct {
	items []stmtItem
}

type stmtItem struct {
	sql  string
	args []any
	rd   func(*pgRows) error // nil for a statement whose result is not read
}

// sqlBeginRead opens the snapshot a read flush's statements share.
const sqlBeginRead = "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY"

// begin puts the read snapshot's BEGIN in front of the statements queued so far.
func (sb *stmtBatch) begin() {
	sb.items = append(sb.items, stmtItem{})
	copy(sb.items[1:], sb.items)
	sb.items[0] = stmtItem{sql: sqlBeginRead}
}

func (sb *stmtBatch) exec(sql string, args ...any) {
	sb.items = append(sb.items, stmtItem{sql: sql, args: args})
}

func (sb *stmtBatch) query(sql string, args []any, rd func(*pgRows) error) {
	sb.items = append(sb.items, stmtItem{sql: sql, args: args, rd: rd})
}

// prepare parses sql on the worker's connection once.
func (w *worker) prepare(sql string) (*prepared, error) {
	if p := w.stmts[sql]; p != nil {
		return p, nil
	}
	sd, err := w.conn.Prepare(context.Background(), "s"+strconv.Itoa(len(w.stmts)), sql, nil)
	if err != nil {
		return nil, err
	}
	p := newPrepared(sd)
	w.stmts[sql] = p
	return p, nil
}

func (w *worker) run1(sb *stmtBatch) error {
	if len(sb.items) == 0 {
		return nil
	}
	if w.conn == nil || w.conn.IsClosed() {
		if err := w.reconnect(); err != nil {
			return err
		}
	}
	ps := w.psBuf[:0]
	for i := range sb.items {
		p, err := w.prepare(sb.items[i].sql)
		if err != nil {
			return err
		}
		ps = append(ps, p)
	}
	w.psBuf = ps
	pl := w.conn.StartPipeline(context.Background())
	for i := range sb.items {
		it, p := &sb.items[i], ps[i]
		vals, err := w.encode(it, p)
		if err != nil {
			pl.Close() // unsynced: the connection is dropped and re-made by the next batch
			return err
		}
		pl.SendQueryStatement(p.sd, vals, p.pfmt, p.rfmt)
	}
	pl.SendPipelineSync()
	if err := pl.Flush(); err != nil {
		pl.Close()
		return err
	}
	var first error
	k := 0
	for {
		res, err := pl.GetResults()
		if err != nil {
			if first == nil {
				first = err
			}
			break
		}
		switch r := res.(type) {
		case *pgconn.ResultReader:
			it := &sb.items[k]
			k++
			if it.rd != nil && first == nil {
				rows := pgRows{src: r, ar: &w.ar}
				first = it.rd(&rows)
			}
			if _, err := r.Close(); first == nil {
				first = err
			}
			if first != nil {
				pl.Close()
				return first
			}
		case *pgconn.PipelineSync:
			if err := pl.Close(); first == nil {
				first = err
			}
			return first
		}
	}
	pl.Close() // drains up to the Sync; first carries the statement's error
	return first
}

// encode converts it.args to the binary parameters of p, using the worker's reusable buffers.
func (w *worker) encode(it *stmtItem, p *prepared) ([][]byte, error) {
	if len(it.args) != len(p.sd.ParamOIDs) {
		return nil, fmt.Errorf("%d arguments for %d parameters", len(it.args), len(p.sd.ParamOIDs))
	}
	for len(w.enc) < len(it.args) {
		w.enc = append(w.enc, nil)
	}
	vals := w.vals[:0]
	for i, a := range it.args {
		b, null, err := appendParam(w.enc[i][:0], p.sd.ParamOIDs[i], a)
		if err != nil {
			return nil, err
		}
		w.enc[i] = b
		if null {
			vals = append(vals, nil)
		} else {
			vals = append(vals, b)
		}
	}
	w.vals = vals
	return vals, nil
}

// rollback leaves an aborted transaction behind.
func (w *worker) rollback() {
	if w.conn == nil || w.conn.IsClosed() {
		return
	}
	if w.conn.TxStatus() != 'I' {
		if _, err := w.conn.Exec(context.Background(), "ROLLBACK").ReadAll(); err != nil {
			w.conn.Close(context.Background())
		}
	}
}

func pgCode(err error) string {
	var pe *pgconn.PgError
	if errors.As(err, &pe) {
		return pe.Code
	}
	return ""
}

// complete hands every answered request of this flush back to the HTTP layer with one DoneBatch.
func (w *worker) complete() {
	if len(w.pend) == 0 {
		return
	}
	http.DoneBatch(w.pend)
	clear(w.pend)
	w.pend = w.pend[:0]
}

func failAll(items []*opState, status int, msg string) {
	for _, s := range items {
		conduit.Fail(s.op, status, msg)
		s.done()
	}
}
