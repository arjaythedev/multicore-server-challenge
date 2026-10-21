package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"conduit/internal/bcryptx"

	"github.com/jackc/pgx/v5/pgconn"
)

// dbDispatcher owns every PostgreSQL connection. Reads and writes have separate
// queues and separate connections, so WAL flush waits never hold up reads.
//
// Each worker goroutine owns one connection. It takes the next queued job, then
// drains whatever else is waiting (up to a batch limit) and sends all of their
// statements as one pipeline: Bind/Execute per statement and a single Sync.
//
// Reads: each result is answered as soon as its rows are read.
//
// Writes: the pipeline is one implicit transaction, so a batch is a group
// commit: one round trip and one WAL flush for every mutation in it. Responses
// wait for the commit. If any statement fails the whole group rolls back and
// each request is retried alone; if the connection fails mid-commit the outcome
// is unknown, so nothing is replayed and the requests get 500.
type dbDispatcher struct {
	s      *reactorServer
	cfg    dbConfig
	pgcfg  *pgconn.Config
	secret []byte

	read, write chan *reactorJob
	bcrypt      chan *reactorJob
	// collector -> compute workers, and the reusable batch pool
	bcryptBatches, bcryptFree chan *bcryptBatch

	workers []*worker
	wg      sync.WaitGroup
	bcWG    sync.WaitGroup
}

type dbConfig struct {
	readConns, writeConns      int
	pipelineDepth              int
	readBatch, writeBatch      int
	readQueue, writeQueue      int
	writeLinger, writeFlush    time.Duration
	queueTimeout, execTimeout  time.Duration
	bcryptWorkers              int
	bcryptWait, bcryptStretch  time.Duration
	reconnectMin, reconnectMax time.Duration
	bcryptQueue                int
}

// slots is the number of request slots the event loops hold. Every queue is sized
// for all of them, so a queue can never be full: overload shows up as latency.
func dbConfigFromEnv(cores, slots int) (dbConfig, error) {
	c := dbConfig{}
	var err error
	ints := []struct {
		name        string
		dst         *int
		def, lo, hi int
	}{
		{"DB_READ_CONNS", &c.readConns, 20, 1, 95},
		{"DB_WRITE_CONNS", &c.writeConns, 2, 1, 95},
		{"READ_BATCH", &c.readBatch, 32, 1, 256},
		{"WRITE_BATCH", &c.writeBatch, 128, 1, 1024},
		{"PIPELINE_DEPTH", &c.pipelineDepth, 4, 1, 16},
		{"BCRYPT_WORKERS", &c.bcryptWorkers, max(1, cores/4), 1, 128},
		{"BCRYPT_QUEUE", &c.bcryptQueue, slots, 1, 1 << 20},
	}
	for _, v := range ints {
		if *v.dst, err = envInt(v.name, v.def, v.lo, v.hi); err != nil {
			return c, err
		}
	}
	if c.readConns+c.writeConns > 95 {
		return c, errors.New("DB_READ_CONNS + DB_WRITE_CONNS must be at most 95")
	}
	durations := []struct {
		name string
		dst  *time.Duration
		def  time.Duration
	}{
		{"WRITE_LINGER", &c.writeLinger, time.Millisecond},
		{"WRITE_FLUSH_INTERVAL", &c.writeFlush, 200 * time.Millisecond},
		{"QUEUE_TIMEOUT", &c.queueTimeout, 30 * time.Second},
		{"DB_EXEC_TIMEOUT", &c.execTimeout, 10 * time.Second},
		{"BCRYPT_WAIT", &c.bcryptWait, 150 * time.Millisecond},
		{"BCRYPT_STRETCH", &c.bcryptStretch, time.Second},
		{"DB_RECONNECT_MIN", &c.reconnectMin, 100 * time.Millisecond},
		{"DB_RECONNECT_MAX", &c.reconnectMax, 5 * time.Second},
	}
	for _, v := range durations {
		*v.dst = v.def
		if s := envOr(v.name, ""); s != "" {
			d, e := time.ParseDuration(s)
			if e != nil || d < 0 || d > time.Minute {
				return c, fmt.Errorf("%s must be a duration between 0 and 1m", v.name)
			}
			*v.dst = d
		}
	}
	c.readQueue, c.writeQueue = slots, slots
	if c.reconnectMin <= 0 || c.reconnectMax < c.reconnectMin {
		return c, errors.New("DB_RECONNECT_MIN must be above 0 and at most DB_RECONNECT_MAX")
	}
	return c, nil
}

// flight is one batch sent on a connection's pipeline and not yet read back.
// single marks an isolated retry, whose failure is that request's own answer.
type flight struct {
	jobs   []*reactorJob
	single bool
}

type worker struct {
	d       *dbDispatcher
	write   bool
	jwt     *jwtCodec
	pg      *pgconn.PgConn
	pipe    *pgconn.Pipeline
	sd      [numStmts]*pgconn.StatementDescription
	jobs    []*reactorJob
	pending []*reactorJob
	single  [1]*reactorJob
	retry   []*reactorJob // requests to resend alone after their batch failed
	ring    []flight      // batches in flight, oldest at head
	head, n int
	// After a statement fails mid-batch pgx leaves the skipped statements'
	// descriptions queued (v5.11.0), so the pipeline is drained and restarted.
	restart bool
	retryAt time.Time
	bo      backoff
	timer   *time.Timer
}

func newDBDispatcher(s *reactorServer, cfg dbConfig, pgcfg *pgconn.Config, secret []byte) *dbDispatcher {
	d := &dbDispatcher{s: s, cfg: cfg, pgcfg: pgcfg, secret: secret,
		read: make(chan *reactorJob, cfg.readQueue), write: make(chan *reactorJob, cfg.writeQueue),
		bcrypt: make(chan *reactorJob, cfg.bcryptQueue)}
	for i := range cfg.readConns + cfg.writeConns {
		w := &worker{d: d, write: i >= cfg.readConns, jwt: newJWTCodec(secret), bo: backoff{min: cfg.reconnectMin, max: cfg.reconnectMax}}
		limit := cfg.readBatch
		if w.write {
			limit = cfg.writeBatch
		}
		w.jobs = make([]*reactorJob, 0, limit)
		w.pending = make([]*reactorJob, 0, limit)
		w.ring = make([]flight, cfg.pipelineDepth)
		for i := range w.ring {
			w.ring[i].jobs = make([]*reactorJob, 0, limit)
		}
		w.timer = time.NewTimer(time.Hour)
		w.timer.Stop()
		d.workers = append(d.workers, w)
	}
	return d
}

// connectAll opens and prepares every connection that is not open yet.
func (d *dbDispatcher) connectAll(ctx context.Context) error {
	errs := make(chan error, len(d.workers))
	for _, w := range d.workers {
		if w.pg != nil {
			errs <- nil
			continue
		}
		go func() { errs <- w.connect(ctx) }()
	}
	var first error
	for range d.workers {
		if err := <-errs; err != nil && first == nil {
			first = err
		}
	}
	return first
}

// connectWithRetry opens every connection before the server listens, retrying
// with exponential backoff for up to limit, so a PostgreSQL that is still
// starting does not fail the boot.
func (d *dbDispatcher) connectWithRetry(ctx context.Context, limit time.Duration) error {
	deadline := time.Now().Add(limit)
	bo := backoff{min: d.cfg.reconnectMin, max: d.cfg.reconnectMax}
	for {
		attemptCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		err := d.connectAll(attemptCtx)
		cancel()
		if err == nil {
			return nil
		}
		wait := bo.fail()
		if ctx.Err() != nil || time.Now().Add(wait).After(deadline) {
			return err
		}
		log.Printf("database not ready (attempt %d), retrying in %s: %v", bo.attempts, wait.Round(time.Millisecond), err)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(wait):
		}
	}
}

func (d *dbDispatcher) start() {
	for _, w := range d.workers {
		q := d.read
		if w.write {
			q = d.write
		}
		d.wg.Go(func() { w.loop(q) })
	}
	d.startBcrypt()
}

// stop runs after every event loop has drained its outstanding jobs, so no
// job is queued or in flight.
func (d *dbDispatcher) stop() {
	close(d.read)
	close(d.write)
	d.wg.Wait()
	close(d.bcrypt)
	d.bcWG.Wait()
	for _, w := range d.workers {
		if w.pipe != nil {
			_ = w.pipe.Close()
		}
		if w.pg != nil {
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			w.pg.Close(ctx)
			cancel()
		}
	}
}

func (d *dbDispatcher) submit(j *reactorJob) bool {
	q := d.read
	if j.class == classWrite {
		q = d.write
	}
	select {
	case q <- j:
		return true
	default:
		return false
	}
}

// ---------- connections ----------

var paramOIDs = map[byte][]uint32{'i': {20}, 't': {25, 1043}, 'a': {1009}}

func (w *worker) connect(ctx context.Context) error {
	pg, err := pgconn.ConnectConfig(ctx, w.d.pgcfg)
	if err != nil {
		return fmt.Errorf("connect: %w", err)
	}
	lo, hi := stTags, firstWriteStmt
	if w.write {
		lo, hi = firstWriteStmt, numStmts
	}
	for id := lo; id < hi; id++ {
		def := stmts[id]
		sd, err := pg.Prepare(ctx, "s"+strconv.Itoa(int(id)), def.sql, nil)
		if err != nil {
			pg.Close(ctx)
			return fmt.Errorf("prepare statement %d: %w", id, err)
		}
		if len(sd.ParamOIDs) != len(def.params) {
			pg.Close(ctx)
			return fmt.Errorf("statement %d: %d parameters, want %d", id, len(sd.ParamOIDs), len(def.params))
		}
		for i, oid := range sd.ParamOIDs {
			ok := false
			for _, want := range paramOIDs[def.params[i]] {
				ok = ok || oid == want
			}
			if !ok {
				pg.Close(ctx)
				return fmt.Errorf("statement %d parameter %d has type oid %d, want %c", id, i+1, oid, def.params[i])
			}
		}
		w.sd[id] = sd
	}
	w.pg = pg
	// The pipeline stays open for the connection's life; its context must not
	// expire, so it is not the connect deadline.
	w.pipe = pg.StartPipeline(context.Background())
	return nil
}

// reconnect makes sure the worker has a connection and pipeline before it sends
// jobs. If the connection is broken it retries with exponential backoff,
// holding the jobs: during an outage requests wait rather than fail. Jobs that
// pass QUEUE_TIMEOUT, or whose client left, get 503. It returns the live jobs.
func (w *worker) reconnect(jobs []*reactorJob) []*reactorJob {
	for {
		if w.pg != nil && !w.pg.IsClosed() && w.pipe != nil {
			return jobs
		}
		if w.n > 0 {
			// The connection closed under batches still in flight: settle them first.
			w.broken(errors.New("connection closed"), 0)
		}
		if w.pg != nil {
			w.pg.Close(context.Background())
			w.pg, w.pipe = nil, nil
		}
		if wait := time.Until(w.retryAt); wait > 0 {
			time.Sleep(wait)
		}
		jobs = w.expire(jobs)
		if len(jobs) == 0 {
			return jobs // nothing waiting; the next job retries when the backoff allows
		}
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		err := w.connect(ctx)
		cancel()
		if err == nil {
			down, failed := w.bo.reset()
			log.Printf("database connection re-established (write=%v) after %s, %d failed attempts",
				w.write, down.Round(time.Millisecond), failed)
			return jobs
		}
		wait := w.bo.fail()
		w.retryAt = time.Now().Add(wait)
		if w.bo.logWorthy() {
			log.Printf("database reconnect failed (write=%v, attempt %d, %d requests waiting), retrying in %s: %v",
				w.write, w.bo.attempts, len(jobs), wait.Round(time.Millisecond), err)
		}
	}
}

// expire answers 503 to jobs that waited past QUEUE_TIMEOUT or lost their
// client, and returns the rest.
func (w *worker) expire(jobs []*reactorJob) []*reactorJob {
	live := jobs[:0]
	now := monoNow()
	for _, j := range jobs {
		if atomic.LoadUint32(&j.abandoned) != 0 || now-j.enqueued > int64(w.d.cfg.queueTimeout) {
			respond(j, 503, errBusy)
			w.d.s.finish(j)
			continue
		}
		live = append(live, j)
	}
	return live
}

// ---------- batching ----------

// loop keeps up to PIPELINE_DEPTH batches in flight on the connection. It
// blocks for new work only when nothing is in flight; otherwise it sends
// whatever is already queued and then reads the oldest batch, so PostgreSQL
// executes the next batch while this goroutine turns the last one into JSON.
func (w *worker) loop(q chan *reactorJob) {
	open := true
	for {
		for w.n < len(w.ring) && !w.restart {
			if len(w.retry) > 0 {
				w.single[0] = w.retry[0]
				w.retry[0] = nil
				w.retry = w.retry[1:]
				w.send(w.single[:], true)
				continue
			}
			if !open {
				break
			}
			jobs, ok := w.next(q, w.n == 0)
			if !ok {
				open = false
				break
			}
			if len(jobs) == 0 {
				break
			}
			if pending := w.process(jobs); len(pending) > 0 {
				w.send(pending, false)
			}
			clear(jobs)
		}
		if w.n > 0 {
			w.receive()
			continue
		}
		if w.restart {
			w.restartPipeline()
			continue
		}
		if !open && len(w.retry) == 0 {
			return
		}
	}
}

// next returns queued jobs: blocking for the first one only when asked, then
// draining what else is queued (see collect).
func (w *worker) next(q chan *reactorJob, block bool) ([]*reactorJob, bool) {
	jobs := w.jobs[:0]
	if block {
		j, ok := <-q
		if !ok {
			return nil, false
		}
		jobs = append(jobs, j)
	} else {
		select {
		case j, ok := <-q:
			if !ok {
				return nil, false
			}
			jobs = append(jobs, j)
		default:
			return jobs, true
		}
	}
	return w.collect(q, jobs, block), true
}

// collect drains already-queued jobs. With nothing in flight, a write batch
// also waits up to WRITE_LINGER for further writes, and never longer than
// WRITE_FLUSH_INTERVAL after its first job was queued, so concurrent
// mutations share one commit.
func (w *worker) collect(q chan *reactorJob, jobs []*reactorJob, linger bool) []*reactorJob {
	limit := cap(jobs)
	for len(jobs) < limit {
		select {
		case j, ok := <-q:
			if !ok {
				return jobs
			}
			jobs = append(jobs, j)
			continue
		default:
		}
		if !linger || !w.write || w.d.cfg.writeLinger == 0 {
			return jobs
		}
		wait := w.d.cfg.writeLinger
		if left := time.Duration(jobs[0].enqueued + int64(w.d.cfg.writeFlush) - monoNow()); left < wait {
			wait = left
		}
		if wait <= 0 {
			return jobs
		}
		w.timer.Reset(wait)
		select {
		case j, ok := <-q:
			w.timer.Stop()
			if !ok {
				return jobs
			}
			jobs = append(jobs, j)
		case <-w.timer.C:
			return jobs
		}
	}
	return jobs
}

// process plans each job and returns those that need a statement.
func (w *worker) process(jobs []*reactorJob) []*reactorJob {
	pending := w.pending[:0]
	now := monoNow()
	for _, j := range jobs {
		if atomic.LoadUint32(&j.abandoned) != 0 || now-j.enqueued > int64(w.d.cfg.queueTimeout) {
			respond(j, 503, errBusy)
			w.d.s.finish(j)
			continue
		}
		if j.db.stage == 0 && !parseJob(j) {
			w.d.s.finish(j)
			continue
		}
		act := w.safePlan(j)
		if act == actQuery {
			pending = append(pending, j)
		} else {
			w.d.after(j, act)
		}
	}
	return pending
}

func (w *worker) safePlan(j *reactorJob) (act action) {
	defer func() {
		if p := recover(); p != nil {
			log.Printf("handler panic: %v", p)
			act = respond(j, 500, errInternal)
		}
	}()
	return w.plan(j)
}

func (w *worker) safeFinish(j *reactorJob, rr *pgconn.ResultReader) (act action, err error) {
	defer func() {
		if p := recover(); p != nil {
			log.Printf("handler panic: %v", p)
			err = fmt.Errorf("panic: %v", p)
		}
	}()
	return w.finish(j, rr)
}

var resultBinary = []int16{1}
var paramBinary = []int16{1}

// send queues one batch on the pipeline: Bind/Execute per statement (no
// Describe; prepared descriptions are known) and one Sync, so the batch is one
// implicit transaction. A write batch is therefore one group commit.
func (w *worker) send(jobs []*reactorJob, single bool) {
	if jobs = w.reconnect(jobs); len(jobs) == 0 {
		return
	}
	f := &w.ring[(w.head+w.n)%len(w.ring)]
	f.jobs = append(f.jobs[:0], jobs...)
	f.single = single
	for _, j := range jobs {
		d := &j.db
		pf := paramBinary
		if d.nparams == 0 {
			pf = nil
		}
		w.pipe.SendQueryStatement(w.sd[d.stmt], d.params[:d.nparams], pf, resultBinary)
	}
	w.pipe.SendPipelineSync()
	_ = w.pg.Conn().SetDeadline(time.Now().Add(w.d.cfg.execTimeout))
	w.n++
	if err := w.pipe.Flush(); err != nil {
		if w.n > 1 {
			// Older batches were already sent and may have run: drop the
			// "nothing was sent" marking so their writes are not replayed.
			err = errors.New(err.Error())
		}
		w.broken(err, 0)
	}
}

// receive reads the oldest batch's results through its Sync.
func (w *worker) receive() {
	f := &w.ring[w.head]
	jobs := f.jobs
	done := 0
	var failed error
	synced := false
	for _, j := range jobs {
		res, err := w.pipe.GetResults()
		if err != nil {
			failed = err
			break
		}
		rr, ok := res.(*pgconn.ResultReader)
		if !ok {
			synced = res != nil
			failed = errors.New("pipeline returned too few results")
			break
		}
		act, err := w.safeFinish(j, rr)
		if err != nil {
			failed = err
			break
		}
		j.db.next = act
		done++
		if !w.write {
			w.d.after(j, act)
		}
	}
	for !synced {
		res, err := w.pipe.GetResults()
		var pgErr *pgconn.PgError
		switch {
		case errors.As(err, &pgErr):
			// A statement or the commit failed; the batch rolled back.
			if failed == nil {
				failed = err
			}
		case err != nil || res == nil:
			if err == nil {
				err = errors.New("pipeline ended before Sync")
			}
			if failed != nil {
				err = failed // the first error says whether the batch ran
			}
			w.broken(err, done)
			return
		default:
			switch r := res.(type) {
			case *pgconn.PipelineSync:
				synced = true
			case *pgconn.ResultReader:
				_, _ = r.Close()
			}
		}
	}
	if failed != nil && connectionLost(w.pg, failed) {
		// Lost results, or the server ended the session: the connection is unusable.
		w.broken(failed, done)
		return
	}
	w.pop()
	if failed == nil {
		if w.write {
			for _, j := range jobs {
				w.d.after(j, j.db.next)
			}
		}
		clear(jobs)
		return
	}
	if done+1 < len(jobs) {
		w.restart = true
	}
	// Nothing in a failed write batch committed, and reads are idempotent:
	// retry each remaining request alone so one failure affects only itself.
	rest := jobs
	if !w.write {
		rest = jobs[done:]
	}
	if f.single {
		w.fail(rest[0], failed)
		w.d.s.finish(rest[0])
	} else {
		w.retry = append(w.retry, rest...)
	}
	clear(jobs)
}

func (w *worker) pop() {
	w.head = (w.head + 1) % len(w.ring)
	w.n--
}

// broken handles a lost connection. Reads in flight are retried on a new
// connection; writes may or may not have committed, so they are not replayed.
// broken settles every batch in flight after the connection is lost. headDone
// is how many of the oldest batch's results arrived (those reads are answered).
// Reads run again after reconnecting. Writes run again only if they certainly
// never ran (see neverRan): if the oldest batch never ran, no later one did
// either. Any other write may have committed, so it gets a 500, never a replay.
func (w *worker) broken(err error, headDone int) {
	log.Printf("database connection lost with %d batches in flight: %v", w.n, err)
	safe := neverRan(err, headDone)
	head := true
	for w.n > 0 {
		f := &w.ring[w.head]
		jobs := f.jobs
		if head && !w.write {
			jobs = jobs[min(headDone, len(jobs)):]
		}
		head = false
		for _, j := range jobs {
			if !w.write || safe {
				w.retry = append(w.retry, j)
			} else {
				respond(j, 500, errInternal)
				w.d.s.finish(j)
			}
		}
		clear(f.jobs)
		w.pop()
	}
	w.head = 0
	w.pipe = nil
	if w.pg != nil {
		w.pg.Close(context.Background())
	}
	w.restart = false
}

// restartPipeline resets pgx's pipeline state once nothing is in flight.
func (w *worker) restartPipeline() {
	w.restart = false
	log.Printf("restarting database pipeline after a failed batch (write=%v)", w.write)
	if w.pipe == nil {
		return
	}
	if err := w.pipe.Close(); err != nil {
		w.pipe = nil
		w.pg.Close(context.Background())
		return
	}
	w.pipe = w.pg.StartPipeline(context.Background())
}

// after routes a job whose plan or result requires no more database work here.
func (d *dbDispatcher) after(j *reactorJob, act action) {
	switch act {
	case actHash, actVerify:
		j.db.next = act
		select {
		case d.bcrypt <- j:
			return
		default:
			respond(j, 503, errBusy)
		}
	}
	d.s.finish(j)
}

// ---------- passwords ----------

// Password work is split in two so batches actually fill. One collector gathers
// requests into batches of up to four, holding a partial batch open for at most
// BCRYPT_WAIT after its oldest request was queued. BCRYPT_WORKERS compute
// goroutines each hash a whole batch with the 4-lane bcrypt. While every
// compute worker is busy the collector blocks, requests accumulate, and the
// next batch fills at once, so under load batches are full and still spread
// over several cores. If no worker frees up within BCRYPT_STRETCH, an extra
// goroutine hashes that batch: the worker count stretches with the backlog, so
// logins get slower under load instead of waiting until the client gives up.
type bcryptBatch struct {
	n    int
	jobs [bcryptx.MaxLanes]*reactorJob
}

func (d *dbDispatcher) startBcrypt() {
	d.bcryptFree = make(chan *bcryptBatch, d.cfg.bcryptWorkers+1)
	d.bcryptBatches = make(chan *bcryptBatch)
	for range d.cfg.bcryptWorkers + 1 {
		d.bcryptFree <- new(bcryptBatch)
	}
	d.bcWG.Go(d.bcryptCollect)
	for range d.cfg.bcryptWorkers {
		d.bcWG.Go(d.bcryptCompute)
	}
}

func (d *dbDispatcher) bcryptCollect() {
	defer close(d.bcryptBatches)
	timer := time.NewTimer(time.Hour)
	timer.Stop()
	stretch := time.NewTimer(time.Hour)
	stretch.Stop()
	for {
		first, ok := <-d.bcrypt
		if !ok {
			return
		}
		var b *bcryptBatch
		select {
		case b = <-d.bcryptFree:
		default:
			b = new(bcryptBatch) // extra workers hold the pooled batches
		}
		b.jobs[0], b.n = first, 1
		deadline := first.enqueued + int64(d.cfg.bcryptWait)
	collect:
		for b.n < bcryptx.MaxLanes {
			select {
			case j, ok := <-d.bcrypt:
				if !ok {
					break collect
				}
				b.jobs[b.n] = j
				b.n++
				continue
			default:
			}
			// Requests that waited for a database connection already count
			// against the wait.
			wait := time.Duration(deadline - monoNow())
			if wait <= 0 {
				break
			}
			timer.Reset(wait)
			select {
			case j, ok := <-d.bcrypt:
				timer.Stop()
				if !ok {
					break collect
				}
				b.jobs[b.n] = j
				b.n++
			case <-timer.C:
				break collect
			}
		}
		select {
		case d.bcryptBatches <- b:
			continue
		default:
		}
		// Every compute worker is busy: wait for one, but not forever.
		stretch.Reset(d.cfg.bcryptStretch)
		select {
		case d.bcryptBatches <- b:
			if !stretch.Stop() {
				<-stretch.C
			}
		case <-stretch.C:
			d.bcWG.Go(func() {
				var bw bcryptx.Worker
				d.hashBatch(&bw, newJWTCodec(d.secret), b)
			})
		}
	}
}

func (d *dbDispatcher) bcryptCompute() {
	var bw bcryptx.Worker
	codec := newJWTCodec(d.secret)
	for b := range d.bcryptBatches {
		d.hashBatch(&bw, codec, b)
	}
}

// hashBatch hashes or verifies one batch, answers or requeues its requests and
// returns the batch to the pool.
func (d *dbDispatcher) hashBatch(bw *bcryptx.Worker, codec *jwtCodec, b *bcryptBatch) {
	var reqs [bcryptx.MaxLanes]bcryptx.Request
	var ptrs [bcryptx.MaxLanes]*bcryptx.Request
	n := b.n
	for i := range n {
		db := &b.jobs[i].db
		r := &reqs[i]
		*r = bcryptx.Request{Password: sbytes(db.str[1])}
		if db.next == actHash {
			r.Password, r.Cost = sbytes(db.str[2]), bcryptCost
		} else {
			r.Hash = db.hash[:db.hashLen]
			if db.hashLen == 0 {
				r.Hash = []byte{}
			}
		}
		ptrs[i] = r
	}
	bw.Process(ptrs[:n])
	for i := range n {
		j := b.jobs[i]
		db := &j.db
		switch {
		case db.next == actVerify:
			completeLogin(codec, j, reqs[i].OK)
			d.s.finish(j)
		case !reqs[i].OK:
			respond(j, 422, errPasswordLong)
			d.s.finish(j)
		default:
			db.hashLen = copy(db.hash[:], reqs[i].Result[:])
			db.stage = 1
			j.enqueued = monoNow()
			select {
			case d.write <- j:
			default:
				respond(j, 503, errBusy)
				d.s.finish(j)
			}
		}
		b.jobs[i] = nil
		reqs[i] = bcryptx.Request{}
	}
	b.n = 0
	select {
	case d.bcryptFree <- b:
	default: // the pool is full; this was an extra batch
	}
}

const bcryptCost = 10
