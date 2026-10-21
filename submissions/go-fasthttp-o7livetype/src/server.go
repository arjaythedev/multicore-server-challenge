package main

// server.go is the HTTP side: fasthttp calls handle on the connection's
// goroutine, which runs the request through its steps (see api.go) and sends
// the response.

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

// job is one request in flight. Jobs are pooled, so their buffers are reused.
type job struct {
	req      request
	db       dbJob
	status   int
	resp     []byte
	done     chan struct{} // a database worker signals here when the statement is done
	enqueued time.Time     // when it joined a database queue
}

type server struct {
	d      *dbDispatcher
	jwt    *jwtCodec
	bcrypt chan struct{} // slots bounding concurrent bcrypt work (see acquireBcrypt)
	wait   time.Duration // BCRYPT_WAIT
	pool   sync.Pool
	log    *logConfig
}

func newServer(d *dbDispatcher, codec *jwtCodec, bcryptWorkers int, bcryptWait time.Duration, lc *logConfig) *server {
	s := &server{d: d, jwt: codec, bcrypt: make(chan struct{}, bcryptWorkers), wait: bcryptWait, log: lc}
	s.pool.New = func() any { return &job{done: make(chan struct{}, 1)} }
	return s
}

// handle serves one request: copy what it needs from fasthttp, run it, send
// the response, log it.
func (s *server) handle(ctx *fasthttp.RequestCtx) {
	start := time.Now()
	j := s.pool.Get().(*job)
	j.db.reset()
	j.status, j.resp = 0, nil

	auth := ctx.Request.Header.PeekAll(fasthttp.HeaderAuthorization)
	j.req = request{
		method:    bstr(ctx.Method()),
		path:      bstr(ctx.URI().PathOriginal()),
		body:      ctx.PostBody(),
		args:      ctx.QueryArgs(),
		authCount: len(auth),
	}
	if len(auth) > 0 {
		j.req.authHeader = auth[0]
	}

	s.run(j)

	ctx.SetStatusCode(j.status)
	ctx.SetContentType("application/json")
	if j.status != fasthttp.StatusNoContent {
		ctx.SetBody(j.resp) // copies, so the job's buffer can go back to the pool
	}
	elapsed := time.Since(start)
	stats.observe(j.status, elapsed)
	logRequest(s.log, ctx.ID(), j.req.method, j.req.path, j.db.route, j.status, elapsed)
	j.req, j.resp = request{}, nil
	s.pool.Put(j)
}

// run takes the request through its steps until the response is ready:
// plan, then (as plan and finish decide) query, hash or verify.
func (s *server) run(j *job) {
	defer func() {
		if p := recover(); p != nil {
			stats.panics.Add(1)
			slog.Error("panic in request handler", "route", j.db.route.String(),
				"panic", fmt.Sprint(p), "stack", string(debug.Stack()))
			respond(j, 500, errInternal)
		}
	}()
	act := s.plan(j)
	for act != actDone {
		switch act {
		case actQuery:
			act = s.query(j)
		case actHash:
			act = s.hashPassword(j)
		case actVerify:
			s.verifyPassword(j)
			act = actDone
		}
	}
}

// query hands the planned statement to a database worker and waits for it.
func (s *server) query(j *job) action {
	if !s.d.submit(j) {
		return respond(j, 503, errBusy)
	}
	<-j.done
	return j.db.next
}

// hashPassword hashes a new password (register, update-user), then plans the
// route again to build its statement.
func (s *server) hashPassword(j *job) action {
	release := s.acquireBcrypt()
	h, err := bcrypt.GenerateFromPassword(sbytes(*j.db.in.password), bcryptCost)
	release()
	if errors.Is(err, bcrypt.ErrPasswordTooLong) {
		return respond(j, 422, errPasswordLong)
	}
	if err != nil {
		slog.Error("bcrypt hash failed", "route", j.db.route.String(), "err", err)
		return respond(j, 500, errInternal)
	}
	j.db.hashLen = copy(j.db.hash[:], h)
	j.db.hashed = true
	return s.plan(j)
}

// verifyPassword checks a login password against the stored hash and responds.
func (s *server) verifyPassword(j *job) {
	release := s.acquireBcrypt()
	err := bcrypt.CompareHashAndPassword(j.db.hash[:j.db.hashLen], sbytes(*j.db.in.password))
	release()
	if err != nil && !errors.Is(err, bcrypt.ErrMismatchedHashAndPassword) {
		// A stored hash this server cannot read: fail closed, but say why.
		slog.Error("stored password hash is unreadable", "user_id", j.db.userID, "err", err)
	}
	completeLogin(s.jwt, j, err == nil)
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
// body over the size limit). They never reach handle.
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
