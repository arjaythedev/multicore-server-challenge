// Conduit serves the fixed multicore challenge API using networked PostgreSQL.
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
		log.Fatal(err)
	}
}

func run() error {
	dbURL, secret := os.Getenv("DATABASE_URL"), os.Getenv("JWT_SECRET")
	if dbURL == "" || secret == "" {
		return errors.New("DATABASE_URL and JWT_SECRET are required")
	}
	cores := runtime.GOMAXPROCS(0) // Go respects cgroup CPU quotas; never nproc's host CPU count.
	inflight, err := envInt("MAX_INFLIGHT", 4096, 1, 16384)
	if err != nil {
		return err
	}
	queued, err := envInt("MAX_QUEUED", 20480, 2, 65536)
	if err != nil {
		return err
	}
	// Default: every descriptor left after the database and listener reserve.
	sockets, err := envInt("MAX_CONNECTIONS", 1<<20, 16, 1<<20)
	if err != nil {
		return err
	}
	dbCfg, err := dbConfigFromEnv(cores, inflight+queued)
	if err != nil {
		return err
	}
	if os.Getenv("DB_POOL_SIZE") != "" {
		log.Printf("DB_POOL_SIZE is ignored; use DB_READ_CONNS and DB_WRITE_CONNS")
	}
	var fdLimit syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &fdLimit); err != nil {
		return err
	}
	reserve := uint64(dbCfg.readConns + dbCfg.writeConns + 256)
	if fdLimit.Cur <= reserve+16 {
		return errors.New("nofile is too low for the database and socket reserves")
	}
	sockets = int(min(uint64(sockets), fdLimit.Cur-reserve))
	if os.Getenv("GOMEMLIMIT") == "" {
		// 1/4 of RAM, at most 3 GB; PostgreSQL needs the rest.
		debug.SetMemoryLimit(goMemoryLimit(4, 3<<30))
	}
	if os.Getenv("GOGC") == "" {
		// The live heap is mostly fixed, pointer-free arenas; collect less often.
		debug.SetGCPercent(400)
	}
	pgcfg, err := pgconn.ParseConfig(dbURL)
	if err != nil {
		return errors.New("invalid DATABASE_URL")
	}
	pgcfg.ConnectTimeout = 3 * time.Second
	// These are session settings, not changes to PostgreSQL's fixed server config.
	planMode := envOr("PG_PLAN_MODE", "force_generic_plan")
	if planMode != "auto" && planMode != "force_generic_plan" && planMode != "force_custom_plan" {
		return errors.New("invalid PG_PLAN_MODE")
	}
	for k, v := range map[string]string{
		"application_name": "conduit-go-network", "statement_timeout": "5000", "lock_timeout": "2000",
		"idle_in_transaction_session_timeout": "6000", "TimeZone": "UTC", "plan_cache_mode": planMode,
		"jit": "off", "max_parallel_workers_per_gather": "0",
	} {
		pgcfg.RuntimeParams[k] = v
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	cfgHTTP, err := reactorConfigFromEnv(cores, inflight, queued, sockets, int(min(fdLimit.Cur, uint64(sockets)+reserve)))
	if err != nil {
		return err
	}
	var disp *dbDispatcher
	srv, err := newReactorServerWith(cfgHTTP, func(s *reactorServer) dispatcher {
		disp = newDBDispatcher(s, dbCfg, pgcfg, []byte(secret))
		return disp
	})
	if err != nil {
		return err
	}
	// The box's health check allows 60 s from start; keep trying for most of it.
	if err := disp.connectWithRetry(ctx, 50*time.Second); err != nil {
		return fmt.Errorf("database not ready: %w", err)
	}
	log.Printf("conduit transport=epoll listening=%s cores=%d pipeline_depth=%d read_conns=%d write_conns=%d read_queue=%d write_queue=%d read_batch=%d write_batch=%d write_linger=%s write_flush=%s bcrypt_workers=%d bcrypt_wait=%s connections=%d loops=%d",
		srv.Addr(), cores, dbCfg.pipelineDepth, dbCfg.readConns, dbCfg.writeConns, dbCfg.readQueue, dbCfg.writeQueue, dbCfg.readBatch, dbCfg.writeBatch,
		dbCfg.writeLinger, dbCfg.writeFlush, dbCfg.bcryptWorkers, dbCfg.bcryptWait, sockets, cfgHTTP.loops)
	return srv.Serve(ctx)
}
