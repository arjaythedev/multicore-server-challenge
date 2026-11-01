package main

import (
	"time"

	"conduit/third_party/fastbc"

	"multicorelab/http"
	"multicorelab/http/conduit"
)

// bcPool runs every bcrypt computation: logins verify against the stored hash,
// Register and UpdateUser create a new hash. A dispatcher fills batches of
// bcWidth and releases one when full or when its oldest request has waited
// bcMaxWait; bcWorkers goroutines run them.
type bcPool struct {
	db   *DB
	impl *fastbc.Impl
	in   chan *opState
	work chan []*opState
}

func newBcPool(db *DB, impl *fastbc.Impl) *bcPool {
	p := &bcPool{db: db, impl: impl, in: make(chan *opState, len(db.st)+1), work: make(chan []*opState)}
	go p.dispatch()
	for i := 0; i < bcWorkers; i++ {
		go p.worker()
	}
	return p
}

// submit queues a request; it never blocks (each Op is queued at most once).
func (p *bcPool) submit(s *opState) {
	s.bcAt = time.Now()
	p.in <- s
}

func (p *bcPool) dispatch() {
	var cur []*opState
	for {
		var out chan []*opState
		var timeout <-chan time.Time
		var timer *time.Timer
		if len(cur) > 0 {
			if wait := time.Until(cur[0].bcAt.Add(bcMaxWait)); len(cur) >= bcWidth || wait <= 0 {
				out = p.work
			} else {
				timer = time.NewTimer(wait)
				timeout = timer.C
			}
		}
		var batch []*opState
		if out != nil {
			batch = cur[:min(len(cur), bcWidth)]
		}
		select {
		case s := <-p.in:
			cur = append(cur, s)
		case out <- batch:
			cur = append([]*opState(nil), cur[len(batch):]...)
		case <-timeout:
		}
		if timer != nil {
			timer.Stop()
		}
	}
}

func (p *bcPool) worker() {
	var tasks [bcWidth]fastbc.Task
	for batch := range p.work {
		t := tasks[:len(batch)]
		for i, s := range batch {
			t[i] = fastbc.Task{}
			if s.c.Endpoint == conduit.Login {
				t[i].Hash, t[i].PW = s.hash, s.c.Password.V
			} else {
				t[i].PW = pwOf(s.c)
			}
		}
		statBcrypt(len(t))
		p.impl.Do(t, bcCost)
		for i, s := range batch {
			if s.c.Endpoint == conduit.Login {
				p.db.finishLogin(s, t[i].OK)
				continue
			}
			s.hash = append(s.hash[:0], t[i].Out...)
			p.db.afterHash(s)
		}
	}
}

func pwOf(c *conduit.Call) []byte { return c.Password.V }

// finishLogin answers a login whose password has been checked.
func (d *DB) finishLogin(s *opState, ok bool) {
	op := s.op
	if !ok {
		conduit.Fail(op, 401, "invalid email or password")
		op.Done()
		return
	}
	d.respondUser(s, 200, true)
	op.Done()
}

var _ = http.Config{}
