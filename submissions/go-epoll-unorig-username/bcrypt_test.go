package main

import (
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"
)

func init() { startBcrypt(1, 20*time.Millisecond) }

// Both ways against x/crypto/bcrypt, for every lane count, plus the seed's hash of "password123".
func TestBcrypt(t *testing.T) {
	seeded := "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq"
	if !passwordMatches(seeded, "password123") || passwordMatches(seeded, "password124") || passwordMatches("$2a$10$short", "x") {
		t.Fatal("seeded hash")
	}
	for n := 1; n <= 4; n++ {
		var wg sync.WaitGroup
		for i := range n {
			wg.Go(func() {
				pw := fmt.Sprint("pw", i, strings.Repeat("x", i*23)) // up to 72 bytes
				h, err := hashPassword(pw)
				if err != nil || bcrypt.CompareHashAndPassword([]byte(h), []byte(pw)) != nil {
					t.Error("x/crypto rejects", pw, h, err)
				}
				ref, _ := bcrypt.GenerateFromPassword([]byte(pw), 4+i)
				if !passwordMatches(string(ref), pw) || passwordMatches(string(ref), "!"+pw) {
					t.Error("rejects x/crypto", pw, string(ref))
				}
			})
		}
		wg.Wait()
	}
}

// go test -bench . -benchtime 8x: ns/op is wall time; cpu-ms/hash is the cost per hash with n lanes.
func BenchmarkBcrypt(b *testing.B) {
	salt := [16]byte{3}
	for _, n := range []int{0, 1, 4} {
		b.Run(fmt.Sprint("lanes=", n), func(b *testing.B) {
			for b.Loop() {
				if n == 0 {
					bcrypt.GenerateFromPassword([]byte("password123"), 10)
					continue
				}
				jobs := make([]*bcJob, n)
				for k := range jobs {
					jobs[k] = &bcJob{10, salt, []byte("password123\x00"), make(chan [24]byte, 1)}
				}
				eks(jobs)
			}
			b.ReportMetric(float64(b.Elapsed().Milliseconds())/float64(b.N*max(n, 1)), "ms/hash")
		})
	}
}
