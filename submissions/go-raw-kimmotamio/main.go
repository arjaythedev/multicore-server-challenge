// Command conduit is a Go implementation of the RealWorld "Conduit" API for the multicore server
// challenge: its own HTTP/1.1 server, batched reads and group-committed writes on pgconn.
package main

import (
	"log"
	"net"
	"net/http"
	_ "net/http/pprof"
	"os"
	"runtime"
	"runtime/debug"
	"strconv"
	"time"
)

func envOr(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func envInt(name string, fallback int) int {
	if v := os.Getenv(name); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 {
			log.Fatalf("%s must be a positive integer, got %q", name, v)
		}
		return n
	}
	return fallback
}

func main() {
	dbURL := os.Getenv("DATABASE_URL")
	secret := os.Getenv("JWT_SECRET")
	if dbURL == "" || secret == "" {
		log.Fatal("DATABASE_URL and JWT_SECRET are required")
	}
	if os.Getenv("DUMP_SQL") != "" {
		for k := kind(0); k < nReadKinds; k++ {
			os.Stdout.WriteString("-- read kind " + strconv.Itoa(int(k)) + "\n" + readSpecs[k].sql + ";\n\n")
		}
		for s := wstmt(0); s < nWriteStmts; s++ {
			os.Stdout.WriteString("-- write stmt " + strconv.Itoa(int(s)) + "\n" + writeSpecs[s].sql + ";\n\n")
		}
		return
	}
	cores := runtime.GOMAXPROCS(0)
	nRead := envInt("DB_READ_CONNS", 12)
	nWrite := envInt("DB_WRITE_CONNS", 4)
	readBatch := envInt("READ_BATCH", 64)
	readKindInflight := envInt("READ_KIND_INFLIGHT", max(2, nRead/2))
	writeBatch := envInt("WRITE_BATCH", 128)
	bcryptThreads := envInt("BCRYPT_THREADS", max(2, cores/2))
	bcryptLanes := envInt("BCRYPT_LANES", map[bool]int{true: 2, false: 4}[runtime.GOARCH == "arm64"])
	bcryptWait := time.Duration(envInt("BCRYPT_BATCH_MS", 50)) * time.Millisecond
	if os.Getenv("GOGC") == "" {
		debug.SetGCPercent(200)
	}

	if addr := os.Getenv("PPROF_ADDR"); addr != "" {
		go func() { log.Println(http.ListenAndServe(addr, nil)) }()
	}
	d := &db{url: dbURL, reads: newReadSched(readBatch, readKindInflight), writes: newWriteSched(writeBatch)}
	d.start(nRead, nWrite)

	a := &app{db: d, sig: &signer{secret: []byte(secret)}, bc: newBcryptPool(bcryptThreads, min(bcryptLanes, 4), bcryptWait)}
	addr := net.JoinHostPort(envOr("HOST", "127.0.0.1"), envOr("PORT", "3000"))
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("conduit listening on %s: %d read + %d write connections, read batch %d, write batch %d, bcrypt %d threads x %d lanes, GOMAXPROCS %d",
		addr, nRead, nWrite, readBatch, writeBatch, bcryptThreads, bcryptLanes, cores)
	s := &server{app: a}
	log.Fatal(s.serve(ln))
}
