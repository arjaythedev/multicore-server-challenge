package main

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

const maxGroup = 128

// writers commit concurrent writes together (group commit). A free worker queues the statements of
// every waiting write into one pipeline, which Postgres runs as one implicit transaction with one
// commit, and each caller returns after that commit. A statement that fails rolls the group back,
// so then every write of the group runs again alone and gets its own result.
type writers struct {
	pool  *pgxpool.Pool
	queue chan *wcall
	sig   chan struct{}
}

type wcall struct {
	queue func(b *pgx.Batch)
	err   error
	done  chan struct{}
}

// do commits the statements queue adds. queue may run more than once, and its callbacks must not
// return pgx.ErrNoRows: an error from a callback, unlike one from Postgres, leaves the group committed.
func (w *writers) do(queue func(b *pgx.Batch)) error {
	c := &wcall{queue: queue, done: donePool.Get().(chan struct{})}
	w.queue <- c
	w.wake()
	<-c.done
	donePool.Put(c.done)
	return c.err
}

func (w *writers) wake() {
	select {
	case w.sig <- struct{}{}:
	default:
	}
}

func (w *writers) start(workers int) {
	w.queue = make(chan *wcall, 1<<14)
	w.sig = make(chan struct{}, 1)
	for range workers {
		go w.work()
	}
}

func (w *writers) work() {
	ctx := context.Background()
	calls := make([]*wcall, 0, maxGroup)
	for range w.sig {
		calls = calls[:0]
		for n := min(len(w.queue), maxGroup); len(calls) < n; {
			calls = append(calls, <-w.queue)
		}
		if len(w.queue) > 0 {
			w.wake()
		}
		if len(calls) == 0 {
			continue
		}
		err := w.send(ctx, calls)
		var pe *pgconn.PgError
		if len(calls) > 1 && errors.As(err, &pe) {
			for i, c := range calls {
				c.err = w.send(ctx, calls[i:i+1])
			}
		} else {
			for _, c := range calls {
				c.err = err
			}
		}
		for _, c := range calls {
			c.done <- struct{}{}
		}
	}
}

func (w *writers) send(ctx context.Context, calls []*wcall) error {
	b := &pgx.Batch{}
	for _, c := range calls {
		c.queue(b)
	}
	return w.pool.SendBatch(ctx, b).Close()
}

// row scans a row that may be missing, reporting which in ok instead of as an error.
func row(err error, ok *bool) error {
	*ok = err == nil
	if err == pgx.ErrNoRows {
		return nil
	}
	return err
}
