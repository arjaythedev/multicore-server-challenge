//go:build profile

package server

import (
	"encoding/json"
	"log"
	"net"
	"net/http"
	"net/http/pprof"
	"os"
	"runtime"
	"sync/atomic"
)

var readBatchHistogram [maxReadBatchSize + 1]atomic.Uint64
var readBatchStatements atomic.Uint64
var articleReferences atomic.Uint64
var articleRows atomic.Uint64
var articleFlagPairs, articleFlagRows atomic.Uint64
var commentRequests, commentThreads, commentRows, commentReferences atomic.Uint64
var passwordBatchHistogram [maxPasswordBatchSize + 1]atomic.Uint64
var jsonBodyCounts [3]atomic.Uint64 // <=2 KiB, <=4 KiB, larger.
var jsonBodyBytes atomic.Uint64
var favoriteBatchCounts [33]atomic.Uint64
var favoriteRetries atomic.Uint64
var writeBatchCounts [maxWriteBatchSize + 1]atomic.Uint64
var writeRetries atomic.Uint64
var prefixResponseCount, vectorResponseCount atomic.Uint64
var compactAPIReadCount atomic.Uint64

func recordCompactAPIRead() { compactAPIReadCount.Add(1) }

func recordHTTPResponseBuffer(prefix bool) {
	if prefix {
		prefixResponseCount.Add(1)
	} else {
		vectorResponseCount.Add(1)
	}
}

func recordWriteBatch(size, retries int) {
	writeBatchCounts[size].Add(1)
	writeRetries.Add(uint64(retries))
}

func recordFavoriteBatch(size, retries int) {
	favoriteBatchCounts[size].Add(1)
	favoriteRetries.Add(uint64(retries))
}

func recordJSONBody(size int) {
	index := 2
	if size <= 2048 {
		index = 0
	} else if size <= 4096 {
		index = 1
	}
	jsonBodyCounts[index].Add(1)
	jsonBodyBytes.Add(uint64(size))
}

func recordPasswordBatch(n int) {
	passwordBatchHistogram[n].Add(1)
}

func recordArticleBatch(references, rows int) {
	articleReferences.Add(uint64(references))
	articleRows.Add(uint64(rows))
}

func recordArticleFlags(pairs, rows int) {
	articleFlagPairs.Add(uint64(pairs))
	articleFlagRows.Add(uint64(rows))
}

func recordCommentBatch(requests, threads, rows, references int) {
	commentRequests.Add(uint64(requests))
	commentThreads.Add(uint64(threads))
	commentRows.Add(uint64(rows))
	commentReferences.Add(uint64(references))
}

func recordReadBatch(requests, statements int) {
	readBatchHistogram[requests].Add(1)
	readBatchStatements.Add(uint64(statements))
}

// Profiling is compiled only with -tags profile and listens on loopback.
func startProfiling(a *app) func() {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /debug/pprof/", pprof.Index)
	mux.HandleFunc("GET /debug/pprof/profile", pprof.Profile)
	mux.HandleFunc("GET /debug/pprof/cmdline", pprof.Cmdline)
	mux.HandleFunc("GET /debug/pprof/symbol", pprof.Symbol)
	mux.HandleFunc("GET /debug/pprof/trace", pprof.Trace)
	mux.HandleFunc("GET /debug/stats", func(w http.ResponseWriter, _ *http.Request) {
		s := a.pool.Stat()
		var mem runtime.MemStats
		runtime.ReadMemStats(&mem)
		hist := make([]uint64, len(readBatchHistogram))
		for i := range hist {
			hist[i] = readBatchHistogram[i].Load()
		}
		pending := 0
		readWorkers, readBatchSize := 0, 0
		if a.reads != nil {
			pending = len(a.reads.pending)
			readWorkers, readBatchSize = a.reads.workerCount, a.reads.batchSize
		}
		cryptoHist := make([]uint64, len(passwordBatchHistogram))
		for i := range cryptoHist {
			cryptoHist[i] = passwordBatchHistogram[i].Load()
		}
		cryptoPending, cryptoActive := 0, int64(0)
		if a.passwords != nil {
			cryptoPending, cryptoActive = len(a.passwords.pending), a.passwords.active.Load()
		}
		w.Header().Set("Content-Type", "application/json")
		bodyCounts := make([]uint64, len(jsonBodyCounts))
		for i := range bodyCounts {
			bodyCounts[i] = jsonBodyCounts[i].Load()
		}
		writeCounts := make([]uint64, len(writeBatchCounts))
		for i := range writeCounts {
			writeCounts[i] = writeBatchCounts[i].Load()
		}
		writePending := 0
		if a.writes != nil {
			writePending = len(a.writes.pending)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"http_hot_path":         compactHTTPHotPath,
			"http_response_prefix":  compactPrefixResponses,
			"http_prefix_responses": prefixResponseCount.Load(),
			"http_vector_responses": vectorResponseCount.Load(),
			"http_workers":          compactHTTPWorkers,
			"http_context_parent":   compactContextParent,
			"write_batch_jobs":      writeCounts, "write_retries": writeRetries.Load(), "write_queued": writePending,
			"write_admission": writeAdmissionTime.snapshot(), "write_worker_wait": writeWorkerWait.snapshot(),
			"write_ready": writeReadyTime.snapshot(), "write_execution": writeExecutionTime.snapshot(),
			"scale":               scaleDiagnostics(),
			"favorite_batch_jobs": favoriteJobs(), "favorite_retries": favoriteRetries.Load(),
			"json_body_counts": bodyCounts, "json_body_bytes": jsonBodyBytes.Load(),
			"batch_histogram": hist, "batch_statements": readBatchStatements.Load(), "queued": pending,
			"read_workers": readWorkers, "read_batch_size": readBatchSize,
			"article_references": articleReferences.Load(), "article_rows": articleRows.Load(),
			"http_api_read_requests": compactAPIReadCount.Load(),
			"article_flag_pairs":     articleFlagPairs.Load(), "article_flag_rows": articleFlagRows.Load(),
			"comment_requests": commentRequests.Load(), "comment_threads": commentThreads.Load(),
			"comment_rows": commentRows.Load(), "comment_references": commentReferences.Load(),
			"password_batch_histogram": cryptoHist, "password_queued": cryptoPending, "password_active": cryptoActive,
			"pool_acquires": s.AcquireCount(), "pool_waits": s.EmptyAcquireCount(),
			"pool_wait_ns": s.EmptyAcquireWaitTime().Nanoseconds(), "pool_connections": s.TotalConns(),
			"allocated_bytes": mem.TotalAlloc, "allocated_objects": mem.Mallocs,
			"heap_bytes": mem.HeapAlloc, "gc_cycles": mem.NumGC, "gc_pause_ns": mem.PauseTotalNs,
			"heap_objects": mem.HeapObjects, "heap_inuse_bytes": mem.HeapInuse,
			"stack_inuse_bytes": mem.StackInuse, "runtime_sys_bytes": mem.Sys,
			"goroutines": runtime.NumGoroutine(),
		})
	})
	if os.Getenv("PROFILE_BLOCK") == "1" {
		runtime.SetBlockProfileRate(1_000_000)
		runtime.SetMutexProfileFraction(10)
	}
	ln, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", envOr("PROFILE_PORT", "6067")))
	if err != nil {
		log.Fatal(err)
	}
	srv := &http.Server{Handler: mux}
	go func() {
		if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
			log.Printf("profiling: %v", err)
		}
	}()
	return func() { _ = srv.Close() }
}

func favoriteJobs() []uint64 {
	counts := make([]uint64, len(favoriteBatchCounts))
	for i := range counts {
		counts[i] = favoriteBatchCounts[i].Load()
	}
	return counts
}
