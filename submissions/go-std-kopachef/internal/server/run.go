// Package server implements the RealWorld "Conduit" API for the
// multicore server challenge (see SPEC.md).
//
// Standard library net/http with Go 1.22+ pattern routing, encoding/json, pgx/v5 (pgxpool),
// golang.org/x/crypto/bcrypt and standard-library HS256.
package server

import (
	"context"
	"errors"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"conduit/internal/auth"

	"github.com/jackc/pgx/v5/pgxpool"
)

func envOr(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

// Run starts the configured server and waits for shutdown.
func Run() {
	if mode := envOr("HTTP_RESPONSE_BUFFER", "vector"); mode != "vector" && mode != "prefix" {
		log.Fatal("HTTP_RESPONSE_BUFFER must be vector or prefix")
	}
	if mode := envOr("HTTP_HOT_PATH", "0"); mode != "0" && mode != "1" {
		log.Fatal("HTTP_HOT_PATH must be 0 or 1")
	}
	if server := envOr("HTTP_SERVER", "compact"); server != "standard" && server != "compact" {
		log.Fatal("HTTP_SERVER must be standard or compact")
	}
	if responseEncoding != "direct" && responseEncoding != "standard" {
		log.Fatal("JSON_ENCODING must be direct or standard")
	}
	if requestDecoding != "stream" && requestDecoding != "standard" {
		log.Fatal("JSON_DECODING must be stream or standard")
	}
	if compactContextParent != "server" && compactContextParent != "connection" && compactContextParent != "sharded" {
		log.Fatal("HTTP_CONTEXT_PARENT must be server, connection or sharded")
	}
	dbURL := os.Getenv("DATABASE_URL")
	secret := os.Getenv("JWT_SECRET")
	if dbURL == "" || secret == "" {
		log.Fatal("DATABASE_URL and JWT_SECRET are required")
	}
	poolSize, err := strconv.Atoi(envOr("DB_POOL_SIZE", "24"))
	if err != nil || poolSize <= 0 {
		log.Fatalf("DB_POOL_SIZE must be a positive integer, got %q", os.Getenv("DB_POOL_SIZE"))
	}

	poolCfg, err := pgxpool.ParseConfig(dbURL)
	if err != nil {
		log.Fatalf("parse DATABASE_URL: %v", err)
	}
	poolCfg.MaxConns = int32(poolSize)
	// Small repeated queries benefit from prepared generic plans. Avoid JIT
	// compilation when a generic plan overestimates these small result sets.
	for key, value := range map[string]string{"plan_cache_mode": "force_generic_plan", "jit": "off"} {
		if _, supplied := poolCfg.ConnConfig.RuntimeParams[key]; !supplied {
			poolCfg.ConnConfig.RuntimeParams[key] = value
		}
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	pool, err := pgxpool.NewWithConfig(ctx, poolCfg)
	if err != nil {
		log.Fatalf("create pool: %v", err)
	}
	defer pool.Close()

	a := &app{pool: pool, tokens: auth.NewSigner([]byte(secret))}
	if envOr("WRITE_BATCHING", "0") == "1" {
		workers, err := strconv.Atoi(envOr("WRITE_WORKERS", "2"))
		if err != nil || workers < 1 || workers > 8 {
			log.Fatal("WRITE_WORKERS must be between 1 and 8")
		}
		wait, err := strconv.Atoi(envOr("WRITE_BATCH_WAIT_US", "2000"))
		if err != nil || wait < 0 || wait > 5000 {
			log.Fatal("WRITE_BATCH_WAIT_US must be between 0 and 5000")
		}
		a.writes = newWriteQueueConfig(pool, time.Duration(wait)*time.Microsecond, workers)
		defer a.writes.close()
	}

	if envOr("BCRYPT_BATCHING", "1") != "0" {
		workers, err := strconv.Atoi(envOr("BCRYPT_WORKERS", "4"))
		if err != nil || workers < 1 || workers > 16 {
			log.Fatal("BCRYPT_WORKERS must be between 1 and 16")
		}
		waitUS, err := strconv.Atoi(envOr("BCRYPT_BATCH_WAIT_US", strconv.Itoa(defaultPasswordBatchWaitUS)))
		if err != nil || waitUS < 0 || waitUS > 200_000 {
			log.Fatal("BCRYPT_BATCH_WAIT_US must be between 0 and 200000")
		}
		batchSize, err := strconv.Atoi(envOr("BCRYPT_BATCH_SIZE", strconv.Itoa(defaultPasswordBatchSize)))
		if err != nil || batchSize < 1 || batchSize > maxPasswordBatchSize {
			log.Fatal("BCRYPT_BATCH_SIZE must be between 1 and 5")
		}
		a.passwords = newPasswordQueueConfig(workers, time.Duration(waitUS)*time.Microsecond, batchSize)
		defer a.passwords.close()
	}
	if envOr("READ_BATCHING", "1") != "0" {
		workers, err := strconv.Atoi(envOr("READ_WORKERS", strconv.Itoa(defaultReadWorkers)))
		if err != nil || workers < 1 || workers > 16 {
			log.Fatal("READ_WORKERS must be between 1 and 16")
		}
		batchSize, err := strconv.Atoi(envOr("READ_BATCH_SIZE", strconv.Itoa(defaultReadBatchSize)))
		if err != nil || batchSize < 1 || batchSize > maxReadBatchSize {
			log.Fatal("READ_BATCH_SIZE must be between 1 and 2048")
		}
		queueSize, err := strconv.Atoi(envOr("READ_QUEUE_SIZE", strconv.Itoa(defaultReadQueueSize)))
		if err != nil || queueSize < 1 || queueSize > 65536 {
			log.Fatal("READ_QUEUE_SIZE must be between 1 and 65536")
		}
		waitUS, err := strconv.Atoi(envOr("READ_BATCH_WAIT_US", strconv.Itoa(defaultReadBatchWaitUS)))
		if err != nil || waitUS < 0 || waitUS > 50_000 {
			log.Fatal("READ_BATCH_WAIT_US must be between 0 and 50000")
		}
		a.reads = newReadQueueConfig(pool, time.Duration(waitUS)*time.Microsecond, batchSize, workers, queueSize)
		defer a.reads.close()
	}
	srv := &http.Server{
		Addr:    net.JoinHostPort(envOr("HOST", "127.0.0.1"), envOr("PORT", "3000")),
		Handler: a.routes(),
		// Outlive Nginx's upstream keep-alive (series rule 7).
		IdleTimeout:       75 * time.Second,
		ReadHeaderTimeout: 10 * time.Second,
	}

	done := make(chan struct{})
	go func() {
		defer close(done)
		<-ctx.Done()
		sctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(sctx)
	}()

	log.Printf("conduit (go) listening on http://%s, pool %d", srv.Addr, poolSize)
	serve := srv.ListenAndServe
	if envOr("HTTP_SERVER", "compact") == "compact" {
		serve = func() error { return serveCompactHTTP(ctx, srv.Addr, srv.Handler) }
	}
	if err := serve(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
	<-done
}
