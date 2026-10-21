// Conduit (the RealWorld API) for the multicore server challenge, on fasthttp
// and PostgreSQL.
//
// How a request flows through the files:
//
//	server.go  fasthttp calls handle on the connection's goroutine.
//	api.go     plan: route, authenticate, validate, pick the prepared statement.
//	db.go      a database worker batches the statement with others and runs it.
//	api.go     finish: the worker writes the JSON response from the result rows.
//	server.go  the handler sends the response (after bcrypt, for logins).
//
// The rest: sql.go holds the statements, jsonw.go and jwt.go encode, validate.go
// checks input, observe.go logs, backoff.go reconnects to PostgreSQL.
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

func main() {
	if err := run(); err != nil {
		slog.Error("server stopped", "err", err)
		os.Exit(1)
	}
	slog.Info("server stopped cleanly")
}

// run starts everything and blocks until SIGTERM (or a fatal error).
func run() error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// 1. Database: open every connection before accepting traffic.
	codec := newJWTCodec([]byte(cfg.secret))
	disp := newDBDispatcher(cfg.db, cfg.pg, codec)
	slog.Info("connecting to database", "host", cfg.pg.Host, "port", cfg.pg.Port,
		"database", cfg.pg.Database, "connections", cfg.db.readConns+cfg.db.writeConns)
	// The box's health check allows 60 s from start; keep trying for most of it.
	if err := disp.connectWithRetry(ctx, 50*time.Second); err != nil {
		return fmt.Errorf("database not ready: %w", err)
	}
	disp.start()

	// 2. HTTP.
	app := newServer(disp, codec, cfg.db.bcryptWorkers, cfg.db.bcryptWait, &cfg.log)
	srv := newHTTPServer(app, cfg.sockets)
	ln, err := net.Listen("tcp", cfg.addr)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", cfg.addr, err)
	}
	logStartup(cfg, ln.Addr().String())
	go reportStats(ctx, cfg.log.stats, disp)

	served := make(chan error, 1)
	go func() { served <- srv.Serve(ln) }()
	select {
	case err = <-served:
		return fmt.Errorf("http server: %w", err)
	case <-ctx.Done():
	}

	// 3. Shutdown: stop accepting, finish in-flight requests, then close the database.
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

func newHTTPServer(app *server, sockets int) *fasthttp.Server {
	return &fasthttp.Server{
		Handler:               app.handle,
		ErrorHandler:          errorHandler,
		Concurrency:           sockets,
		MaxRequestBodySize:    1 << 20,
		ReadBufferSize:        16 << 10,
		WriteBufferSize:       16 << 10,
		ReadTimeout:           15 * time.Second,
		WriteTimeout:          15 * time.Second,
		IdleTimeout:           75 * time.Second, // longer than Nginx's 60 s upstream keep-alive
		ReduceMemoryUsage:     true,             // idle keep-alive connections release their buffers
		NoDefaultServerHeader: true,
		CloseOnShutdown:       true,
	}
}

// ---------- configuration ----------

// config is everything read from the environment. Only DATABASE_URL and
// JWT_SECRET are required; every other setting has a measured default.
type config struct {
	secret  string
	addr    string // HOST:PORT
	cores   int
	sockets int // most open client connections
	db      dbConfig
	pg      *pgconn.Config
	log     logConfig
}

func loadConfig() (config, error) {
	var cfg config
	var err error
	if cfg.log, err = setupLogging(); err != nil {
		return cfg, err
	}
	warnLog.n = cfg.log.burst

	dbURL := os.Getenv("DATABASE_URL")
	cfg.secret = os.Getenv("JWT_SECRET")
	if dbURL == "" || cfg.secret == "" {
		return cfg, errors.New("DATABASE_URL and JWT_SECRET are required")
	}
	host, port := envOr("HOST", "0.0.0.0"), envOr("PORT", "3000")
	if p, err := strconv.Atoi(port); err != nil || p < 1 || p > 65535 {
		return cfg, fmt.Errorf("PORT must be a number between 1 and 65535, got %q", port)
	}
	cfg.addr = net.JoinHostPort(host, port)

	cfg.cores = runtime.GOMAXPROCS(0) // Go respects cgroup CPU quotas
	if cfg.db, err = dbConfigFromEnv(cfg.cores); err != nil {
		return cfg, err
	}

	// Sockets: every file descriptor left after the database connections and a reserve.
	var fdLimit syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &fdLimit); err != nil {
		return cfg, err
	}
	reserve := uint64(cfg.db.readConns + cfg.db.writeConns + 256)
	if fdLimit.Cur <= reserve+16 {
		return cfg, fmt.Errorf("open file limit %d is too low: need more than %d", fdLimit.Cur, reserve+16)
	}
	sockets, err := envInt("MAX_CONNECTIONS", 1<<20, 16, 1<<20)
	if err != nil {
		return cfg, err
	}
	cfg.sockets = int(min(uint64(sockets), fdLimit.Cur-reserve))

	// One queue slot per possible connection: each connection has at most one
	// request in flight, so a queue can never fill up. Overload shows up as
	// latency, not 503s.
	queued, err := envInt("MAX_QUEUED", cfg.sockets, 2, 1<<20)
	if err != nil {
		return cfg, err
	}
	cfg.db.readQueue, cfg.db.writeQueue = queued, queued

	if os.Getenv("GOMEMLIMIT") == "" {
		// A soft limit for the garbage collector, not a cap. fasthttp parks one
		// goroutine per open connection; leave room for their stacks.
		debug.SetMemoryLimit(6 << 30)
	}
	if os.Getenv("GOGC") == "" {
		debug.SetGCPercent(200)
	}

	cfg.pg, err = postgresConfig(dbURL)
	return cfg, err
}

// postgresConfig parses DATABASE_URL and adds session settings. These apply to
// our own connections only, not to PostgreSQL's fixed server configuration.
func postgresConfig(url string) (*pgconn.Config, error) {
	pg, err := pgconn.ParseConfig(url)
	if err != nil {
		return nil, errors.New("DATABASE_URL is not a valid PostgreSQL connection string")
	}
	pg.ConnectTimeout = 3 * time.Second
	planMode := envOr("PG_PLAN_MODE", "force_generic_plan")
	if planMode != "auto" && planMode != "force_generic_plan" && planMode != "force_custom_plan" {
		return nil, errors.New("PG_PLAN_MODE must be auto, force_generic_plan or force_custom_plan")
	}
	settings := map[string]string{
		"application_name":                    "conduit-go-fasthttp",
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
	slog.Info("listening", "addr", addr, "cores", cfg.cores,
		"read_conns", db.readConns, "write_conns", db.writeConns,
		"read_queue", db.readQueue, "write_queue", db.writeQueue,
		"read_batch", db.readBatch, "write_batch", db.writeBatch,
		"write_linger", db.writeLinger.String(), "write_flush", db.writeFlush.String(),
		"bcrypt_workers", db.bcryptWorkers, "max_sockets", cfg.sockets,
		"go_memory_limit_mb", debug.SetMemoryLimit(-1)>>20,
		"access_log", cfg.log.access, "slow_request", cfg.log.slow.String(),
		"stats_interval", cfg.log.stats.String())
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
