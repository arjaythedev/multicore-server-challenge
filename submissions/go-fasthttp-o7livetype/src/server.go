package main

import (
	"errors"
	"fmt"
	"log/slog"
	"runtime/debug"
	"sync"
	"time"

	"github.com/valyala/fasthttp"
	"golang.org/x/crypto/bcrypt"
)

const bcryptCost = 10

// job is one request's state while its handler goroutine waits for a database
// worker. Jobs are pooled; their response and parameter buffers are reused.
type job struct {
	req      request
	db       dbJob
	status   int
	resp     []byte
	done     chan struct{}
	enqueued time.Time
}

type server struct {
	d      *dbDispatcher
	jwt    *jwtCodec
	bcrypt chan struct{} // bounds concurrent bcrypt work to protect database CPU
	wait   time.Duration
	pool   sync.Pool
	log    *logConfig
}

func newServer(d *dbDispatcher, codec *jwtCodec, bcryptWorkers int, bcryptWait time.Duration, lc *logConfig) *server {
	s := &server{d: d, jwt: codec, bcrypt: make(chan struct{}, bcryptWorkers), wait: bcryptWait, log: lc}
	s.pool.New = func() any { return &job{done: make(chan struct{}, 1)} }
	return s
}

// handle plans the request on this goroutine (routing, auth, validation and
// parameter encoding), hands database work to the read or write queue, and
// writes the JSON the worker produced from the result rows.
func (s *server) handle(ctx *fasthttp.RequestCtx) {
	start := time.Now()
	j := s.pool.Get().(*job)
	j.db.reset()
	j.status, j.resp = 0, nil
	auth := ctx.Request.Header.PeekAll(fasthttp.HeaderAuthorization)
	j.req = request{method: bstr(ctx.Method()), path: bstr(ctx.URI().PathOriginal()), body: ctx.PostBody(), args: ctx.QueryArgs(), authCount: len(auth)}
	if len(auth) > 0 {
		j.req.authHeader = auth[0]
	}
	s.run(j)
	ctx.SetStatusCode(j.status)
	ctx.SetContentType("application/json")
	if j.status != fasthttp.StatusNoContent {
		ctx.SetBody(j.resp) // copies; the job's buffer goes back to the pool
	}
	elapsed := time.Since(start)
	stats.observe(j.status, elapsed)
	logRequest(s.log, ctx.ID(), j.req.method, j.req.path, j.db.route, j.status, elapsed)
	j.req, j.resp = request{}, nil
	s.pool.Put(j)
}

func (s *server) run(j *job) {
	defer func() {
		if p := recover(); p != nil {
			stats.panics.Add(1)
			slog.Error("panic in request handler", "route", j.db.route.String(), "panic", fmt.Sprint(p), "stack", string(debug.Stack()))
			respond(j, 500, errInternal)
		}
	}()
	act := s.plan(j)
	for act != actDone {
		switch act {
		case actQuery:
			if !s.d.submit(j) {
				respond(j, 503, errBusy) // queue full: shed load instead of growing latency
				return
			}
			<-j.done
			act = j.db.next
		case actHash:
			release := s.acquireBcrypt()
			h, err := bcrypt.GenerateFromPassword(sbytes(j.db.str[2]), bcryptCost)
			release()
			if errors.Is(err, bcrypt.ErrPasswordTooLong) {
				respond(j, 422, errPasswordLong)
				return
			}
			if err != nil {
				slog.Error("bcrypt hash failed", "route", j.db.route.String(), "err", err)
				respond(j, 500, errInternal)
				return
			}
			j.db.hashLen = copy(j.db.hash[:], h)
			j.db.stage = 1
			act = s.plan(j)
		case actVerify:
			release := s.acquireBcrypt()
			err := bcrypt.CompareHashAndPassword(j.db.hash[:j.db.hashLen], sbytes(j.db.str[1]))
			release()
			if err != nil && !errors.Is(err, bcrypt.ErrMismatchedHashAndPassword) {
				// A stored hash this server cannot read: fail closed, but say why.
				slog.Error("stored password hash is unreadable", "user_id", j.db.userID, "err", err)
			}
			completeLogin(s.jwt, j, err == nil)
			return
		}
	}
}

// acquireBcrypt takes one of the BCRYPT_WORKERS slots. Normally that bounds how
// much CPU logins can take from PostgreSQL. When logins arrive faster than the
// slots can serve them, a login that has waited BCRYPT_WAIT hashes anyway: the
// limit stretches with the backlog, so logins get slower under load instead of
// queueing until the client gives up.
func (s *server) acquireBcrypt() (release func()) {
	select {
	case s.bcrypt <- struct{}{}:
		return s.releaseBcrypt
	default:
	}
	t := time.NewTimer(s.wait)
	defer t.Stop()
	select {
	case s.bcrypt <- struct{}{}:
		return s.releaseBcrypt
	case <-t.C:
		stats.bcryptOverflow.Add(1)
		return func() {}
	}
}

func (s *server) releaseBcrypt() { <-s.bcrypt }

// errorHandler answers requests fasthttp could not parse (malformed HTTP, a
// body over the size limit). They never reach the handler.
func errorHandler(ctx *fasthttp.RequestCtx, err error) {
	status := fasthttp.StatusBadRequest
	if errors.Is(err, fasthttp.ErrBodyTooLarge) {
		status = fasthttp.StatusRequestEntityTooLarge
	}
	stats.observe(status, 0)
	slog.Debug("malformed request", "remote", ctx.RemoteAddr().String(), "status", status, "err", err)
	ctx.SetStatusCode(status)
	ctx.SetContentType("application/json")
	ctx.SetBody(errBadRequest)
}
