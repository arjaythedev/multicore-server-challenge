//go:build profile

package server

import (
	"runtime/metrics"
	"sync/atomic"
	"time"
)

// All clocks are monotonic. A request's stamp is immutable after enqueueing,
// so a worker may inspect it while the handler records admission latency.
type readTimingProfile struct{ started int64 }

var profileEpoch = time.Now()

func profileClock() int64 { return time.Since(profileEpoch).Nanoseconds() }

// 10us buckets below 10ms, 100us to 110ms, 1ms to 1110ms, then
// 10ms to 11.11s. Bucket 4000 contains longer observations.
type latencyHistogram struct {
	counts [4001]atomic.Uint64
	total  atomic.Uint64
}

func (h *latencyHistogram) add(ns int64) {
	us := max(0, ns/1000)
	var bucket int64
	switch {
	case us < 10_000:
		bucket = us / 10
	case us < 110_000:
		bucket = 1000 + (us-10_000)/100
	case us < 1_110_000:
		bucket = 2000 + (us-110_000)/1000
	case us < 11_110_000:
		bucket = 3000 + (us-1_110_000)/10_000
	default:
		bucket = 4000
	}
	h.total.Add(uint64(max(0, ns)))
	h.counts[bucket].Add(1)
}

func latencyUpperUS(bucket int) int64 {
	switch {
	case bucket < 1000:
		return int64(bucket+1) * 10
	case bucket < 2000:
		return 10_000 + int64(bucket-999)*100
	case bucket < 3000:
		return 110_000 + int64(bucket-1999)*1000
	case bucket < 4000:
		return 1_110_000 + int64(bucket-2999)*10_000
	default:
		return -1 // Open upper bound, encoded without non-JSON infinity.
	}
}

func (h *latencyHistogram) snapshot() map[string]any {
	buckets := make([][2]uint64, 0)
	var count uint64
	for i := range h.counts {
		n := h.counts[i].Load()
		if n != 0 {
			// Zero denotes the open upper bound; all finite bounds are >0.
			buckets = append(buckets, [2]uint64{uint64(max(0, latencyUpperUS(i))), n})
			count += n
		}
	}
	return map[string]any{"buckets_upper_us_count": buckets, "count": count, "total_ns": h.total.Load()}
}

var readAdmissionTime, readWorkerWait, readReadyTime latencyHistogram
var readStages [2]latencyHistogram
var responseEncodeTime, responseWriteTime latencyHistogram
var writeAdmissionTime, writeWorkerWait, writeReadyTime, writeExecutionTime latencyHistogram
var readWaiters, readWaitersPeak atomic.Int64

func profileWriteAdmission(job *writeJob) {
	writeAdmissionTime.add(time.Since(job.queued).Nanoseconds())
}

func profileWriteReady(job *writeJob) {
	writeReadyTime.add(time.Since(job.queued).Nanoseconds())
}

func profileWriteExecute(jobs []*writeJob) int64 {
	now := time.Now()
	for _, job := range jobs {
		writeWorkerWait.add(now.Sub(job.queued).Nanoseconds())
	}
	return profileClock()
}

func profileWriteDone(started int64) {
	writeExecutionTime.add(profileClock() - started)
}

func profileReadEnter(call *queuedRead) {
	call.profile.started = profileClock()
	n := readWaiters.Add(1)
	for old := readWaitersPeak.Load(); n > old; old = readWaitersPeak.Load() {
		if readWaitersPeak.CompareAndSwap(old, n) {
			break
		}
	}
}

func profileReadAdmission(call *queuedRead) {
	readAdmissionTime.add(profileClock() - call.profile.started)
}

func profileReadLeave(call *queuedRead) {
	readReadyTime.add(profileClock() - call.profile.started)
	readWaiters.Add(-1)
}

func profileReadExecute(calls []*queuedRead) int64 {
	now := profileClock()
	for _, call := range calls {
		if call.profile.started != 0 {
			readWorkerWait.add(now - call.profile.started)
		}
	}
	return now
}

func profileReadStage(stage int, start int64) { readStages[stage].add(profileClock() - start) }
func profileResponseEncode(start int64)       { responseEncodeTime.add(profileClock() - start) }
func profileResponseWrite(start int64)        { responseWriteTime.add(profileClock() - start) }

func scaleDiagnostics() map[string]any {
	latencies := make(map[string]any)
	for name, h := range map[string]*latencyHistogram{
		"admission": &readAdmissionTime, "worker_wait": &readWorkerWait,
		"ready": &readReadyTime, "selection_batch": &readStages[0], "enrichment_batch": &readStages[1],
		"encode": &responseEncodeTime, "write": &responseWriteTime,
	} {
		latencies[name] = h.snapshot()
	}
	names := []string{"/cpu/classes/gc/total:cpu-seconds", "/cpu/classes/gc/mark/assist:cpu-seconds",
		"/cpu/classes/user:cpu-seconds", "/cpu/classes/idle:cpu-seconds", "/cpu/classes/total:cpu-seconds",
		"/cpu/classes/scavenge/assist:cpu-seconds", "/gc/scan/heap:bytes", "/gc/scan/stack:bytes",
		"/gc/heap/goal:bytes", "/memory/classes/heap/stacks:bytes", "/sched/goroutines:goroutines"}
	samples := make([]metrics.Sample, len(names))
	for i, name := range names {
		samples[i].Name = name
	}
	metrics.Read(samples)
	runtimeMetrics := make(map[string]any)
	for _, sample := range samples {
		switch sample.Value.Kind() {
		case metrics.KindUint64:
			runtimeMetrics[sample.Name] = sample.Value.Uint64()
		case metrics.KindFloat64:
			runtimeMetrics[sample.Name] = sample.Value.Float64()
		}
	}
	return map[string]any{"latency": latencies, "runtime": runtimeMetrics,
		"read_waiters": readWaiters.Load(), "read_waiters_peak": readWaitersPeak.Load()}
}
