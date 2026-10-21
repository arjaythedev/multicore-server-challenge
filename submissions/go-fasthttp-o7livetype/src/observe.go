package main

// observe.go is logging and metrics: log/slog setup, the per-request log
// policy, process-wide counters and the periodic stats line.

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"sync/atomic"
	"time"
)

// Logging goes to stderr (the systemd journal on the benchmark box) through
// log/slog. Normal requests are not logged by default: at tens of thousands of
// requests per second a line per request costs real CPU. Instead the server logs
// server errors, slow requests and a periodic stats line. ACCESS_LOG=1 logs every
// request.

type logConfig struct {
	access bool
	slow   time.Duration
	stats  time.Duration
	burst  int64 // per-request warnings allowed per second; the rest are counted
}

func setupLogging() (logConfig, error) {
	var level slog.Level
	switch strings.ToLower(envOr("LOG_LEVEL", "info")) {
	case "debug":
		level = slog.LevelDebug
	case "info":
		level = slog.LevelInfo
	case "warn":
		level = slog.LevelWarn
	case "error":
		level = slog.LevelError
	default:
		return logConfig{}, fmt.Errorf("LOG_LEVEL must be debug, info, warn or error")
	}
	opts := &slog.HandlerOptions{Level: level}
	var h slog.Handler
	switch strings.ToLower(envOr("LOG_FORMAT", "json")) {
	case "json":
		h = slog.NewJSONHandler(os.Stderr, opts)
	case "text":
		h = slog.NewTextHandler(os.Stderr, opts)
	default:
		return logConfig{}, fmt.Errorf("LOG_FORMAT must be json or text")
	}
	slog.SetDefault(slog.New(h)) // also routes the standard log package (used by libraries)

	cfg := logConfig{}
	var err error
	if cfg.access, err = envBool("ACCESS_LOG", false); err != nil {
		return cfg, err
	}
	if cfg.slow, err = envDuration("SLOW_REQUEST", time.Second, 0, time.Minute); err != nil {
		return cfg, err
	}
	if cfg.stats, err = envDuration("STATS_INTERVAL", 30*time.Second, 0, time.Hour); err != nil {
		return cfg, err
	}
	burst, err := envInt("LOG_BURST", 20, 1, 100000)
	cfg.burst = int64(burst)
	return cfg, err
}

func envBool(name string, fallback bool) (bool, error) {
	switch strings.ToLower(os.Getenv(name)) {
	case "":
		return fallback, nil
	case "1", "true", "yes", "on":
		return true, nil
	case "0", "false", "no", "off":
		return false, nil
	}
	return false, fmt.Errorf("%s must be true or false", name)
}

func envDuration(name string, fallback, lo, hi time.Duration) (time.Duration, error) {
	s := os.Getenv(name)
	if s == "" {
		return fallback, nil
	}
	d, err := time.ParseDuration(s)
	if err != nil || d < lo || d > hi {
		return 0, fmt.Errorf("%s must be a duration between %s and %s", name, lo, hi)
	}
	return d, nil
}

// limiter allows up to n events per wall-clock second and counts the rest, so
// an incident (a database outage, an overload) cannot flood the log.
type limiter struct {
	n       int64
	sec     atomic.Int64
	used    atomic.Int64
	dropped atomic.Int64
}

func (l *limiter) allow() bool {
	now := time.Now().Unix()
	if s := l.sec.Load(); s != now && l.sec.CompareAndSwap(s, now) {
		l.used.Store(0)
	}
	if l.used.Add(1) <= l.n {
		return true
	}
	l.dropped.Add(1)
	return false
}

// metrics are process-wide counters reported by the stats loop.
type metrics struct {
	requests, client4xx, server5xx, busy, slow     atomic.Int64
	panics, dbErrors, groupRetries, unknownOutcome atomic.Int64
	reconnects, reconnectFailures, bcryptOverflow  atomic.Int64
	latencyNanos, maxLatencyNanos                  atomic.Int64
}

var stats metrics

// warnLog is the rate limit shared by every per-request warning.
var warnLog = &limiter{n: 20} // LOG_BURST

func (m *metrics) observe(status int, d time.Duration) {
	m.requests.Add(1)
	switch {
	case status >= 500:
		m.server5xx.Add(1)
		if status == 503 {
			m.busy.Add(1)
		}
	case status >= 400:
		m.client4xx.Add(1)
	}
	ns := int64(d)
	m.latencyNanos.Add(ns)
	for {
		cur := m.maxLatencyNanos.Load()
		if ns <= cur || m.maxLatencyNanos.CompareAndSwap(cur, ns) {
			break
		}
	}
}

// reportStats logs one line per interval with the counters since the last line.
func reportStats(ctx context.Context, every time.Duration, d *dbDispatcher) {
	if every <= 0 {
		return
	}
	t := time.NewTicker(every)
	defer t.Stop()
	var last struct{ req, c4, s5, busy, slow, lat, dbe, dropped int64 }
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		req, c4, s5 := stats.requests.Load(), stats.client4xx.Load(), stats.server5xx.Load()
		busy, slow, lat := stats.busy.Load(), stats.slow.Load(), stats.latencyNanos.Load()
		dbe, dropped := stats.dbErrors.Load(), warnLog.dropped.Load()
		n := req - last.req
		avg := time.Duration(0)
		if n > 0 {
			avg = time.Duration((lat - last.lat) / n)
		}
		slog.Info("stats",
			"interval", every.String(),
			"requests", n,
			"rps", float64(n)/every.Seconds(),
			"client_errors", c4-last.c4,
			"server_errors", s5-last.s5,
			"busy_503", busy-last.busy,
			"slow", slow-last.slow,
			"avg_latency", avg.String(),
			"max_latency", time.Duration(stats.maxLatencyNanos.Swap(0)).String(),
			"read_queue", len(d.read),
			"write_queue", len(d.write),
			"db_errors", dbe-last.dbe,
			"log_suppressed", dropped-last.dropped,
			"total_panics", stats.panics.Load(),
			"total_reconnects", stats.reconnects.Load(),
			"total_reconnect_failures", stats.reconnectFailures.Load(),
			"total_unknown_write_outcomes", stats.unknownOutcome.Load(),
			"total_group_retries", stats.groupRetries.Load(),
			"total_bcrypt_overflow", stats.bcryptOverflow.Load(),
		)
		last.req, last.c4, last.s5, last.busy = req, c4, s5, busy
		last.slow, last.lat, last.dbe, last.dropped = slow, lat, dbe, dropped
	}
}

// logRequest applies the request logging policy after a response is ready.
func logRequest(cfg *logConfig, id uint64, method, path string, rt route, status int, d time.Duration) {
	slowReq := cfg.slow > 0 && d >= cfg.slow
	if slowReq {
		stats.slow.Add(1)
	}
	switch {
	case cfg.access:
		slog.Info("request", "id", id, "method", method, "path", clip(path),
			"route", rt.String(), "status", status, "duration", d.String())
	case status >= 500 && warnLog.allow():
		slog.Warn("server error", "id", id, "method", method, "path", clip(path),
			"route", rt.String(), "status", status, "duration", d.String())
	case slowReq && warnLog.allow():
		slog.Warn("slow request", "id", id, "method", method, "path", clip(path),
			"route", rt.String(), "status", status, "duration", d.String())
	}
}

// clip bounds what a client can make us write to the log.
func clip(s string) string {
	if len(s) > 200 {
		return s[:200] + "..."
	}
	return s
}

var routeNames = [...]string{
	rNotFound: "not_found", rTags: "tags", rRegister: "register", rLogin: "login",
	rCurrentUser: "current_user", rUpdateUser: "update_user", rProfile: "profile",
	rFollow: "follow", rUnfollow: "unfollow", rList: "list_articles", rFeed: "feed",
	rArticle: "article", rCreateArticle: "create_article", rUpdateArticle: "update_article",
	rDeleteArticle: "delete_article", rFavorite: "favorite", rUnfavorite: "unfavorite",
	rComments: "comments", rCreateComment: "create_comment", rDeleteComment: "delete_comment",
}

func (r route) String() string {
	if int(r) < len(routeNames) {
		return routeNames[r]
	}
	return "unknown"
}
