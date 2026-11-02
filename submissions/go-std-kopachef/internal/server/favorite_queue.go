package server

import (
	"context"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const insertFavoriteSQL = `INSERT INTO favorites (user_id, article_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`
const deleteFavoriteSQL = `DELETE FROM favorites WHERE user_id = $1 AND article_id = $2`

func favoriteStatement(insert bool) string {
	if insert {
		return insertFavoriteSQL
	}
	return deleteFavoriteSQL
}

type favoriteJob struct {
	ctx             context.Context
	queued          time.Time
	viewer, article int64
	insert          bool
	done            chan struct{}
	err             error
}

type favoriteQueue struct {
	pool    *pgxpool.Pool
	ctx     context.Context
	cancel  context.CancelFunc
	pending chan *favoriteJob
	work    chan []*favoriteJob
	wait    time.Duration
	workers sync.WaitGroup
}

func newFavoriteQueue(pool *pgxpool.Pool, wait time.Duration) *favoriteQueue {
	ctx, cancel := context.WithCancel(context.Background())
	q := &favoriteQueue{pool: pool, ctx: ctx, cancel: cancel, pending: make(chan *favoriteJob, 256),
		work: make(chan []*favoriteJob), wait: wait}
	q.workers.Add(3)
	go q.collect()
	for range 2 {
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

func (q *favoriteQueue) close() { q.cancel(); q.workers.Wait() }

func (q *favoriteQueue) apply(ctx context.Context, viewer, article int64, insert bool) error {
	job := &favoriteJob{ctx: ctx, queued: time.Now(), viewer: viewer, article: article, insert: insert, done: make(chan struct{})}
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

func (q *favoriteQueue) collect() {
	defer q.workers.Done()
	timer := time.NewTimer(time.Hour)
	timer.Stop()
	defer timer.Stop()
	for {
		var first *favoriteJob
		select {
		case first = <-q.pending:
		case <-q.ctx.Done():
			return
		}
		batch := make([]*favoriteJob, 1, 32)
		batch[0] = first
		remaining := time.Until(first.queued.Add(q.wait))
		if remaining > 0 {
			timer.Reset(remaining)
		}
	collect:
		for len(batch) < 32 {
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

func (q *favoriteQueue) execute(jobs []*favoriteJob) {
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
		batch.Queue(favoriteStatement(job.insert), job.viewer, job.article)
	}
	// SendBatch runs an implicit transaction. Close consumes ReadyForQuery,
	// including COMMIT, before any successful response can be published.
	err := q.pool.SendBatch(ctx, &batch).Close()
	retries := 0
	if retryWriteCohort(err) {
		// A PostgreSQL error rolls back the whole implicit transaction. Retry
		// its independent idempotent writes to isolate the failing request.
		// Network/commit uncertainty never triggers replay.
		for _, job := range active {
			job.err = job.ctx.Err()
			if job.err == nil {
				retries++
				_, job.err = q.pool.Exec(ctx, favoriteStatement(job.insert), job.viewer, job.article)
			}
		}
	} else {
		for _, job := range active {
			job.err = err
		}
	}
	recordFavoriteBatch(len(active), retries)
	for _, job := range active {
		close(job.done)
	}
}
