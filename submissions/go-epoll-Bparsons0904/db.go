package main

import (
	"fmt"
	"log"
	"os"
	"strconv"
	"sync"
	"time"

	"conduit/third_party/fastbc"

	"golang.org/x/sys/cpu"

	"multicorelab/http"
	"multicorelab/http/conduit"
)

// Tunables, sweepable through the environment.
var (
	readWait   = time.Duration(envNonNeg("CONDUIT_READ_WAIT_US", 10000)) * time.Microsecond // 0: take whatever is queued at once; waits for up to readFill queued
	readFill   = envInt("CONDUIT_READ_FILL", 256)                                           // stop waiting once this many are queued
	writeWait  = time.Duration(envNonNeg("CONDUIT_WRITE_WAIT_US", 0)) * time.Microsecond
	writeFill  = envInt("CONDUIT_WRITE_FILL", 16)
	nWorkers   = envInt("CONDUIT_DB_WORKERS", 12)                         // database workers, one connection each
	nWriters   = min(envInt("CONDUIT_DB_WRITERS", 4), max(nWorkers-1, 1)) // workers that receive writes, so group commits are larger
	readGroups = envInt("CONDUIT_READ_GROUPS", 0)                         // 0: one read queue for all readers
	flushCap   = envInt("CONDUIT_FLUSH_CAP", 512)                         // ops a worker takes per flush
)

const (
	bcWorkers = 3
	bcWidth   = 4
	bcMaxWait = 100 * time.Millisecond
	bcCost    = 10
)

// opState is the database side's state of one deferred request, indexed by
// Op.ID. Nothing in it outlives the request.
type opState struct {
	op *http.Op
	c  *conduit.Call

	stage     uint8 // sNew, sWrite (after hashing), sDone
	found     bool  // a row came back
	inTxCount bool  // a favorite or unfavorite whose count is read inside the transaction (see markRepeatedFavs)
	bcAt      time.Time
	hash      []byte // Login: the stored hash; Register, UpdateUser: the new hash

	// Results of the statements of this request.
	id       int64
	authorID int64
	user     userRow
	com      commRow
	art      artRow  // the article a write returns
	slot     int     // index into the flush's arrays for this request's read key
	slot2    int     // index of the per-viewer flag probe, where the request has one
	favLo    int     // a list request's first entry in the flush's favorites probe refs
	w        *worker // the worker flushing it, which completes it
}

const (
	sNew uint8 = iota
	sWrite
)

// readGroup is a set of readers: its queues are rqs[first:first+queues] and its readers' indexes rds.
type readGroup struct {
	queue, readers int
	rds            []int
}

// DB is the http.Batcher: it routes deferred requests to database workers and
// the bcrypt pool.
type DB struct {
	front    *conduit.Front
	sharing  bool
	workers  []*worker
	wqs      []*queue       // one write queue per writer: writes on the same key stay on one connection
	famGroup [nReadFams]int // the read group of each family, under a read plan
	planned  bool
	groups   []readGroup
	rqs      []*queue // read queues: one per read group
	st       []opState
	bc       *bcPool
}

func newDB(sharing bool) *DB { return &DB{sharing: sharing} }

// init is called once the server knows how many Ops it has.
func (d *DB) init(front *conduit.Front, ops int, dsn string) error {
	d.front = front
	d.st = make([]opState, ops)
	impl := fastbc.AsmSR4
	if cpu.X86.HasBMI2 {
		impl = fastbc.AsmBMI2SR4
	}
	d.bc = newBcPool(d, impl)
	readers := nWorkers - nWriters
	var plan []planGroup
	if readPlan != "" {
		p, err := parsePlan(readPlan)
		if err != nil {
			return fmt.Errorf("CONDUIT_READ_PLAN: %w", err)
		}
		plan, readers = p, 0
		for gi, g := range p {
			readers += g.readers
			for _, f := range g.fams {
				d.famGroup[f] = gi
			}
		}
		d.planned = true
		log.Printf("read plan: %d groups, %d readers (CONDUIT_DB_WORKERS and CONDUIT_READ_GROUPS ignored)", len(p), readers)
	}
	total := nWriters + readers
	d.workers = make([]*worker, total)
	var wg sync.WaitGroup
	errs := make([]error, total)
	if plan == nil { // READ_GROUPS shared queues (one group when 0), readers split evenly
		g := 1
		if readGroups > 1 && readers > 0 {
			g = min(readGroups, readers, maxGroups)
		}
		plan = make([]planGroup, g)
		for i := range plan {
			plan[i].readers = readers / g
			if i < readers%g {
				plan[i].readers++
			}
		}
	}
	// One queue per group; assign[r] is the group of the r-th reader.
	var assign []int
	for gi, g := range plan {
		rg := readGroup{queue: len(d.rqs), readers: g.readers}
		d.rqs = append(d.rqs, newQueue(readWait, readFill))
		for range g.readers {
			rg.rds = append(rg.rds, len(assign))
			assign = append(assign, gi)
		}
		d.groups = append(d.groups, rg)
	}
	for i, q := range d.rqs {
		for j, p := range d.rqs {
			if i != j {
				q.peers = append(q.peers, p)
			}
		}
	}
	statReaders(readers)
	d.wqs = make([]*queue, nWriters)
	for i := range d.wqs {
		d.wqs[i] = newQueue(writeWait, writeFill)
	}
	for i := range d.workers {
		var q *queue
		grp, rd := -1, -1
		if i < nWriters {
			q = d.wqs[i]
		} else {
			rd = i - nWriters
			grp = assign[rd]
			q = d.rqs[d.groups[grp].queue]
		}
		d.workers[i] = newWorker(d, i, q)
		d.workers[i].grp, d.workers[i].rd = grp, rd
		wg.Add(1)
		go func() {
			defer wg.Done()
			errs[i] = d.workers[i].connect(dsn)
		}()
	}
	wg.Wait()
	for _, err := range errs {
		if err != nil {
			return err
		}
	}
	for _, w := range d.workers {
		go w.run()
	}
	return nil
}

// subBatch collects the requests of one SubmitBatch call by destination queue, so each queue is locked and
// signalled once per call instead of once per request.
type subBatch struct {
	rqs [][]*opState
	wqs [][]*opState
}

var subBatches = sync.Pool{New: func() any { return &subBatch{} }}

// SubmitBatch implements http.Batcher. It only queues.
func (d *DB) SubmitBatch(ops []*http.Op) {
	sb := subBatches.Get().(*subBatch)
	if len(sb.wqs) != len(d.wqs) {
		sb.wqs = make([][]*opState, len(d.wqs))
	}
	if len(sb.rqs) != len(d.rqs) {
		sb.rqs = make([][]*opState, len(d.rqs))
	}
	for _, op := range ops {
		c := d.front.Call(op)
		s := &d.st[op.ID()]
		*s = opState{op: op, c: c, hash: s.hash[:0]}
		switch c.Endpoint {
		case conduit.Register:
			d.bc.submit(s)
		case conduit.UpdateUser:
			if c.Password.Valid {
				d.bc.submit(s)
			} else {
				sb.add(d, s)
			}
		case conduit.Feed:
			if c.Limit+c.Offset > 1<<31-1 {
				// The reference's int4 overflow in the feed's LIMIT: a 500 for this request alone.
				conduit.Fail(op, 500, "internal error")
				op.Done()
				continue
			}
			sb.add(d, s)
		default:
			sb.add(d, s)
		}
	}
	for i, q := range d.rqs {
		q.pushAll(sb.rqs[i])
		clear(sb.rqs[i])
		sb.rqs[i] = sb.rqs[i][:0]
	}
	for i, q := range d.wqs {
		q.pushAll(sb.wqs[i])
		clear(sb.wqs[i])
		sb.wqs[i] = sb.wqs[i][:0]
	}
	subBatches.Put(sb)
}

// add files s under the queue that serves it.
func (sb *subBatch) add(d *DB, s *opState) {
	if isWrite(s.c.Endpoint) {
		i := d.writerOf(s)
		sb.wqs[i] = append(sb.wqs[i], s)
		return
	}
	i := d.readQueueOf(s)
	sb.rqs[i] = append(sb.rqs[i], s)
}

// writeQ picks the writer by the key a write contends on. Writes taken by different connections at once would
// queue on each other's row locks (a hot article's counts, a popular user's followers) while holding their
// transactions open, so the same key always goes to the same connection.
func (d *DB) writeQ(s *opState) *queue { return d.wqs[d.writerOf(s)] }

func (d *DB) writerOf(s *opState) int {
	c := s.c
	h := fnvInit
	switch c.Endpoint {
	case conduit.CreateArticle, conduit.UpdateUser:
		var b [8]byte
		putInt(b[:], c.Viewer)
		h = fnvAdd(h, b[:])
	case conduit.Register:
		h = fnvAdd(h, c.NewUsername.V)
	case conduit.Follow, conduit.Unfollow:
		h = fnvAdd(h, c.Username)
	default:
		h = fnvAdd(h, c.Slug)
	}
	return int(h % uint32(len(d.wqs)))
}

// fnvInit and fnvAdd are FNV-1a (hash/fnv's New32a) without the interface and its allocation.
const fnvInit uint32 = 2166136261

func fnvAdd(h uint32, b []byte) uint32 {
	for _, c := range b {
		h = (h ^ uint32(c)) * 16777619
	}
	return h
}

func isWrite(e conduit.Endpoint) bool {
	switch e {
	case conduit.Register, conduit.UpdateUser, conduit.Follow, conduit.Unfollow, conduit.CreateArticle,
		conduit.UpdateArticle, conduit.DeleteArticle, conduit.Favorite, conduit.Unfavorite,
		conduit.CreateComment, conduit.DeleteComment:
		return true
	}
	return false
}

// afterHash continues a request once bcrypt is done with it.
func (d *DB) afterHash(s *opState) {
	s.stage = sWrite
	d.writeQ(s).push(s)
}

func envInt(name string, def int) int {
	if n, err := strconv.Atoi(os.Getenv(name)); err == nil && n > 0 {
		return n
	}
	return def
}

// envNonNeg is envInt for settings where 0 is a real value (a wait of 0 turns the wait off).
func envNonNeg(name string, def int) int {
	if n, err := strconv.Atoi(os.Getenv(name)); err == nil && n >= 0 {
		return n
	}
	return def
}

func envBool(name string, def bool) bool {
	switch os.Getenv(name) {
	case "0", "false", "off", "no":
		return false
	case "1", "true", "on", "yes":
		return true
	}
	return def
}

func putInt(b []byte, v int64) {
	for i := 0; i < 8; i++ {
		b[i] = byte(v >> (8 * i))
	}
}

// done queues the finished request for its worker's next completion, which hands a whole phase of a flush back to
// the HTTP loop at once.
func (s *opState) done() { s.w.pend = append(s.w.pend, s.op) }

// maxGroups bounds CONDUIT_READ_GROUPS (the stats arrays).
const maxGroups = 16

// readQueueOf picks the read queue by the key the request shares work on, so identical and overlapping requests
// meet in one queue's batches: with a plan by family; otherwise the global list in
// one group, tag and author lists by their value, a feed by its viewer, an article, its comments and a profile by
// slug or username.
func (d *DB) readQueueOf(s *opState) int {
	if len(d.rqs) == 1 {
		return 0
	}
	c := s.c
	if d.planned {
		return d.groups[d.famGroup[readFamOf(c)]].queue
	}
	h := fnvInit
	switch c.Endpoint {
	case conduit.ListArticles:
		h = fnvAdd(h, []byte{byte(c.Filter)})
		h = fnvAdd(h, c.FilterValue)
	case conduit.Feed:
		var b [9]byte
		b[0] = 'f'
		putInt(b[1:], c.Viewer)
		h = fnvAdd(h, b[:])
	case conduit.GetProfile:
		h = fnvAdd(h, c.Username)
	case conduit.GetArticle, conduit.ListComments:
		h = fnvAdd(h, c.Slug)
	case conduit.Login:
		h = fnvAdd(h, c.Email.V)
	case conduit.GetUser:
		var b [9]byte
		b[0] = 'u'
		putInt(b[1:], c.Viewer)
		h = fnvAdd(h, b[:])
	}
	return int(h % uint32(len(d.rqs)))
}
