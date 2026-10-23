package main

import (
	"bytes"
	"crypto/rand"
	"fmt"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"
)

func TestBcryptMatchesXCrypto(t *testing.T) {
	pool := newBcryptPool(2, 4, 5*time.Millisecond)
	for _, cost := range []int{4, 6, 10} {
		for n := 1; n <= 4; n++ {
			// n passwords hashed together with our lanes must each verify under x/crypto, and
			// x/crypto hashes must verify under ours.
			jobs := make([]*bcryptJob, n)
			pws := make([][]byte, n)
			for i := range jobs {
				l := 1 + i*17
				if cost == 10 {
					l = 72
				}
				pw := make([]byte, l)
				rand.Read(pw)
				pws[i] = pw
				jobs[i] = &bcryptJob{password: pw, cost: uint32(cost)}
				rand.Read(jobs[i].salt[:])
			}
			bcryptLanes(jobs)
			for i, j := range jobs {
				h := append([]byte{}, fmt.Sprintf("$2a$%02d$", cost)...)
				h = bcEncoding.AppendEncode(h, j.salt[:])
				h = bcEncoding.AppendEncode(h, j.out[:])
				if err := bcrypt.CompareHashAndPassword(h, pws[i]); err != nil {
					t.Fatalf("cost %d, %d lanes, lane %d: x/crypto rejects our hash %s: %v", cost, n, i, h, err)
				}
				if !pool.verify(h, pws[i]) {
					t.Fatalf("cost %d, %d lanes, lane %d: we reject our own hash", cost, n, i)
				}
				if pool.verify(h, append(pws[i][:len(pws[i]):len(pws[i])], 'x')) {
					t.Fatalf("cost %d: wrong password accepted", cost)
				}
			}
			if cost == 10 {
				continue
			}
			ref, _ := bcrypt.GenerateFromPassword(pws[0], cost)
			if !pool.verify(ref, pws[0]) {
				t.Fatalf("cost %d: we reject an x/crypto hash %s", cost, ref)
			}
		}
	}
	// Seed-style hash.
	ref, _ := bcrypt.GenerateFromPassword([]byte("password123"), 10)
	if !pool.verify(ref, []byte("password123")) {
		t.Fatal("cost-10 x/crypto hash rejected")
	}
	ours, err := pool.hash([]byte("password123"), 10)
	if err != nil || bcrypt.CompareHashAndPassword(ours, []byte("password123")) != nil {
		t.Fatalf("our cost-10 hash %s rejected by x/crypto: %v", ours, err)
	}
	if !bytes.HasPrefix(ours, []byte("$2a$10$")) || len(ours) != 60 {
		t.Fatalf("bad hash format %s", ours)
	}
}

func benchLanes(b *testing.B, n int) {
	jobs := make([]*bcryptJob, n)
	for i := range jobs {
		jobs[i] = &bcryptJob{password: []byte("password123"), cost: 10}
		rand.Read(jobs[i].salt[:])
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		bcryptLanes(jobs)
	}
	b.ReportMetric(float64(b.Elapsed().Nanoseconds())/float64(b.N)/float64(n)/1e6, "ms/hash")
}

func BenchmarkLanes1(b *testing.B) { benchLanes(b, 1) }
func BenchmarkLanes2(b *testing.B) { benchLanes(b, 2) }
func BenchmarkLanes3(b *testing.B) { benchLanes(b, 3) }
func BenchmarkLanes4(b *testing.B) { benchLanes(b, 4) }
func BenchmarkXCrypto(b *testing.B) {
	h, _ := bcrypt.GenerateFromPassword([]byte("password123"), 10)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		bcrypt.CompareHashAndPassword(h, []byte("password123"))
	}
	b.ReportMetric(float64(b.Elapsed().Nanoseconds())/float64(b.N)/1e6, "ms/hash")
}

// TestPoolBatches checks that jobs arriving together share one interleaved run.
func TestPoolBatches(t *testing.T) {
	pool := newBcryptPool(2, 4, 30*time.Millisecond)
	h, err := pool.hash([]byte("pw"), 4)
	if err != nil {
		t.Fatal(err)
	}
	pool.runs.Store(0)
	done := make(chan bool, 4)
	for i := 0; i < 4; i++ {
		go func() { done <- pool.verify(h, []byte("pw")) }()
	}
	for i := 0; i < 4; i++ {
		if !<-done {
			t.Fatal("verify failed")
		}
	}
	if n := pool.runs.Load(); n != 1 {
		t.Fatalf("4 concurrent jobs took %d runs, want 1", n)
	}
}
