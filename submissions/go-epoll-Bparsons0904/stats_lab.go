//go:build lab

// Lab instrumentation: counters, the sampler and the pprof hook. The submission build leaves all of it out
// (stats_nolab.go), so nothing here costs the hot path anything.

package main

import (
	"fmt"
	"log"
	nethttp "net/http"
	_ "net/http/pprof"
	"os"
	"os/signal"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"multicorelab/http"
)

// counters for the SIGUSR1 dump and the line printed at shutdown.
var stats struct {
	flushes, flushOps  atomic.Int64 // worker flushes and the requests in them
	commits, commitOps atomic.Int64 // group commits and the writes in them
	groupFails         atomic.Int64 // groups rolled back and re-run request by request
	shared             atomic.Int64 // requests served by another request's execution
	bcBatches, bcJobs  atomic.Int64
	fam                [nFamStats]famStat // batch sizes per statement family
	rd                 []readerStat       // per reader: its flushes, requests, and steals
	txNs, txN          atomic.Int64       // time in the write transactions (BEGIN..COMMIT pipelines) and their count
	postReadNs         atomic.Int64       // time in the reads that follow a commit in the same flush
	postReadN          atomic.Int64
}

func ratio(a, b int64) float64 {
	if b == 0 {
		return 0
	}
	return float64(a) / float64(b)
}

// parkString reports how often a request found every Op in flight and waited, and for how long.
func parkString(st *http.Stats) string {
	var b strings.Builder
	fmt.Fprintf(&b, " parks=%d", st.Parks)
	for i, n := range st.ParkWait {
		fmt.Fprintf(&b, " park_wait_lt_%dms=%d", 1<<i, n)
	}
	return b.String()
}

func statsString(srv *http.Server) string {
	hs := srv.Stats()
	s := &stats
	return fmt.Sprintf("STATS flushes=%d ops/flush=%.2f commits=%d writes/commit=%.2f group_fails=%d shared_saved=%d bcrypt_batches=%d bcrypt_per_batch=%.2f tx_ms_avg=%.2f post_read_ms_avg=%.2f%s%s",
		s.flushes.Load(), ratio(s.flushOps.Load(), s.flushes.Load()), s.commits.Load(),
		ratio(s.commitOps.Load(), s.commits.Load()), s.groupFails.Load(), s.shared.Load(),
		s.bcBatches.Load(), ratio(s.bcJobs.Load(), s.bcBatches.Load()),
		ratio(s.txNs.Load(), s.txN.Load())/1e6, ratio(s.postReadNs.Load(), s.postReadN.Load())/1e6, totalFams(), parkString(&hs))
}

// sample logs, every interval, the state that explains a latency stall: per worker the queue depth, the share of
// the interval spent in flushes and the longest flush; the server's requests, deferred requests in flight and
// connections; the bcrypt queue.
func (d *DB) sample(every time.Duration, srv *http.Server) {
	start := time.Now()
	var lastReq, lastParks uint64
	rdPrev := make([]readerSnap, len(stats.rd))
	rdBusy := make([]int64, len(stats.rd))
	var famPrev, famCur famSnapshot
	var lTxNs, lTxN, lPrNs, lPrN, lCo, lCm int64
	busy := make([]int64, len(d.workers))
	flushes := make([]int64, len(d.workers))
	for range time.Tick(every) {
		st := srv.Stats()
		var b, m, f strings.Builder
		for i, w := range d.workers {
			bn, fn := w.busyNs.Load(), w.flushN.Load()
			fmt.Fprintf(&b, "%d ", (bn-busy[i])*100/int64(every))
			fmt.Fprintf(&m, "%d ", w.maxNs.Swap(0)/1e6)
			fmt.Fprintf(&f, "%d ", fn-flushes[i])
			busy[i], flushes[i] = bn, fn
		}
		txNs, txN, prNs, prN := stats.txNs.Load(), stats.txN.Load(), stats.postReadNs.Load(), stats.postReadN.Load()
		co, cm := stats.commitOps.Load(), stats.commits.Load()
		wr := fmt.Sprintf("tx_ms=%.1f post_read_ms=%.1f writes/commit=%.1f", ratio(txNs-lTxNs, txN-lTxN)/1e6,
			ratio(prNs-lPrNs, prN-lPrN)/1e6, ratio(co-lCo, cm-lCm))
		famCur.load()
		fams := famString(&famCur, &famPrev)
		famPrev = famCur
		lTxNs, lTxN, lPrNs, lPrN, lCo, lCm = txNs, txN, prNs, prN, co, cm
		log.Printf("SAMPLE t=%d req/s=%d inflight=%d conns=%d bcq=%d wq=%d rq=%d parks=%d %s busy%%=[%s] maxflush_ms=[%s] flushes=[%s]",
			int(time.Since(start).Seconds()), (st.Requests-lastReq)*uint64(time.Second)/uint64(every), st.OpsInFlight,
			st.Conns, len(d.bc.in), wqLen(d.wqs), rqLen(d.rqs), st.Parks-lastParks, wr, b.String(), m.String(), f.String())
		lastReq, lastParks = st.Requests, st.Parks
		log.Printf("BATCH t=%d (family=flushes:requests/flush:keys/flush)%s", int(time.Since(start).Seconds()), fams)
		if len(d.groups) > 1 || len(d.rqs) > 1 {
			var g strings.Builder
			for gi, grp := range d.groups {
				var fl, ops, steals, busy int64
				for _, r := range grp.rds {
					rs := &stats.rd[r]
					fl, ops, steals = fl+rs.flushes.Load()-rdPrev[r].flushes, ops+rs.ops.Load()-rdPrev[r].ops, steals+rs.steals.Load()-rdPrev[r].steals
					busy += d.workers[nWriters+r].busyNs.Load() - rdBusy[r]
				}
				ql := 0
				ql = d.rqs[grp.queue].len()
				fmt.Fprintf(&g, " g%d[r=%d q=%d fl=%d req/fl=%.1f busy=%d%% steals=%d]", gi, grp.readers, ql, fl, ratio(ops, fl),
					busy*100/(int64(every)*int64(grp.readers)), steals)
			}
			for r := range stats.rd {
				rs := &stats.rd[r]
				rdPrev[r] = readerSnap{rs.flushes.Load(), rs.ops.Load(), rs.steals.Load()}
				rdBusy[r] = d.workers[nWriters+r].busyNs.Load()
			}
			log.Printf("GROUPS t=%d (readers, queue, flushes, requests/flush, busy, steals per interval)%s", int(time.Since(start).Seconds()), g.String())
		}
	}
}

func rqLen(qs []*queue) (n int) { return wqLen(qs) }

func wqLen(qs []*queue) (n int) {
	for _, q := range qs {
		n += q.len()
	}
	return n
}

var famStatName = [nFamStats]string{"global", "tag", "author", "favorited", "feed",
	"cnt-global", "cnt-tag", "cnt-author", "cnt-favorited", "cnt-feed", "articles", "ids", "fav-pairs", "fol-pairs"}

// famStat counts, over the flushes that contain the family, the requests and the distinct keys they ran.
type famStat struct{ n, reqs, keys atomic.Int64 }

func (f *famStat) add(reqs, keys int) {
	if reqs == 0 && keys == 0 {
		return
	}
	f.n.Add(1)
	f.reqs.Add(int64(reqs))
	f.keys.Add(int64(keys))
}

// famSnapshot is the cumulative state of every family, to diff between samples.
type famSnapshot [nFamStats][3]int64

func (s *famSnapshot) load() {
	for i := range stats.fam {
		f := &stats.fam[i]
		s[i] = [3]int64{f.n.Load(), f.reqs.Load(), f.keys.Load()}
	}
}

// famString lists, per family seen since prev, "name:flushes reqs/flush keys/flush".
func famString(cur, prev *famSnapshot) string {
	var b strings.Builder
	for i := range cur {
		n := cur[i][0] - prev[i][0]
		if n == 0 {
			continue
		}
		fmt.Fprintf(&b, " %s=%d:%.1f/%.1f", famStatName[i], n, float64(cur[i][1]-prev[i][1])/float64(n), float64(cur[i][2]-prev[i][2])/float64(n))
	}
	return b.String()
}

func totalFams() string {
	var cur, zero famSnapshot
	cur.load()
	return " fam[" + strings.TrimSpace(famString(&cur, &zero)) + "]"
}

// readerStat counts one reader's work, for the GROUPS line.
type readerStat struct{ flushes, ops, steals atomic.Int64 }

type readerSnap struct{ flushes, ops, steals int64 }

// labWorker is a worker's busy-time counters, read by the sampler.
type labWorker struct{ busyNs, maxNs, flushN atomic.Int64 }

type statStamp = time.Time

func statNow() statStamp { return time.Now() }
func statShared()        { stats.shared.Add(1) }
func statBcrypt(jobs int) {
	stats.bcBatches.Add(1)
	stats.bcJobs.Add(int64(jobs))
}
func statFlush(n int) {
	stats.flushes.Add(1)
	stats.flushOps.Add(int64(n))
}
func statCommit(n int) {
	stats.commits.Add(1)
	stats.commitOps.Add(int64(n))
}
func statPostRead(t statStamp) {
	stats.postReadNs.Add(int64(time.Since(t)))
	stats.postReadN.Add(1)
}
func statTx(t statStamp) {
	stats.txNs.Add(int64(time.Since(t)))
	stats.txN.Add(1)
}
func statReaders(n int) { stats.rd = make([]readerStat, n) }
func statSteal(rd int)  { stats.rd[rd].steals.Add(1) }
func statReaderFlush(rd, n int) {
	rs := &stats.rd[rd]
	rs.flushes.Add(1)
	rs.ops.Add(int64(n))
}
func statGroupFail()            { stats.groupFails.Add(1) }
func statFam(i, reqs, keys int) { stats.fam[i].add(reqs, keys) }
func statFlushEnd(w *worker, t statStamp) {
	d := int64(time.Since(t))
	w.busyNs.Add(d)
	w.flushN.Add(1)
	for m := w.maxNs.Load(); d > m && !w.maxNs.CompareAndSwap(m, d); m = w.maxNs.Load() {
	}
}

// labStart starts the sampler, the SIGUSR1 dump and, with CONDUIT_PPROF=addr, the pprof server.
func labStart(db *DB, srv *http.Server) {
	if every := time.Duration(envInt("CONDUIT_SAMPLE_SECS", 5)) * time.Second; every > 0 {
		go db.sample(every, srv)
	}
	if addr := os.Getenv("CONDUIT_PPROF"); addr != "" {
		go func() { log.Print(nethttp.ListenAndServe(addr, nil)) }()
	}
	usr := make(chan os.Signal, 1)
	signal.Notify(usr, syscall.SIGUSR1)
	go func() {
		for range usr {
			log.Print(statsString(srv))
		}
	}()
}

// labStop logs the counters at shutdown.
func labStop(srv *http.Server) { log.Print(statsString(srv)) }
