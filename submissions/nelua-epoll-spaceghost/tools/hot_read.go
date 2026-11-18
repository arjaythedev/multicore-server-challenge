// Diagnostic closed-loop HTTP load with byte-exact, per-URL response oracles.
// This fixed hot read set is not the challenge workload or a capacity score.
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"io"
	"net/http"
	"os"
	"runtime"
	"sort"
	"sync"
	"syscall"
	"time"
)

type target struct {
	URL    string `json:"url"`
	SHA256 string `json:"sha256"`
}
type totals struct {
	count, errors, mismatches int
	latencies                 []int64
}

func cpu() float64 {
	var r syscall.Rusage
	if syscall.Getrusage(syscall.RUSAGE_SELF, &r) != nil {
		panic("getrusage")
	}
	return float64(r.Utime.Sec+r.Stime.Sec) + float64(r.Utime.Usec+r.Stime.Usec)/1e6
}
func main() {
	input := flag.String("targets", "", "JSON URL/body-hash list")
	seconds := flag.Duration("duration", 5*time.Second, "measurement duration")
	clients := flag.Int("clients", 64, "concurrent keepalive clients")
	flag.Parse()
	runtime.GOMAXPROCS(2)
	if *seconds <= 0 || *clients < 1 || *clients > 1024 {
		panic("invalid load settings")
	}
	data, err := os.ReadFile(*input)
	if err != nil {
		panic(err)
	}
	var targets []target
	if json.Unmarshal(data, &targets) != nil || len(targets) == 0 {
		panic("invalid targets")
	}
	transport := &http.Transport{MaxIdleConns: *clients, MaxIdleConnsPerHost: *clients, MaxConnsPerHost: *clients, DisableCompression: true}
	client := &http.Client{Transport: transport, Timeout: 2 * time.Second}
	var wg sync.WaitGroup
	parts := make([]totals, *clients)
	start := time.Now()
	deadline := start.Add(*seconds)
	before := cpu()
	for id := range parts {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			p := &parts[id]
			for sequence := id; time.Now().Before(deadline); sequence++ {
				t := targets[sequence%len(targets)]
				begin := time.Now()
				response, err := client.Get(t.URL)
				p.count++
				if err != nil {
					p.errors++
					p.latencies = append(p.latencies, time.Since(begin).Microseconds())
					continue
				}
				body, err := io.ReadAll(io.LimitReader(response.Body, 16*1024*1024+1))
				response.Body.Close()
				hash := sha256.Sum256(body)
				if err != nil || response.StatusCode != 200 {
					p.errors++
				} else if hex.EncodeToString(hash[:]) != t.SHA256 {
					p.errors++
					p.mismatches++
				}
				p.latencies = append(p.latencies, time.Since(begin).Microseconds())
			}
		}(id)
	}
	wg.Wait()
	elapsed := time.Since(start).Seconds()
	used := cpu() - before
	transport.CloseIdleConnections()
	var all totals
	for _, p := range parts {
		all.count += p.count
		all.errors += p.errors
		all.mismatches += p.mismatches
		all.latencies = append(all.latencies, p.latencies...)
	}
	sort.Slice(all.latencies, func(i, j int) bool { return all.latencies[i] < all.latencies[j] })
	percentile := func(p float64) float64 {
		if len(all.latencies) == 0 {
			return 0
		}
		return float64(all.latencies[int(float64(len(all.latencies)-1)*p)]) / 1000
	}
	json.NewEncoder(os.Stdout).Encode(map[string]any{"requests": all.count, "errors": all.errors, "body_mismatches": all.mismatches, "elapsed_s": elapsed, "rps": float64(all.count) / elapsed, "goodput_rps": float64(all.count-all.errors) / elapsed, "p50_ms": percentile(.5), "p95_ms": percentile(.95), "p99_ms": percentile(.99), "client_cpu_s": used, "client_cores": used / elapsed, "clients": *clients, "gomaxprocs": 2, "targets": len(targets)})
}
