package main

// db.go: Postgres connections owned by worker goroutines.
//
// Reads: requests of the same kind that are waiting together run as ONE statement, the per-request
// query lateral-joined to unnest() of their parameters, each row tagged with its request's ordinal.
// Writes: every waiting write runs in one pipelined implicit transaction (one Sync, one commit,
// one WAL flush); responses are released only after the commit. A failed group is rolled back by
// Postgres and each write is retried alone; a lost connection fails its writes (the commit is
// uncertain) without retrying them.

import (
	"context"
	"encoding/binary"
	"fmt"
	"log"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5/pgconn"
)

var (
	bg       = context.Background()
	binary1  = []int16{1}
	dbConfig *pgconn.Config
	stmts    = map[string]string{}                     // name -> SQL, prepared on every connection
	stmtOIDs = map[string][]uint32{"cross": crossOIDs} // parameter types a statement does not imply
)

type job struct {
	kind        int
	v, lim, off int64
	s           string
	calls       []call // writes
	row         func(j *job, stmt int, c [][]byte)
	prefix      string

	out  []byte
	rows int // rows of statement 0 seen so far
	n    int64
	hash string
	err  error
	t0   time.Time
	done chan struct{}
}

type call struct {
	stmt string
	args [][]byte
}

func (j *job) reset() {
	j.out = append(j.out[:0], j.prefix...)
	j.rows, j.n, j.hash = 0, 0, ""
}

type dbConn struct {
	pc *pgconn.PgConn
	sd map[string]*pgconn.StatementDescription
}

func connect() *dbConn {
	for {
		pc, err := pgconn.ConnectConfig(bg, dbConfig)
		if err != nil {
			log.Print("db connect: ", err)
			time.Sleep(200 * time.Millisecond)
			continue
		}
		c := &dbConn{pc: pc, sd: map[string]*pgconn.StatementDescription{}}
		for name, sql := range stmts {
			if c.sd[name], err = pc.Prepare(bg, name, sql, stmtOIDs[name]); err != nil {
				log.Fatalf("prepare %s: %v\n%s", name, err, sql)
			}
		}
		return c
	}
}

// exec runs calls in one round trip as one implicit transaction; emit gets every row of call i.
// A panic while reading rows closes the connection (its protocol state is unknown) instead of the process.
func (c *dbConn) exec(calls []call, emit func(i int, v [][]byte)) (err error) {
	defer func() {
		if e := recover(); e != nil {
			c.pc.Close(bg)
			err = fmt.Errorf("panic reading rows: %v", e)
		}
	}()
	b := &pgconn.Batch{}
	for _, cl := range calls {
		b.ExecStatement(c.sd[cl.stmt], cl.args, nil, binary1)
	}
	mrr := c.pc.ExecBatch(bg, b)
	for i := 0; mrr.NextResult(); i++ {
		rr := mrr.ResultReader()
		for rr.NextRow() {
			emit(i, rr.Values())
		}
		if _, err := rr.Close(); err != nil {
			mrr.Close()
			return err
		}
	}
	return mrr.Close()
}

// ---------- reads ----------

type kind struct {
	stmts  []string
	prefix string
	row    func(j *job, stmt int, c [][]byte)
}

type readPool struct {
	mu   sync.Mutex
	cond *sync.Cond
	q    [nKinds][]*job
	wait time.Duration
	max  int
	// cross: a batch takes the waiting reads of every kind and runs them as one statement (cross.go).
	cross bool
}

var reads readPool

func read(k int, v, lim, off int64, s string) *job {
	j := &job{kind: k, v: v, lim: lim, off: off, s: s, row: kinds[k].row, prefix: kinds[k].prefix,
		t0: time.Now(), done: make(chan struct{})}
	p := &reads
	p.mu.Lock()
	p.q[k] = append(p.q[k], j)
	p.mu.Unlock()
	p.cond.Signal()
	<-j.done
	return j
}

// take returns the kind whose oldest request has waited longest, once it has waited p.wait
// (or a full batch is ready).
func (p *readPool) take() (int, []*job) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for {
		k := -1
		for i := range p.q {
			if len(p.q[i]) > 0 && (k < 0 || p.q[i][0].t0.Before(p.q[k][0].t0)) {
				k = i
			}
		}
		if k < 0 {
			p.cond.Wait()
			continue
		}
		q := p.q[k]
		n := len(q)
		if p.cross {
			n = 0
			for i := range p.q {
				n += len(p.q[i])
			}
		}
		if d := p.wait - time.Since(q[0].t0); d > 0 && n < p.max {
			p.mu.Unlock()
			time.Sleep(d)
			p.mu.Lock()
			continue
		}
		if !p.cross {
			return k, p.cut(k, p.max)
		}
		var batch []*job
		for i := range p.q {
			batch = append(batch, p.cut(i, p.max-len(batch))...)
		}
		return -1, batch
	}
}

// cut removes and returns up to n of kind k's oldest requests.
func (p *readPool) cut(k, n int) []*job {
	q := p.q[k]
	n = min(len(q), n)
	batch := append([]*job(nil), q[:n]...)
	rest := copy(q, q[n:])
	clear(q[rest:])
	p.q[k] = q[:rest]
	return batch
}

func (p *readPool) worker() {
	c := connect()
	for {
		k, batch := p.take()
		run := batch
		var err error
		if k < 0 {
			// A string Postgres rejects (a NUL byte, invalid UTF-8) would fail the whole statement and send
			// every request in it to the one-by-one retry: those run alone, and fail alone.
			run = nil
			for _, j := range batch {
				if strings.IndexByte(j.s, 0) >= 0 || !utf8.ValidString(j.s) {
					j.err = c.read(j.kind, []*job{j})
				} else {
					run = append(run, j)
				}
			}
			if len(run) > 0 {
				err = c.readCross(run)
			}
		} else {
			err = c.read(k, batch)
		}
		if err != nil {
			// A lost connection is safe to retry for reads; an SQL error stays with its own request.
			for _, j := range run {
				if c.pc.IsClosed() {
					c = connect()
				}
				j.err = c.read(j.kind, []*job{j})
			}
		}
		for _, j := range batch {
			close(j.done)
		}
	}
}

func (c *dbConn) read(k int, batch []*job) error {
	var a [5][]byte
	for i := range a {
		a[i] = append(a[i], '{')
	}
	for i, j := range batch {
		if i > 0 {
			for x := range a {
				a[x] = append(a[x], ',')
			}
		}
		j.reset()
		a[0] = strconv.AppendInt(a[0], int64(i), 10)
		a[1] = strconv.AppendInt(a[1], j.v, 10)
		a[2] = strconv.AppendInt(a[2], j.lim, 10)
		a[3] = strconv.AppendInt(a[3], j.off, 10)
		a[4] = appendArrayString(a[4], j.s)
	}
	args := make([][]byte, 5)
	for i := range a {
		args[i] = append(a[i], '}')
	}
	calls := make([]call, len(kinds[k].stmts))
	for i, s := range kinds[k].stmts {
		calls[i] = call{s, args}
	}
	return c.exec(calls, func(st int, v [][]byte) {
		j := batch[binary.BigEndian.Uint32(v[0])]
		j.row(j, st, v[1:])
		if st == 0 {
			j.rows++
		}
	})
}

// appendArrayString quotes s as a Postgres array element.
func appendArrayString(b []byte, s string) []byte {
	b = append(b, '"')
	for i := 0; i < len(s); i++ {
		if s[i] == '"' || s[i] == '\\' {
			b = append(b, '\\')
		}
		b = append(b, s[i])
	}
	return append(b, '"')
}

// ---------- writes ----------

type writePool struct {
	mu   sync.Mutex
	cond *sync.Cond
	q    []*job
	max  int
}

var writes writePool

// write runs calls in the next group commit; row gets the rows of the last call.
func write(prefix string, row func(j *job, stmt int, c [][]byte), calls ...call) *job {
	j := &job{calls: calls, row: row, prefix: prefix, done: make(chan struct{})}
	p := &writes
	p.mu.Lock()
	p.q = append(p.q, j)
	p.mu.Unlock()
	p.cond.Signal()
	<-j.done
	return j
}

func (p *writePool) worker() {
	c := connect()
	for {
		p.mu.Lock()
		for len(p.q) == 0 {
			p.cond.Wait()
		}
		n := min(len(p.q), p.max)
		batch := append([]*job(nil), p.q[:n]...)
		rest := copy(p.q, p.q[n:])
		clear(p.q[rest:])
		p.q = p.q[:rest]
		p.mu.Unlock()

		if err := c.write(batch); err != nil {
			if c.pc.IsClosed() || len(batch) == 1 {
				for _, j := range batch {
					j.err = err
				}
			} else {
				for _, j := range batch {
					if c.pc.IsClosed() {
						c = connect()
					}
					j.err = c.write([]*job{j})
				}
			}
		}
		if c.pc.IsClosed() {
			c = connect()
		}
		for _, j := range batch {
			close(j.done)
		}
	}
}

func (c *dbConn) write(batch []*job) error {
	var calls []call
	var owner []*job // the job whose response is built from call i (its last call)
	for _, j := range batch {
		j.reset()
		for i, cl := range j.calls {
			calls = append(calls, cl)
			if i == len(j.calls)-1 {
				owner = append(owner, j)
			} else {
				owner = append(owner, nil)
			}
		}
	}
	return c.exec(calls, func(i int, v [][]byte) {
		if j := owner[i]; j != nil {
			j.row(j, 0, v)
			j.rows++
		}
	})
}

func startDB(url string, nRead, nWrite int, wait time.Duration, cross bool, maxRead int) {
	var err error
	if dbConfig, err = pgconn.ParseConfig(url); err != nil {
		log.Fatal(err)
	}
	// Session settings only: generic plans for the prepared statements, no JIT or parallel workers
	// for these short queries, and no Memoize so no request reuses a row another request's lookup fetched.
	for k, v := range map[string]string{"plan_cache_mode": "force_generic_plan", "jit": "off",
		"max_parallel_workers_per_gather": "0", "enable_memoize": "off"} {
		dbConfig.RuntimeParams[k] = v
	}
	if maxRead <= 0 {
		maxRead = 64
		if cross {
			maxRead = 1024
		}
	}
	reads.cond, reads.wait, reads.max, reads.cross = sync.NewCond(&reads.mu), wait, maxRead, cross
	writes.cond, writes.max = sync.NewCond(&writes.mu), 128
	for range nRead {
		go reads.worker()
	}
	for range nWrite {
		go writes.worker()
	}
}
