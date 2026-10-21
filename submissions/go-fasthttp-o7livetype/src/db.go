package main

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

// dbDispatcher owns every PostgreSQL connection. Reads and writes have separate
// queues and separate connections, so WAL flush waits never hold up reads.
//
// Each worker goroutine owns one connection. It takes the next queued job, then
// drains whatever else is waiting (up to a batch limit) and sends all of their
// statements as one pipeline: Bind/Execute per statement and a single Sync.
//
// Reads: each request is released as soon as its rows are read.
//
// Writes: the pipeline is one implicit transaction, so a batch is a group
// commit: one round trip and one WAL flush for every mutation in it. Requests
// are released after the commit. If any statement fails the whole group rolls
// back and each request is retried alone; if the connection fails mid-commit
// the outcome is unknown, so nothing is replayed and the requests get 500.
type dbDispatcher struct {
	cfg   dbConfig
	pgcfg *pgconn.Config
	jwt   *jwtCodec

	read, write chan *job
	workers     []*worker
	wg          sync.WaitGroup
}

type dbConfig struct {
	readConns, writeConns      int
	readBatch, writeBatch      int
	readQueue, writeQueue      int
	writeLinger, writeFlush    time.Duration
	queueTimeout, execTimeout  time.Duration
	bcryptWorkers              int
	bcryptWait                 time.Duration
	reconnectMin, reconnectMax time.Duration
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

type worker struct {
	d       *dbDispatcher
	write   bool
	pg      *pgconn.PgConn
	sd      [numStmts]*pgconn.StatementDescription
	jobs    []*job
	retryAt time.Time
	bo      backoff
	timer   *time.Timer
}

func newDBDispatcher(cfg dbConfig, pgcfg *pgconn.Config, codec *jwtCodec) *dbDispatcher {
	d := &dbDispatcher{cfg: cfg, pgcfg: pgcfg, jwt: codec,
		read: make(chan *job, cfg.readQueue), write: make(chan *job, cfg.writeQueue)}
	for i := range cfg.readConns + cfg.writeConns {
		w := &worker{d: d, write: i >= cfg.readConns, bo: backoff{min: cfg.reconnectMin, max: cfg.reconnectMax}}
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
			_, failed := bo.reset()
			slog.Info("database connections ready", "connections", len(d.workers), "attempts", failed+1)
			return nil
		}
		wait := bo.fail()
		if ctx.Err() != nil || time.Now().Add(wait).After(deadline) {
			return err
		}
		slog.Warn("database not ready, retrying", "attempt", bo.attempts, "retry_in", wait.Round(time.Millisecond).String(), "err", err)
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

// submit queues a planned job without blocking; false means the queue is full.
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

// release hands a finished job back to its waiting handler.
func release(j *job) { j.done <- struct{}{} }

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
		if err == nil && len(sd.ParamOIDs) != len(def.params) {
			err = fmt.Errorf("%d parameters, want %d", len(sd.ParamOIDs), len(def.params))
		}
		for i := 0; err == nil && i < len(sd.ParamOIDs); i++ {
			ok := false
			for _, want := range paramOIDs[def.params[i]] {
				ok = ok || sd.ParamOIDs[i] == want
			}
			if !ok {
				err = fmt.Errorf("parameter %d has type oid %d, want %c", i+1, sd.ParamOIDs[i], def.params[i])
			}
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

// reconnect makes sure the worker has a connection before it runs jobs. If the
// connection is broken it retries with exponential backoff, holding the jobs:
// during an outage requests wait rather than fail. Jobs that pass QUEUE_TIMEOUT
// while waiting get 503. It returns the jobs that are still live.
func (w *worker) reconnect(jobs []*job) []*job {
	for {
		if w.pg != nil && !w.pg.IsClosed() {
			return jobs
		}
		w.pg = nil
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

// expire answers 503 to jobs that waited longer than QUEUE_TIMEOUT and returns the rest.
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

// ---------- batching ----------

func (w *worker) loop(q chan *job) {
	for {
		first, ok := <-q
		if !ok {
			return
		}
		jobs := w.collect(q, append(w.jobs[:0], first))
		w.process(jobs)
		clear(jobs)
	}
}

// collect drains already-queued jobs. A write batch also waits up to
// WRITE_LINGER for further writes, and never longer than WRITE_FLUSH_INTERVAL
// after its first job was queued, so concurrent mutations share one commit.
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

func (w *worker) process(jobs []*job) {
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
	if len(live) > 0 {
		w.execute(live)
	}
}

func (w *worker) safeFinish(j *job, rr *pgconn.ResultReader) (act action, err error) {
	defer func() {
		if p := recover(); p != nil {
			stats.panics.Add(1)
			slog.Error("panic while reading results", "route", j.db.route.String(), "panic", fmt.Sprint(p), "stack", string(debug.Stack()))
			err = fmt.Errorf("panic: %v", p)
		}
	}()
	return w.finish(j, rr)
}

var resultBinary = []int16{1}
var paramBinary = []int16{1}

// execute runs the jobs' statements in one pipeline ending in a single Sync.
func (w *worker) execute(jobs []*job) {
	for {
		if jobs = w.reconnect(jobs); len(jobs) == 0 {
			return
		}
		rerun, ok := w.run(jobs)
		if ok {
			return
		}
		jobs = rerun // the connection was lost before these ran: reconnect, then run them again
	}
}

// run executes one batch. If the connection is lost and some requests can run
// again safely, it returns them with ok false.
func (w *worker) run(jobs []*job) (rerun []*job, ok bool) {
	var batch pgconn.Batch
	for _, j := range jobs {
		d := &j.db
		pf := paramBinary
		if d.nparams == 0 {
			pf = nil
		}
		batch.ExecStatement(w.sd[d.stmt], d.params[:d.nparams], pf, resultBinary)
	}
	if err := w.pg.Conn().SetDeadline(time.Now().Add(w.d.cfg.execTimeout)); err != nil {
		// The socket is unusable and nothing was sent: reconnect, then run the batch.
		slog.Error("database socket deadline failed", "write", w.write, "err", err)
		w.pg.Close(context.Background())
		return jobs, false
	}
	mrr := w.pg.ExecBatch(context.Background(), &batch)
	done := 0
	var failed error
	for _, j := range jobs {
		if !mrr.NextResult() {
			break
		}
		act, err := w.safeFinish(j, mrr.ResultReader())
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
	err := mrr.Close()
	if err == nil {
		err = failed
	}
	if err == nil && done < len(jobs) {
		err = errors.New("pipeline returned too few results")
	}
	if err == nil {
		if w.write {
			for _, j := range jobs {
				release(j)
			}
		}
		return nil, true
	}
	stats.dbErrors.Add(1)
	rest := jobs
	if !w.write {
		rest = jobs[done:] // reads already answered are done
	}
	if connectionLost(w.pg, err) {
		w.pg.Close(context.Background())
		if !w.write || neverRan(err, done) {
			// Reads are safe to repeat, and these writes never ran.
			slog.Warn("database connection lost; requests will run again after reconnecting",
				"write", w.write, "requests", len(rest), "err", err)
			return rest, false
		}
		// The group may or may not have committed: never replay it.
		stats.unknownOutcome.Add(int64(len(rest)))
		slog.Error("write group failed with unknown commit outcome; answering 500 without retry",
			"batch", len(jobs), "err", err)
		for _, j := range rest {
			respond(j, 500, errInternal)
			release(j)
		}
		return nil, true
	}
	if len(jobs) == 1 {
		w.fail(jobs[0], err)
		release(jobs[0])
		return nil, true
	}
	// Nothing in a failed write group committed, and reads are idempotent:
	// retry each remaining request alone so one failure affects only itself.
	stats.groupRetries.Add(1)
	slog.Debug("batch failed, retrying requests one at a time", "write", w.write, "batch", len(jobs), "retry", len(rest), "err", err)
	for _, j := range rest {
		single := [1]*job{j}
		w.execute(single[:])
	}
	return nil, true
}
