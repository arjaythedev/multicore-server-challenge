// Command conduit serves the Conduit API on an epoll HTTP front, with every
// database access batched across requests.
package main

import (
	"log"
	"os"
	"os/signal"
	"runtime/debug"
	"strconv"
	"syscall"

	"multicorelab/http"
	"multicorelab/http/conduit"
)

func appendInt(dst []byte, n int64) []byte { return strconv.AppendInt(dst, n, 10) }

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	log.SetFlags(0)
	// Large heap headroom keeps the GC idle; the limit stays well under the
	// box's 16 GB next to Postgres's 4 GB of shared buffers.
	if os.Getenv("GOGC") == "" {
		debug.SetGCPercent(800)
	}
	if os.Getenv("GOMEMLIMIT") == "" {
		debug.SetMemoryLimit(5 << 30)
	}
	dsn := os.Getenv("DATABASE_URL")
	secret := os.Getenv("JWT_SECRET")
	if dsn == "" || secret == "" {
		log.Fatal("DATABASE_URL and JWT_SECRET are required")
	}
	db := newDB(envBool("CONDUIT_BATCH_SHARING", true))
	var front *conduit.Front
	srv, err := http.New(http.Config{
		Addr:       getenv("HOST", "0.0.0.0") + ":" + getenv("PORT", "3000"),
		Loops:      envInt("CONDUIT_HTTP_LOOPS", 1),
		OpsPerLoop: envInt("CONDUIT_HTTP_SLOTS", 4096),
		Wait:       waitMode(),
		Handler:    func(q *http.Request, r *http.Response) { front.Handle(q, r) },
		Batcher:    db,
	})
	if err != nil {
		log.Fatal(err)
	}
	front = conduit.New(srv.Ops(), []byte(secret))
	if err := db.init(front, srv.Ops(), dsn); err != nil {
		log.Fatal(err)
	}
	labStart(db, srv)
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sig
		srv.Close()
		labStop(srv)
	}()
	if err := srv.Serve(); err != nil {
		log.Fatal(err)
	}
}

func waitMode() http.Wait {
	if os.Getenv("CONDUIT_HTTP_WAIT") == "netpoll" {
		return http.WaitNetpoll
	}
	return http.WaitEpoll
}
