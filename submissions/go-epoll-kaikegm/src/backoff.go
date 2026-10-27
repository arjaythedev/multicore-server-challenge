package main

import (
	"errors"
	"math/rand/v2"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

// backoff is a capped exponential delay between reconnect attempts. Each
// failure doubles it, from DB_RECONNECT_MIN up to DB_RECONNECT_MAX; a success
// resets it. The wait is randomised between half and all of the current delay,
// so many connections that broke together do not retry in lockstep against a
// PostgreSQL that is just coming back.
type backoff struct {
	min, max, cur time.Duration
	attempts      int
	since         time.Time // when the current outage began
}

// fail records a failed attempt and returns how long to wait before the next.
func (b *backoff) fail() time.Duration {
	if b.attempts == 0 {
		b.since = time.Now()
	}
	b.attempts++
	if b.cur == 0 {
		b.cur = b.min
	} else {
		b.cur = min(b.cur*2, b.max)
	}
	half := b.cur / 2
	return half + rand.N(half+1)
}

// reset ends an outage and returns how long it lasted and how many attempts failed.
func (b *backoff) reset() (time.Duration, int) {
	down, n := time.Duration(0), b.attempts
	if n > 0 {
		down = time.Since(b.since)
	}
	b.cur, b.attempts = 0, 0
	return down, n
}

// logWorthy limits reconnect logs to the 1st, 2nd, 4th, 8th... failure.
func (b *backoff) logWorthy() bool { return b.attempts&(b.attempts-1) == 0 }

// connectionLost reports whether err means the connection is gone, not just
// one statement failing: a network error, or the server ending the session
// (FATAL, e.g. 57P01 when PostgreSQL shuts down or restarts).
func connectionLost(pg *pgconn.PgConn, err error) bool {
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) {
		return true
	}
	return pgErr.Severity == "FATAL" || pgErr.Severity == "PANIC" || pg == nil || pg.IsClosed()
}

// neverRan reports whether a batch whose connection was lost certainly did not
// execute, so its writes can run again without risk of applying them twice:
// either pgx sent nothing, or the server ended the session before returning any
// statement result (a transaction is only committed after all its results).
func neverRan(err error, results int) bool {
	if pgconn.SafeToRetry(err) {
		return true
	}
	var pgErr *pgconn.PgError
	return results == 0 && errors.As(err, &pgErr) && (pgErr.Severity == "FATAL" || pgErr.Severity == "PANIC")
}
