package main

// db.go runs planned requests against PostgreSQL.
//
// Reads and writes have separate queues and separate connections, so writes
// waiting on WAL flushes never hold up reads. Each connection is owned by one
// worker goroutine, which repeats:
//
//  1. collect   Take the next queued request plus whatever else is waiting, up
//               to READ_BATCH or WRITE_BATCH. Writes wait up to WRITE_LINGER
//               for company, so concurrent writes share a commit.
//  2. send      Send every request's prepared statement in one pipeline ending
//               in a single Sync: one round trip for the whole batch.
//  3. finish    Write each response from its result rows (api.go). A read is
//               answered as soon as its rows arrive. A write batch is one
//               implicit transaction (group commit), so writes are answered
//               only after the commit.
//
// When something fails:
//   - one statement fails: the batch rolled back, so each request runs again
//     alone and only the bad one fails;
//   - the connection is lost: the worker reconnects with exponential backoff
//     while holding its requests. Reads run again. Writes run again only if
//     they certainly never executed; one that may have committed gets a 500 and
//     is never replayed.
//   - a request waited longer than QUEUE_TIMEOUT: it gets a 503.

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"runtime/debug"
	"strconv"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

// ---------- configuration ----------

type dbConfig struct {
	readConns, writeConns      int           // connections (and workers) per queue
	readBatch, writeBatch      int           // most requests per round trip
	readQueue, writeQueue      int           // queue sizes (set in main.go)
	writeLinger, writeFlush    time.Duration // how long a write batch waits for company
	queueTimeout, execTimeout  time.Duration // 503 after this long queued; socket deadline
	bcryptWorkers              int           // concurrent bcrypt hashes (server.go)
	bcryptWait                 time.Duration // when the bcrypt limit stretches (server.go)
	reconnectMin, reconnectMax time.Duration // reconnect backoff bounds (backoff.go)
}

func dbConfigFromEnv(cores int) (dbConfig, error) {
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
		{"BCRYPT_WORKERS", &c.bcryptWorkers, max(1, cores/2), 1, 128},
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
		// Nginx gives up on an upstream response after 30 s; past that nobody is waiting.
		{"QUEUE_TIMEOUT", &c.queueTimeout, 30 * time.Second},
		{"DB_EXEC_TIMEOUT", &c.execTimeout, 10 * time.Second},
		{"BCRYPT_WAIT", &c.bcryptWait, time.Second},
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
	if c.reconnectMin <= 0 || c.reconnectMax < c.reconnectMin {
		return c, errors.New("DB_RECONNECT_MIN must be above 0 and at most DB_RECONNECT_MAX")
	}
	return c, nil
}

// ---------- dispatcher: queues and workers ----------

type dbDispatcher struct {
	cfg   dbConfig
	pgcfg *pgconn.Config
	jwt   *jwtCodec

	read, write chan *job
	workers     []*worker
	wg          sync.WaitGroup
}

// worker owns one connection and serves one queue.
type worker struct {
	d       *dbDispatcher
	write   bool
	pg      *pgconn.PgConn
	sd      [numStmts]*pgconn.StatementDescription // prepared statements, by id
	jobs    []*job                                 // the current batch (reused)
	retryAt time.Time                              // no reconnect attempt before this
	bo      backoff
	timer   *time.Timer // write linger
}

func newDBDispatcher(cfg dbConfig, pgcfg *pgconn.Config, codec *jwtCodec) *dbDispatcher {
	d := &dbDispatcher{
		cfg: cfg, pgcfg: pgcfg, jwt: codec,
		read:  make(chan *job, cfg.readQueue),
		write: make(chan *job, cfg.writeQueue),
	}
	for i := range cfg.readConns + cfg.writeConns {
		w := &worker{d: d, write: i >= cfg.readConns}
		w.bo = backoff{min: cfg.reconnectMin, max: cfg.reconnectMax}
		limit := cfg.readBatch
		if w.write {
			limit = cfg.writeBatch
		}
		w.jobs = make([]*job, 0, limit)
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
			_, failed := bo.reset()
			slog.Info("database connections ready", "connections", len(d.workers), "attempts", failed+1)
			return nil
		}
		wait := bo.fail()
		if ctx.Err() != nil || time.Now().Add(wait).After(deadline) {
			return err
		}
		slog.Warn("database not ready, retrying", "attempt", bo.attempts,
			"retry_in", wait.Round(time.Millisecond).String(), "err", err)
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
}

// stop runs after the HTTP server has shut down, so no job is queued.
func (d *dbDispatcher) stop() {
	close(d.read)
	close(d.write)
	d.wg.Wait()
	for _, w := range d.workers {
		if w.pg != nil {
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			w.pg.Close(ctx)
			cancel()
		}
	}
}

// submit queues a planned request without blocking; false means the queue is
// full (it is sized so that cannot happen; see main.go).
func (d *dbDispatcher) submit(j *job) bool {
	q := d.read
	if j.db.stmt >= firstWriteStmt {
		q = d.write
	}
	j.enqueued = time.Now()
	select {
	case q <- j:
		return true
	default:
		return false
	}
}

// release hands a finished request back to its waiting handler.
func release(j *job) { j.done <- struct{}{} }

// ---------- worker: collect, send, finish ----------

func (w *worker) loop(q chan *job) {
	for {
		first, ok := <-q
		if !ok {
			return
		}
		jobs := w.collect(q, append(w.jobs[:0], first))
		if jobs = w.expire(jobs); len(jobs) > 0 {
			w.execute(jobs)
		}
		clear(w.jobs[:cap(w.jobs)])
	}
}

// collect drains already-queued requests into the batch. A write batch also
// waits up to WRITE_LINGER for more writes, but never past WRITE_FLUSH_INTERVAL
// after its first request was queued.
func (w *worker) collect(q chan *job, jobs []*job) []*job {
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
		if !w.write || w.d.cfg.writeLinger == 0 {
			return jobs
		}
		wait := min(w.d.cfg.writeLinger, time.Until(jobs[0].enqueued.Add(w.d.cfg.writeFlush)))
		if wait <= 0 {
			return jobs
		}
		w.timer.Reset(wait)
		select {
		case j, ok := <-q:
			if !w.timer.Stop() {
				<-w.timer.C
			}
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

// expire answers 503 to requests that waited longer than QUEUE_TIMEOUT and
// returns the rest.
func (w *worker) expire(jobs []*job) []*job {
	live := jobs[:0]
	now := time.Now()
	for _, j := range jobs {
		if now.Sub(j.enqueued) > w.d.cfg.queueTimeout {
			respond(j, 503, errBusy)
			release(j)
			continue
		}
		live = append(live, j)
	}
	return live
}

// execute runs one batch to the end: it reconnects first if needed, and after
// a lost connection runs again whatever is safe to run again.
func (w *worker) execute(jobs []*job) {
	for {
		if jobs = w.reconnect(jobs); len(jobs) == 0 {
			return
		}
		done, err := w.send(jobs)
		if err == nil {
			if w.write {
				for _, j := range jobs {
					release(j) // committed
				}
			}
			return
		}
		if jobs = w.settleFailure(jobs, done, err); len(jobs) == 0 {
			return
		}
	}
}

var resultBinary = []int16{1}
var paramBinary = []int16{1}

// notSent marks an error that happened before anything reached PostgreSQL, so
// the batch is safe to run again (see neverRan).
type notSent struct{ error }

func (notSent) SafeToRetry() bool { return true }

// send runs the batch as one pipeline ending in a single Sync and finishes
// each request from its rows. It returns how many results it read. Reads are
// released as they finish; writes are left for the caller.
func (w *worker) send(jobs []*job) (done int, err error) {
	var batch pgconn.Batch
	for _, j := range jobs {
		d := &j.db
		formats := paramBinary
		if d.nparams == 0 {
			formats = nil
		}
		batch.ExecStatement(w.sd[d.stmt], d.params[:d.nparams], formats, resultBinary)
	}
	if err := w.pg.Conn().SetDeadline(time.Now().Add(w.d.cfg.execTimeout)); err != nil {
		w.pg.Close(context.Background())
		return 0, notSent{fmt.Errorf("socket deadline: %w", err)}
	}

	results := w.pg.ExecBatch(context.Background(), &batch)
	var failed error
	for _, j := range jobs {
		if !results.NextResult() {
			break
		}
		act, err := w.safeFinish(j, results.ResultReader())
		if err != nil {
			failed = err
			break
		}
		j.db.next = act
		done++
		if !w.write {
			release(j)
		}
	}
	err = results.Close()
	switch {
	case err != nil:
	case failed != nil:
		err = failed
	case done < len(jobs):
		err = errors.New("pipeline returned too few results")
	}
	return done, err
}

// safeFinish runs finish (api.go), turning a panic into an error for this batch.
func (w *worker) safeFinish(j *job, rr *pgconn.ResultReader) (act action, err error) {
	defer func() {
		if p := recover(); p != nil {
			stats.panics.Add(1)
			slog.Error("panic while reading results", "route", j.db.route.String(),
				"panic", fmt.Sprint(p), "stack", string(debug.Stack()))
			err = fmt.Errorf("panic: %v", p)
		}
	}()
	return w.finish(j, rr)
}

// settleFailure decides what happens to every request of a failed batch. It
// answers the ones it can and returns those that should run again after the
// worker reconnects.
func (w *worker) settleFailure(jobs []*job, done int, err error) (rerun []*job) {
	stats.dbErrors.Add(1)
	rest := jobs
	if !w.write {
		rest = jobs[done:] // reads already answered are done
	}

	// The connection is gone.
	if connectionLost(w.pg, err) {
		w.pg.Close(context.Background())
		if !w.write || neverRan(err, done) {
			slog.Warn("database connection lost; requests will run again after reconnecting",
				"write", w.write, "requests", len(rest), "err", err)
			return rest
		}
		stats.unknownOutcome.Add(int64(len(rest)))
		slog.Error("write group failed with unknown commit outcome; answering 500 without retry",
			"batch", len(jobs), "err", err)
		for _, j := range rest {
			respond(j, 500, errInternal)
			release(j)
		}
		return nil
	}

	// A statement failed and the batch rolled back.
	if len(jobs) == 1 {
		w.fail(jobs[0], err)
		release(jobs[0])
		return nil
	}
	stats.groupRetries.Add(1)
	slog.Debug("batch failed, running its requests one at a time",
		"write", w.write, "batch", len(jobs), "retry", len(rest), "err", err)
	for _, j := range rest {
		single := [1]*job{j}
		w.execute(single[:])
	}
	return nil
}

// ---------- connections ----------

// paramOIDs are the PostgreSQL types each parameter code in sql.go accepts.
var paramOIDs = map[byte][]uint32{'i': {20}, 't': {25, 1043}, 'a': {1009}}

// connect opens a connection and prepares this worker's statements, checking
// that each one takes the parameter types sql.go declares.
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

// reconnect makes sure the worker has a connection before it sends. If the
// connection is broken it retries with exponential backoff, holding the
// requests: during an outage they wait rather than fail. Requests that pass
// QUEUE_TIMEOUT while waiting get 503. It returns the requests still waiting.
func (w *worker) reconnect(jobs []*job) []*job {
	for {
		if w.pg != nil && !w.pg.IsClosed() {
			return jobs
		}
		w.pg = nil
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
			stats.reconnects.Add(1)
			slog.Info("database connection re-established", "write", w.write,
				"downtime", down.Round(time.Millisecond).String(), "failed_attempts", failed)
			return jobs
		}
		wait := w.bo.fail()
		w.retryAt = time.Now().Add(wait)
		stats.reconnectFailures.Add(1)
		if w.bo.logWorthy() {
			slog.Error("database reconnect failed", "write", w.write, "attempt", w.bo.attempts,
				"retry_in", wait.Round(time.Millisecond).String(), "waiting_requests", len(jobs), "err", err)
		}
	}
}
