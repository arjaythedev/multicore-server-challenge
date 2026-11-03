package server

import (
	"context"
	"errors"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

const maxWriteBatchSize = 32

// A job is one SQL statement. Explicit transactions and statements depending
// on another job's result must stay outside this queue.
type writeJob struct {
	ctx    context.Context
	queued time.Time
	sql    string
	args   []any
	dest   []any // nil for Exec; otherwise QueryRow.Scan destinations.
	done   chan struct{}
	err    error
}

type writeQueue struct {
	pool    *pgxpool.Pool
	ctx     context.Context
	cancel  context.CancelFunc
	pending chan *writeJob
	work    chan []*writeJob
	wait    time.Duration
	workers sync.WaitGroup
}

func newWriteQueue(pool *pgxpool.Pool, wait time.Duration) *writeQueue {
	return newWriteQueueConfig(pool, wait, 2)
}

func newWriteQueueConfig(pool *pgxpool.Pool, wait time.Duration, workers int) *writeQueue {
	ctx, cancel := context.WithCancel(context.Background())
	q := &writeQueue{pool: pool, ctx: ctx, cancel: cancel, pending: make(chan *writeJob, 256),
		work: make(chan []*writeJob), wait: wait}
	q.workers.Add(workers + 1)
	go q.collect()
	for range workers {
		go func() {
			defer q.workers.Done()
			for {
				select {
				case batch := <-q.work:
					q.execute(batch)
					clear(batch)
				case <-q.ctx.Done():
					return
				}
			}
		}()
	}
	return q
}

func (q *writeQueue) close() { q.cancel(); q.workers.Wait() }

func (q *writeQueue) apply(ctx context.Context, sql string, args, dest []any) error {
	job := &writeJob{ctx: ctx, queued: time.Now(), sql: sql, args: args, dest: dest, done: make(chan struct{})}
	select {
	case q.pending <- job:
	case <-ctx.Done():
		return ctx.Err()
	case <-q.ctx.Done():
		return q.ctx.Err()
	}
	select {
	case <-job.done:
		return job.err
	case <-ctx.Done():
		return ctx.Err()
	case <-q.ctx.Done():
		return q.ctx.Err()
	}
}

func (q *writeQueue) collect() {
	defer q.workers.Done()
	timer := time.NewTimer(time.Hour)
	timer.Stop()
	defer timer.Stop()
	for {
		var first *writeJob
		select {
		case first = <-q.pending:
		case <-q.ctx.Done():
			return
		}
		batch := make([]*writeJob, 1, maxWriteBatchSize)
		batch[0] = first
		remaining := time.Until(first.queued.Add(q.wait))
		if remaining > 0 {
			timer.Reset(remaining)
		}
	collect:
		for len(batch) < maxWriteBatchSize {
			if remaining <= 0 {
				select {
				case job := <-q.pending:
					batch = append(batch, job)
				default:
					break collect
				}
			} else {
				select {
				case job := <-q.pending:
					batch = append(batch, job)
				case <-timer.C:
					break collect
				case <-q.ctx.Done():
					return
				}
			}
		}
		timer.Stop()
		select {
		case q.work <- batch:
		case <-q.ctx.Done():
			return
		}
	}
}

func (q *writeQueue) execute(jobs []*writeJob) {
	active := jobs[:0]
	for _, job := range jobs {
		if job.err = job.ctx.Err(); job.err != nil {
			close(job.done)
		} else {
			active = append(active, job)
		}
	}
	if len(active) == 0 {
		return
	}
	ctx, cancel := context.WithTimeout(q.ctx, 5*time.Second)
	defer cancel()
	var batch pgx.Batch
	for _, job := range active {
		batch.Queue(job.sql, job.args...)
	}
	results := q.pool.SendBatch(ctx, &batch)
	for _, job := range active {
		if job.dest == nil {
			_, job.err = results.Exec()
		} else {
			job.err = results.QueryRow().Scan(job.dest...)
		}
	}
	// Returned rows are provisional until Close consumes the implicit COMMIT.
	// In particular, do not wake a comment caller when its RETURNING row arrives.
	err := results.Close()
	if retryWriteCohort(err) {
		// A definite PostgreSQL transaction abort rolls back every statement,
		// including non-idempotent inserts whose RETURNING rows we already read.
		// Retry separately to isolate errors. Never replay unknown completion.
		for _, job := range active {
			job.err = job.ctx.Err()
			if job.err != nil {
				continue
			}
			if job.dest == nil {
				_, job.err = q.pool.Exec(ctx, job.sql, job.args...)
			} else {
				job.err = q.pool.QueryRow(ctx, job.sql, job.args...).Scan(job.dest...)
			}
		}
	} else if err != nil {
		for _, job := range active {
			job.err = err
		}
	}
	for _, job := range active {
		close(job.done)
	}
}

func (a *app) execWrite(ctx context.Context, sql string, args ...any) error {
	if a.writes != nil {
		return a.writes.apply(ctx, sql, args, nil)
	}
	_, err := a.pool.Exec(ctx, sql, args...)
	return err
}

func (a *app) scanWrite(ctx context.Context, sql string, args, dest []any) error {
	if a.writes != nil {
		return a.writes.apply(ctx, sql, args, dest)
	}
	return a.pool.QueryRow(ctx, sql, args...).Scan(dest...)
}

func retryWriteCohort(err error) bool {
	var databaseError *pgconn.PgError
	if !errors.As(err, &databaseError) {
		return false
	}
	severity := databaseError.SeverityUnlocalized
	if severity == "" {
		severity = databaseError.Severity
	}
	// Only definite transaction aborts are replayable. In particular, 40003
	// (completion unknown), FATAL shutdown and transport errors are excluded.
	return severity == "ERROR" && (strings.HasPrefix(databaseError.Code, "23") ||
		databaseError.Code == "40001" || databaseError.Code == "40P01")
}
