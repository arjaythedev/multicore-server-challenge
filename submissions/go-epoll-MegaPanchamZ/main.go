package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"os/signal"
	"runtime"
	"runtime/debug"
	"strconv"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

type serverOptions struct {
	jwtSecret string
	cpuCount  int
	maxConns  int
	poller    pollerOptions
	db        batcherOptions
	pg        *pgconn.Config
}

func main() {
	if err := bootConduit(); err != nil {
		log.Fatal(err)
	}
}

func bootConduit() error {
	opts, err := readServerOptions()
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var eng *pgEngine
	srv, err := newNetServer(opts.poller, func(ns *netServer) taskRouter {
		eng = newPGEngine(ns, opts.db, opts.pg, []byte(opts.jwtSecret))
		return eng
	})
	if err != nil {
		return err
	}
	if err := eng.openPoolWithRetry(ctx, 50*time.Second); err != nil {
		return fmt.Errorf("database startup failed: %w", err)
	}
	log.Printf("conduit listening on %s (cpus=%d loops=%d max_conns=%d r_conns=%d w_conns=%d bf_workers=%d)",
		srv.ListenAddr(), opts.cpuCount, opts.poller.loopCount, opts.maxConns,
		opts.db.readPoolSize, opts.db.writePoolSize, opts.db.hashThreads)
	return srv.Run(ctx)
}

func readServerOptions() (serverOptions, error) {
	var opts serverOptions
	dsn := os.Getenv("DATABASE_URL")
	opts.jwtSecret = os.Getenv("JWT_SECRET")
	if dsn == "" || opts.jwtSecret == "" {
		return opts, errors.New("DATABASE_URL and JWT_SECRET are required")
	}
	opts.cpuCount = runtime.GOMAXPROCS(0)

	activeCap, err := readEnvRange("MAX_INFLIGHT", 4096, 1, 16384)
	if err != nil {
		return opts, err
	}
	queueCap, err := readEnvRange("MAX_QUEUED", 20480, 2, 65536)
	if err != nil {
		return opts, err
	}
	connCap, err := readEnvRange("MAX_CONNECTIONS", 1<<20, 16, 1<<20)
	if err != nil {
		return opts, err
	}
	totalSlots := activeCap + queueCap
	if opts.db, err = readBatcherOptions(opts.cpuCount, totalSlots); err != nil {
		return opts, err
	}

	var rlim syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &rlim); err != nil {
		return opts, err
	}
	fdHeadroom := uint64(opts.db.readPoolSize + opts.db.writePoolSize + 256)
	if rlim.Cur <= fdHeadroom+16 {
		return opts, errors.New("RLIMIT_NOFILE is too low")
	}
	opts.maxConns = int(min(uint64(connCap), rlim.Cur-fdHeadroom))
	fdTableCap := int(min(rlim.Cur, uint64(opts.maxConns)+fdHeadroom))
	if opts.poller, err = readPollerOptions(opts.cpuCount, activeCap, queueCap, opts.maxConns, fdTableCap); err != nil {
		return opts, err
	}

	if os.Getenv("GOMEMLIMIT") == "" {
		debug.SetMemoryLimit(3 << 30)
	}
	if os.Getenv("GOGC") == "" {
		debug.SetGCPercent(400)
	}

	pgCfg, err := pgconn.ParseConfig(dsn)
	if err != nil {
		return opts, errors.New("invalid DATABASE_URL")
	}
	if pgCfg.Host == "127.0.0.1" || pgCfg.Host == "localhost" || pgCfg.Host == "::1" {
		pgCfg.TLSConfig = nil
		pgCfg.Fallbacks = nil
	}
	pgCfg.ConnectTimeout = 3 * time.Second
	cacheMode := readEnvStr("PG_PLAN_MODE", "force_generic_plan")
	if cacheMode != "auto" && cacheMode != "force_generic_plan" && cacheMode != "force_custom_plan" {
		return opts, errors.New("invalid PG_PLAN_MODE")
	}
	pgCfg.RuntimeParams["application_name"] = "conduit"
	pgCfg.RuntimeParams["statement_timeout"] = "5000"
	pgCfg.RuntimeParams["lock_timeout"] = "2000"
	pgCfg.RuntimeParams["idle_in_transaction_session_timeout"] = "6000"
	pgCfg.RuntimeParams["TimeZone"] = "UTC"
	pgCfg.RuntimeParams["plan_cache_mode"] = cacheMode
	pgCfg.RuntimeParams["jit"] = "off"
	pgCfg.RuntimeParams["max_parallel_workers_per_gather"] = "0"
	opts.pg = pgCfg
	return opts, nil
}

func readEnvStr(key, fallback string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return fallback
}

func readEnvRange(key string, fallback, lo, hi int) (int, error) {
	raw := os.Getenv(key)
	if raw == "" {
		return fallback, nil
	}
	val, err := strconv.Atoi(raw)
	if err != nil || val < lo || val > hi {
		return 0, fmt.Errorf("%s must be in [%d..%d]", key, lo, hi)
	}
	return val, nil
}
