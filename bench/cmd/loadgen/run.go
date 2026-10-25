package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"hash/fnv"
	"math/rand/v2"
	"net/url"
	"os"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"conduitbench/seed"
)

func cmdRun(args []string) int {
	fs := flag.NewFlagSet("run", flag.ExitOnError)
	target := fs.String("target", "http://127.0.0.1:3000", "base URL of the server (http only); several comma-separated URLs (the same server on more IPs) spread the users over them")
	users := fs.Int("users", 100, "virtual users on this box")
	box := fs.Int("box-index", 0, "index of this load box (0-based); used for unique sign-ups and reporting")
	idOffset := fs.Int("id-offset", 0, "global index of this box's first user (VU global index g -> seeded user id g mod 100000 + 1)")
	ramp := fs.Duration("ramp", 60*time.Second, "users arrive evenly over this period")
	measure := fs.Duration("measure", 60*time.Second, "measured window after the ramp")
	tail := fs.Duration("tail", 15*time.Second, "users keep running this long after the window (requests started in the window finish)")
	startAt := fs.Int64("start-at", 0, "unix ms when the ramp starts (all boxes use the same value); 0 = now + 2 s")
	secret := fs.String("secret", os.Getenv("CONDUIT_JWT_SECRET"), "JWT HS256 secret (default $CONDUIT_JWT_SECRET)")
	runID := fs.String("run-id", "", "run id (part of sign-up usernames, so it must differ between runs on the same database)")
	out := fs.String("out", "results.json", "results JSON path ('-' = stdout)")
	articles := fs.Int("articles", seed.NArticles, "number of seeded articles (deep links pick ids 1..N); 10000 for the dev DB")
	thinkScale := fs.Float64("think-scale", 1.0, "TESTING ONLY: multiply think times and session lengths")
	quiet := fs.Bool("q", false, "don't print the summary table")
	fs.Parse(args)

	if *secret == "" {
		fmt.Fprintln(os.Stderr, "run: -secret (or $CONDUIT_JWT_SECRET) is required")
		return 2
	}
	cfg := runConfig{target: *target, users: *users, box: *box, idOffset: *idOffset, ramp: *ramp, measure: *measure, tail: *tail,
		secret: *secret, runID: *runID, articles: *articles, thinkScale: *thinkScale, t0: time.Now().Add(2 * time.Second)}
	if *startAt > 0 {
		cfg.t0 = time.UnixMilli(*startAt)
	}
	res, err := runBox(cfg)
	if err != nil {
		fmt.Fprintln(os.Stderr, "run:", err)
		return 2
	}
	if err := writeJSON(*out, res); err != nil {
		fmt.Fprintln(os.Stderr, "run:", err)
		return 1
	}
	if !*quiet {
		mg := mergeResults([]*BoxResult{res})
		printMerged(os.Stderr, mg)
	}
	return 0
}

type runConfig struct {
	target               string
	users, box, idOffset int
	ramp, measure, tail  time.Duration
	secret, runID        string
	articles             int
	thinkScale           float64
	t0                   time.Time
}

// runBox runs this box's virtual users and returns its results.
func runBox(c runConfig) (*BoxResult, error) {
	t, err := parseTargets(c.target)
	if err != nil {
		return nil, err
	}
	if c.runID == "" {
		c.runID = "r" + strconv.FormatInt(time.Now().Unix(), 36)
	}
	t0 := c.t0
	if late := time.Since(t0); late > 0 {
		fmt.Fprintf(os.Stderr, "run: warning: start-at is %v in the past\n", late.Round(time.Millisecond))
	}
	total := c.ramp + c.measure + c.tail
	stopAt := t0.Add(total)
	rec := newRecorder(t0, c.ramp, c.measure, total+reqTimeout+5*time.Second)
	m := newModel(t, rec, c.secret, c.thinkScale, c.articles, c.runID, c.box, stopAt)
	host, _ := os.Hostname()
	meta := RunMeta{Version: version, RunID: c.runID, Target: c.target, Host: host, BoxIndex: c.box, Users: c.users,
		IDOffset: c.idOffset, StartAtMs: t0.UnixMilli(), RampS: c.ramp.Seconds(), MeasureS: c.measure.Seconds(), TailS: c.tail.Seconds(),
		ThinkScale: c.thinkScale, Articles: c.articles, NCPU: runtime.NumCPU(), GOMAXPROCS: runtime.GOMAXPROCS(0),
		WindowStart: rec.winStart.UnixMilli(), WindowEnd: rec.winEnd.UnixMilli()}
	fmt.Fprintf(os.Stderr, "run %s: box %d, %d users -> %s, start %s, ramp %v + measure %v + tail %v\n",
		c.runID, c.box, c.users, c.target, t0.Format("15:04:05.000"), c.ramp, c.measure, c.tail)

	h := fnv.New64a()
	h.Write([]byte(c.runID + "/" + strconv.Itoa(c.box)))
	rngSeed := h.Sum64()
	ctx, cancel := context.WithDeadline(context.Background(), stopAt)
	defer cancel()
	var wg sync.WaitGroup
	ar := rand.New(rand.NewPCG(rngSeed, 1))
	for i := 0; i < c.users; i++ {
		v := newVU(m, int64(c.idOffset+i), rngSeed)
		arrive := t0.Add(time.Duration((float64(i) + ar.Float64()) / float64(c.users) * float64(c.ramp)))
		wg.Add(1)
		go func() { defer wg.Done(); v.run(ctx, arrive) }()
	}
	allDone := make(chan struct{})
	go func() { wg.Wait(); close(allDone) }()

	timeline := sample(rec, t0, stopAt, allDone)
	meta.FinishedAtMs = time.Now().UnixMilli()
	return buildBoxResult(rec, meta, timeline), nil
}

// sample runs the once-per-second sampler from t0 until every VU has stopped (or the hard deadline).
func sample(rec *Recorder, t0, stopAt time.Time, allDone <-chan struct{}) []Second {
	if d := time.Until(t0); d > 0 {
		time.Sleep(d)
	}
	cpu := newCPUSampler()
	lastProc, lastWall := procCPU(), time.Now()
	ncpu := float64(runtime.NumCPU())
	spare := newHist()
	hard := stopAt.Add(reqTimeout + 3*time.Second)
	var tl []Second
	for k := 1; ; k++ {
		tick := t0.Add(time.Duration(k) * time.Second)
		done := false
		select {
		case <-time.After(time.Until(tick)):
		case <-allDone:
			done = true
		}
		now := time.Now()
		h := rec.rotateSecond(spare)
		spare = h
		s := Second{T: k - 1, Active: rec.active.Load(), Goroutines: runtime.NumGoroutine(), RSSMB: rssMB()}
		if !done {
			s.TickLagMs = float64(now.Sub(tick).Microseconds()) / 1000
		}
		if c := h.TotalCount(); c > 0 {
			s.P50Ms = float64(h.ValueAtQuantile(50)) / 1000
			s.P95Ms = float64(h.ValueAtQuantile(95)) / 1000
			s.P99Ms = float64(h.ValueAtQuantile(99)) / 1000
			s.Hist = encodeHist(h)
		}
		if k-1 < len(rec.secs) {
			sc := &rec.secs[k-1]
			s.Started, s.Completed, s.Errors = sc.started.Load(), sc.completed.Load(), sc.errors.Load()
			if n := sc.lagN.Load(); n > 0 {
				s.LagMeanMs = float64(sc.lagSumUs.Load()) / float64(n) / 1000
				s.LagMaxMs = float64(sc.lagMaxUs.Load()) / 1000
			}
		}
		s.CPU = cpu.sample()
		pc := procCPU()
		if dw := now.Sub(lastWall); dw > 0 {
			s.ProcCPU = 100 * float64(pc-lastProc) / float64(dw) / ncpu
		}
		lastProc, lastWall = pc, now
		tl = append(tl, s)
		if done || now.After(hard) {
			break
		}
	}
	return tl
}

func buildBoxResult(rec *Recorder, meta RunMeta, tl []Second) *BoxResult {
	res := &BoxResult{Meta: meta, Endpoints: map[string]*EndpointResult{}, Pages: map[string]int64{}, Sessions: map[string]int64{}, Timeline: tl}
	rec.mu.Lock()
	for i := range rec.ep {
		e := &rec.ep[i]
		if e.hist.TotalCount() == 0 {
			continue
		}
		er := &EndpointResult{Count: e.hist.TotalCount(), Statuses: map[string]int64{}, Errors: map[string]int64{}, ErrorEx: e.errEx,
			Hist: encodeHist(e.hist)}
		for k, n := range e.statuses {
			er.Statuses[strconv.Itoa(k)] = n
		}
		for k, n := range e.errors {
			er.Errors[k] = n
		}
		res.Endpoints[labelNames[i]] = er
	}
	rec.mu.Unlock()
	for i := range rec.pages {
		res.Pages[pageNames[i]] = rec.pages[i].Load()
	}
	for i := range rec.sessions {
		res.Sessions[sessionNames[i]] = rec.sessions[i].Load()
	}
	res.Box = boxStats(&res.Meta, tl)
	res.Box.Dials = rec.dials.Load()
	return res
}

// boxStats summarizes the measure window of one box's timeline and decides whether the box fell behind.
func boxStats(meta *RunMeta, tl []Second) BoxStats {
	var b BoxStats
	lo, hi := int(meta.RampS), int(meta.RampS+meta.MeasureS)
	var cpuSum, cpuMax, procSum float64
	var cpuN, n, slow int
	maxTick := 0.0
	for _, s := range tl {
		if s.RSSMB > b.RSSPeakMB {
			b.RSSPeakMB = s.RSSMB
		}
		if s.T < lo || s.T >= hi {
			continue
		}
		if s.T == lo {
			b.ActiveAtWin = s.Active
		}
		n++
		procSum += s.ProcCPU
		if s.CPU != nil {
			cpuSum += *s.CPU
			cpuN++
			cpuMax = max(cpuMax, *s.CPU)
		}
		if s.LagMeanMs > 50 {
			slow++
		}
		maxTick = max(maxTick, s.TickLagMs)
	}
	if n > 0 {
		b.ProcCPUAvg = procSum / float64(n)
	}
	if cpuN > 0 {
		avg := cpuSum / float64(cpuN)
		b.CPUAvg, b.CPUMax = &avg, &cpuMax
	} else {
		b.Note = "box CPU N/A (no /proc/stat)"
	}
	if lim := max(2, n/20); slow > lim {
		b.BehindWhy = append(b.BehindWhy, fmt.Sprintf("%d of %d seconds had mean timer wake-up lag > 50 ms", slow, n))
	}
	if maxTick > 500 {
		b.BehindWhy = append(b.BehindWhy, fmt.Sprintf("sampler tick %.0f ms late", maxTick))
	}
	if n > 0 && float64(b.ActiveAtWin) < 0.99*float64(meta.Users) {
		b.BehindWhy = append(b.BehindWhy, fmt.Sprintf("only %d of %d users active at window start", b.ActiveAtWin, meta.Users))
	}
	if n == 0 {
		b.BehindWhy = append(b.BehindWhy, "no samples in the measure window")
	}
	b.Behind = len(b.BehindWhy) > 0
	return b
}

func writeJSON(path string, v any) error {
	b, err := json.MarshalIndent(v, "", " ")
	if err != nil {
		return err
	}
	b = append(b, '\n')
	if path == "-" {
		_, err = os.Stdout.Write(b)
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// parseTargets parses -target: one http://host[:port] URL, or several comma-separated ones for the same server
// on more IPs (each IP gives a load box another ~64k source ports).
func parseTargets(s string) (*httpTarget, error) {
	t := &httpTarget{}
	for _, part := range strings.Split(s, ",") {
		u, err := url.Parse(strings.TrimSpace(part))
		if err != nil || u.Scheme != "http" || u.Host == "" {
			return nil, fmt.Errorf("-target must be http://host[:port] (or several, comma-separated)")
		}
		addr := u.Host
		if u.Port() == "" {
			addr += ":80"
		}
		if t.host == "" {
			t.host = u.Host
		}
		t.addrs = append(t.addrs, addr)
	}
	return t, nil
}
