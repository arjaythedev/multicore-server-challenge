package main

// db.go runs queued requests against PostgreSQL, and runs bcrypt.
//
// Reads and writes have separate queues and separate connections, so writes
// waiting on WAL flushes never hold up reads. Each connection is owned by one
// worker goroutine, which keeps up to PIPELINE_DEPTH batches in flight:
//
//  1. collect   Take the next queued request plus whatever else is waiting, up
//               to READ_BATCH or WRITE_BATCH. With nothing in flight, writes
//               wait up to WRITE_LINGER for company, so they share a commit.
//  2. plan      Parse and plan each request (api.go). Requests that need no
//               statement (errors, bcrypt) leave the batch here.
//  3. send      Queue the batch on the connection's pipeline: one prepared
//               statement per request and a single Sync, so a write batch is
//               one implicit transaction (group commit).
//  4. receive   When the pipeline is full, or nothing else is queued, read the
//               oldest batch's results. Each request is finished from its rows
//               (api.go); reads are answered at once, writes after the commit.
//
// While PostgreSQL runs one batch the worker turns the previous one into JSON.
//
// When something fails:
//   - one statement fails: the batch rolled back, so each request is sent again
//     alone (w.retry) and only the bad one fails. pgx then needs its pipeline
//     restarted (see restartPipeline);
//   - the connection is lost: every batch in flight is settled (broken), and
//     the worker reconnects with exponential backoff while holding requests.
//     Reads run again. Writes run again only if they certainly never executed;
//     one that may have committed gets a 500 and is never replayed;
//   - a request waited longer than QUEUE_TIMEOUT or its client left: 503.
//
// Logins and new passwords go to the bcrypt workers (end of this file), and a
// new password's request comes back to the write queue once hashed.

import (
	"context"
	"errors"
	"fmt"
	"log"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"conduit/src/internal/bcryptx"

	"github.com/jackc/pgx/v5/pgconn"
)

const bcryptCost = 10

// ---------- configuration ----------

type dbConfig struct {
	readConns, writeConns      int           // connections (and workers) per queue
	pipelineDepth              int           // batches in flight per connection
	readBatch, writeBatch      int           // most requests per batch
	readQueue, writeQueue      int           // queue sizes: every request slot fits
	writeLinger, writeFlush    time.Duration // how long a write batch waits for company
	queueTimeout, execTimeout  time.Duration // 503 after this long queued; socket deadline
	bcryptWorkers              int           // bcrypt compute goroutines
	bcryptQueue                int           // requests waiting for bcrypt
	bcryptWait, bcryptStretch  time.Duration // batch fill window; when extra workers start
	reconnectMin, reconnectMax time.Duration // reconnect backoff bounds (backoff.go)
}

// dbConfigFromEnv reads the database settings. slots is the number of request
// slots the event loops hold: every queue is sized for all of them, so a queue
// can never be full and overload shows up as latency.
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

// ---------- dispatcher: queues and workers ----------

type dbDispatcher struct {
	s      *reactorServer
	cfg    dbConfig
	pgcfg  *pgconn.Config
	secret []byte

	read, write chan *reactorJob
	bcrypt      chan *reactorJob  // requests waiting for bcrypt
	bcryptReady chan *bcryptBatch // collector -> compute workers
	bcryptFree  chan *bcryptBatch // reusable batches

	workers []*worker
	wg      sync.WaitGroup // database workers
	bcWG    sync.WaitGroup // bcrypt goroutines
}

// worker owns one connection and its pipeline, and serves one queue.
type worker struct {
	d     *dbDispatcher
	write bool
	jwt   *jwtCodec
	pg    *pgconn.PgConn
	pipe  *pgconn.Pipeline
	sd    [numStmts]*pgconn.StatementDescription // prepared statements, by id

	jobs    []*reactorJob // the batch being collected (reused)
	pending []*reactorJob // the part of it that needs a statement (reused)
	single  [1]*reactorJob
	retry   []*reactorJob // requests to send again alone after their batch failed

	ring    []flight // batches in flight, oldest at head
	head, n int

	// After a statement fails mid-batch, pgx (v5.11.0) leaves the skipped
	// statements' descriptions queued, so the pipeline is drained and restarted.
	restart bool

	retryAt time.Time // no reconnect attempt before this
	bo      backoff
	timer   *time.Timer // write linger
}

// flight is one batch sent on the pipeline and not yet read back. single marks
// a request sent again alone, whose failure is that request's own answer.
type flight struct {
	jobs   []*reactorJob
	single bool
}

func newDBDispatcher(s *reactorServer, cfg dbConfig, pgcfg *pgconn.Config, secret []byte) *dbDispatcher {
	d := &dbDispatcher{
		s: s, cfg: cfg, pgcfg: pgcfg, secret: secret,
		read:   make(chan *reactorJob, cfg.readQueue),
		write:  make(chan *reactorJob, cfg.writeQueue),
		bcrypt: make(chan *reactorJob, cfg.bcryptQueue),
	}
	for i := range cfg.readConns + cfg.writeConns {
		w := &worker{d: d, write: i >= cfg.readConns, jwt: newJWTCodec(secret)}
		w.bo = backoff{min: cfg.reconnectMin, max: cfg.reconnectMax}
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
		log.Printf("database not ready (attempt %d), retrying in %s: %v",
			bo.attempts, wait.Round(time.Millisecond), err)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(wait):
		}
	}
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

// stop runs after every event loop has drained its outstanding requests, so
// nothing is queued or in flight.
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

// submit queues a request from an event loop without blocking; false means the
// queue is full (it is sized so that cannot happen).
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

// after hands on a request that needs no more database work from this worker:
// to the bcrypt workers, or back to its event loop with its response.
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

// ---------- worker: collect, plan, send, receive ----------

// loop keeps up to PIPELINE_DEPTH batches in flight. It blocks for new work
// only when nothing is in flight; otherwise it sends whatever is already queued
// and then reads the oldest batch back.
func (w *worker) loop(q chan *reactorJob) {
	open := true
	for {
		// Fill the pipeline: retries first, then new batches.
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
				open = false // queue closed: shutting down
				break
			}
			if len(jobs) == 0 {
				break
			}
			if pending := w.plan(jobs); len(pending) > 0 {
				w.send(pending, false)
			}
			clear(jobs)
		}
		// Then read back the oldest batch, or restart the pipeline once empty.
		switch {
		case w.n > 0:
			w.receive()
		case w.restart:
			w.restartPipeline()
		case !open && len(w.retry) == 0:
			return
		}
	}
}

// next returns queued requests: blocking for the first one only when asked,
// then draining what else is queued (see collect).
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

// collect drains already-queued requests into the batch. With nothing in
// flight (linger), a write batch also waits up to WRITE_LINGER for more writes,
// but never past WRITE_FLUSH_INTERVAL after its first request was queued.
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

// plan parses and plans each request and returns those that need a statement.
// The rest (expired, invalid, answered or bound for bcrypt) leave here.
func (w *worker) plan(jobs []*reactorJob) []*reactorJob {
	pending := w.pending[:0]
	for _, j := range w.expire(jobs) {
		if !j.db.hashed && !parseJob(j) {
			w.d.s.finish(j)
			continue
		}
		if act := w.safePlan(j); act == actQuery {
			pending = append(pending, j)
		} else {
			w.d.after(j, act)
		}
	}
	return pending
}

// expire answers 503 to requests that waited past QUEUE_TIMEOUT or lost their
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

// safePlan runs the request's plan (api.go), turning a panic into a 500.
func (w *worker) safePlan(j *reactorJob) (act action) {
	defer func() {
		if p := recover(); p != nil {
			log.Printf("handler panic: %v", p)
			act = respond(j, 500, errInternal)
		}
	}()
	return w.planRequest(j)
}

// safeFinish runs finish (api.go), turning a panic into an error for the batch.
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

// send queues one batch on the pipeline: one prepared statement per request
// (no Describe; the descriptions are known) and a single Sync.
func (w *worker) send(jobs []*reactorJob, single bool) {
	if jobs = w.reconnect(jobs); len(jobs) == 0 {
		return
	}
	f := &w.ring[(w.head+w.n)%len(w.ring)]
	f.jobs = append(f.jobs[:0], jobs...)
	f.single = single
	for _, j := range jobs {
		d := &j.db
		formats := paramBinary
		if d.nparams == 0 {
			formats = nil
		}
		w.pipe.SendQueryStatement(w.sd[d.stmt], d.params[:d.nparams], formats, resultBinary)
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

// receive reads the oldest batch's results up to its Sync and settles it.
func (w *worker) receive() {
	f := &w.ring[w.head]
	jobs := f.jobs
	done, failed, synced := w.readResults(jobs)
	if !synced {
		if lost := w.drainToSync(&failed); lost != nil {
			w.broken(lost, done)
			return
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
				w.d.after(j, j.db.next) // committed
			}
		}
		clear(jobs)
		return
	}

	// A statement failed and the batch rolled back. Nothing in it committed and
	// reads are idempotent, so the remaining requests are sent again one at a
	// time and only the bad one fails.
	if done+1 < len(jobs) {
		w.restart = true
	}
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

// readResults finishes requests from their result sets in order until one
// fails or the batch ends. It returns how many finished, the first error, and
// whether the batch's Sync was already reached.
func (w *worker) readResults(jobs []*reactorJob) (done int, failed error, synced bool) {
	for _, j := range jobs {
		res, err := w.pipe.GetResults()
		if err != nil {
			return done, err, false
		}
		rr, ok := res.(*pgconn.ResultReader)
		if !ok {
			return done, errors.New("pipeline returned too few results"), res != nil
		}
		act, err := w.safeFinish(j, rr)
		if err != nil {
			return done, err, false
		}
		j.db.next = act
		done++
		if !w.write {
			w.d.after(j, act)
		}
	}
	return done, nil, false
}

// drainToSync reads the rest of the batch up to its Sync. A statement error
// becomes *failed (if none yet). It returns the error to settle the connection
// with if it was lost before the Sync.
func (w *worker) drainToSync(failed *error) error {
	for {
		res, err := w.pipe.GetResults()
		var pgErr *pgconn.PgError
		switch {
		case errors.As(err, &pgErr):
			// A statement or the commit failed; the batch rolled back.
			if *failed == nil {
				*failed = err
			}
		case err != nil || res == nil:
			if *failed != nil {
				return *failed // the first error says whether the batch ran
			}
			if err == nil {
				err = errors.New("pipeline ended before Sync")
			}
			return err
		default:
			switch r := res.(type) {
			case *pgconn.PipelineSync:
				return nil
			case *pgconn.ResultReader:
				_, _ = r.Close()
			}
		}
	}
}

func (w *worker) pop() {
	w.head = (w.head + 1) % len(w.ring)
	w.n--
}

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

// ---------- connections ----------

// paramOIDs are the PostgreSQL types each parameter code in sql.go accepts.
var paramOIDs = map[byte][]uint32{'i': {20}, 't': {25, 1043}, 'a': {1009}}

// connect opens a connection, prepares this worker's statements (checking each
// takes the parameter types sql.go declares) and starts its pipeline.
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
		if err == nil {
			err = checkParams(sd, def.params)
		}
		if err != nil {
			pg.Close(ctx)
			return fmt.Errorf("prepare statement %d: %w", id, err)
		}
		w.sd[id] = sd
	}
	w.pg = pg
	// The pipeline stays open for the connection's life, so its context must
	// not be the connect deadline.
	w.pipe = pg.StartPipeline(context.Background())
	return nil
}

func checkParams(sd *pgconn.StatementDescription, want string) error {
	if len(sd.ParamOIDs) != len(want) {
		return fmt.Errorf("%d parameters, want %d", len(sd.ParamOIDs), len(want))
	}
	for i, oid := range sd.ParamOIDs {
		ok := false
		for _, accepted := range paramOIDs[want[i]] {
			ok = ok || oid == accepted
		}
		if !ok {
			return fmt.Errorf("parameter %d has type oid %d, want %c", i+1, oid, want[i])
		}
	}
	return nil
}

// reconnect makes sure the worker has a connection and pipeline before it
// sends. If the connection is broken it retries with exponential backoff,
// holding the requests: during an outage they wait rather than fail. Requests
// that pass QUEUE_TIMEOUT, or whose client left, get 503. It returns the
// requests still waiting.
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
		if jobs = w.expire(jobs); len(jobs) == 0 {
			return jobs // nothing waiting; the next request retries when the backoff allows
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

// ---------- bcrypt workers ----------

// Password work is split in two so batches actually fill. One collector groups
// waiting requests into batches of up to four, holding a partial batch open for
// at most BCRYPT_WAIT after its oldest request was queued. BCRYPT_WORKERS
// compute goroutines each hash a whole batch with the 4-lane bcrypt. While every
// compute worker is busy the collector waits, requests accumulate and the next
// batch fills at once, so under load batches are full and still spread over
// several cores. If no worker frees up within BCRYPT_STRETCH, an extra
// goroutine hashes that batch: the worker count stretches with the backlog, so
// logins get slower under load instead of waiting until the client gives up.
type bcryptBatch struct {
	n    int
	jobs [bcryptx.MaxLanes]*reactorJob
}

func (d *dbDispatcher) startBcrypt() {
	d.bcryptFree = make(chan *bcryptBatch, d.cfg.bcryptWorkers+1)
	d.bcryptReady = make(chan *bcryptBatch)
	for range d.cfg.bcryptWorkers + 1 {
		d.bcryptFree <- new(bcryptBatch)
	}
	d.bcWG.Go(d.bcryptCollect)
	for range d.cfg.bcryptWorkers {
		d.bcWG.Go(d.bcryptCompute)
	}
}

// bcryptCollect builds batches and hands them to the compute workers.
func (d *dbDispatcher) bcryptCollect() {
	defer close(d.bcryptReady)
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
		// Time spent waiting for the database already counts against the wait.
		deadline := first.enqueued + int64(d.cfg.bcryptWait)
	fill:
		for b.n < bcryptx.MaxLanes {
			select {
			case j, ok := <-d.bcrypt:
				if !ok {
					break fill
				}
				b.jobs[b.n] = j
				b.n++
				continue
			default:
			}
			wait := time.Duration(deadline - monoNow())
			if wait <= 0 {
				break
			}
			timer.Reset(wait)
			select {
			case j, ok := <-d.bcrypt:
				timer.Stop()
				if !ok {
					break fill
				}
				b.jobs[b.n] = j
				b.n++
			case <-timer.C:
				break fill
			}
		}

		// Hand the batch to a free compute worker; if none frees up within
		// BCRYPT_STRETCH, start an extra one for it.
		select {
		case d.bcryptReady <- b:
			continue
		default:
		}
		stretch.Reset(d.cfg.bcryptStretch)
		select {
		case d.bcryptReady <- b:
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
	for b := range d.bcryptReady {
		d.hashBatch(&bw, codec, b)
	}
}

// hashBatch hashes new passwords and verifies logins for one batch, then
// answers logins, sends hashed requests back to the write queue, and returns
// the batch to the pool.
func (d *dbDispatcher) hashBatch(bw *bcryptx.Worker, codec *jwtCodec, b *bcryptBatch) {
	var reqs [bcryptx.MaxLanes]bcryptx.Request
	var ptrs [bcryptx.MaxLanes]*bcryptx.Request
	n := b.n
	for i := range n {
		db := &b.jobs[i].db
		r := &reqs[i]
		*r = bcryptx.Request{Password: sbytes(*db.in.password)}
		if db.next == actHash {
			r.Cost = bcryptCost
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
			db.hashed = true
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
