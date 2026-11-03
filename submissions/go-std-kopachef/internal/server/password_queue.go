package server

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"sync"
	"sync/atomic"
	"time"

	"conduit/internal/bcryptlane"
	"golang.org/x/crypto/bcrypt"
)

// At the 200,000-user target, roughly 56 password jobs arrive each second.
// A 50 ms collection budget fills lanes while keeping four workers available
// for bursts. Idle traffic still dispatches immediately.
const defaultPasswordBatchWaitUS = 50_000
const defaultPasswordBatchSize = 4
const maxPasswordBatchSize = 5

var passwordEncoding = base64.NewEncoding("./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789").WithPadding(base64.NoPadding)

type passwordJob struct {
	ctx      context.Context
	queued   time.Time
	password []byte
	salt     [16]byte
	result   [23]byte
	done     chan struct{}
}

// A single collector preserves coalescing opportunities across all workers.
// Idle traffic dispatches immediately. While workers are busy, collection is
// bounded by the oldest job's age; waiting in the queue consumes that budget.
type passwordQueue struct {
	ctx       context.Context
	cancel    context.CancelFunc
	pending   chan *passwordJob
	work      chan []*passwordJob
	workers   sync.WaitGroup
	active    atomic.Int64
	batchWait time.Duration
	batchSize int
}

func newPasswordQueue(workers int, batchWait time.Duration) *passwordQueue {
	return newPasswordQueueConfig(workers, batchWait, defaultPasswordBatchSize)
}

func newPasswordQueueConfig(workers int, batchWait time.Duration, batchSize int) *passwordQueue {
	ctx, cancel := context.WithCancel(context.Background())
	q := &passwordQueue{ctx: ctx, cancel: cancel, pending: make(chan *passwordJob, 256),
		work: make(chan []*passwordJob), batchWait: batchWait, batchSize: batchSize}
	q.workers.Add(workers + 1)
	go q.collect()
	for range workers {
		go q.run()
	}
	return q
}

func (q *passwordQueue) close() {
	q.cancel()
	q.workers.Wait()
}

func (q *passwordQueue) collect() {
	defer q.workers.Done()
	timer := time.NewTimer(time.Hour)
	timer.Stop()
	defer timer.Stop()
	for {
		var first *passwordJob
		select {
		case first = <-q.pending:
		case <-q.ctx.Done():
			return
		}
		if first.ctx.Err() != nil {
			continue
		}
		batch := make([]*passwordJob, 1, q.batchSize)
		batch[0] = first
		wait := time.Until(first.queued.Add(q.batchWait))
		if q.active.Load() == 0 || wait <= 0 {
			wait = 0
		} else {
			timer.Reset(wait)
		}
	collect:
		for len(batch) < q.batchSize {
			if wait > 0 {
				select {
				case job := <-q.pending:
					if job.ctx.Err() == nil {
						batch = append(batch, job)
					}
				case <-timer.C:
					break collect
				case <-q.ctx.Done():
					return
				}
			} else {
				select {
				case job := <-q.pending:
					if job.ctx.Err() == nil {
						batch = append(batch, job)
					}
				default:
					break collect
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

func (q *passwordQueue) run() {
	defer q.workers.Done()
	for {
		select {
		case batch := <-q.work:
			q.active.Add(1)
			// A caller can cancel while the collector waits for a worker.
			active := batch[:0]
			for _, job := range batch {
				if job.ctx.Err() == nil {
					active = append(active, job)
				}
			}
			q.execute(active)
			q.active.Add(-1)
			clear(batch)
		case <-q.ctx.Done():
			return
		}
	}
}

func (q *passwordQueue) execute(batch []*passwordJob) {
	if len(batch) == 0 {
		return
	}
	var passwords [maxPasswordBatchSize][]byte
	var salts [maxPasswordBatchSize][16]byte
	var results [maxPasswordBatchSize][23]byte
	for i, job := range batch {
		passwords[i], salts[i] = job.password, job.salt
	}
	switch len(batch) {
	case 1:
		results[0] = bcryptlane.Single(passwords[0], salts[0], bcryptCost)
	case 2:
		pair := bcryptlane.Sum2([2][]byte{passwords[0], passwords[1]}, [2][16]byte{salts[0], salts[1]}, bcryptCost)
		results[0], results[1] = pair[0], pair[1]
	case 3:
		v := bcryptlane.Sum3([3][]byte(passwords[:3]), [3][16]byte(salts[:3]), bcryptCost)
		copy(results[:], v[:])
	case 4:
		v := bcryptlane.Sum4([4][]byte(passwords[:4]), [4][16]byte(salts[:4]), bcryptCost)
		copy(results[:], v[:])
	case 5:
		results = bcryptlane.Sum5(passwords, salts, bcryptCost)
	default:
		panic("invalid password batch width")
	}
	for i, job := range batch {
		job.result = results[i]
		close(job.done)
	}
}

func (q *passwordQueue) sum(ctx context.Context, password string, salt [16]byte) ([23]byte, error) {
	job := &passwordJob{ctx: ctx, queued: time.Now(), password: []byte(password), salt: salt, done: make(chan struct{})}
	select {
	case <-ctx.Done():
		return [23]byte{}, ctx.Err()
	case <-q.ctx.Done():
		return [23]byte{}, q.ctx.Err()
	case q.pending <- job:
	}
	select {
	case <-ctx.Done():
		return [23]byte{}, ctx.Err()
	case <-q.ctx.Done():
		return [23]byte{}, q.ctx.Err()
	case <-job.done:
		return job.result, nil
	}
}

// Recognize the canonical cost-10 encodings handled by the lane kernel.
// Other versions, costs and encodings retain standard-library behavior.
func parsePasswordHash(encoded string) (salt [16]byte, expected [23]byte, ok bool) {
	if len(encoded) != 60 || (encoded[:7] != "$2a$10$" && encoded[:7] != "$2b$10$" && encoded[:7] != "$2y$10$") {
		return
	}
	n, err := passwordEncoding.Decode(salt[:], []byte(encoded[7:29]))
	if err != nil || n != len(salt) {
		return
	}
	n, err = passwordEncoding.Decode(expected[:], []byte(encoded[29:]))
	if err != nil || n != len(expected) {
		return
	}
	// Reject noncanonical trailing padding bits into the compatibility path.
	var canonical [53]byte
	passwordEncoding.Encode(canonical[:22], salt[:])
	passwordEncoding.Encode(canonical[22:], expected[:])
	ok = string(canonical[:]) == encoded[7:]
	return
}

func (a *app) checkPassword(ctx context.Context, encoded, password string) error {
	if a.passwords == nil {
		return bcrypt.CompareHashAndPassword([]byte(encoded), []byte(password))
	}
	salt, expected, ok := parsePasswordHash(encoded)
	if !ok || len(password) > 72 {
		return bcrypt.CompareHashAndPassword([]byte(encoded), []byte(password))
	}
	actual, err := a.passwords.sum(ctx, password, salt)
	if err != nil {
		return err
	}
	if subtle.ConstantTimeCompare(actual[:], expected[:]) != 1 {
		return bcrypt.ErrMismatchedHashAndPassword
	}
	return nil
}

func (a *app) hashPassword(ctx context.Context, password string) (string, error) {
	if len(password) > 72 {
		return "", bcrypt.ErrPasswordTooLong
	}
	if a.passwords == nil {
		hash, err := bcrypt.GenerateFromPassword([]byte(password), bcryptCost)
		return string(hash), err
	}
	var salt [16]byte
	if _, err := rand.Read(salt[:]); err != nil {
		return "", err
	}
	checksum, err := a.passwords.sum(ctx, password, salt)
	if err != nil {
		return "", err
	}
	encoded := make([]byte, 60)
	copy(encoded, "$2a$10$")
	passwordEncoding.Encode(encoded[7:29], salt[:])
	passwordEncoding.Encode(encoded[29:], checksum[:])
	return string(encoded), nil
}
