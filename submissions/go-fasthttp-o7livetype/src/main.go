// Conduit serves the fixed multicore challenge API using networked PostgreSQL.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"runtime"
	"runtime/debug"
	"strconv"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/valyala/fasthttp"
)

func envOr(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func envInt(name string, fallback, lo, hi int) (int, error) {
	value := os.Getenv(name)
	if value == "" {
		return fallback, nil
	}
	n, err := strconv.Atoi(value)
	if err != nil || n < lo || n > hi {
		return 0, fmt.Errorf("%s must be between %d and %d", name, lo, hi)
	}
	return n, nil
}

func main() {
	if err := run(); err != nil {
		slog.Error("server stopped", "err", err)
		os.Exit(1)
	}
	slog.Info("server stopped cleanly")
}

func run() error {
	logCfg, err := setupLogging()
	if err != nil {
		return err
	}
	warnLog.n = logCfg.burst
	dbURL, secret := os.Getenv("DATABASE_URL"), os.Getenv("JWT_SECRET")
	if dbURL == "" || secret == "" {
		return errors.New("DATABASE_URL and JWT_SECRET are required")
	}
	host, port := envOr("HOST", "0.0.0.0"), envOr("PORT", "3000")
	if p, err := strconv.Atoi(port); err != nil || p < 1 || p > 65535 {
		return fmt.Errorf("PORT must be a number between 1 and 65535, got %q", port)
	}
	cores := runtime.GOMAXPROCS(0) // Go respects cgroup CPU quotas; never nproc's host CPU count.
	dbCfg, err := dbConfigFromEnv(cores)
	if err != nil {
		return err
	}
	var fdLimit syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &fdLimit); err != nil {
		return err
	}
	reserve := uint64(dbCfg.readConns + dbCfg.writeConns + 256)
	if fdLimit.Cur <= reserve+16 {
		return fmt.Errorf("open file limit %d is too low: need more than %d for database connections and reserves", fdLimit.Cur, reserve+16)
	}
	// Default: every descriptor left after the database and listener reserve.
	sockets, err := envInt("MAX_CONNECTIONS", 1<<20, 16, 1<<20)
	if err != nil {
		return err
	}
	sockets = int(min(uint64(sockets), fdLimit.Cur-reserve))
	// One queue slot per possible connection: each connection has at most one request
	// in flight, so a queue can never fill up. Overload shows up as latency, not 503s.
	queued, err := envInt("MAX_QUEUED", sockets, 2, 1<<20)
	if err != nil {
		return err
	}
	dbCfg.readQueue, dbCfg.writeQueue = queued, queued
	if os.Getenv("GOMEMLIMIT") == "" {
		// fasthttp parks one goroutine per open connection; leave room for their
		// stacks. 3/8 of RAM (6 GB on a 16 GB box); PostgreSQL needs the rest.
		debug.SetMemoryLimit(goMemoryLimit(6, 6<<30))
	}
	if os.Getenv("GOGC") == "" {
		debug.SetGCPercent(200)
	}
	pgcfg, err := pgconn.ParseConfig(dbURL)
	if err != nil {
		return errors.New("DATABASE_URL is not a valid PostgreSQL connection string")
	}
	pgcfg.ConnectTimeout = 3 * time.Second
	// These are session settings, not changes to PostgreSQL's fixed server config.
	planMode := envOr("PG_PLAN_MODE", "force_generic_plan")
	if planMode != "auto" && planMode != "force_generic_plan" && planMode != "force_custom_plan" {
		return errors.New("PG_PLAN_MODE must be auto, force_generic_plan or force_custom_plan")
	}
	for k, v := range map[string]string{
		"application_name": "conduit-go-fasthttp", "statement_timeout": "5000", "lock_timeout": "2000",
		"idle_in_transaction_session_timeout": "6000", "TimeZone": "UTC", "plan_cache_mode": planMode,
		"jit": "off", "max_parallel_workers_per_gather": "0",
	} {
		pgcfg.RuntimeParams[k] = v
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	codec := newJWTCodec([]byte(secret))
	disp := newDBDispatcher(dbCfg, pgcfg, codec)
	slog.Info("connecting to database", "host", pgcfg.Host, "port", pgcfg.Port, "database", pgcfg.Database,
		"connections", dbCfg.readConns+dbCfg.writeConns)
	// The box's health check allows 60 s from start; keep trying for most of it.
	if err := disp.connectWithRetry(ctx, 50*time.Second); err != nil {
		return fmt.Errorf("database not ready: %w", err)
	}
	disp.start()

	app := newServer(disp, codec, dbCfg.bcryptWorkers, dbCfg.bcryptWait, &logCfg)
	srv := &fasthttp.Server{
		Handler: app.handle, ErrorHandler: errorHandler,
		Concurrency: sockets, MaxRequestBodySize: 1 << 20,
		ReadBufferSize: 16 << 10, WriteBufferSize: 16 << 10,
		ReadTimeout: 15 * time.Second, WriteTimeout: 15 * time.Second,
		IdleTimeout: 75 * time.Second, // above Nginx's 60 s upstream keep-alive
		// Idle keep-alive connections release their buffers.
		ReduceMemoryUsage:     true,
		NoDefaultServerHeader: true,
		CloseOnShutdown:       true,
	}
	addr := net.JoinHostPort(host, port)
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", addr, err)
	}
	slog.Info("listening", "addr", ln.Addr().String(), "cores", cores,
		"read_conns", dbCfg.readConns, "write_conns", dbCfg.writeConns,
		"read_queue", dbCfg.readQueue, "write_queue", dbCfg.writeQueue,
		"read_batch", dbCfg.readBatch, "write_batch", dbCfg.writeBatch,
		"write_linger", dbCfg.writeLinger.String(), "write_flush", dbCfg.writeFlush.String(),
		"bcrypt_workers", dbCfg.bcryptWorkers, "max_sockets", sockets,
		"go_memory_limit_mb", debug.SetMemoryLimit(-1)>>20,
		"access_log", logCfg.access, "slow_request", logCfg.slow.String(), "stats_interval", logCfg.stats.String())
	go reportStats(ctx, logCfg.stats, disp)
	served := make(chan error, 1)
	go func() { served <- srv.Serve(ln) }()
	select {
	case err = <-served:
		return fmt.Errorf("http server: %w", err)
	case <-ctx.Done():
	}
	slog.Info("shutdown signal received, draining connections", "timeout", "10s")
	shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.ShutdownWithContext(shutdown); err != nil {
		// Handlers may still be running; leave the database workers to process exit.
		return fmt.Errorf("shutdown: %w", err)
	}
	disp.stop() // no handler is running, so nothing can be queued any more
	return nil
}
