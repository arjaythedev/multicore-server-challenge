package main

import (
	"context"
	"log"
	"net/netip"
	"os"
	"runtime"
	"runtime/debug"
	"strconv"
	"time"

	"conduit/bcrypt4"
)

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envInt(key string, def int) int {
	if v, err := strconv.Atoi(os.Getenv(key)); err == nil {
		return v
	}
	return def
}

func main() {
	if env("SCHED_BATCH", "1") == "1" {
		if err := batchSched(); err != nil {
			log.Print("SCHED_BATCH: ", err)
		}
	}
	debug.SetGCPercent(envInt("GOGC_PERCENT", 400))
	debug.SetMemoryLimit(int64(envInt("MEMORY_LIMIT_MB", 4096)) << 20)

	hasher = bcrypt4.New(envInt("BCRYPT_WORKERS", 3), time.Duration(envInt("BCRYPT_WAIT_MS", 50))*time.Millisecond,
		time.Duration(envInt("BCRYPT_SHED_MS", 5000))*time.Millisecond)
	jwt = newSigner(env("JWT_SECRET", "dev-secret"))
	s, err := newStore(context.Background(), os.Getenv("DATABASE_URL"), envInt("DB_FAST", 2), envInt("DB_READERS", 8), envInt("DB_WRITERS", 4),
		time.Duration(envInt("DB_GAP_US", 10000))*time.Microsecond)
	if err != nil {
		log.Fatal(err)
	}
	host := env("HOST", "0.0.0.0")
	if host == "localhost" {
		host = "127.0.0.1"
	}
	addr, err := netip.ParseAddrPort(host + ":" + env("PORT", "3000"))
	if err != nil {
		log.Fatal(err)
	}
	api := &Api{PublicApi: PublicApi{s: s}, AuthApi: AuthApi{s: s}}
	log.Printf("listening on %s", addr)
	log.Fatal(serve(addr, envInt("LOOPS", runtime.NumCPU()), api))
}
