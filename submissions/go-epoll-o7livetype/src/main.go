// Conduit (the RealWorld API) for the multicore server challenge, tuned for
// the most users per core.
//
// How a request flows through the files:
//
//	reactor_linux.go  An event loop reads the request from its socket, parses
//	                  it (wire_http.go) and queues it as a read or a write.
//	db.go             A database worker takes it in a batch, plans it, sends
//	                  the batch's statements in one pipeline and reads results.
//	api.go            plan (route, authenticate, validate, pick the statement)
//	                  and finish (write the JSON response from the rows).
//	db.go             Logins and new passwords go to the bcrypt workers first.
//	reactor_linux.go  The event loop writes the response to the socket.
//
// The rest: sql.go holds the statements, jsonw.go and jwt.go encode, util.go
// reads request bodies, backoff.go reconnects to PostgreSQL, and
// internal/bcryptx is the 4-lane bcrypt.
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

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

// run starts everything and blocks until SIGTERM (or a fatal error).
func run() error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// The reactor and the database dispatcher refer to each other: the reactor
	// queues requests on the dispatcher, and workers hand finished ones back.
	var disp *dbDispatcher
	srv, err := newReactorServerWith(cfg.http, func(s *reactorServer) dispatcher {
		disp = newDBDispatcher(s, cfg.db, cfg.pg, []byte(cfg.secret))
		return disp
	})
	if err != nil {
		return err
	}
	// Open every database connection before accepting traffic. The box's health
	// check allows 60 s from start; keep trying for most of it.
	if err := disp.connectWithRetry(ctx, 50*time.Second); err != nil {
		return fmt.Errorf("database not ready: %w", err)
	}
	logStartup(cfg, srv.Addr())
	return srv.Serve(ctx) // returns after SIGTERM, once in-flight requests finish
}

// ---------- configuration ----------

// config is everything read from the environment. Only DATABASE_URL and
// JWT_SECRET are required; every other setting has a measured default.
type config struct {
	secret  string
	cores   int
	sockets int // most open client connections
	http    reactorConfig
	db      dbConfig
	pg      *pgconn.Config
}

func loadConfig() (config, error) {
	var cfg config
	dbURL := os.Getenv("DATABASE_URL")
	cfg.secret = os.Getenv("JWT_SECRET")
	if dbURL == "" || cfg.secret == "" {
		return cfg, errors.New("DATABASE_URL and JWT_SECRET are required")
	}
	cfg.cores = runtime.GOMAXPROCS(0) // Go respects cgroup CPU quotas

	// Request slots: requests being worked on, plus requests waiting in queues.
	inflight, err := envInt("MAX_INFLIGHT", 4096, 1, 16384)
	if err != nil {
		return cfg, err
	}
	queued, err := envInt("MAX_QUEUED", 20480, 2, 65536)
	if err != nil {
		return cfg, err
	}
	sockets, err := envInt("MAX_CONNECTIONS", 1<<20, 16, 1<<20)
	if err != nil {
		return cfg, err
	}
	if cfg.db, err = dbConfigFromEnv(cfg.cores, inflight+queued); err != nil {
		return cfg, err
	}
	if os.Getenv("DB_POOL_SIZE") != "" {
		log.Printf("DB_POOL_SIZE is ignored; use DB_READ_CONNS and DB_WRITE_CONNS")
	}

	// Sockets: every file descriptor left after the database connections and a reserve.
	var fdLimit syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &fdLimit); err != nil {
		return cfg, err
	}
	reserve := uint64(cfg.db.readConns + cfg.db.writeConns + 256)
	if fdLimit.Cur <= reserve+16 {
		return cfg, errors.New("nofile is too low for the database and socket reserves")
	}
	cfg.sockets = int(min(uint64(sockets), fdLimit.Cur-reserve))
	fdSlots := int(min(fdLimit.Cur, uint64(cfg.sockets)+reserve))
	if cfg.http, err = reactorConfigFromEnv(cfg.cores, inflight, queued, cfg.sockets, fdSlots); err != nil {
		return cfg, err
	}

	if os.Getenv("GOMEMLIMIT") == "" {
		// A soft limit for the garbage collector, not a cap.
		debug.SetMemoryLimit(3 << 30)
	}
	if os.Getenv("GOGC") == "" {
		// The live heap is mostly fixed, pointer-free arenas; collect less often.
		debug.SetGCPercent(400)
	}

	cfg.pg, err = postgresConfig(dbURL)
	return cfg, err
}

// postgresConfig parses DATABASE_URL and adds session settings. These apply to
// our own connections only, not to PostgreSQL's fixed server configuration.
func postgresConfig(url string) (*pgconn.Config, error) {
	pg, err := pgconn.ParseConfig(url)
	if err != nil {
		return nil, errors.New("invalid DATABASE_URL")
	}
	pg.ConnectTimeout = 3 * time.Second
	planMode := envOr("PG_PLAN_MODE", "force_generic_plan")
	if planMode != "auto" && planMode != "force_generic_plan" && planMode != "force_custom_plan" {
		return nil, errors.New("invalid PG_PLAN_MODE")
	}
	settings := map[string]string{
		"application_name":                    "conduit-go-network",
		"statement_timeout":                   "5000",
		"lock_timeout":                        "2000",
		"idle_in_transaction_session_timeout": "6000",
		"TimeZone":                            "UTC",
		"plan_cache_mode":                     planMode, // plans are prepared once per connection
		"jit":                                 "off",    // short queries; JIT only adds latency
		"max_parallel_workers_per_gather":     "0",      // concurrency comes from many requests
	}
	for k, v := range settings {
		pg.RuntimeParams[k] = v
	}
	return pg, nil
}

func logStartup(cfg config, addr string) {
	db := cfg.db
	log.Printf("conduit transport=epoll listening=%s cores=%d loops=%d connections=%d", addr, cfg.cores, cfg.http.loops, cfg.sockets)
	log.Printf("database read_conns=%d write_conns=%d pipeline_depth=%d read_queue=%d write_queue=%d read_batch=%d write_batch=%d",
		db.readConns, db.writeConns, db.pipelineDepth, db.readQueue, db.writeQueue, db.readBatch, db.writeBatch)
	log.Printf("database write_linger=%s write_flush=%s bcrypt_workers=%d bcrypt_wait=%s",
		db.writeLinger, db.writeFlush, db.bcryptWorkers, db.bcryptWait)
}

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
