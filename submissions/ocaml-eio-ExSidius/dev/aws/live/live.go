package main

// TESTING ONLY, for dev/aws/fast.sh: streams the per-second stats to a file while a run is going, and reads back any
// time range with exact percentiles. Not part of the scoring load generator.

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"time"
)

type liveLine struct {
	WallMs int64 `json:"wall_ms"`
	Second
}

var liveEnc = func() *json.Encoder {
	p := os.Getenv("CONDUIT_LIVE_FILE")
	if p == "" {
		return nil
	}
	f, err := os.OpenFile(p, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		panic(err)
	}
	return json.NewEncoder(f)
}()

func liveEmit(s *Second) {
	if liveEnc != nil {
		_ = liveEnc.Encode(liveLine{time.Now().UnixMilli(), *s})
		s.Hist = "" // an hours-long run shouldn't keep them all in memory
	}
}

// live-read <file> <from-ms> <to-ms>
func cmdLiveRead(args []string) int {
	from, _ := strconv.ParseInt(args[1], 10, 64)
	to, _ := strconv.ParseInt(args[2], 10, 64)
	f, err := os.Open(args[0])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<26)
	h := newHist()
	var secs, done, errs, active int64
	var cpu float64
	for sc.Scan() {
		var l liveLine
		if json.Unmarshal(sc.Bytes(), &l) != nil || l.WallMs <= from || l.WallMs > to {
			continue
		}
		secs++
		done += l.Completed
		errs += l.Errors
		active = l.Active
		if l.CPU != nil {
			cpu += *l.CPU
		}
		if l.Hist != "" {
			d, err := decodeHist(l.Hist)
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				return 1
			}
			h.Merge(d)
		}
	}
	if secs == 0 {
		fmt.Println("no data in range")
		return 1
	}
	fmt.Printf("users=%d secs=%d rps=%d p50=%.0f p95=%.0f p99=%.0f max=%.0f errors=%d lgcpu=%.0f\n", active, secs, done/secs,
		float64(h.ValueAtQuantile(50))/1000, float64(h.ValueAtQuantile(95))/1000, float64(h.ValueAtQuantile(99))/1000,
		float64(h.Max())/1000, errs, cpu/float64(secs))
	return 0
}
