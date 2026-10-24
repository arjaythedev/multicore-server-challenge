package main

import (
	"errors"
	"strings"
	"testing"
	"time"

	"conduit/src/internal/bcryptx"
	"github.com/golang-jwt/jwt/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"golang.org/x/crypto/bcrypt"
)

func TestBcryptLanesMatchReference(t *testing.T) {
	passwords := []string{"password123", "a\x00b", "é🙂", strings.Repeat("x", 72)}
	for lanes := 1; lanes <= 4; lanes++ {
		var worker bcryptx.Worker
		var requests []*bcryptx.Request
		for i := 0; i < lanes; i++ {
			hash, err := bcrypt.GenerateFromPassword([]byte(passwords[i]), 4)
			if err != nil {
				t.Fatal(err)
			}
			requests = append(requests, &bcryptx.Request{Password: []byte(passwords[i]), Hash: hash})
		}
		worker.Process(requests)
		for _, r := range requests {
			if !r.OK {
				t.Fatalf("%d-lane verify differed", lanes)
			}
		}
		for _, r := range requests {
			r.Password = []byte("wrong")
		}
		worker.Process(requests)
		for _, r := range requests {
			if r.OK {
				t.Fatal("accepted wrong password")
			}
		}
	}
	var worker bcryptx.Worker
	r := &bcryptx.Request{Password: []byte("new password"), Cost: 10}
	worker.Process([]*bcryptx.Request{r})
	if !r.OK || bcrypt.CompareHashAndPassword(r.Result[:], r.Password) != nil {
		t.Fatal("cost-10 hash incompatible")
	}
	if cost, err := bcrypt.Cost(r.Result[:]); err != nil || cost != 10 {
		t.Fatal("wrong bcrypt cost")
	}
}

func TestJWTOverflowAndFallback(t *testing.T) {
	c := newJWTCodec([]byte("test-secret"))
	for _, claims := range []jwt.MapClaims{
		{"sub": "1", "exp": int64(1) << 40},
		{"sub": "1", "exp": time.Now().Add(time.Hour).Unix()},
		{"sub": "1", "exp": time.Now().Add(-time.Hour).Unix()},
		{"sub": "1", "exp": int64(1) << 40, "nbf": int64(1) << 40},
		{"sub": 1, "exp": int64(1) << 40},
		{"sub": "1", "exp": int64(1) << 40, "extra": "claim"},
	} {
		token, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(c.secret)
		if err != nil {
			t.Fatal(err)
		}
		id, ok := c.verify([]byte(token))
		wantID, wantOK := c.slowVerify(token)
		if id != wantID || ok != wantOK {
			t.Fatalf("fast/library disagreement: %v", claims)
		}
	}
}

func TestUncertainWritesAreNeverReplayable(t *testing.T) {
	for _, err := range []error{errors.New("connection reset"), &pgconn.PgError{Severity: "FATAL", Code: "57P01"}, &pgconn.PgError{Severity: "PANIC"}} {
		if neverRan(err, 0) || neverRan(err, 1) {
			t.Fatalf("uncertain commit allowed replay: %v", err)
		}
	}
}

func FuzzJWTMatchesLibrary(f *testing.F) {
	c := newJWTCodec([]byte("fuzz-secret"))
	token, _ := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{"sub": "1", "exp": int64(1) << 40}).SignedString(c.secret)
	f.Add([]byte(token))
	f.Add([]byte("not.a.jwt"))
	f.Fuzz(func(t *testing.T, raw []byte) {
		codec := newJWTCodec(c.secret)
		id, ok := codec.verify(raw)
		wantID, wantOK := codec.slowVerify(string(raw))
		if ok != wantOK || ok && id != wantID {
			t.Fatal("JWT parser disagrees with library")
		}
	})
}
