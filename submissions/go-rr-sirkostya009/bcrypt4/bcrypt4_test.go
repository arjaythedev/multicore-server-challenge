package bcrypt4

import (
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"
)

func TestMatchesXCrypto(t *testing.T) {
	h := New(2, time.Millisecond, 0)
	pws := []string{"", "a", "password123", "pässwörd", string(make([]byte, 71)), "0123456789012345678901234567890123456789012345678901234567890123456789ab"}
	var wg sync.WaitGroup
	for _, pw := range pws {
		for _, cost := range []int{4, 5} {
			wg.Go(func() {
				ref, err := bcrypt.GenerateFromPassword([]byte(pw), cost)
				if err != nil {
					t.Error(err)
					return
				}
				if err := h.Compare(string(ref), []byte(pw)); err != nil {
					t.Errorf("%q cost %d: x/crypto hash rejected: %v", pw, cost, err)
				}
				if err := h.Compare(string(ref), []byte(pw+"x")); len(pw) < maxKey && err != ErrMismatch {
					t.Errorf("%q cost %d: wrong password: %v", pw, cost, err)
				}
				mine, err := h.Generate([]byte(pw), cost)
				if err != nil {
					t.Error(err)
					return
				}
				if err := bcrypt.CompareHashAndPassword([]byte(mine), []byte(pw)); err != nil {
					t.Errorf("%q cost %d: x/crypto rejects %s: %v", pw, cost, mine, err)
				}
			})
		}
	}
	wg.Wait()
	if _, err := h.Generate(make([]byte, 73), 4); err != ErrTooLong {
		t.Fatal("73 bytes accepted")
	}
}

func BenchmarkGroupOf4(b *testing.B) {
	var salt [saltLen]byte
	ls := [4]lane{newLane([]byte("a"), &salt), newLane([]byte("b"), &salt), newLane([]byte("c"), &salt), newLane([]byte("d"), &salt)}
	var out [4][hashLen]byte
	for b.Loop() {
		run(&ls, 10, &out)
	}
	b.ReportMetric(float64(b.Elapsed().Milliseconds())/float64(b.N)/4, "ms/hash")
}

func BenchmarkXCrypto(b *testing.B) {
	ref, _ := bcrypt.GenerateFromPassword([]byte("password123"), 10)
	for b.Loop() {
		_ = bcrypt.CompareHashAndPassword(ref, []byte("password123"))
	}
}
