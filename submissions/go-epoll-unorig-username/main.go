package main

import (
	"log"
	"os"
	"runtime/debug"
	"strconv"
	"time"
)

func env(key string, def int) int {
	if v, err := strconv.Atoi(os.Getenv(key)); err == nil {
		return v
	}
	return def
}

func main() {
	secret = []byte(os.Getenv("JWT_SECRET"))
	host := os.Getenv("HOST")
	if host == "" {
		host = "0.0.0.0"
	}
	debug.SetGCPercent(env("GOGC", 400)) // the live heap is small; collect less often
	startBcrypt(env("BCRYPT_THREADS", 2), time.Duration(env("BCRYPT_WAIT_MS", 250))*time.Millisecond)
	startDB(os.Getenv("DATABASE_URL"), env("DB_READ_CONNS", 10), env("DB_WRITE_CONNS", 6),
		time.Duration(env("READ_WAIT_US", 20000))*time.Microsecond, env("READ_CROSS", 1) == 1, env("READ_BATCH_MAX", 0))
	port := env("PORT", 3000)
	for range env("LOOPS", 4) {
		go newLoop(host, port).run()
	}
	log.Printf("listening on %s:%d", host, port)
	select {}
}
