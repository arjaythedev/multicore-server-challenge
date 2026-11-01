package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/csv"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"conduitbench/seed"
)

// search: the per language x box protocol from DESIGN.md, run on the m-4 load box and driving the others over SSH.
//
//	switch.sh <lang> on the target (fresh DB, caches dropped, app started and healthy)
//	warm-up (3 min at -start users), then 2-minute probes doubling from -start until one fails, bisect to
//	-resolution, then 5-minute holds from the highest passing probe, stepping down 5% until one passes = score.

type boxSpec struct {
	host   string // ssh destination, or "local"
	weight int
}

type searcher struct {
	targetSSH, targetURL, lang, label, outdir string
	start, max                                int
	resolution                                float64
	boxes                                     []boxSpec
	sshKey, secret, remoteBin, remoteDir      string
	switchCmd, monitorCmd, monitorDir         string
	restartCmd                                string
	pushBin, noSwitch, dry                    bool
	warmupRamp, warmupMeasure                 time.Duration
	probeRamp, probeMeasure                   time.Duration
	holdRamp, holdMeasure, tail, startDelay   time.Duration
	idleMax                                   time.Duration
	articles                                  int
	idleCPU                                   float64
	thinkScale                                float64
	tzOffset                                  time.Duration
	log                                       io.Writer
	logf                                      *os.File
	firstPhase                                bool
	extras                                    []extraHost
}

// extraHost is another box of a multi-box target (-extra-ssh): it gets the same monitor as the target
// (CSV saved as monitor-<name>.csv) and must be idle before each phase too.
type extraHost struct{ name, host string }

type phaseResult struct {
	Name   string  `json:"phase"`
	Users  int     `json:"users"`
	Pass   bool    `json:"pass"`
	LG     bool    `json:"lg_limited"`
	RPS    float64 `json:"rps"`
	P50    float64 `json:"p50_ms"`
	P95    float64 `json:"p95_ms"`
	P99    float64 `json:"p99_ms"`
	ErrPct float64 `json:"error_pct"`
	// the app failed the health check before this phase and was restarted for it (a phase that wedged it, often
	// the overload probe at -max, would otherwise fail every later phase too)
	Restarted bool `json:"restarted_before,omitempty"`
	m         *Merged
	dir       string
}

func cmdSearch(args []string) int {
	s := &searcher{}
	fs := flag.NewFlagSet("search", flag.ExitOnError)
	fs.StringVar(&s.targetSSH, "target-ssh", "", "ssh destination of the target, e.g. root@10.0.0.2")
	fs.StringVar(&s.targetURL, "target-url", "", "base URL the load boxes hit, e.g. http://10.0.0.2, or several comma-separated (default: http://<target-ssh host>)")
	fs.StringVar(&s.lang, "lang", "", "language to switch the target to (go, rust, java, python)")
	fs.StringVar(&s.label, "label", "", "run label (default <lang>-<target host>)")
	fs.StringVar(&s.outdir, "outdir", "", "results directory (default results/<label>)")
	fs.IntVar(&s.start, "start", 500, "first probe (and warm-up) users")
	fs.IntVar(&s.max, "max", 120000, "never probe above this many users")
	fs.Float64Var(&s.resolution, "resolution", 0.05, "bisect until (fail - pass) <= resolution x pass; holds step down by this fraction")
	boxes := fs.String("boxes", "local=1", "load boxes as host=weight; 'local' = this machine")
	fs.StringVar(&s.sshKey, "ssh-key", "", "ssh identity for the target and the load boxes ('' = ssh default)")
	fs.StringVar(&s.secret, "secret", os.Getenv("CONDUIT_JWT_SECRET"), "the target's JWT_SECRET (default $CONDUIT_JWT_SECRET)")
	fs.StringVar(&s.remoteBin, "remote-bin", "/usr/local/bin/conduit-loadgen", "loadgen path on the remote load boxes")
	fs.StringVar(&s.remoteDir, "remote-dir", "/root/conduit-lg", "scratch directory on the remote load boxes")
	fs.BoolVar(&s.pushBin, "push-bin", true, "copy this binary to -remote-bin on the remote boxes when it differs")
	fs.StringVar(&s.switchCmd, "switch", "/opt/conduit-tools/switch.sh", "target command run as '<switch> <lang>'")
	fs.BoolVar(&s.noSwitch, "no-switch", false, "don't run the switch command (target already prepared)")
	fs.StringVar(&s.restartCmd, "restart", "systemctl restart challenge.service", "target command that restarts the app when it fails the health check before a phase ('' = never restart)")
	fs.StringVar(&s.monitorCmd, "monitor", "/opt/conduit-tools/monitor.sh", "target monitor run as '<monitor> 1 <tag>' during each phase ('' = none)")
	fs.StringVar(&s.monitorDir, "monitor-dir", "/root/conduit-monitor", "working directory of the monitor on the target (its CSV is looked for there)")
	fs.DurationVar(&s.warmupRamp, "warmup-ramp", 60*time.Second, "warm-up ramp")
	fs.DurationVar(&s.warmupMeasure, "warmup", 120*time.Second, "warm-up time after its ramp (0 = no warm-up)")
	fs.DurationVar(&s.probeRamp, "probe-ramp", 60*time.Second, "probe ramp")
	fs.DurationVar(&s.probeMeasure, "probe-measure", 60*time.Second, "probe measured window")
	fs.DurationVar(&s.holdRamp, "hold-ramp", 60*time.Second, "hold ramp")
	fs.DurationVar(&s.holdMeasure, "hold-measure", 300*time.Second, "hold measured window")
	fs.DurationVar(&s.tail, "tail", 15*time.Second, "users keep running after each window")
	fs.DurationVar(&s.startDelay, "start-delay", 5*time.Second, "start-at = now + this, pushed to every box")
	fs.IntVar(&s.articles, "articles", seed.NArticles, "seeded articles on the target")
	fs.Float64Var(&s.idleCPU, "idle-cpu", 15, "between phases, wait until the target's CPU is below this %")
	fs.DurationVar(&s.idleMax, "idle-max", 90*time.Second, "longest wait for the target to go idle between phases (after a fixed 5 s)")
	fs.BoolVar(&s.dry, "dry", false, "print the plan only")
	fs.Float64Var(&s.thinkScale, "think-scale", 1.0, "TESTING ONLY: passed to every box")
	extra := fs.String("extra-ssh", "", "more boxes of the target as name=user@host,... (monitored and idle-checked like the target)")
	fs.Parse(args)
	for _, kv := range strings.Split(*extra, ",") {
		if kv = strings.TrimSpace(kv); kv == "" {
			continue
		}
		name, host, ok := strings.Cut(kv, "=")
		if !ok || name == "" || host == "" {
			fmt.Fprintln(os.Stderr, "search: -extra-ssh wants name=user@host,...")
			return 2
		}
		s.extras = append(s.extras, extraHost{name, host})
	}

	var err error
	if s.boxes, err = parseBoxes(*boxes); err != nil {
		fmt.Fprintln(os.Stderr, "search:", err)
		return 2
	}
	if s.lang == "" || (s.targetSSH == "" && !s.dry) {
		fmt.Fprintln(os.Stderr, "search: -lang and -target-ssh are required")
		return 2
	}
	thost := s.targetSSH[strings.LastIndex(s.targetSSH, "@")+1:]
	if s.targetURL == "" {
		s.targetURL = "http://" + thost
	}
	if s.label == "" {
		s.label = s.lang + "-" + thost
	}
	s.label = labelRe.ReplaceAllString(s.label, "-")
	if s.outdir == "" {
		s.outdir = filepath.Join("results", s.label)
	}
	if s.secret == "" && !s.dry {
		fmt.Fprintln(os.Stderr, "search: -secret (or $CONDUIT_JWT_SECRET) is required")
		return 2
	}
	if s.dry {
		s.plan()
		return 0
	}
	if err := os.MkdirAll(s.outdir, 0o755); err != nil {
		fmt.Fprintln(os.Stderr, "search:", err)
		return 1
	}
	s.logf, err = os.OpenFile(filepath.Join(s.outdir, "search.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		fmt.Fprintln(os.Stderr, "search:", err)
		return 1
	}
	defer s.logf.Close()
	s.log = io.MultiWriter(os.Stdout, s.logf)
	if err := s.runSearch(); err != nil {
		s.logln("ERROR: %v", err)
		return 1
	}
	return 0
}

func parseBoxes(spec string) ([]boxSpec, error) {
	var out []boxSpec
	for _, p := range strings.Split(spec, ",") {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		h, w, ok := strings.Cut(p, "=")
		n, err := strconv.Atoi(w)
		if !ok || err != nil || n <= 0 {
			return nil, fmt.Errorf("bad box %q (want host=weight)", p)
		}
		out = append(out, boxSpec{h, n})
	}
	if len(out) == 0 {
		return nil, errors.New("no load boxes")
	}
	return out, nil
}

// split divides users across boxes by weight (largest remainder, so the shares sum to users).
func split(users int, boxes []boxSpec) []int {
	tw := 0
	for _, b := range boxes {
		tw += b.weight
	}
	out := make([]int, len(boxes))
	type rem struct {
		i int
		r float64
	}
	var rs []rem
	sum := 0
	for i, b := range boxes {
		x := float64(users) * float64(b.weight) / float64(tw)
		out[i] = int(x)
		sum += out[i]
		rs = append(rs, rem{i, x - float64(out[i])})
	}
	sort.SliceStable(rs, func(a, b int) bool { return rs[a].r > rs[b].r })
	for k := 0; sum < users; k++ {
		out[rs[k%len(rs)].i]++
		sum++
	}
	return out
}

// nice rounds to a tidy number of users (2 significant digits, at least 10s).
func nice(x float64) int {
	if x < 10 {
		return int(math.Max(1, math.Round(x)))
	}
	step := math.Pow(10, math.Floor(math.Log10(x))-1)
	step = math.Max(step, 10)
	return int(math.Round(x/step) * step)
}

func (s *searcher) logln(format string, a ...any) {
	fmt.Fprintf(s.log, "[%s] %s\n", time.Now().UTC().Format("15:04:05"), fmt.Sprintf(format, a...))
}

func (s *searcher) plan() {
	fmt.Printf("plan for %s (lang %s) -> %s, results in %s\n", s.label, s.lang, s.targetURL, s.outdir)
	fmt.Printf("load boxes: ")
	for _, b := range s.boxes {
		fmt.Printf("%s (weight %d)  ", b.host, b.weight)
	}
	fmt.Println()
	if !s.noSwitch {
		fmt.Printf("1. on %s: %s %s  (fresh DB, caches dropped, app started)\n", s.targetSSH, s.switchCmd, s.lang)
	}
	if s.monitorCmd != "" {
		fmt.Printf("   each phase: %s 1 %s-<phase> on the target (cwd %s), CSV fetched afterwards\n", s.monitorCmd, s.label, s.monitorDir)
	}
	if s.pushBin {
		fmt.Printf("   push this binary to %s on the remote boxes if it differs\n", s.remoteBin)
	}
	if s.warmupMeasure > 0 {
		fmt.Printf("2. warm-up: %d users, %v ramp + %v (+%v tail), split %v\n", s.start, s.warmupRamp, s.warmupMeasure, s.tail, split(s.start, s.boxes))
	}
	fmt.Printf("3. probes: %v ramp + %v measured (+%v tail) each, start-at = now + %v on every box\n", s.probeRamp, s.probeMeasure, s.tail, s.startDelay)
	fmt.Printf("   doubling: ")
	for u := s.start; ; u *= 2 {
		if u > s.max {
			u = s.max
		}
		fmt.Printf("%d %v  ", u, split(u, s.boxes))
		if u >= s.max {
			break
		}
	}
	fmt.Printf("\n   ... until one fails, then bisect to %.0f%% (rounded to 2 significant digits)\n", 100*s.resolution)
	fmt.Printf("   pass = p95 < %d ms, p99 < %d ms, errors < %.0f%%; any box CPU > %d%% or falling behind = LG-limited (stop)\n",
		passP95Ms, passP99Ms, 100*passErrRate, lgCPULimitPct)
	fmt.Printf("4. holds: %v ramp + %v measured at the highest passing probe, stepping down %.0f%% until one passes = score\n",
		s.holdRamp, s.holdMeasure, 100*s.resolution)
	fmt.Printf("between phases: wait >= 5 s and until target CPU < %.0f%% (max %v); no DB reset between phases\n", s.idleCPU, s.idleMax)
	ex := s.boxArgs(0, 1000, 0, time.Now().Add(s.startDelay), s.probeRamp, s.probeMeasure, s.label+"-probe-1000-XXXX", "OUT")
	fmt.Printf("example box command: %s run %s\n", s.remoteBin, strings.Join(ex, " "))
}

// ---------- ssh ----------

func (s *searcher) sshArgs(host string) []string {
	a := []string{"-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4"}
	if s.sshKey != "" {
		a = append(a, "-i", s.sshKey)
	}
	return append(a, host)
}

// ssh runs a remote command, retrying once (after 3 s) if ssh itself fails (exit 255).
func (s *searcher) ssh(host, cmd string, stdout io.Writer) error {
	var err error
	for attempt := 0; attempt < 2; attempt++ {
		var buf bytes.Buffer
		c := exec.Command("ssh", append(s.sshArgs(host), cmd)...)
		if host == "local" || host == "bash" { // testing: "local" target, or "bash" = a load box driven through the remote path on this machine
			c = exec.Command("bash", "-c", cmd)
		}
		c.Stdout = &buf
		var eb bytes.Buffer
		c.Stderr = &eb
		err = c.Run()
		if err == nil {
			if stdout != nil {
				stdout.Write(buf.Bytes())
			}
			return nil
		}
		var ee *exec.ExitError
		if errors.As(err, &ee) && ee.ExitCode() != 255 {
			if stdout != nil {
				stdout.Write(buf.Bytes())
			}
			return fmt.Errorf("ssh %s: %w: %s", host, err, strings.TrimSpace(eb.String()))
		}
		err = fmt.Errorf("ssh %s: %w: %s", host, err, strings.TrimSpace(eb.String()))
		if attempt == 0 {
			s.logln("  ssh hiccup (%v), retrying once", err)
			time.Sleep(3 * time.Second)
		}
	}
	return err
}

func (s *searcher) sshOut(host, cmd string) (string, error) {
	var b bytes.Buffer
	err := s.ssh(host, cmd, &b)
	return b.String(), err
}

func shq(x string) string { return "'" + strings.ReplaceAll(x, "'", `'\''`) + "'" }

// ---------- the search ----------

func (s *searcher) runSearch() error {
	started := time.Now()
	s.logln("=== search %s: lang %s, target %s (%s), boxes %v", s.label, s.lang, s.targetURL, s.targetSSH, s.boxes)
	if err := s.preflight(); err != nil {
		return err
	}
	marker := filepath.Join(s.outdir, "switch.ok")
	if !s.noSwitch {
		if _, err := os.Stat(marker); err == nil {
			s.logln("switch already done (%s exists): resuming without a DB reset", marker)
		} else {
			s.logln("switch: %s %s", s.switchCmd, s.lang)
			out, err := s.sshOut(s.targetSSH, s.switchCmd+" "+shq(s.lang)+" 2>&1")
			os.WriteFile(filepath.Join(s.outdir, "switch.log"), []byte(out), 0o644)
			if err != nil {
				return fmt.Errorf("switch failed (see switch.log): %v", err)
			}
			os.WriteFile(marker, []byte(time.Now().UTC().Format(time.RFC3339)+"\n"), 0o644)
			s.logln("switch ok")
		}
	}
	s.firstPhase = true
	if s.warmupMeasure > 0 {
		if _, err := s.phase("warmup", s.start, s.warmupRamp, s.warmupMeasure); err != nil {
			return err
		}
	}

	var probes, holds []*phaseResult
	lgAt := 0
	probe := func(u int) (*phaseResult, error) {
		r, err := s.phase(fmt.Sprintf("probe-%d", u), u, s.probeRamp, s.probeMeasure)
		if err == nil {
			probes = append(probes, r)
			if r.LG {
				lgAt = u
			}
		}
		return r, err
	}
	lo, hi := 0, 0 // highest pass, lowest fail (0 = none)
	u := min(s.start, s.max)
	for lgAt == 0 {
		r, err := probe(u)
		if err != nil {
			return err
		}
		if r.LG {
			break
		}
		if r.Pass {
			lo = u
			if u >= s.max || hi != 0 {
				break
			}
			u = min(u*2, s.max)
		} else {
			hi = u
			if lo > 0 {
				break
			}
			if u <= 10 { // nothing passes
				break
			}
			u = nice(float64(u) / 2) // the start already fails: halve until something passes
		}
	}
	for lgAt == 0 && lo > 0 && hi > 0 && float64(hi-lo) > s.resolution*float64(lo) {
		m := nice(float64(lo+hi) / 2)
		if m <= lo || m >= hi {
			break
		}
		r, err := probe(m)
		if err != nil {
			return err
		}
		if r.LG {
			break
		}
		if r.Pass {
			lo = m
		} else {
			hi = m
		}
	}
	if lgAt == 0 && lo > 0 {
		s.logln("probes: highest pass %d, lowest fail %s", lo, orNone(hi))
	}

	score := 0
	var scored *phaseResult
	for u := lo; lgAt == 0 && u > 0; {
		r, err := s.phase(fmt.Sprintf("hold-%d", u), u, s.holdRamp, s.holdMeasure)
		if err != nil {
			return err
		}
		holds = append(holds, r)
		if r.LG {
			lgAt = u
			break
		}
		if r.Pass {
			score, scored = u, r
			break
		}
		next := nice(float64(u) * (1 - s.resolution))
		if next >= u {
			next = u - 1
		}
		u = next
	}
	switch {
	case lgAt > 0:
		s.logln("RESULT: LG-limited at %d users (not a server failure); highest clean pass %s", lgAt, orNone(lo))
	case score > 0:
		s.logln("RESULT: score %d users (5-minute hold passed)", score)
	default:
		s.logln("RESULT: no passing hold")
	}
	return s.writeSummary(started, score, scored, lgAt, lo, hi, probes, holds)
}

func orNone(x int) string {
	if x == 0 {
		return "none"
	}
	return strconv.Itoa(x)
}

func (s *searcher) preflight() error {
	if out, err := s.sshOut(s.targetSSH, "date +%z; getconf _NPROCESSORS_ONLN"); err != nil {
		return fmt.Errorf("target unreachable: %v", err)
	} else {
		f := strings.Fields(out)
		if len(f) > 0 {
			if t, err := time.Parse("-0700", f[0]); err == nil {
				_, off := t.Zone()
				s.tzOffset = time.Duration(off) * time.Second
			}
		}
		s.logln("target: tz %s, %s cores", firstField(f, 0), firstField(f, 1))
	}
	self, err := os.Executable()
	if err != nil {
		return err
	}
	sum := ""
	if s.pushBin {
		b, err := os.ReadFile(self)
		if err != nil {
			return err
		}
		h := sha256.Sum256(b)
		sum = hex.EncodeToString(h[:])
	}
	for _, b := range s.boxes {
		if b.host == "local" {
			continue
		}
		out, err := s.sshOut(b.host, "sha256sum "+shq(s.remoteBin)+" 2>/dev/null; getconf _NPROCESSORS_ONLN; ulimit -Hn")
		if err != nil {
			return fmt.Errorf("load box %s unreachable: %v", b.host, err)
		}
		if s.pushBin && !strings.HasPrefix(out, sum) {
			s.logln("pushing loadgen to %s:%s", b.host, s.remoteBin)
			tmp := s.remoteBin + ".new"
			c := exec.Command("scp", append(s.sshArgs(b.host)[:len(s.sshArgs(b.host))-1], "-q", self, b.host+":"+tmp)...)
			if o, err := c.CombinedOutput(); err != nil {
				return fmt.Errorf("scp to %s: %v: %s", b.host, err, o)
			}
			if err := s.ssh(b.host, "chmod 755 "+shq(tmp)+" && mv "+shq(tmp)+" "+shq(s.remoteBin), nil); err != nil {
				return err
			}
		}
		s.logln("box %s ok (%s)", b.host, strings.Join(strings.Fields(out)[max(0, len(strings.Fields(out))-2):], " cores, nofile "))
	}
	return nil
}

func firstField(f []string, i int) string {
	if i < len(f) {
		return f[i]
	}
	return "?"
}

func (s *searcher) boxArgs(i, users, idOffset int, t0 time.Time, ramp, measure time.Duration, runID, out string) []string {
	return []string{"-target", s.targetURL, "-users", strconv.Itoa(users), "-box-index", strconv.Itoa(i), "-id-offset", strconv.Itoa(idOffset),
		"-ramp", ramp.String(), "-measure", measure.String(), "-tail", s.tail.String(), "-start-at", strconv.FormatInt(t0.UnixMilli(), 10),
		"-run-id", runID, "-articles", strconv.Itoa(s.articles), "-think-scale", strconv.FormatFloat(s.thinkScale, 'g', -1, 64), "-out", out, "-q"}
}

// waitIdle waits at least 5 s, then until the target's CPU is below -idle-cpu (max 90 s).
func (s *searcher) waitIdle() {
	time.Sleep(5 * time.Second)
	deadline := time.Now().Add(s.idleMax)
	last := -1.0
	for ; time.Now().Before(deadline); time.Sleep(2 * time.Second) {
		worst := -1.0
		for _, h := range s.allHosts() {
			out, err := s.sshOut(h, "head -1 /proc/stat; sleep 2; head -1 /proc/stat")
			if err != nil {
				s.logln("  idle check failed on %s: %v", h, err)
				return
			}
			lines := strings.Split(strings.TrimSpace(out), "\n")
			if len(lines) == 2 {
				b0, t0 := statLine(lines[0])
				b1, t1 := statLine(lines[1])
				if t1 > t0 {
					worst = max(worst, 100*float64(b1-b0)/float64(t1-t0))
				}
			}
		}
		if worst >= 0 && worst < s.idleCPU {
			return
		}
		last = worst
	}
	if s.idleMax > 0 {
		s.logln("  target not idle after %v (last CPU %.0f%%); continuing", s.idleMax, last)
	}
}

func statLine(l string) (busy, total uint64) {
	f := strings.Fields(l)
	var v [8]uint64
	for i := 1; i < len(f) && i <= 8; i++ {
		v[i-1], _ = strconv.ParseUint(f[i], 10, 64)
	}
	total = v[0] + v[1] + v[2] + v[3] + v[4] + v[5] + v[6] + v[7]
	return total - v[3] - v[4], total
}

// phase runs one warm-up/probe/hold on every box at once and merges the results. Completed phases (merged.json
// exists) are loaded instead of re-run.
func (s *searcher) phase(name string, users int, ramp, measure time.Duration) (*phaseResult, error) {
	dir := filepath.Join(s.outdir, name)
	mpath := filepath.Join(dir, "merged.json")
	if b, err := os.ReadFile(mpath); err == nil {
		var m Merged
		if json.Unmarshal(b, &m) == nil {
			r := s.result(name, users, &m, dir)
			s.logln("%-12s %s (cached)", name, oneLine(&m))
			s.firstPhase = false
			return r, nil
		}
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	if !s.firstPhase {
		s.waitIdle()
	}
	s.firstPhase = false
	health := "curl -s -m 5 -o /dev/null -w '%{http_code}' " + shq(strings.Split(s.targetURL, ",")[0]+"/api/tags")
	restarted := false
	if out, err := s.sshOut(s.targetSSH, health); err != nil || strings.TrimSpace(out) != "200" {
		s.logln("  WARNING: target health check: %q %v", out, err)
		// An app that a previous phase wedged (typically the overload probe at -max) would fail every later phase
		// at 100% errors, so restart it for this one. Healthy apps are never restarted: they keep their warm state.
		if s.restartCmd != "" {
			s.logln("  restarting the app before %s: %s", name, s.restartCmd)
			if rout, rerr := s.sshOut(s.targetSSH, s.restartCmd+" 2>&1"); rerr != nil {
				s.logln("  restart failed: %v %s", rerr, strings.TrimSpace(rout))
			}
			ok := false
			for t0 := time.Now(); time.Since(t0) < 120*time.Second; time.Sleep(2 * time.Second) {
				if out, err := s.sshOut(s.targetSSH, health); err == nil && strings.TrimSpace(out) == "200" {
					ok = true
					break
				}
			}
			restarted = ok
			if ok {
				s.logln("  app healthy again after the restart")
			} else {
				s.logln("  WARNING: app still unhealthy 120 s after the restart")
			}
		}
	}
	runID := fmt.Sprintf("%s-%s-%s", s.label, name, strconv.FormatInt(time.Now().Unix(), 36))
	tag := s.label + "-" + name
	monitoring := s.monitorCmd != "" && s.startMonitor(tag)

	shares := split(users, s.boxes)
	t0 := time.Now().Add(s.startDelay)
	total := ramp + measure + s.tail
	s.logln("%-12s %d users %v, ramp %v + %v, start %s", name, users, shares, ramp, measure, t0.UTC().Format("15:04:05"))
	var wg sync.WaitGroup
	errs := make([]error, len(s.boxes))
	files := make([]string, len(s.boxes))
	off := 0
	for i, b := range s.boxes {
		files[i] = filepath.Join(dir, fmt.Sprintf("box%d.json", i))
		if shares[i] == 0 {
			files[i] = ""
			continue
		}
		args := s.boxArgs(i, shares[i], off, t0, ramp, measure, runID, files[i])
		off += shares[i]
		wg.Add(1)
		go func(i int, b boxSpec, args []string) {
			defer wg.Done()
			if b.host == "local" {
				errs[i] = s.runLocal(args, filepath.Join(dir, fmt.Sprintf("box%d.log", i)))
			} else {
				errs[i] = s.runRemote(b.host, i, args, runID, files[i], filepath.Join(dir, fmt.Sprintf("box%d.log", i)), t0.Add(total))
			}
		}(i, b, args)
	}
	wg.Wait()
	if monitoring {
		s.stopMonitor(tag, filepath.Join(dir, "monitor.csv"))
	}
	var rs []*BoxResult
	for i, f := range files {
		if f == "" {
			continue
		}
		if errs[i] != nil {
			return nil, fmt.Errorf("%s: box %d (%s): %v", name, i, s.boxes[i].host, errs[i])
		}
		r, err := readBoxResult(f)
		if err != nil {
			return nil, fmt.Errorf("%s: box %d: %v", name, i, err)
		}
		rs = append(rs, r)
	}
	m := mergeResults(rs)
	for i := range m.Boxes {
		m.Boxes[i].File = filepath.Base(files[m.Boxes[i].Index])
	}
	if err := writeJSON(mpath, m); err != nil {
		return nil, err
	}
	var tb bytes.Buffer
	printMerged(&tb, m)
	os.WriteFile(filepath.Join(dir, "merged.txt"), tb.Bytes(), 0o644)
	s.logln("%-12s %s", name, oneLine(m))
	if m.Verdict.LGLimited {
		s.logln("  LG-limited: %s", strings.Join(m.Verdict.LGReasons, "; "))
	}
	if !m.Verdict.Pass {
		s.logln("  fail: %s", strings.Join(m.Verdict.Reasons, ", "))
	}
	r := s.result(name, users, m, dir)
	r.Restarted = restarted
	return r, nil
}

func (s *searcher) result(name string, users int, m *Merged, dir string) *phaseResult {
	return &phaseResult{Name: name, Users: users, Pass: m.Verdict.Pass, LG: m.Verdict.LGLimited && name != "warmup",
		RPS: m.Overall.RPS, P50: m.Overall.P50Ms, P95: m.Overall.P95Ms, P99: m.Overall.P99Ms, ErrPct: 100 * m.Overall.ErrorRate, m: m, dir: dir}
}

func (s *searcher) runLocal(args []string, logPath string) error {
	self, err := os.Executable()
	if err != nil {
		return err
	}
	lf, err := os.Create(logPath)
	if err != nil {
		return err
	}
	defer lf.Close()
	c := exec.Command(self, append([]string{"run", "-secret", s.secret}, args...)...)
	c.Stdout, c.Stderr = lf, lf
	return c.Run()
}

// runRemote starts loadgen detached on a box (so an ssh drop doesn't kill it), waits for it to finish, then fetches
// its JSON. A mkdir guard keeps a retried launch from starting it twice.
func (s *searcher) runRemote(host string, i int, args []string, runID, outFile, logPath string, endAt time.Time) error {
	rdir := s.remoteDir + "/" + runID
	rjson := fmt.Sprintf("%s/box%d.json", rdir, i)
	rargs := []string{"run"}
	for j := 0; j < len(args); j++ {
		if args[j] == "-out" {
			args[j+1] = rjson
		}
	}
	rargs = append(rargs, args...)
	var q []string
	for _, a := range rargs {
		q = append(q, shq(a))
	}
	inner := fmt.Sprintf("ulimit -n 1048576 2>/dev/null || ulimit -n $(ulimit -Hn); CONDUIT_JWT_SECRET=%s %s %s > %s 2>&1; echo $? > %s",
		shq(s.secret), shq(s.remoteBin), strings.Join(q, " "), shq(fmt.Sprintf("%s/box%d.log", rdir, i)), shq(fmt.Sprintf("%s/box%d.rc", rdir, i)))
	launch := fmt.Sprintf("mkdir -p %s && mkdir %s/started%d 2>/dev/null && ($(command -v setsid) nohup bash -c %s > /dev/null 2>&1 < /dev/null &) ; echo launched",
		shq(rdir), shq(rdir), i, shq(inner))
	if err := s.ssh(host, launch, nil); err != nil {
		return fmt.Errorf("launch: %v", err)
	}
	// poll every 10 s during the run (fail fast if it died), every 2 s after its end
	deadline := endAt.Add(reqTimeout + 60*time.Second)
	rcFile := shq(fmt.Sprintf("%s/box%d.rc", rdir, i))
	rc := ""
	for {
		wait := 2 * time.Second
		if d := time.Until(endAt); d > 0 {
			wait = min(d, 10*time.Second)
		}
		time.Sleep(wait)
		out, err := s.sshOut(host, "cat "+rcFile+" 2>/dev/null; true")
		if err == nil && strings.TrimSpace(out) != "" {
			rc = strings.TrimSpace(out)
			break
		}
		if time.Now().After(deadline) {
			lg, _ := s.sshOut(host, fmt.Sprintf("tail -c 2000 %s 2>&1", shq(fmt.Sprintf("%s/box%d.log", rdir, i))))
			return fmt.Errorf("no exit code from %s after %v; log tail: %s", rdir, time.Since(endAt).Round(time.Second), lg)
		}
	}
	if lg, err := s.sshOut(host, "tail -c 20000 "+shq(fmt.Sprintf("%s/box%d.log", rdir, i))); err == nil {
		os.WriteFile(logPath, []byte(lg), 0o644)
	}
	if rc != "0" {
		return fmt.Errorf("loadgen exit %s (see %s)", rc, logPath)
	}
	js, err := s.sshOut(host, "cat "+shq(rjson))
	if err != nil {
		return fmt.Errorf("fetch: %v", err)
	}
	return os.WriteFile(outFile, []byte(js), 0o644)
}

// ---------- target monitor ----------

// allHosts is the target followed by every -extra-ssh box.
func (s *searcher) allHosts() []string {
	hs := []string{s.targetSSH}
	for _, e := range s.extras {
		hs = append(hs, e.host)
	}
	return hs
}

func (s *searcher) startMonitor(tag string) bool {
	for _, e := range s.extras {
		s.startMonitorOn(e.host, tag)
	}
	return s.startMonitorOn(s.targetSSH, tag)
}

func (s *searcher) stopMonitor(tag, csvPath string) {
	for _, e := range s.extras {
		s.stopMonitorOn(e.host, tag, filepath.Join(filepath.Dir(csvPath), "monitor-"+e.name+".csv"))
	}
	s.stopMonitorOn(s.targetSSH, tag, csvPath)
}

func (s *searcher) startMonitorOn(host, tag string) bool {
	cmd := fmt.Sprintf("mkdir -p %[1]s && cd %[1]s && ($(command -v setsid) nohup %[2]s 1 %[3]s.csv > %[3]s.stdout 2>&1 < /dev/null & echo $! > %[3]s.pid)",
		shq(s.monitorDir), s.monitorCmd, shq(tag))
	if err := s.ssh(host, cmd, nil); err != nil {
		s.logln("  monitor start failed on %s: %v", host, err)
		return false
	}
	return true
}

func (s *searcher) stopMonitorOn(host, tag, csvPath string) {
	cmd := fmt.Sprintf("cd %s && p=$(cat %s.pid 2>/dev/null) && { kill -TERM -- -$p 2>/dev/null || { pkill -TERM -P $p; kill -TERM $p; }; } 2>/dev/null; sleep 1; kill -KILL -- -$p 2>/dev/null; "+
		"f=$(ls -t %s/*%s*.csv /opt/conduit-tools/results/*%s*.csv /root/results/*%s*.csv 2>/dev/null | head -1); "+
		"if [ -n \"$f\" ]; then cat \"$f\"; else echo NO_CSV; tail -c 200000 %s.stdout; fi",
		shq(s.monitorDir), shq(tag), shq(s.monitorDir), tag, tag, tag, shq(tag))
	out, err := s.sshOut(host, cmd)
	if err != nil {
		s.logln("  monitor stop/fetch failed on %s: %v", host, err)
		return
	}
	if strings.HasPrefix(out, "NO_CSV") {
		s.logln("  monitor wrote no CSV; saved its stdout instead")
		os.WriteFile(strings.TrimSuffix(csvPath, ".csv")+".stdout.txt", []byte(strings.TrimPrefix(out, "NO_CSV\n")), 0o644)
		return
	}
	os.WriteFile(csvPath, []byte(out), 0o644)
}

var labelRe = regexp.MustCompile(`[^A-Za-z0-9._-]+`)

var hmsRe = regexp.MustCompile(`^\d{1,2}:\d{2}:\d{2}$`)

// monitorAverages averages every numeric column of the monitor CSV over [from, to). The time column may be
// unix seconds/ms, RFC 3339, or HH:MM:SS in the target's local time (the old monitor.sh format).
func monitorAverages(path string, from, to time.Time, tz time.Duration) (map[string]float64, int, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, 0, err
	}
	defer f.Close()
	rd := csv.NewReader(f)
	rd.FieldsPerRecord = -1
	rows, err := rd.ReadAll()
	if err != nil || len(rows) < 2 {
		return nil, 0, fmt.Errorf("monitor csv: %v (%d rows)", err, len(rows))
	}
	hdr := rows[0]
	tcol := -1
	for i, h := range hdr {
		h = strings.ToLower(strings.TrimSpace(h))
		if h == "time" || h == "ts" || h == "timestamp" || h == "epoch" || h == "unix" || h == "t" {
			tcol = i
			break
		}
	}
	day := from.UTC().Add(tz)
	parseT := func(v string) (time.Time, bool) {
		v = strings.TrimSpace(v)
		if x, err := strconv.ParseFloat(v, 64); err == nil {
			switch {
			case x > 1e12:
				return time.UnixMilli(int64(x)), true
			case x > 1e9:
				return time.Unix(0, int64(x*1e9)), true
			}
			return time.Time{}, false
		}
		if t, err := time.Parse(time.RFC3339Nano, v); err == nil {
			return t, true
		}
		if hmsRe.MatchString(v) {
			p := strings.Split(v, ":")
			h, _ := strconv.Atoi(p[0])
			m, _ := strconv.Atoi(p[1])
			sec, _ := strconv.Atoi(p[2])
			local := time.Date(day.Year(), day.Month(), day.Day(), h, m, sec, 0, time.UTC)
			t := local.Add(-tz)
			// a window that crosses midnight
			if t.Before(from.Add(-12 * time.Hour)) {
				t = t.Add(24 * time.Hour)
			} else if t.After(to.Add(12 * time.Hour)) {
				t = t.Add(-24 * time.Hour)
			}
			return t, true
		}
		return time.Time{}, false
	}
	sums := map[string]float64{}
	ns := map[string]int{}
	used := 0
	for _, r := range rows[1:] {
		if tcol >= 0 {
			if tcol >= len(r) {
				continue
			}
			t, ok := parseT(r[tcol])
			// a sample stamped t covers the interval before t
			if !ok || t.Before(from.Add(time.Second)) || t.After(to) {
				continue
			}
		}
		used++
		for i, v := range r {
			if i == tcol || i >= len(hdr) {
				continue
			}
			if x, err := strconv.ParseFloat(strings.TrimSpace(v), 64); err == nil {
				sums[hdr[i]] += x
				ns[hdr[i]]++
			}
		}
	}
	out := map[string]float64{}
	for k, v := range sums {
		out[k] = v / float64(ns[k])
	}
	return out, used, nil
}

// pick finds the first column whose lowercase name matches one of the candidates.
func pick(avg map[string]float64, names ...string) *float64 {
	for _, n := range names {
		for k, v := range avg {
			if strings.EqualFold(strings.TrimSpace(k), n) {
				x := v
				return &x
			}
		}
	}
	return nil
}

// ---------- summary ----------

type TargetCPU struct {
	Samples  int                `json:"samples"`
	CPU      *float64           `json:"cpu_pct"`
	Steal    *float64           `json:"steal_pct"`
	App      *float64           `json:"app_pct_of_one_core"`
	DB       *float64           `json:"db_pct_of_one_core"`
	Nginx    *float64           `json:"nginx_pct_of_one_core"`
	Averages map[string]float64 `json:"all_columns"`
	Note     string             `json:"note,omitempty"`
}

type Summary struct {
	Label        string           `json:"label"`
	Lang         string           `json:"lang"`
	Target       string           `json:"target"`
	Boxes        []string         `json:"load_boxes"`
	Status       string           `json:"status"` // ok | lg_limited | no_pass
	ScoreUsers   int              `json:"score_users"`
	LGLimitedAt  int              `json:"lg_limited_at,omitempty"`
	HighestProbe int              `json:"highest_passing_probe"`
	LowestFail   int              `json:"lowest_failing_probe,omitempty"`
	Hold         *Merged          `json:"-"`
	RPS          float64          `json:"rps"`
	P50Ms        float64          `json:"p50_ms"`
	P95Ms        float64          `json:"p95_ms"`
	P99Ms        float64          `json:"p99_ms"`
	ErrorPct     float64          `json:"error_pct"`
	ErrorClasses map[string]int64 `json:"error_classes,omitempty"`
	Endpoints    []EndpointStats  `json:"endpoints,omitempty"`
	TargetCPU    *TargetCPU       `json:"target_cpu,omitempty"`
	LGBoxes      []BoxSummary     `json:"lg_boxes,omitempty"`
	Probes       []*phaseResult   `json:"probes"`
	Holds        []*phaseResult   `json:"holds"`
	Started      string           `json:"started"`
	Finished     string           `json:"finished"`
}

func (s *searcher) writeSummary(started time.Time, score int, scored *phaseResult, lgAt, lo, hi int, probes, holds []*phaseResult) error {
	sum := Summary{Label: s.label, Lang: s.lang, Target: s.targetURL, ScoreUsers: score, LGLimitedAt: lgAt, HighestProbe: lo,
		LowestFail: hi, Probes: probes, Holds: holds, Started: started.UTC().Format(time.RFC3339), Finished: time.Now().UTC().Format(time.RFC3339)}
	for _, b := range s.boxes {
		sum.Boxes = append(sum.Boxes, fmt.Sprintf("%s=%d", b.host, b.weight))
	}
	switch {
	case lgAt > 0:
		sum.Status = "lg_limited"
	case score > 0:
		sum.Status = "ok"
	default:
		sum.Status = "no_pass"
	}
	if sum.Probes == nil {
		sum.Probes = []*phaseResult{}
	}
	if sum.Holds == nil {
		sum.Holds = []*phaseResult{}
	}
	if scored != nil {
		m := scored.m
		sum.RPS, sum.P50Ms, sum.P95Ms, sum.P99Ms = m.Overall.RPS, m.Overall.P50Ms, m.Overall.P95Ms, m.Overall.P99Ms
		sum.ErrorPct, sum.ErrorClasses, sum.Endpoints, sum.LGBoxes = 100*m.Overall.ErrorRate, m.Overall.ErrorClasses, m.Endpoints, m.Boxes
		csvPath := filepath.Join(scored.dir, "monitor.csv")
		from := time.UnixMilli(m.StartAtMs).Add(time.Duration(m.RampS * float64(time.Second)))
		to := from.Add(time.Duration(m.WindowS * float64(time.Second)))
		tc := &TargetCPU{}
		if avg, n, err := monitorAverages(csvPath, from, to, s.tzOffset); err != nil {
			tc.Note = err.Error()
		} else {
			tc.Samples, tc.Averages = n, avg
			tc.CPU = pick(avg, "cpu%", "cpu", "cpu_pct", "cpu_total")
			tc.Steal = pick(avg, "steal%", "steal", "steal_pct")
			tc.App = pick(avg, "app_box", "app%", "app", "app_pct", "app_cpu")
			tc.DB = pick(avg, "pg_box", "db%", "pg%", "postgres%", "db", "db_pct", "pg_cpu", "db_cpu")
			tc.Nginx = pick(avg, "ngx_box", "nginx%", "nginx", "nginx_pct", "nginx_cpu")
		}
		sum.TargetCPU = tc
	}
	if err := writeJSON(filepath.Join(s.outdir, "SUMMARY.json"), sum); err != nil {
		return err
	}
	var b strings.Builder
	fmt.Fprintf(&b, "%s  (lang %s, target %s)\n", s.label, s.lang, s.targetURL)
	switch sum.Status {
	case "ok":
		fmt.Fprintf(&b, "SCORE: %d users held 5 minutes\n", score)
	case "lg_limited":
		fmt.Fprintf(&b, "LG-LIMITED at %d users (the load boxes, not the server, were the limit); highest clean passing probe %s\n", lgAt, orNone(lo))
	default:
		fmt.Fprintf(&b, "NO PASSING HOLD\n")
	}
	fmt.Fprintf(&b, "probes: highest pass %s, lowest fail %s\n\n", orNone(lo), orNone(hi))
	if scored != nil {
		fmt.Fprintf(&b, "hold at %d users: %.0f req/s, p50 %.1f ms, p95 %.1f ms, p99 %.1f ms, errors %.3f%%\n",
			score, sum.RPS, sum.P50Ms, sum.P95Ms, sum.P99Ms, sum.ErrorPct)
		if tc := sum.TargetCPU; tc != nil {
			f := func(p *float64) string {
				if p == nil {
					return "?"
				}
				return fmt.Sprintf("%.0f", *p)
			}
			fmt.Fprintf(&b, "target over the hold window (%d samples): cpu %s%%, steal %s%%, app %s%% / db %s%% / nginx %s%% (of one core)%s\n",
				tc.Samples, f(tc.CPU), f(tc.Steal), f(tc.App), f(tc.DB), f(tc.Nginx), map[bool]string{true: "  [" + tc.Note + "]", false: ""}[tc.Note != ""])
		}
		var tb bytes.Buffer
		printMerged(&tb, scored.m)
		b.WriteString(tb.String())
	}
	b.WriteString("\nphase         users   pass  lg     req/s     p50     p95     p99   err%\n")
	for _, r := range append(append([]*phaseResult{}, probes...), holds...) {
		fmt.Fprintf(&b, "%-12s %6d   %-5v %-5v %7.0f %7.1f %7.1f %7.1f %6.2f%s\n", r.Name, r.Users, r.Pass, r.LG, r.RPS, r.P50, r.P95, r.P99, r.ErrPct,
			map[bool]string{true: "  (app restarted first: it failed the health check after the phase before)", false: ""}[r.Restarted])
	}
	if err := os.WriteFile(filepath.Join(s.outdir, "SUMMARY.txt"), []byte(b.String()), 0o644); err != nil {
		return err
	}
	fmt.Fprint(s.log, "\n"+b.String())
	return nil
}
