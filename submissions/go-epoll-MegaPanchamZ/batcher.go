package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log"
	"math/rand/v2"
	"sync"
	"sync/atomic"
	"time"

	"conduit/blowfish8"

	"github.com/jackc/pgx/v5/pgconn"
)

const defaultBcryptCost = 10

var (
	wireFormatBin1  = []int16{1}
	wireFormatSlice = []int16{1, 1, 1, 1, 1, 1}
)

type batcherOptions struct {
	readPoolSize, writePoolSize int
	pipeWindow                  int
	maxReadBatch, maxWriteBatch int
	readRingCap, writeChanCap   int
	commitLinger                time.Duration
	maxQueueAge, queryDeadline  time.Duration
	hashThreads                 int
	hashRingCap                 int
	hashCoalesce                time.Duration
	retryMinWait, retryMaxWait  time.Duration
}

func readBatcherOptions(cpus, totalSlots int) (batcherOptions, error) {
	var cfg batcherOptions
	var err error
	intSpecs := []struct {
		env         string
		target      *int
		def, lo, hi int
	}{
		{"DB_READ_CONNS", &cfg.readPoolSize, min(16, max(4, cpus)), 1, 95},
		{"DB_WRITE_CONNS", &cfg.writePoolSize, min(8, max(2, cpus/2)), 1, 95},
		{"READ_BATCH", &cfg.maxReadBatch, 256, 1, 512},
		{"WRITE_BATCH", &cfg.maxWriteBatch, 256, 1, 1024},
		{"PIPELINE_DEPTH", &cfg.pipeWindow, 2, 1, 16},
		{"BCRYPT_WORKERS", &cfg.hashThreads, max(2, cpus/2), 1, 128},
		{"BCRYPT_QUEUE", &cfg.hashRingCap, totalSlots, 1, 1 << 20},
	}
	for _, sp := range intSpecs {
		if *sp.target, err = readEnvRange(sp.env, sp.def, sp.lo, sp.hi); err != nil {
			return cfg, err
		}
	}
	if cfg.readPoolSize+cfg.writePoolSize > 95 {
		return cfg, errors.New("DB_READ_CONNS + DB_WRITE_CONNS exceeds 95")
	}
	durSpecs := []struct {
		env    string
		target *time.Duration
		def    time.Duration
	}{
		{"WRITE_LINGER", &cfg.commitLinger, time.Millisecond},
		{"QUEUE_TIMEOUT", &cfg.maxQueueAge, 30 * time.Second},
		{"DB_EXEC_TIMEOUT", &cfg.queryDeadline, 10 * time.Second},
		{"BCRYPT_WAIT", &cfg.hashCoalesce, 5 * time.Millisecond},
		{"DB_RECONNECT_MIN", &cfg.retryMinWait, 100 * time.Millisecond},
		{"DB_RECONNECT_MAX", &cfg.retryMaxWait, 5 * time.Second},
	}
	for _, sp := range durSpecs {
		*sp.target = sp.def
		if raw := readEnvStr(sp.env, ""); raw != "" {
			d, parseErr := time.ParseDuration(raw)
			if parseErr != nil || d < 0 || d > time.Minute {
				return cfg, fmt.Errorf("%s must be between 0 and 1m", sp.env)
			}
			*sp.target = d
		}
	}
	cfg.readRingCap = totalSlots
	cfg.writeChanCap = totalSlots
	if cfg.retryMinWait <= 0 || cfg.retryMaxWait < cfg.retryMinWait {
		return cfg, errors.New("invalid DB_RECONNECT_MIN / DB_RECONNECT_MAX bounds")
	}
	return cfg, nil
}

type retryBackoff struct {
	minWait, maxWait, curWait time.Duration
	tries                     int
	downSince                 time.Time
}

func (rb *retryBackoff) nextDelay() time.Duration {
	if rb.tries == 0 {
		rb.downSince = time.Now()
		rb.curWait = rb.minWait
	} else if rb.curWait *= 2; rb.curWait > rb.maxWait {
		rb.curWait = rb.maxWait
	}
	rb.tries++
	half := rb.curWait >> 1
	return half + rand.N(half+1)
}

func (rb *retryBackoff) markUp() (time.Duration, int) {
	failedTries := rb.tries
	var downDur time.Duration
	if failedTries > 0 {
		downDur = time.Since(rb.downSince)
	}
	rb.curWait = 0
	rb.tries = 0
	return downDur, failedTries
}

func (rb *retryBackoff) shouldLog() bool {
	return rb.tries > 0 && (rb.tries&(rb.tries-1)) == 0
}

func isConnBroken(conn *pgconn.PgConn, err error) bool {
	if conn == nil || conn.IsClosed() {
		return true
	}
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) {
		return true
	}
	return pgErr.Severity == "FATAL" || pgErr.Severity == "PANIC"
}

func queryNeverExecuted(err error, completedCount int) bool {
	if pgconn.SafeToRetry(err) {
		return true
	}
	if completedCount != 0 {
		return false
	}
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && (pgErr.Severity == "FATAL" || pgErr.Severity == "PANIC")
}

type stmtRing struct {
	lock        sync.Mutex
	items       []*reqCtx
	readIdx     int
	writeIdx    int
	stored      int
	running     int
	concurrency int
	oldestAt    atomic.Int64
}

type readBatchUnit struct {
	op    sqlOp
	tasks []*reqCtx
}

type hashDeque struct {
	lock      sync.Mutex
	fifoBuf   []*reqCtx
	fifoHead  int
	fifoTail  int
	fifoCount int
	shutting  bool
	notifyCh  chan struct{}
}

func (hd *hashDeque) enqueue(t *reqCtx) (dropped *reqCtx, accepted bool) {
	hd.lock.Lock()
	if hd.shutting {
		hd.lock.Unlock()
		return nil, false
	}
	ringLen := len(hd.fifoBuf)
	if hd.fifoCount < ringLen {
		hd.fifoBuf[hd.fifoTail] = t
		hd.fifoTail = (hd.fifoTail + 1) % ringLen
		hd.fifoCount++
	} else {
		dropped = hd.fifoBuf[hd.fifoHead]
		hd.fifoBuf[hd.fifoHead] = t
		hd.fifoHead = (hd.fifoHead + 1) % ringLen
		hd.fifoTail = (hd.fifoTail + 1) % ringLen
	}
	wake := hd.fifoCount <= blowfish8.Lanes
	hd.lock.Unlock()
	if wake {
		select {
		case hd.notifyCh <- struct{}{}:
		default:
		}
	}
	return dropped, true
}

func (hd *hashDeque) shutdown() {
	hd.lock.Lock()
	hd.shutting = true
	hd.lock.Unlock()
	select {
	case hd.notifyCh <- struct{}{}:
	default:
	}
}

type hashWorkBatch struct {
	count int
	items [blowfish8.Lanes]*reqCtx
}

type pgEngine struct {
	srv     *netServer
	opts    batcherOptions
	pgCfg   *pgconn.Config
	hmacKey []byte

	rings        [firstWriteOp]stmtRing
	readyBitmask atomic.Uint32
	parkedReads  atomic.Int32
	readSignal   chan struct{}
	stopSignal   chan struct{}

	writeQueue chan *reqCtx
	hashQ      hashDeque
	hashBaseCh chan *hashWorkBatch
	hashBurst  chan *hashWorkBatch
	hashPool   chan *hashWorkBatch

	sessions []*pgSession
	dbGroup  sync.WaitGroup
	hashWG   sync.WaitGroup
}

type writeSpanRange struct {
	from, to int
	isBatch  bool
}

type inflightBatch struct {
	tasks  []*reqCtx
	ranges []writeSpanRange
	solo   bool
}

type pgSession struct {
	engine     *pgEngine
	isWriter   bool
	cursorOp   sqlOp
	signer     *tokenSigner
	conn       *pgconn.PgConn
	pipeline   *pgconn.Pipeline
	prepared   [sqlOpCount]*pgconn.StatementDescription
	scratch    []*reqCtx
	unitBuf    [4]readBatchUnit
	colSlices  [4][]byte
	soloSlice  [1]*reqCtx
	retryQueue []*reqCtx
	wireBuf    []byte

	flights        []inflightBatch
	fHead, fActive int
	needsReset     bool
	nextConnectAt  time.Time
	backoff        retryBackoff
	lingerTimer    *time.Timer
}

func newPGEngine(srv *netServer, opts batcherOptions, pgCfg *pgconn.Config, hmacKey []byte) *pgEngine {
	for _, w := range srv.workers {
		w.signer = newTokenSigner(hmacKey)
	}
	eng := &pgEngine{
		srv:        srv,
		opts:       opts,
		pgCfg:      pgCfg,
		hmacKey:    hmacKey,
		readSignal: make(chan struct{}, max(16, opts.readPoolSize*2)),
		stopSignal: make(chan struct{}),
		writeQueue: make(chan *reqCtx, opts.writeChanCap),
		hashQ: hashDeque{
			fifoBuf:  make([]*reqCtx, opts.hashRingCap),
			notifyCh: make(chan struct{}, 1),
		},
	}
	for op := sqlOp(0); op < firstWriteOp; op++ {
		limit := opts.readPoolSize
		if op == opTags {
			limit = 1
		}
		eng.rings[op] = stmtRing{
			items:       make([]*reqCtx, opts.readRingCap),
			concurrency: limit,
		}
	}
	totalSessions := opts.readPoolSize + opts.writePoolSize
	for idx := range totalSessions {
		writer := idx >= opts.readPoolSize
		sess := &pgSession{
			engine:   eng,
			isWriter: writer,
			cursorOp: sqlOp(idx % int(firstWriteOp)),
			signer:   newTokenSigner(hmacKey),
			backoff:  retryBackoff{minWait: opts.retryMinWait, maxWait: opts.retryMaxWait},
		}
		if writer {
			batchCap := opts.maxWriteBatch
			sess.scratch = make([]*reqCtx, 0, batchCap)
			sess.wireBuf = make([]byte, 0, batchCap*128)
			sess.flights = make([]inflightBatch, opts.pipeWindow)
			for k := range sess.flights {
				sess.flights[k].tasks = make([]*reqCtx, 0, batchCap)
				sess.flights[k].ranges = make([]writeSpanRange, 0, batchCap)
			}
			sess.lingerTimer = time.NewTimer(time.Hour)
			sess.lingerTimer.Stop()
		} else {
			batchCap := opts.maxReadBatch
			sess.scratch = make([]*reqCtx, 0, batchCap+1024)
			sess.wireBuf = make([]byte, 0, batchCap*128)
		}
		eng.sessions = append(eng.sessions, sess)
	}
	return eng
}

var startupWarmSQL = [10]string{
	"SET statement_timeout = 0; SET enable_indexonlyscan = off; SET enable_indexscan = off; SET enable_bitmapscan = off; SELECT count(body) FROM comments;",
	"SET statement_timeout = 0; SET enable_indexonlyscan = off; SET enable_indexscan = off; SET enable_bitmapscan = off; SELECT count(body) FROM articles;",
	"SET statement_timeout = 0; SET enable_indexonlyscan = off; SET enable_indexscan = off; SET enable_bitmapscan = off; SELECT count(*) FROM favorites;",
	"SET statement_timeout = 0; SET enable_seqscan = off; SELECT count(*) FROM (SELECT user_id FROM favorites ORDER BY user_id, article_id) s;",
	"SET statement_timeout = 0; SET enable_indexonlyscan = off; SET enable_indexscan = off; SET enable_bitmapscan = off; SELECT count(*) FROM follows; SELECT count(*) FROM article_tags;",
	"SET statement_timeout = 0; SET enable_seqscan = off; SELECT count(*) FROM (SELECT article_id FROM comments ORDER BY article_id, created_at DESC, id DESC) s; SELECT count(*) FROM (SELECT id FROM comments ORDER BY id) s;",
	"SET statement_timeout = 0; SET enable_seqscan = off; SELECT count(*) FROM (SELECT follower_id FROM follows ORDER BY follower_id, followee_id) s; SELECT count(*) FROM (SELECT article_id FROM favorites ORDER BY article_id) s; SELECT count(*) FROM (SELECT followee_id FROM follows ORDER BY followee_id) s;",
	"SET statement_timeout = 0; SET enable_seqscan = off; SELECT count(*) FROM (SELECT slug FROM articles ORDER BY slug) s; SELECT count(*) FROM (SELECT author_id FROM articles ORDER BY author_id, id DESC) s; SELECT count(*) FROM (SELECT id FROM articles ORDER BY id) s;",
	"SET statement_timeout = 0; SET enable_seqscan = off; SELECT count(*) FROM (SELECT article_id FROM article_tags ORDER BY article_id, tag_id) s; SELECT count(*) FROM (SELECT tag_id FROM article_tags ORDER BY tag_id, article_id) s;",
	"SET statement_timeout = 0; SET enable_indexonlyscan = off; SET enable_indexscan = off; SET enable_bitmapscan = off; SELECT count(bio) FROM users; SELECT count(name) FROM tags; RESET enable_indexonlyscan; RESET enable_indexscan; RESET enable_bitmapscan; SET enable_seqscan = off; SELECT count(*) FROM (SELECT author_id FROM comments ORDER BY author_id) s; SELECT count(*) FROM (SELECT id FROM users ORDER BY id) s; SELECT count(*) FROM (SELECT username FROM users ORDER BY username) s; SELECT count(*) FROM (SELECT email FROM users ORDER BY email) s;",
}

func (eng *pgEngine) openPoolWithRetry(ctx context.Context, maxWait time.Duration) error {
	deadline := time.Now().Add(maxWait)
	bo := retryBackoff{minWait: eng.opts.retryMinWait, maxWait: eng.opts.retryMaxWait}
	for {
		tryCtx, cancel := context.WithTimeout(ctx, 25*time.Second)
		err := eng.openAllSessions(tryCtx)
		cancel()
		if err == nil {
			return nil
		}
		delay := bo.nextDelay()
		if ctx.Err() != nil || time.Now().Add(delay).After(deadline) {
			return err
		}
		log.Printf("database not ready (try %d), waiting %s: %v",
			bo.tries, delay.Round(time.Millisecond), err)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(delay):
		}
	}
}

func (eng *pgEngine) openAllSessions(ctx context.Context) error {
	errCh := make(chan error, len(eng.sessions))
	for i, s := range eng.sessions {
		if s.conn != nil {
			errCh <- nil
			continue
		}
		var warmSQL string
		if i < len(startupWarmSQL) {
			warmSQL = startupWarmSQL[i]
		}
		go func(sess *pgSession, wsql string) {
			errCh <- sess.openConnection(ctx, wsql)
		}(s, warmSQL)
	}
	var firstErr error
	for range eng.sessions {
		if err := <-errCh; err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

func (eng *pgEngine) startWorkers() {
	for _, s := range eng.sessions {
		sess := s
		if sess.isWriter {
			eng.dbGroup.Go(func() { sess.writeWorkerLoop(eng.writeQueue) })
		} else {
			eng.dbGroup.Go(sess.readWorkerLoop)
		}
	}
	eng.launchHashWorkers()
}

func (eng *pgEngine) stopWorkers() {
	close(eng.stopSignal)
	close(eng.writeQueue)
	eng.dbGroup.Wait()
	eng.hashQ.shutdown()
	eng.hashWG.Wait()
	for _, s := range eng.sessions {
		if s.pipeline != nil {
			_ = s.pipeline.Close()
		}
		if s.conn != nil {
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			s.conn.Close(ctx)
			cancel()
		}
	}
}

func guardedPrepare(signer *tokenSigner, t *reqCtx) (step nextStep) {
	defer func() {
		if rec := recover(); rec != nil {
			log.Printf("panic in request planner: %v", rec)
			step = finishWith(t, 500, msgServerError)
		}
	}()
	return prepareRequest(signer, t)
}

func (eng *pgEngine) enqueueTask(t *reqCtx) bool {
	signer := t.loop.signer
	if signer == nil {
		signer = newTokenSigner(eng.hmacKey)
		t.loop.signer = signer
	}
	switch step := guardedPrepare(signer, t); step {
	case stepRespond:
		eng.srv.completeInline(t)
		return true
	case stepHashPass:
		t.plan.nextAction = stepHashPass
		evicted, ok := eng.hashQ.enqueue(t)
		if evicted != nil {
			finishWith(evicted, 503, msgServerBusy)
			eng.srv.completeAsync(evicted)
		}
		return ok
	case stepRunSQL:
		if t.plan.sqlID < firstWriteOp {
			return eng.pushReadRing(t)
		}
		select {
		case eng.writeQueue <- t:
			return true
		default:
			return false
		}
	default:
		eng.srv.completeInline(t)
		return true
	}
}

func (eng *pgEngine) setRingBit(op sqlOp, active bool) {
	maskBit := uint32(1) << op
	for {
		cur := eng.readyBitmask.Load()
		var updated uint32
		if active {
			updated = cur | maskBit
		} else {
			updated = cur &^ maskBit
		}
		if cur == updated || eng.readyBitmask.CompareAndSwap(cur, updated) {
			return
		}
	}
}

func (eng *pgEngine) wakeReadWorker() {
	if eng.parkedReads.Load() <= 0 {
		return
	}
	select {
	case eng.readSignal <- struct{}{}:
	default:
	}
}

func (eng *pgEngine) pushReadRing(t *reqCtx) bool {
	op := t.plan.sqlID
	ring := &eng.rings[op]
	ring.lock.Lock()
	if ring.stored == len(ring.items) {
		ring.lock.Unlock()
		return false
	}
	ring.items[ring.writeIdx] = t
	ring.writeIdx = (ring.writeIdx + 1) % len(ring.items)
	ring.stored++
	if ring.stored == 1 {
		ring.oldestAt.Store(t.queuedAt)
	}
	canSchedule := ring.running < ring.concurrency
	if canSchedule {
		eng.setRingBit(op, true)
	}
	ring.lock.Unlock()
	if canSchedule {
		eng.wakeReadWorker()
	}
	return true
}

func (eng *pgEngine) releaseReadSlot(op sqlOp) {
	ring := &eng.rings[op]
	ring.lock.Lock()
	ring.running--
	canSchedule := ring.stored > 0 && ring.running < ring.concurrency
	eng.setRingBit(op, canSchedule)
	ring.lock.Unlock()
	if canSchedule || eng.readyBitmask.Load() != 0 {
		eng.wakeReadWorker()
	}
}

func (eng *pgEngine) submitPasswordTask(t *reqCtx) {
	if t.plan.nextAction == stepRespond {
		t.plan.nextAction = stepCheckPass
	}
	evicted, ok := eng.hashQ.enqueue(t)
	if evicted != nil {
		finishWith(evicted, 503, msgServerBusy)
		eng.srv.completeAsync(evicted)
	}
	if !ok {
		finishWith(t, 503, msgServerBusy)
		eng.srv.completeAsync(t)
	}
}

func (eng *pgEngine) routeFollowup(t *reqCtx, step nextStep) {
	if step >= stepHashPass {
		t.plan.nextAction = step
		eng.submitPasswordTask(t)
		return
	}
	eng.srv.completeAsync(t)
}

// ---------- Read Session Execution ----------

func (s *pgSession) readWorkerLoop() {
	for {
		units, ok := s.awaitReadUnits()
		if !ok {
			return
		}
		if len(units) == 1 {
			s.execSingleReadUnit(units[0].op, units[0].tasks)
			clear(units[0].tasks)
			s.engine.releaseReadSlot(units[0].op)
		} else {
			s.execPipelinedReadUnits(units)
			clear(s.scratch)
			for i := range units {
				units[i].tasks = nil
				if units[i].op != opTags {
					s.engine.releaseReadSlot(units[i].op)
				}
			}
		}
	}
}

func (s *pgSession) awaitReadUnits() ([]readBatchUnit, bool) {
	eng := s.engine
	for {
		if eng.readyBitmask.Load() != 0 {
			if units := s.drainReadyRings(); len(units) > 0 {
				if eng.readyBitmask.Load() != 0 {
					eng.wakeReadWorker()
				}
				return units, true
			}
		}
		eng.parkedReads.Add(1)
		if eng.readyBitmask.Load() != 0 {
			eng.parkedReads.Add(-1)
			if units := s.drainReadyRings(); len(units) > 0 {
				if eng.readyBitmask.Load() != 0 {
					eng.wakeReadWorker()
				}
				return units, true
			}
			eng.parkedReads.Add(1)
		}
		select {
		case <-eng.readSignal:
			eng.parkedReads.Add(-1)
		case <-eng.stopSignal:
			eng.parkedReads.Add(-1)
			if units := s.drainReadyRings(); len(units) > 0 {
				return units, true
			}
			return nil, false
		}
	}
}

func (s *pgSession) drainReadyRings() []readBatchUnit {
	eng := s.engine
	maxTasks := eng.opts.maxReadBatch
	now := clockNano()
	maxAge := int64(eng.opts.maxQueueAge)
	s.scratch = s.scratch[:0]
	unitCount := 0
	nonTagCount := 0
	var visited uint32

	for unitCount < len(s.unitBuf) && nonTagCount < maxTasks {
		avail := eng.readyBitmask.Load()
		if unitCount > 0 && (avail == 0 || eng.parkedReads.Load() > 0) {
			break
		}
		candidates := avail &^ visited
		if nonTagCount >= 64 {
			candidates &^= uint32(1) << opListFeed
		}
		if candidates == 0 {
			break
		}
		chosen := s.cursorOp
		if candidates&(uint32(1)<<opTags) != 0 {
			chosen = opTags
		} else if candidates&(uint32(1)<<opUserByEmail) != 0 {
			chosen = opUserByEmail
		} else {
			if unitCount > 0 && maxTasks-nonTagCount < 16 {
				break
			}
			earliest := int64(1<<63 - 1)
			for off := 0; off < int(firstWriteOp); off++ {
				op := sqlOp((int(s.cursorOp) + off) % int(firstWriteOp))
				if candidates&(uint32(1)<<op) == 0 {
					continue
				}
				ts := eng.rings[op].oldestAt.Load()
				if op == opListFeed {
					ts -= 40_000_000
				}
				if ts < earliest {
					earliest = ts
					chosen = op
				}
			}
		}
		visited |= uint32(1) << chosen
		ring := &eng.rings[chosen]
		ring.lock.Lock()
		if ring.stored == 0 || ring.running >= ring.concurrency {
			stillReady := ring.stored > 0 && ring.running < ring.concurrency
			eng.setRingBit(chosen, stillReady)
			ring.lock.Unlock()
			continue
		}
		ring.running++
		fromIdx := len(s.scratch)
		budget := maxTasks - nonTagCount
		if chosen == opTags {
			budget = 1024
		} else if chosen == opListFeed {
			budget = min(budget, 128)
		}
		capLimit := min(fromIdx+budget, cap(s.scratch))
		for ring.stored > 0 && len(s.scratch) < capLimit {
			t := ring.items[ring.readIdx]
			ring.items[ring.readIdx] = nil
			ring.readIdx = (ring.readIdx + 1) % len(ring.items)
			ring.stored--
			if atomic.LoadUint32(&t.canceled) != 0 || now-t.queuedAt > maxAge {
				finishWith(t, 503, msgServerBusy)
				eng.srv.completeAsync(t)
				continue
			}
			s.scratch = append(s.scratch, t)
		}
		if ring.stored > 0 {
			ring.oldestAt.Store(ring.items[ring.readIdx].queuedAt)
		} else {
			ring.oldestAt.Store(0)
		}
		if len(s.scratch) == fromIdx {
			ring.running--
			eng.setRingBit(chosen, false)
			ring.lock.Unlock()
			continue
		}
		stillReady := ring.stored > 0 && ring.running < ring.concurrency
		eng.setRingBit(chosen, stillReady)
		ring.lock.Unlock()
		if chosen != opTags {
			s.cursorOp = (chosen + 1) % firstWriteOp
			nonTagCount += len(s.scratch) - fromIdx
		}
		s.unitBuf[unitCount] = readBatchUnit{
			op:    chosen,
			tasks: s.scratch[fromIdx:len(s.scratch)],
		}
		unitCount++
		if chosen == opListFeed {
			break
		}
	}
	for i := 1; i < unitCount; i++ {
		if s.unitBuf[i].op == opTags {
			u := s.unitBuf[i]
			copy(s.unitBuf[1:i+1], s.unitBuf[0:i])
			s.unitBuf[0] = u
		}
	}
	return s.unitBuf[:unitCount]
}

func calcColumnarSize(batch []*reqCtx, colOIDs []uint32) int {
	numCols := len(colOIDs)
	size := numCols * 20
	for _, t := range batch {
		for c := 0; c < numCols; c++ {
			size += 4 + len(t.plan.bindArgs[c])
		}
	}
	return size
}

func primarySortArgIdx(op sqlOp) int {
	switch op {
	case opProfile, opArticle, opComments:
		return 1
	case opListTag, opListAuthor, opListFav:
		return 3
	case opListAll:
		return 2
	default:
		return 0
	}
}

func orderReadTasks(op sqlOp, batch []*reqCtx) {
	if len(batch) <= 1 {
		return
	}
	keyCol := primarySortArgIdx(op)
	for i := 1; i < len(batch); i++ {
		item := batch[i]
		keyA := item.plan.bindArgs[keyCol]
		key0 := item.plan.bindArgs[0]
		var key2 []byte
		if keyCol == 3 {
			key2 = item.plan.bindArgs[2]
		}
		pos := i - 1
		for pos >= 0 {
			cmp := bytes.Compare(keyA, batch[pos].plan.bindArgs[keyCol])
			if cmp == 0 && keyCol == 3 {
				cmp = bytes.Compare(key2, batch[pos].plan.bindArgs[2])
			}
			if cmp > 0 || (cmp == 0 && (keyCol == 0 || bytes.Compare(key0, batch[pos].plan.bindArgs[0]) >= 0)) {
				break
			}
			batch[pos+1] = batch[pos]
			pos--
		}
		batch[pos+1] = item
	}
}

func (s *pgSession) packReadArrayArgs(op sqlOp, batch []*reqCtx, colOIDs []uint32) [][]byte {
	s.wireBuf = s.wireBuf[:0]
	return s.appendReadArrayArgs(op, batch, colOIDs)
}

func (s *pgSession) appendReadArrayArgs(op sqlOp, batch []*reqCtx, colOIDs []uint32) [][]byte {
	orderReadTasks(op, batch)
	return s.packColumnarArrays(batch, colOIDs)
}

func (s *pgSession) packColumnarArrays(batch []*reqCtx, colOIDs []uint32) [][]byte {
	numCols := len(colOIDs)
	numRows := len(batch)
	byteLen := calcColumnarSize(batch, colOIDs)
	startOffset := len(s.wireBuf)
	needed := startOffset + byteLen
	if cap(s.wireBuf) < needed {
		expanded := make([]byte, startOffset, max(needed*2, 4096))
		copy(expanded, s.wireBuf)
		s.wireBuf = expanded
	}
	s.wireBuf = s.wireBuf[:needed]
	slice := s.wireBuf[startOffset:needed]
	cursor := 0
	for cIdx, oid := range colOIDs {
		colStart := cursor
		binary.BigEndian.PutUint32(slice[cursor:], 1)
		binary.BigEndian.PutUint32(slice[cursor+4:], 0)
		binary.BigEndian.PutUint32(slice[cursor+8:], oid)
		binary.BigEndian.PutUint32(slice[cursor+12:], uint32(numRows))
		binary.BigEndian.PutUint32(slice[cursor+16:], 1)
		cursor += 20
		for _, t := range batch {
			arg := t.plan.bindArgs[cIdx]
			binary.BigEndian.PutUint32(slice[cursor:], uint32(len(arg)))
			cursor += 4
			copy(slice[cursor:], arg)
			cursor += len(arg)
		}
		s.colSlices[cIdx] = slice[colStart:cursor]
	}
	return s.colSlices[:numCols]
}

func (s *pgSession) guardedCompleteBatchReads(op sqlOp, batch []*reqCtx, rr *pgconn.ResultReader) (err error) {
	defer func() {
		if rec := recover(); rec != nil {
			log.Printf("panic in batch read decoder: %v", rec)
			err = fmt.Errorf("panic: %v", rec)
		}
	}()
	return s.completeBatchReads(op, batch, rr)
}

func (s *pgSession) enqueueReadQuery(op sqlOp, batch []*reqCtx) {
	if len(batch) == 1 && op != opTags {
		t := batch[0]
		qp := &t.plan
		var paramFmts []int16
		if qp.bindCount == 1 {
			paramFmts = wireFormatBin1
		} else if qp.bindCount > 1 {
			paramFmts = wireFormatSlice[:qp.bindCount]
		}
		s.pipeline.SendQueryStatement(s.prepared[op], qp.bindArgs[:qp.bindCount], paramFmts, wireFormatBin1)
		return
	}
	if op == opTags {
		s.pipeline.SendQueryStatement(s.prepared[opTags], nil, nil, wireFormatBin1)
		return
	}
	arrArgs := s.appendReadArrayArgs(op, batch, readBatchOIDs[op])
	s.pipeline.SendQueryStatement(s.prepared[toBatchReadOp(op)], arrArgs, wireFormatSlice[:len(arrArgs)], wireFormatBin1)
}

func (s *pgSession) execPipelinedReadUnits(units []readBatchUnit) {
	if s.conn == nil || s.conn.IsClosed() || s.pipeline == nil {
		for _, u := range units {
			s.execSingleReadUnit(u.op, u.tasks)
			if u.op == opTags {
				s.engine.releaseReadSlot(opTags)
			}
		}
		return
	}
	requiredBytes := 0
	for _, u := range units {
		if len(u.tasks) > 1 && u.op != opTags {
			requiredBytes += calcColumnarSize(u.tasks, readBatchOIDs[u.op])
		}
	}
	if cap(s.wireBuf) < requiredBytes {
		s.wireBuf = make([]byte, 0, max(requiredBytes*2, 4096))
	}
	s.wireBuf = s.wireBuf[:0]

	for _, u := range units {
		s.enqueueReadQuery(u.op, u.tasks)
	}
	s.pipeline.SendPipelineSync()
	_ = s.conn.Conn().SetDeadline(time.Now().Add(s.engine.opts.queryDeadline))
	if err := s.pipeline.Flush(); err != nil {
		s.teardownReadConn(err)
		for _, u := range units {
			s.execSingleReadUnit(u.op, u.tasks)
			if u.op == opTags {
				s.engine.releaseReadSlot(opTags)
			}
		}
		return
	}

	var firstErr error
	completedUnits := 0
	gotSync := false
	for idx, u := range units {
		if len(u.tasks) == 1 && u.op != opTags {
			t := u.tasks[0]
			step, err, synced := s.pullSingleResult(t)
			if synced {
				gotSync = true
			}
			if err != nil {
				firstErr = err
				completedUnits = idx
				break
			}
			s.engine.routeFollowup(t, step)
			completedUnits = idx + 1
		} else {
			err, synced := s.pullBatchReadResult(u.op, u.tasks)
			if synced {
				gotSync = true
			}
			if err != nil {
				firstErr = err
				completedUnits = idx
				break
			}
			if u.op == opTags {
				s.engine.releaseReadSlot(opTags)
			}
			completedUnits = idx + 1
		}
	}
	if !gotSync {
		if connErr := s.consumeUntilSync(&firstErr); connErr != nil {
			s.teardownReadConn(connErr)
			for i := completedUnits; i < len(units); i++ {
				s.execSingleReadUnit(units[i].op, units[i].tasks)
				if units[i].op == opTags {
					s.engine.releaseReadSlot(opTags)
				}
			}
			return
		}
	}
	if firstErr == nil {
		return
	}
	if isConnBroken(s.conn, firstErr) {
		s.teardownReadConn(firstErr)
	} else {
		s.resetPipelineState()
	}
	for i := completedUnits; i < len(units); i++ {
		u := units[i]
		if i == completedUnits && len(u.tasks) == 1 && u.op != opTags && !isConnBroken(s.conn, firstErr) {
			s.handleQueryError(u.tasks[0], firstErr)
			s.engine.srv.completeAsync(u.tasks[0])
			continue
		}
		for _, t := range u.tasks {
			s.soloSlice[0] = t
			s.execSingleReadUnit(u.op, s.soloSlice[:])
		}
		if u.op == opTags {
			s.engine.releaseReadSlot(opTags)
		}
	}
}

func (s *pgSession) execSingleReadUnit(op sqlOp, batch []*reqCtx) {
	for {
		if batch = s.ensureConnected(batch); len(batch) == 0 {
			return
		}
		if len(batch) == 1 && op != opTags {
			t := batch[0]
			qp := &t.plan
			var paramFmts []int16
			if qp.bindCount == 1 {
				paramFmts = wireFormatBin1
			} else if qp.bindCount > 1 {
				paramFmts = wireFormatSlice[:qp.bindCount]
			}
			s.pipeline.SendQueryStatement(s.prepared[op], qp.bindArgs[:qp.bindCount], paramFmts, wireFormatBin1)
			s.pipeline.SendPipelineSync()
			_ = s.conn.Conn().SetDeadline(time.Now().Add(s.engine.opts.queryDeadline))
			if err := s.pipeline.Flush(); err != nil {
				s.teardownReadConn(err)
				continue
			}
			step, err, synced := s.pullSingleResult(t)
			if !synced {
				if connErr := s.consumeUntilSync(&err); connErr != nil {
					s.teardownReadConn(connErr)
					continue
				}
			}
			if err != nil {
				if isConnBroken(s.conn, err) {
					s.teardownReadConn(err)
					continue
				}
				s.resetPipelineState()
				s.handleQueryError(t, err)
				s.engine.srv.completeAsync(t)
				return
			}
			s.engine.routeFollowup(t, step)
			return
		}

		if op == opTags {
			s.pipeline.SendQueryStatement(s.prepared[opTags], nil, nil, wireFormatBin1)
		} else {
			arrArgs := s.packReadArrayArgs(op, batch, readBatchOIDs[op])
			s.pipeline.SendQueryStatement(s.prepared[toBatchReadOp(op)], arrArgs, wireFormatSlice[:len(arrArgs)], wireFormatBin1)
		}
		s.pipeline.SendPipelineSync()
		_ = s.conn.Conn().SetDeadline(time.Now().Add(s.engine.opts.queryDeadline))
		if err := s.pipeline.Flush(); err != nil {
			s.teardownReadConn(err)
			continue
		}
		err, synced := s.pullBatchReadResult(op, batch)
		if !synced {
			if connErr := s.consumeUntilSync(&err); connErr != nil {
				s.teardownReadConn(connErr)
				continue
			}
		}
		if err == nil {
			return
		}
		if isConnBroken(s.conn, err) {
			s.teardownReadConn(err)
			continue
		}
		s.resetPipelineState()
		for _, t := range batch {
			s.soloSlice[0] = t
			s.execSingleReadUnit(op, s.soloSlice[:])
		}
		return
	}
}

func (s *pgSession) pullSingleResult(t *reqCtx) (step nextStep, err error, synced bool) {
	msg, pErr := s.pipeline.GetResults()
	if pErr != nil {
		return stepRespond, pErr, false
	}
	rr, ok := msg.(*pgconn.ResultReader)
	if !ok {
		return stepRespond, errors.New("unexpected pipeline result type"), msg != nil
	}
	step, err = s.guardedCompleteSingle(t, rr)
	return step, err, false
}

func (s *pgSession) pullBatchReadResult(op sqlOp, batch []*reqCtx) (err error, synced bool) {
	msg, pErr := s.pipeline.GetResults()
	if pErr != nil {
		return pErr, false
	}
	rr, ok := msg.(*pgconn.ResultReader)
	if !ok {
		return errors.New("unexpected pipeline result type"), msg != nil
	}
	err = s.guardedCompleteBatchReads(op, batch, rr)
	return err, false
}

func (s *pgSession) teardownReadConn(err error) {
	log.Printf("read connection dropped: %v", err)
	s.pipeline = nil
	if s.conn != nil {
		s.conn.Close(context.Background())
		s.conn = nil
	}
	s.needsReset = false
}

// ---------- Write Session Execution ----------

func (s *pgSession) writeWorkerLoop(inCh chan *reqCtx) {
	chOpen := true
	for {
		for s.fActive < len(s.flights) && !s.needsReset {
			if len(s.retryQueue) > 0 {
				s.soloSlice[0] = s.retryQueue[0]
				s.retryQueue[0] = nil
				s.retryQueue = s.retryQueue[1:]
				s.dispatchWriteFlight(s.soloSlice[:], true)
				continue
			}
			if !chOpen {
				break
			}
			tasks, ok := s.pullWriteBatch(inCh, s.fActive == 0)
			if !ok {
				chOpen = false
				break
			}
			if len(tasks) == 0 {
				break
			}
			if validTasks := s.pruneExpired(tasks); len(validTasks) > 0 {
				s.dispatchWriteFlight(validTasks, false)
			}
			clear(tasks)
		}
		switch {
		case s.fActive > 0:
			s.completeWriteFlight()
		case s.needsReset:
			s.resetPipelineState()
		case !chOpen && len(s.retryQueue) == 0:
			return
		}
	}
}

func (s *pgSession) pullWriteBatch(inCh chan *reqCtx, waitIfEmpty bool) ([]*reqCtx, bool) {
	batch := s.scratch[:0]
	if waitIfEmpty {
		t, ok := <-inCh
		if !ok {
			return nil, false
		}
		batch = append(batch, t)
	} else {
		select {
		case t, ok := <-inCh:
			if !ok {
				return nil, false
			}
			batch = append(batch, t)
		default:
			return batch, true
		}
	}
	return s.coalesceWriteBatch(inCh, batch, waitIfEmpty), true
}

func (s *pgSession) coalesceWriteBatch(inCh chan *reqCtx, batch []*reqCtx, allowLinger bool) []*reqCtx {
	maxCap := cap(batch)
	lingerDur := s.engine.opts.commitLinger
	for len(batch) < maxCap {
		select {
		case t, ok := <-inCh:
			if !ok {
				return batch
			}
			batch = append(batch, t)
			continue
		default:
		}
		if !allowLinger || lingerDur == 0 {
			return batch
		}
		rem := lingerDur
		if elapsedRem := time.Duration(batch[0].queuedAt + int64(lingerDur) - clockNano()); elapsedRem < rem {
			rem = elapsedRem
		}
		if rem <= 0 {
			return batch
		}
		s.lingerTimer.Reset(rem)
		select {
		case t, ok := <-inCh:
			s.lingerTimer.Stop()
			if !ok {
				return batch
			}
			batch = append(batch, t)
		case <-s.lingerTimer.C:
			return batch
		}
	}
	return batch
}

func (s *pgSession) pruneExpired(tasks []*reqCtx) []*reqCtx {
	kept := tasks[:0]
	now := clockNano()
	maxAge := int64(s.engine.opts.maxQueueAge)
	for _, t := range tasks {
		if atomic.LoadUint32(&t.canceled) != 0 || now-t.queuedAt > maxAge {
			finishWith(t, 503, msgServerBusy)
			s.engine.srv.completeAsync(t)
			continue
		}
		kept = append(kept, t)
	}
	return kept
}

func (s *pgSession) guardedCompleteSingle(t *reqCtx, rr *pgconn.ResultReader) (step nextStep, err error) {
	defer func() {
		if rec := recover(); rec != nil {
			log.Printf("panic in single result decoder: %v", rec)
			err = fmt.Errorf("panic: %v", rec)
		}
	}()
	return s.completeSingleResult(t, rr)
}

func (s *pgSession) guardedCompleteBatchWrites(op sqlOp, batch []*reqCtx, rr *pgconn.ResultReader) (err error) {
	defer func() {
		if rec := recover(); rec != nil {
			log.Printf("panic in batch write decoder: %v", rec)
			err = fmt.Errorf("panic: %v", rec)
		}
	}()
	return s.completeBatchWrites(op, batch, rr)
}

func writeSortColIdx(op sqlOp) int {
	if op >= opFollow && op <= opUnfavorite {
		return 1
	}
	return 0
}

func orderWriteTasks(tasks []*reqCtx) {
	if len(tasks) <= 1 {
		return
	}
	for i := 1; i < len(tasks); i++ {
		item := tasks[i]
		op := item.plan.sqlID
		col := writeSortColIdx(op)
		keyA := item.plan.bindArgs[col]
		key0 := item.plan.bindArgs[0]
		pos := i - 1
		for pos >= 0 {
			prev := tasks[pos]
			if prev.plan.sqlID < op {
				break
			}
			if prev.plan.sqlID == op {
				cmp := bytes.Compare(keyA, prev.plan.bindArgs[col])
				if cmp > 0 || (cmp == 0 && (col == 0 || bytes.Compare(key0, prev.plan.bindArgs[0]) >= 0)) {
					break
				}
			}
			tasks[pos+1] = prev
			pos--
		}
		tasks[pos+1] = item
	}
}

func (s *pgSession) dispatchWriteFlight(tasks []*reqCtx, solo bool) {
	if tasks = s.ensureConnected(tasks); len(tasks) == 0 {
		return
	}
	slot := &s.flights[(s.fHead+s.fActive)%len(s.flights)]
	slot.tasks = append(slot.tasks[:0], tasks...)
	slot.ranges = slot.ranges[:0]
	slot.solo = solo
	if !solo {
		orderWriteTasks(slot.tasks)
	}
	s.wireBuf = s.wireBuf[:0]
	for from := 0; from < len(slot.tasks); {
		op := slot.tasks[from].plan.sqlID
		to := from + 1
		if !solo && isBatchableWriteOp(op) {
			for to < len(slot.tasks) && slot.tasks[to].plan.sqlID == op {
				to++
			}
		}
		if to-from > 1 {
			sub := slot.tasks[from:to]
			s.wireBuf = s.wireBuf[:0]
			arrArgs := s.packColumnarArrays(sub, writeBatchOIDs(op))
			s.pipeline.SendQueryStatement(s.prepared[toBatchWriteOp(op)], arrArgs, wireFormatSlice[:len(arrArgs)], wireFormatBin1)
			slot.ranges = append(slot.ranges, writeSpanRange{from: from, to: to, isBatch: true})
		} else {
			t := slot.tasks[from]
			qp := &t.plan
			var paramFmts []int16
			if qp.bindCount == 1 {
				paramFmts = wireFormatBin1
			} else if qp.bindCount > 1 {
				paramFmts = wireFormatSlice[:qp.bindCount]
			}
			s.pipeline.SendQueryStatement(s.prepared[qp.sqlID], qp.bindArgs[:qp.bindCount], paramFmts, wireFormatBin1)
			slot.ranges = append(slot.ranges, writeSpanRange{from: from, to: to, isBatch: false})
		}
		from = to
	}
	s.pipeline.SendPipelineSync()
	_ = s.conn.Conn().SetDeadline(time.Now().Add(s.engine.opts.queryDeadline))
	s.fActive++
	if err := s.pipeline.Flush(); err != nil {
		if s.fActive > 1 {
			err = errors.New(err.Error())
		}
		s.teardownWriteConn(err, 0)
	}
}

func (s *pgSession) completeWriteFlight() {
	slot := &s.flights[s.fHead]
	tasks := slot.tasks
	completedTasks, failedSpan, opErr, synced := s.pullWriteFlightResults(slot)
	if !synced {
		if connErr := s.consumeUntilSync(&opErr); connErr != nil {
			s.teardownWriteConn(connErr, completedTasks)
			return
		}
	}
	if opErr != nil && isConnBroken(s.conn, opErr) {
		s.teardownWriteConn(opErr, completedTasks)
		return
	}
	totalSpans := len(slot.ranges)
	s.advanceFlightHead()

	if opErr == nil {
		s.engine.srv.completeAsyncBatch(tasks)
		clear(tasks)
		return
	}

	if failedSpan+1 < totalSpans {
		s.needsReset = true
	}
	if slot.solo {
		s.handleQueryError(tasks[0], opErr)
		s.engine.srv.completeAsync(tasks[0])
	} else {
		s.retryQueue = append(s.retryQueue, tasks...)
	}
	clear(tasks)
}

func (s *pgSession) pullWriteFlightResults(slot *inflightBatch) (doneTasks, spanPos int, err error, synced bool) {
	for idx, rng := range slot.ranges {
		msg, pErr := s.pipeline.GetResults()
		if pErr != nil {
			return doneTasks, idx, pErr, false
		}
		rr, ok := msg.(*pgconn.ResultReader)
		if !ok {
			return doneTasks, idx, errors.New("unexpected pipeline result type"), msg != nil
		}
		if rng.isBatch {
			sub := slot.tasks[rng.from:rng.to]
			if bErr := s.guardedCompleteBatchWrites(sub[0].plan.sqlID, sub, rr); bErr != nil {
				return doneTasks, idx, bErr, false
			}
		} else {
			t := slot.tasks[rng.from]
			step, sErr := s.guardedCompleteSingle(t, rr)
			if sErr != nil {
				return doneTasks, idx, sErr, false
			}
			t.plan.nextAction = step
		}
		doneTasks = rng.to
	}
	return doneTasks, len(slot.ranges), nil, false
}

func (s *pgSession) consumeUntilSync(firstErr *error) error {
	for {
		msg, err := s.pipeline.GetResults()
		var pgErr *pgconn.PgError
		switch {
		case errors.As(err, &pgErr):
			if *firstErr == nil {
				*firstErr = err
			}
		case err != nil || msg == nil:
			if *firstErr != nil {
				return *firstErr
			}
			if err == nil {
				err = errors.New("pipeline closed before sync")
			}
			return err
		default:
			switch val := msg.(type) {
			case *pgconn.PipelineSync:
				return nil
			case *pgconn.ResultReader:
				_, _ = val.Close()
			}
		}
	}
}

func (s *pgSession) advanceFlightHead() {
	s.fHead = (s.fHead + 1) % len(s.flights)
	s.fActive--
}

func (s *pgSession) teardownWriteConn(err error, doneInHead int) {
	log.Printf("write connection dropped (%d flights active): %v", s.fActive, err)
	canReplay := queryNeverExecuted(err, doneInHead)
	for s.fActive > 0 {
		slot := &s.flights[s.fHead]
		for _, t := range slot.tasks {
			if canReplay {
				s.retryQueue = append(s.retryQueue, t)
			} else {
				finishWith(t, 500, msgServerError)
				s.engine.srv.completeAsync(t)
			}
		}
		clear(slot.tasks)
		s.advanceFlightHead()
	}
	s.fHead = 0
	s.pipeline = nil
	if s.conn != nil {
		s.conn.Close(context.Background())
		s.conn = nil
	}
	s.needsReset = false
}

func (s *pgSession) resetPipelineState() {
	s.needsReset = false
	if s.pipeline == nil {
		return
	}
	if err := s.pipeline.Close(); err != nil {
		s.pipeline = nil
		if s.conn != nil {
			s.conn.Close(context.Background())
			s.conn = nil
		}
		return
	}
	s.pipeline = s.conn.StartPipeline(context.Background())
}

func (s *pgSession) openConnection(ctx context.Context, warmSQL string) error {
	conn, err := pgconn.ConnectConfig(ctx, s.engine.pgCfg)
	if err != nil {
		return fmt.Errorf("pg connect: %w", err)
	}
	if warmSQL != "" {
		_ = conn.Exec(ctx, "SET jit = off; "+warmSQL).Close()
	}
	if err := conn.Exec(ctx, "RESET enable_indexonlyscan; RESET enable_indexscan; RESET enable_bitmapscan; RESET enable_seqscan; SET statement_timeout = 5000; SET plan_cache_mode = force_generic_plan; SET jit = off; SET work_mem = '32MB'").Close(); err != nil {
		conn.Close(ctx)
		return fmt.Errorf("pg session init: %w", err)
	}
	for op := sqlOp(0); op < sqlOpCount; op++ {
		writeOp := (op >= firstWriteOp && op < firstBatchReadOp) || op >= firstBatchWriteOp
		if s.isWriter != writeOp {
			continue
		}
		entry := sqlCatalog[op]
		desc, prepErr := conn.Prepare(ctx, entry.id, entry.query, nil)
		if prepErr != nil {
			conn.Close(ctx)
			return fmt.Errorf("prepare %s (%d): %w", entry.id, op, prepErr)
		}
		s.prepared[op] = desc
	}
	s.conn = conn
	s.pipeline = conn.StartPipeline(context.Background())
	return nil
}

func (s *pgSession) ensureConnected(tasks []*reqCtx) []*reqCtx {
	for {
		if s.conn != nil && !s.conn.IsClosed() && s.pipeline != nil {
			return tasks
		}
		if s.isWriter && s.fActive > 0 {
			s.teardownWriteConn(errors.New("connection lost"), 0)
		}
		if s.conn != nil {
			s.conn.Close(context.Background())
			s.conn, s.pipeline = nil, nil
		}
		if delay := time.Until(s.nextConnectAt); delay > 0 {
			time.Sleep(delay)
		}
		if tasks = s.pruneExpired(tasks); len(tasks) == 0 {
			return tasks
		}
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		err := s.openConnection(ctx, "")
		cancel()
		if err == nil {
			downDur, tries := s.backoff.markUp()
			log.Printf("pg connection restored (writer=%v) after %s (%d tries)",
				s.isWriter, downDur.Round(time.Millisecond), tries)
			return tasks
		}
		delay := s.backoff.nextDelay()
		s.nextConnectAt = time.Now().Add(delay)
		if s.backoff.shouldLog() {
			log.Printf("pg reconnect failed (writer=%v, try %d, %d queued), next in %s: %v",
				s.isWriter, s.backoff.tries, len(tasks), delay.Round(time.Millisecond), err)
		}
	}
}

// ---------- Password Hashing Pool ----------

func (eng *pgEngine) launchHashWorkers() {
	burstThreads := max(2, eng.opts.hashThreads/2)
	poolSize := (eng.opts.hashThreads + burstThreads) * 2
	eng.hashPool = make(chan *hashWorkBatch, poolSize+1)
	eng.hashBaseCh = make(chan *hashWorkBatch)
	eng.hashBurst = make(chan *hashWorkBatch)
	for range poolSize + 1 {
		eng.hashPool <- new(hashWorkBatch)
	}
	eng.hashWG.Go(eng.collectHashBatches)
	for range eng.opts.hashThreads {
		eng.hashWG.Go(func() { eng.runHashWorker(eng.hashBaseCh) })
	}
	for range burstThreads {
		eng.hashWG.Go(func() { eng.runHashWorker(eng.hashBurst) })
	}
}

func (eng *pgEngine) pullNextHashBatch(wb *hashWorkBatch, now, maxAge int64) (backlog int, isClosed bool) {
	hd := &eng.hashQ
	ringLen := len(hd.fifoBuf)
	for wb.count < blowfish8.Lanes {
		hd.lock.Lock()
		for hd.fifoCount > 0 {
			headTask := hd.fifoBuf[hd.fifoHead]
			if atomic.LoadUint32(&headTask.canceled) != 0 {
				hd.fifoBuf[hd.fifoHead] = nil
				hd.fifoHead = (hd.fifoHead + 1) % ringLen
				hd.fifoCount--
				hd.lock.Unlock()
				eng.srv.completeAsync(headTask)
				hd.lock.Lock()
				continue
			}
			if now-headTask.queuedAt > maxAge {
				hd.fifoBuf[hd.fifoHead] = nil
				hd.fifoHead = (hd.fifoHead + 1) % ringLen
				hd.fifoCount--
				hd.lock.Unlock()
				finishWith(headTask, 503, msgServerBusy)
				eng.srv.completeAsync(headTask)
				hd.lock.Lock()
				continue
			}
			break
		}
		if hd.fifoCount == 0 {
			shut := hd.shutting
			hd.lock.Unlock()
			return 0, shut
		}
		var picked *reqCtx
		if hd.fifoCount > 32 {
			hd.fifoTail = (hd.fifoTail - 1 + ringLen) % ringLen
			picked = hd.fifoBuf[hd.fifoTail]
			hd.fifoBuf[hd.fifoTail] = nil
		} else {
			picked = hd.fifoBuf[hd.fifoHead]
			hd.fifoBuf[hd.fifoHead] = nil
			hd.fifoHead = (hd.fifoHead + 1) % ringLen
		}
		hd.fifoCount--
		rem := hd.fifoCount
		hd.lock.Unlock()

		if atomic.LoadUint32(&picked.canceled) != 0 {
			eng.srv.completeAsync(picked)
			continue
		}
		if now-picked.queuedAt > maxAge {
			finishWith(picked, 503, msgServerBusy)
			eng.srv.completeAsync(picked)
			continue
		}
		wb.items[wb.count] = picked
		wb.count++
		backlog = rem
	}
	return backlog, false
}

func (eng *pgEngine) collectHashBatches() {
	defer func() {
		close(eng.hashBaseCh)
		close(eng.hashBurst)
	}()
	waitTimer := time.NewTimer(time.Hour)
	waitTimer.Stop()
	maxAge := min(int64(eng.opts.maxQueueAge), int64(9200*time.Millisecond))
	var lastBatchAt int64
	for {
		var wb *hashWorkBatch
		select {
		case wb = <-eng.hashPool:
		default:
			wb = new(hashWorkBatch)
		}
		wb.count = 0
		_, closed := eng.pullNextHashBatch(wb, clockNano(), maxAge)
		for wb.count == 0 {
			if closed {
				return
			}
			<-eng.hashQ.notifyCh
			_, closed = eng.pullNextHashBatch(wb, clockNano(), maxAge)
		}
		if wb.count < blowfish8.Lanes && !closed {
			now := clockNano()
			coalesceNs := int64(eng.opts.hashCoalesce)
			if now-lastBatchAt < int64(200*time.Millisecond) && coalesceNs < int64(45*time.Millisecond) {
				coalesceNs = int64(45 * time.Millisecond)
			}
			coalesceUntil := now + coalesceNs
			for wb.count < blowfish8.Lanes {
				now = clockNano()
				wait := time.Duration(coalesceUntil - now)
				if wait <= 0 {
					break
				}
				waitTimer.Reset(wait)
				select {
				case <-eng.hashQ.notifyCh:
					if !waitTimer.Stop() {
						select {
						case <-waitTimer.C:
						default:
						}
					}
				case <-waitTimer.C:
				}
				_, closed = eng.pullNextHashBatch(wb, clockNano(), maxAge)
				if closed || clockNano() >= coalesceUntil {
					break
				}
			}
		}
		lastBatchAt = clockNano()

		select {
		case eng.hashBaseCh <- wb:
		default:
			select {
			case eng.hashBaseCh <- wb:
			case eng.hashBurst <- wb:
			}
		}
	}
}

func (eng *pgEngine) runHashWorker(inCh <-chan *hashWorkBatch) {
	var bfEng blowfish8.Engine
	var jobs [blowfish8.Lanes]blowfish8.HashJob
	signer := newTokenSigner(eng.hmacKey)
	for wb := range inCh {
		eng.executeHashBatch(&bfEng, &jobs, signer, wb)
	}
}

func (eng *pgEngine) executeHashBatch(bfEng *blowfish8.Engine, jobs *[blowfish8.Lanes]blowfish8.HashJob, signer *tokenSigner, wb *hashWorkBatch) {
	var completed [blowfish8.Lanes]*reqCtx
	compCount := 0
	count := wb.count
	for i := range count {
		qp := &wb.items[i].plan
		hj := &jobs[i]
		*hj = blowfish8.HashJob{Plain: strToBytes(qp.userForm.password)}
		if qp.nextAction == stepHashPass {
			hj.Cost = defaultBcryptCost
		} else {
			hj.Existing = qp.bcryptBuf[:qp.bcryptLen]
			if qp.bcryptLen == 0 {
				hj.Existing = emptySlice
			}
		}
	}
	bfEng.Evaluate(jobs[:count])
	for i := range count {
		t := wb.items[i]
		qp := &t.plan
		switch {
		case qp.nextAction == stepCheckPass:
			finishLoginVerify(signer, t, jobs[i].Matched)
			completed[compCount] = t
			compCount++
		case !jobs[i].Matched:
			finishWith(t, 422, msgPassTooLong)
			completed[compCount] = t
			compCount++
		default:
			qp.bcryptLen = copy(qp.bcryptBuf[:], jobs[i].Encoded[:])
			qp.passHashed = true
			if step := guardedPrepare(signer, t); step != stepRunSQL {
				completed[compCount] = t
				compCount++
				break
			}
			t.queuedAt = clockNano()
			select {
			case eng.writeQueue <- t:
			default:
				finishWith(t, 503, msgServerBusy)
				completed[compCount] = t
				compCount++
			}
		}
		wb.items[i] = nil
		jobs[i] = blowfish8.HashJob{}
	}
	if compCount > 0 {
		eng.srv.completeAsyncBatch(completed[:compCount])
	}
	wb.count = 0
	select {
	case eng.hashPool <- wb:
	default:
	}
}
