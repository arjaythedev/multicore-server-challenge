package main

import (
	"context"
	"log"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// batcher coalesces concurrent calls of one query kind into a single statement over arrays.
type batcher[Q, R any] struct {
	sql   string
	max   int
	queue chan *call[Q, R]
	wake  func()
	// args turns the queued calls into the statement's array arguments.
	args func(calls []*call[Q, R]) []any
	// scan reads every row and fills each call's result. Row ordinality i maps to calls[i-1].
	scan func(rows pgx.Rows, calls []*call[Q, R]) error
}

type call[Q, R any] struct {
	q    Q
	r    R
	err  error
	done chan struct{}
}

var donePool = sync.Pool{New: func() any { return make(chan struct{}, 1) }}

func (b *batcher[Q, R]) do(q Q) (R, error) {
	c := &call[Q, R]{q: q, done: donePool.Get().(chan struct{})}
	b.queue <- c
	b.wake()
	<-c.done
	donePool.Put(c.done)
	return c.r, c.err
}

func (b *batcher[Q, R]) bind(wake func()) {
	b.queue = make(chan *call[Q, R], 1<<16)
	b.wake = wake
}

func (b *batcher[Q, R]) pending() bool { return len(b.queue) > 0 }

// take moves what is queued into one statement of the pipeline and returns what reads its result.
func (b *batcher[Q, R]) take(pl *pgx.Batch) func(pgx.BatchResults) {
	n := min(len(b.queue), b.max)
	if n == 0 {
		return nil
	}
	calls := make([]*call[Q, R], 0, n)
	for range n {
		calls = append(calls, <-b.queue)
	}
	pl.Queue(b.sql, b.args(calls)...)
	return func(br pgx.BatchResults) {
		rows, err := br.Query()
		if err == nil {
			err = b.scan(rows, calls)
			rows.Close()
			if err == nil {
				err = rows.Err()
			}
		}
		for _, c := range calls {
			if err != nil && c.err == nil {
				c.err = err
			}
			c.done <- struct{}{}
		}
	}
}

type kind interface {
	bind(wake func())
	pending() bool
	take(pl *pgx.Batch) func(pgx.BatchResults)
}

// readers is a fixed set of workers, each on its own connection. A free worker takes everything
// queued across every kind and sends it as one pipeline, one statement per kind. Batches start at
// least gap apart, so they stay at one call under light load and grow with the load under heavy load.
type readers struct {
	pool  *pgxpool.Pool
	kinds []kind
	sig   chan struct{}
	gap   time.Duration

	mu   sync.Mutex
	next time.Time
}

func (r *readers) wake() {
	select {
	case r.sig <- struct{}{}:
	default:
	}
}

// pace waits for this batch's turn: gap after the previous batch started, or now if that has passed.
func (r *readers) pace() {
	r.mu.Lock()
	now := time.Now()
	at := r.next
	if at.Before(now) {
		at = now
	}
	r.next = at.Add(r.gap)
	r.mu.Unlock()
	if d := at.Sub(now); d > 0 {
		time.Sleep(d)
	}
}

func (r *readers) start(workers int) {
	for range workers {
		go r.work()
	}
}

func (r *readers) work() {
	ctx := context.Background()
	finish := make([]func(pgx.BatchResults), 0, len(r.kinds))
	for range r.sig {
		if r.gap > 0 {
			r.pace()
		}
		pl := &pgx.Batch{}
		finish = finish[:0]
		for _, k := range r.kinds {
			if f := k.take(pl); f != nil {
				finish = append(finish, f)
			}
		}
		for _, k := range r.kinds {
			if k.pending() {
				r.wake()
				break
			}
		}
		if len(finish) == 0 {
			continue
		}
		br := r.pool.SendBatch(ctx, pl)
		for _, f := range finish {
			f(br)
		}
		if err := br.Close(); err != nil {
			log.Print(err)
		}
	}
}
