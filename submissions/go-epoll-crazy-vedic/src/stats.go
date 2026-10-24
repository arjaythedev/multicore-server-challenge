package main

import (
	"context"
	"encoding/json"
	"log"
	"math/bits"
	"os"
	"path/filepath"
	"runtime"
	"runtime/pprof"
	"strconv"
	"sync/atomic"
	"time"
)

type dbMetrics struct {
	enabled                                bool
	jobs, executions, batches, completed   atomic.Uint64
	databaseNS, queueNS, queueSamples      atomic.Uint64
	queue, collect, flush, syncWait        [2]distribution
	batch                                  [2]distribution
	bcryptWait, bcryptCompute, bcryptBatch distribution
	bcryptNativeJobs, bcryptFallbackJobs   atomic.Uint64
	statements                             [numStmts]statementMetrics
}

func (m *dbMetrics) init() {
	interval, err := time.ParseDuration(envOr("STATS_INTERVAL", "0s"))
	m.enabled = err == nil && interval > 0
	for _, group := range []*[2]distribution{&m.queue, &m.collect, &m.flush, &m.syncWait, &m.batch} {
		for i := range group {
			group[i].enabled = m.enabled
		}
	}
	m.bcryptWait.enabled, m.bcryptCompute.enabled, m.bcryptBatch.enabled = m.enabled, m.enabled, m.enabled
	for i := range m.statements {
		m.statements[i].firstResult.enabled = m.enabled
		m.statements[i].drain.enabled = m.enabled
	}
}

// Logarithmic histograms retain stage distributions without per-request allocation.
// Latencies are nanoseconds; batch histograms contain counts, never durations.
type distribution struct {
	enabled             bool
	count, sum, maximum atomic.Uint64
	buckets             [32]atomic.Uint64
}

func (m *distribution) observe(value int64) {
	if !m.enabled {
		return
	}
	v := uint64(max(0, value))
	m.count.Add(1)
	m.sum.Add(v)
	for old := m.maximum.Load(); v > old; old = m.maximum.Load() {
		if m.maximum.CompareAndSwap(old, v) {
			break
		}
	}
	m.buckets[min(31, bits.Len64(v))].Add(1)
}
func (m *distribution) snapshot() map[string]any {
	buckets := make([]uint64, len(m.buckets))
	for i := range buckets {
		buckets[i] = m.buckets[i].Load()
	}
	return map[string]any{"count": m.count.Load(), "sum": m.sum.Load(), "max": m.maximum.Load(), "buckets_pow2": buckets}
}

type statementMetrics struct {
	jobs, executions, shared atomic.Uint64
	firstResult, drain       distribution
}

var statementNames = [...]string{"tags", "user", "login", "profile", "global", "tag", "author", "favorited", "feed", "article", "article_after_commit", "comments", "register", "user_update", "follow", "unfollow", "article_create", "article_update", "article_delete", "favorite", "unfavorite", "comment_create", "comment_delete"}

func writeHeapSnapshot(name string) {
	dir := os.Getenv("MEMORY_PROFILE_DIR")
	if dir == "" {
		return
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		log.Print(err)
		return
	}
	f, err := os.Create(filepath.Join(dir, name+".pprof"))
	if err != nil {
		log.Print(err)
		return
	}
	if err := pprof.WriteHeapProfile(f); err != nil {
		log.Print(err)
	}
	f.Close()
}

// Heap snapshots are optional and written only when the process exits cleanly.
func writeMemoryProfiles() {
	dir := os.Getenv("MEMORY_PROFILE_DIR")
	if dir == "" {
		return
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		log.Print(err)
		return
	}
	runtime.GC()
	for _, name := range []string{"heap", "allocs"} {
		f, err := os.Create(filepath.Join(dir, name+".pprof"))
		if err != nil {
			log.Print(err)
			continue
		}
		if err := pprof.Lookup(name).WriteTo(f, 0); err != nil {
			log.Print(err)
		}
		f.Close()
	}
}

// Profiling writes local files only; no debug listener or external service.
func startCPUProfile() (func(), error) {
	path := os.Getenv("CPU_PROFILE")
	if path == "" {
		return func() {}, nil
	}
	f, err := os.Create(path)
	if err != nil {
		return nil, err
	}
	if err = pprof.StartCPUProfile(f); err != nil {
		f.Close()
		return nil, err
	}
	return func() { pprof.StopCPUProfile(); f.Close() }, nil
}

func (d *dbDispatcher) reportStats(ctx context.Context) {
	interval, err := time.ParseDuration(envOr("STATS_INTERVAL", "0s"))
	if err != nil || interval <= 0 {
		return
	}
	var lastGC uint32
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			var mem runtime.MemStats
			runtime.ReadMemStats(&mem)
			if mem.NumGC != lastGC {
				writeHeapSnapshot("heap-gc" + strconv.FormatUint(uint64(mem.NumGC), 10))
				lastGC = mem.NumGC
			}
			queued := 0
			for _, w := range d.readers {
				queued += len(w.q)
			}
			value := map[string]any{
				"type": "stats", "jobs": d.metrics.jobs.Load(), "executions": d.metrics.executions.Load(),
				"batches": d.metrics.batches.Load(), "completed": d.metrics.completed.Load(),
				"read_queued": queued, "write_queued": len(d.write), "bcrypt_queued": len(d.bcrypt),
				"connections": d.s.sockets.Load(), "output_bytes": d.s.outputBytes.Load(),
				"heap_bytes": mem.HeapAlloc, "alloc_bytes": mem.TotalAlloc, "goroutines": runtime.NumGoroutine(),
				"database_batch_ns": d.metrics.databaseNS.Load(), "queue_ns": d.metrics.queueNS.Load(),
				"queue_samples": d.metrics.queueSamples.Load(),
			}
			stages := make(map[string]any)
			for i, kind := range []string{"read", "write"} {
				stages[kind+"_queue_ns"] = d.metrics.queue[i].snapshot()
				stages[kind+"_collect_ns"] = d.metrics.collect[i].snapshot()
				stages[kind+"_flush_ns"] = d.metrics.flush[i].snapshot()
				stages[kind+"_sync_wait_ns"] = d.metrics.syncWait[i].snapshot()
				stages[kind+"_batch_jobs"] = d.metrics.batch[i].snapshot()
			}
			stages["bcrypt_wait_ns"] = d.metrics.bcryptWait.snapshot()
			stages["bcrypt_compute_ns"] = d.metrics.bcryptCompute.snapshot()
			stages["bcrypt_batch_jobs"] = d.metrics.bcryptBatch.snapshot()
			stages["bcrypt_native_jobs"] = d.metrics.bcryptNativeJobs.Load()
			stages["bcrypt_fallback_jobs"] = d.metrics.bcryptFallbackJobs.Load()
			statements := make(map[string]any)
			for i := range d.metrics.statements {
				m := &d.metrics.statements[i]
				if m.jobs.Load() == 0 {
					continue
				}
				statements[statementNames[i]] = map[string]any{"jobs": m.jobs.Load(), "executions": m.executions.Load(), "shared_jobs": m.shared.Load(), "first_result_wait_ns": m.firstResult.snapshot(), "result_drain_ns": m.drain.snapshot()}
			}
			value["stages"], value["statements"] = stages, statements
			value["gc_cycles"], value["heap_objects"], value["heap_inuse_bytes"] = mem.NumGC, mem.HeapObjects, mem.HeapInuse
			encoded, _ := json.Marshal(value)
			log.Print(string(encoded))
		}
	}
}
