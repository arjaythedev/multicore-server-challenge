package main

// db.go: Postgres connections, the read batcher and the write grouper.
//
// Reads: requests of the same kind (an article by slug, a page of the global list, ...) that are
// waiting while a read connection is busy are sent together as ONE statement: the per-request query
// becomes the inner side of a LATERAL join over unnest() of the waiting requests' parameters, and
// every row comes back tagged with its request's ordinal. Each request's rows are still produced by
// its own execution of its own query, inside the request. A subquery that depends on no request
// parameter (the tag list, the global article count) is evaluated once per statement for the requests
// in it, as Postgres does for any uncorrelated subquery. Nothing is kept after the statement.
//
// Writes: requests queued while a write connection is busy go out as one extended-protocol batch with
// a single Sync, i.e. one implicit transaction and one WAL flush (group commit). Every response waits
// for that commit. If any statement fails the transaction is rolled back and each request is retried
// on its own.

import (
	"context"
	"errors"
	"log"
	"math/rand/v2"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

type kind uint8

const (
	kTags kind = iota
	kArticle
	kComments
	kProfile
	kUser
	kLogin
	kListAll
	kListTag
	kListAuthor
	kListFav
	kFeed
	nReadKinds
)

type paramKind uint8

const (
	pViewer paramKind = iota // int8[]  r.v
	pStr                     // text[]  r.s
	pLim                     // int8[]  r.lim
	pOff                     // int8[]  r.off
	pID                      // int8[]  r.id
)

type wstmt uint8

const (
	wRegister wstmt = iota
	wUserUpdate
	wFollow
	wUnfollow
	wArticleCreate
	wArticleUpdate
	wArticleDelete
	wFavorite
	wUnfavorite
	wComment
	wCommentDelete
	nWriteStmts
)

// dbReq is one request's trip through the database layer.
type dbReq struct {
	kind kind
	t    time.Time // enqueue time

	// Read parameters.
	viewer   int64
	id       int64
	s        string
	lim, off int64

	// Write parameters (already encoded).
	stmt   wstmt
	params [][]byte

	// Output. The worker renders rows straight into buf (after headerRoom bytes of header slack).
	buf    *[]byte
	rows   int
	status int
	count  int64  // list total
	hash   []byte // login: stored bcrypt hash
	flag   bool   // kind-specific
	err    error
	done   chan struct{}
}

func (r *dbReq) reset() {
	*r.buf = (*r.buf)[:headerRoom]
	r.rows, r.status, r.count, r.hash, r.flag, r.err = 0, 0, 0, nil, false, nil
}

type kindSpec struct {
	sql    string
	params []paramKind
	row    func(r *dbReq, vals [][]byte)
	finish func(r *dbReq)
}

type wSpec struct {
	sql    string
	oids   []uint32
	row    func(r *dbReq, vals [][]byte)
	finish func(r *dbReq)
}

var binFormats = func() []int16 {
	f := make([]int16, 16)
	for i := range f {
		f[i] = 1
	}
	return f
}()

var binResult = []int16{1}

// ---------- read scheduling ----------

// readSched queues read requests by kind. A free connection takes a batch of one kind when that
// kind has maxBatch waiting requests or its oldest request has waited for the batching window
// (a few milliseconds that let requests arriving together share one statement); it prefers
// the kind whose oldest request has waited longest. A kind may hold at most maxKind connections.
type readSched struct {
	mu       sync.Mutex
	q        [nReadKinds][]*dbReq
	inflight [nReadKinds]int
	pending  int
	maxBatch int
	maxKind  int
	window   time.Duration
	wake     chan struct{}
}

func newReadSched(maxBatch, maxKind int, window time.Duration) *readSched {
	return &readSched{maxBatch: maxBatch, maxKind: maxKind, window: window, wake: make(chan struct{}, 1)}
}

func (s *readSched) notify() {
	select {
	case s.wake <- struct{}{}:
	default:
	}
}

func (s *readSched) submit(r *dbReq) {
	r.t = time.Now()
	s.mu.Lock()
	q := append(s.q[r.kind], r)
	s.q[r.kind] = q
	s.pending++
	s.mu.Unlock()
	// A new deadline or a full batch: one sleeping worker re-evaluates.
	if len(q) == 1 || len(q) >= s.maxBatch {
		s.notify()
	}
}

// next blocks until a batch is due, then returns it. timer is the caller's reusable timer.
func (s *readSched) next(batch []*dbReq, timer *time.Timer) (kind, []*dbReq) {
	for {
		s.mu.Lock()
		now := time.Now()
		best, earliest := -1, time.Duration(-1)
		var bestT0 time.Time
		if s.pending > 0 {
			for k := 0; k < int(nReadKinds); k++ {
				q := s.q[k]
				if len(q) == 0 || s.inflight[k] >= s.maxKind {
					continue
				}
				waited := now.Sub(q[0].t)
				if len(q) >= s.maxBatch || waited >= s.window {
					if best < 0 || q[0].t.Before(bestT0) {
						best, bestT0 = k, q[0].t
					}
				} else if d := s.window - waited; earliest < 0 || d < earliest {
					earliest = d
				}
			}
		}
		if best >= 0 {
			q := s.q[best]
			n := min(len(q), s.maxBatch)
			batch = append(batch, q[:n]...)
			copy(q, q[n:])
			clear(q[len(q)-n:])
			s.q[best] = q[:len(q)-n]
			s.pending -= n
			s.inflight[best]++
			more := s.pending > 0
			s.mu.Unlock()
			if more {
				s.notify()
			}
			return kind(best), batch
		}
		s.mu.Unlock()
		if earliest < 0 {
			<-s.wake
			continue
		}
		timer.Reset(earliest)
		select {
		case <-s.wake:
			if !timer.Stop() {
				<-timer.C
			}
		case <-timer.C:
		}
	}
}

func (s *readSched) release(k kind) {
	s.mu.Lock()
	s.inflight[k]--
	wake := s.pending > 0
	s.mu.Unlock()
	if wake {
		s.notify()
	}
}

// ---------- write scheduling ----------

// writeSched is one queue: a free write connection takes everything waiting (up to maxBatch) once
// the oldest request has waited for the window, or at once when the queue is full.
type writeSched struct {
	mu       sync.Mutex
	q        []*dbReq
	maxBatch int
	window   time.Duration
	wake     chan struct{}
}

func newWriteSched(maxBatch int, window time.Duration) *writeSched {
	return &writeSched{maxBatch: maxBatch, window: window, wake: make(chan struct{}, 1)}
}

func (s *writeSched) notify() {
	select {
	case s.wake <- struct{}{}:
	default:
	}
}

func (s *writeSched) submit(r *dbReq) {
	r.t = time.Now()
	s.mu.Lock()
	s.q = append(s.q, r)
	n := len(s.q)
	s.mu.Unlock()
	if n == 1 || n >= s.maxBatch {
		s.notify()
	}
}

func (s *writeSched) next(batch []*dbReq, timer *time.Timer) []*dbReq {
	for {
		s.mu.Lock()
		if n := len(s.q); n > 0 {
			waited := time.Since(s.q[0].t)
			if n >= s.maxBatch || waited >= s.window {
				n = min(n, s.maxBatch)
				batch = append(batch, s.q[:n]...)
				copy(s.q, s.q[n:])
				clear(s.q[len(s.q)-n:])
				s.q = s.q[:len(s.q)-n]
				more := len(s.q) > 0
				s.mu.Unlock()
				if more {
					s.notify()
				}
				return batch
			}
			s.mu.Unlock()
			timer.Reset(s.window - waited)
			select {
			case <-s.wake:
				if !timer.Stop() {
					<-timer.C
				}
			case <-timer.C:
			}
			continue
		}
		s.mu.Unlock()
		<-s.wake
	}
}

// ---------- connections ----------

type db struct {
	url    string
	reads  *readSched
	writes *writeSched
}

// Session settings (rule 2 allows session-level SET): generic plans skip per-execution planning
// (every statement's generic plan is as good as its custom one), Memoize is off so no request is handed
// a row another request's lookup fetched within a batched statement, no JIT or parallel workers for
// these index-probe queries, and commits are synchronous (the default; stated for clarity).
const sessionSetup = `SET plan_cache_mode = force_generic_plan; SET enable_memoize = off; SET jit = off;
SET max_parallel_workers_per_gather = 0; SET synchronous_commit = on`

func connect(url string) (*pgconn.PgConn, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	c, err := pgconn.Connect(ctx, url)
	if err != nil {
		return nil, err
	}
	if _, err := c.Exec(ctx, sessionSetup).ReadAll(); err != nil {
		c.Close(ctx)
		return nil, err
	}
	return c, nil
}

// connectRetry keeps trying with exponential backoff and jitter.
func connectRetry(url string) *pgconn.PgConn {
	delay := 100 * time.Millisecond
	for {
		c, err := connect(url)
		if err == nil {
			return c
		}
		log.Printf("db connect: %v (retry in %v)", err, delay)
		time.Sleep(delay + time.Duration(rand.Int64N(int64(delay/2))))
		if delay < 5*time.Second {
			delay *= 2
		}
	}
}

// isConnError reports whether err means the connection is unusable: anything that is not a Postgres
// error, or a FATAL one (pgconn closes the connection on those).
func isConnError(err error) bool {
	var pgErr *pgconn.PgError
	if err == nil {
		return false
	}
	return !errors.As(err, &pgErr) || pgErr.Severity == "FATAL"
}

// readWorker owns one connection prepared with the batched read statements.
type readWorker struct {
	db    *db
	conn  *pgconn.PgConn
	stmts [nReadKinds]*pgconn.StatementDescription
	batch []*dbReq
	idx   []int32
	i8    []int64
	str   []string
}

func (w *readWorker) prepare() error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	for k := kind(0); k < nReadKinds; k++ {
		spec := &readSpecs[k]
		oids := []uint32{oidInt4Array}
		for _, p := range spec.params {
			switch p {
			case pViewer, pID:
				oids = append(oids, oidInt8Array)
			case pStr:
				oids = append(oids, oidTextArray)
			case pLim, pOff:
				oids = append(oids, oidInt8Array)
			}
		}
		sd, err := w.conn.Prepare(ctx, "r"+string('a'+byte(k)), spec.sql, oids)
		if err != nil {
			return err
		}
		w.stmts[k] = sd
	}
	return nil
}

func (w *readWorker) reconnect() {
	if w.conn != nil {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		w.conn.Close(ctx)
		cancel()
	}
	for {
		w.conn = connectRetry(w.db.url)
		if err := w.prepare(); err != nil {
			log.Printf("db prepare: %v", err)
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			w.conn.Close(ctx)
			cancel()
			time.Sleep(time.Second)
			continue
		}
		return
	}
}

func (w *readWorker) run() {
	w.reconnect()
	timer := time.NewTimer(time.Hour)
	timer.Stop()
	for {
		k, batch := w.db.reads.next(w.batch[:0], timer)
		w.batch = batch
		w.exec(k, batch)
		w.db.reads.release(k)
	}
}

// Batch statistics (reported on PPROF_ADDR/debug/batches).
var statBatches, statRequests [nReadKinds]atomic.Int64

func (w *readWorker) exec(k kind, batch []*dbReq) {
	spec := &readSpecs[k]
	n := len(batch)
	statBatches[k].Add(1)
	statRequests[k].Add(int64(n))
	w.idx = w.idx[:0]
	for i := range batch {
		w.idx = append(w.idx, int32(i))
	}
	args := make([][]byte, 0, 1+len(spec.params))
	args = append(args, encInt4Array(w.idx))
	for _, p := range spec.params {
		switch p {
		case pViewer:
			w.i8 = w.i8[:0]
			for _, r := range batch {
				w.i8 = append(w.i8, r.viewer)
			}
			args = append(args, encInt8Array(w.i8))
		case pID:
			w.i8 = w.i8[:0]
			for _, r := range batch {
				w.i8 = append(w.i8, r.id)
			}
			args = append(args, encInt8Array(w.i8))
		case pStr:
			w.str = w.str[:0]
			for _, r := range batch {
				w.str = append(w.str, r.s)
			}
			args = append(args, encTextArray(w.str))
		case pLim:
			w.i8 = w.i8[:0]
			for _, r := range batch {
				w.i8 = append(w.i8, r.lim)
			}
			args = append(args, encInt8Array(w.i8))
		case pOff:
			w.i8 = w.i8[:0]
			for _, r := range batch {
				w.i8 = append(w.i8, r.off)
			}
			args = append(args, encInt8Array(w.i8))
		}
	}
	rr := w.conn.ExecStatement(context.Background(), w.stmts[k], args, binFormats[:len(args)], binResult)
	for rr.NextRow() {
		vals := rr.Values()
		i := int(decInt4(vals[0]))
		if i < 0 || i >= n {
			continue
		}
		r := batch[i]
		r.rows++
		spec.row(r, vals[1:])
	}
	_, err := rr.Close()
	if err != nil {
		if !isConnError(err) && n > 1 {
			// One request's parameters made the statement fail (an invalid offset, bytes that are
			// not UTF-8, ...): run each request alone so only that one fails.
			for _, r := range batch {
				r.reset()
				w.exec(k, []*dbReq{r})
			}
			return
		}
		log.Printf("read batch (kind %d, %d reqs): %v", k, n, err)
		for _, r := range batch {
			r.reset()
			r.err = err
			r.done <- struct{}{}
		}
		if isConnError(err) {
			w.reconnect()
		}
		return
	}
	for _, r := range batch {
		spec.finish(r)
		r.done <- struct{}{}
	}
}

// writeWorker owns one connection prepared with the write statements.
type writeWorker struct {
	db    *db
	conn  *pgconn.PgConn
	stmts [nWriteStmts]*pgconn.StatementDescription
	batch []*dbReq
}

func (w *writeWorker) prepare() error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	for s := wstmt(0); s < nWriteStmts; s++ {
		sd, err := w.conn.Prepare(ctx, "w"+string('a'+byte(s)), writeSpecs[s].sql, writeSpecs[s].oids)
		if err != nil {
			return err
		}
		w.stmts[s] = sd
	}
	return nil
}

func (w *writeWorker) reconnect() {
	if w.conn != nil {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		w.conn.Close(ctx)
		cancel()
	}
	for {
		w.conn = connectRetry(w.db.url)
		if err := w.prepare(); err != nil {
			log.Printf("db prepare: %v", err)
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			w.conn.Close(ctx)
			cancel()
			time.Sleep(time.Second)
			continue
		}
		return
	}
}

func (w *writeWorker) run() {
	w.reconnect()
	timer := time.NewTimer(time.Hour)
	timer.Stop()
	for {
		w.batch = w.db.writes.next(w.batch[:0], timer)
		w.exec(w.batch)
	}
}

// exec runs a group of writes as one implicit transaction. On a server-side error the group is
// rolled back by Postgres and each request is run alone; on a connection error nothing is retried
// (a commit may or may not have happened) and the requests fail.
func (w *writeWorker) exec(batch []*dbReq) {
	err := w.execGroup(batch)
	if err == nil {
		for _, r := range batch {
			writeSpecs[r.stmt].finish(r)
			r.done <- struct{}{}
		}
		return
	}
	if isConnError(err) {
		log.Printf("write group (%d reqs): %v", len(batch), err)
		for _, r := range batch {
			r.reset()
			r.err = err
			r.done <- struct{}{}
		}
		w.reconnect()
		return
	}
	// Server-side error: the whole group was rolled back. Retry one by one.
	for _, r := range batch {
		r.reset()
		err := w.execGroup([]*dbReq{r})
		if err == nil {
			writeSpecs[r.stmt].finish(r)
		} else {
			r.reset()
			r.err = err
			if isConnError(err) {
				r.done <- struct{}{}
				w.reconnect()
				continue
			}
			var pgErr *pgconn.PgError
			if errors.As(err, &pgErr) && pgErr.Code == "23505" {
				// A unique violation that raced past the statement's own clash check.
				r.err, r.status = nil, 422
			} else {
				log.Printf("write %d: %v", r.stmt, err)
			}
		}
		r.done <- struct{}{}
	}
}

func (w *writeWorker) execGroup(batch []*dbReq) error {
	if len(batch) == 0 {
		return nil
	}
	b := &pgconn.Batch{}
	for _, r := range batch {
		b.ExecStatement(w.stmts[r.stmt], r.params, binFormats[:len(r.params)], binResult)
	}
	mrr := w.conn.ExecBatch(context.Background(), b)
	for _, r := range batch {
		if !mrr.NextResult() {
			break
		}
		rr := mrr.ResultReader()
		for rr.NextRow() {
			r.rows++
			writeSpecs[r.stmt].row(r, rr.Values())
		}
		if _, err := rr.Close(); err != nil {
			break
		}
	}
	return mrr.Close()
}

func (d *db) start(nRead, nWrite int) {
	for i := 0; i < nRead; i++ {
		go (&readWorker{db: d}).run()
	}
	for i := 0; i < nWrite; i++ {
		go (&writeWorker{db: d}).run()
	}
}
