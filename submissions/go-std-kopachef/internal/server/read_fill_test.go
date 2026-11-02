package server

import (
	"context"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func TestReadFillWhileWorkerBusy(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	q := &readQueue{ctx: ctx, cancel: cancel, pending: make(chan *queuedRead), work: make(chan []*queuedRead), batchSize: 4, batchWait: time.Millisecond}
	q.workers.Add(1)
	go q.collectWhileWaiting()
	t.Cleanup(func() { cancel(); q.workers.Wait() })
	send := func(i int) {
		select {
		case q.pending <- &queuedRead{viewer: int64(i)}:
		case <-time.After(time.Second):
			t.Fatal("collector stopped receiving while worker busy")
		}
	}
	send(1)
	// Let the collection window end without a receiving SQL worker.
	time.Sleep(20 * time.Millisecond)
	for i := 2; i <= 4; i++ {
		send(i)
	}
	select {
	case batch := <-q.work:
		if len(batch) != 4 {
			t.Fatal("worker received a partial batch despite queued work", len(batch))
		}
		for i, c := range batch {
			if c.viewer != int64(i+1) {
				t.Fatal("request order changed")
			}
		}
	case <-time.After(time.Second):
		t.Fatal("full batch did not dispatch")
	}
	// An available worker still receives a partial batch after the window;
	// the collector must not wait for the cap to be filled.
	send(5)
	select {
	case batch := <-q.work:
		if len(batch) != 1 || batch[0].viewer != 5 {
			t.Fatal("partial dispatch changed")
		}
	case <-time.After(time.Second):
		t.Fatal("idle worker waited for a full batch")
	}
}

func TestReadFillCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	q := &readQueue{ctx: ctx, cancel: cancel, pending: make(chan *queuedRead), work: make(chan []*queuedRead), batchSize: 4}
	q.workers.Add(1)
	go q.collectWhileWaiting()
	q.pending <- &queuedRead{}
	cancel()
	done := make(chan struct{})
	go func() { q.workers.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("collector worker wait did not cancel")
	}
}

func TestReadFillConcurrent(t *testing.T) {
	testReadQueueConcurrent(t, newReadQueueFillConfig)
}

func TestReadFillConfigured(t *testing.T) {
	t.Setenv("READ_WAIT_FILL", "1")
	testReadQueueConcurrent(t, newReadQueueConfig)
}

func TestReadFillBounded(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	q := &readQueue{ctx: ctx, cancel: cancel, pending: make(chan *queuedRead, 8), work: make(chan []*queuedRead), batchSize: 3}
	for i := range 8 {
		q.pending <- &queuedRead{viewer: int64(i)}
	}
	q.workers.Add(1)
	go q.collectWhileWaiting()
	t.Cleanup(func() { cancel(); q.workers.Wait() })
	deadline := time.After(time.Second)
	for len(q.pending) != 5 {
		select {
		case <-deadline:
			t.Fatal("collector did not stop at the active batch cap")
		case <-time.After(time.Millisecond):
		}
	}
	next := int64(0)
	for _, size := range []int{3, 3, 2} {
		select {
		case batch := <-q.work:
			if len(batch) != size {
				t.Fatalf("batch size %d, want %d", len(batch), size)
			}
			for _, c := range batch {
				if c.viewer != next {
					t.Fatalf("FIFO changed: %d, want %d", c.viewer, next)
				}
				next++
			}
		case <-time.After(time.Second):
			t.Fatal("bounded batch did not dispatch")
		}
	}
}

// Keep a direct factory for differential/concurrency checks. The original
// 1,024-cap trial failed; the larger-cap runtime trial remains opt-in.
func newReadQueueFillConfig(pool *pgxpool.Pool, wait time.Duration, size, workers, queue int) *readQueue {
	ctx, cancel := context.WithCancel(context.Background())
	q := &readQueue{pool: pool, ctx: ctx, cancel: cancel, pending: make(chan *queuedRead, queue), work: make(chan []*queuedRead), batchWait: wait, batchSize: size, workerCount: workers}
	q.workers.Add(1)
	go q.collectWhileWaiting()
	for range workers {
		q.workers.Add(1)
		go q.run()
	}
	return q
}
