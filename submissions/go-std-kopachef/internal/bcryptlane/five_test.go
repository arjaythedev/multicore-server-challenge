package bcryptlane

import (
	"bytes"
	"math/rand"
	"sync"
	"testing"
)

func TestFiveChecksums(t *testing.T) {
	rng := rand.New(rand.NewSource(273961))
	for _, cost := range []uint{4, 5, 10} {
		for trial := range 3 {
			var passwords, original [5][]byte
			var salts [5][16]byte
			for k := range 5 {
				size := rng.Intn(73)
				if trial == 0 {
					size = []int{0, 1, 71, 72, 32}[k]
				}
				passwords[k] = make([]byte, size)
				rng.Read(passwords[k]) // Includes NUL and high-bit bytes.
				original[k] = bytes.Clone(passwords[k])
				rng.Read(salts[k][:])
			}
			originalSalts := salts
			got := Five(passwords, salts, cost)
			for k := range 5 {
				if got[k] != standardSingle(passwords[k], salts[k], cost) {
					t.Fatalf("cost %d trial %d lane %d: standard checksum mismatch", cost, trial, k)
				}
				if !bytes.Equal(passwords[k], original[k]) {
					t.Fatal("password input was modified")
				}
			}
			if salts != originalSalts {
				t.Fatal("salt input was modified")
			}
		}
	}
}

func TestFiveConcurrent(t *testing.T) {
	passwords := [5][]byte{nil, {0, 255, 128, 0}, make([]byte, 72), []byte("password123"), []byte("fifth")}
	var salts [5][16]byte
	var want [5][23]byte
	for k := range 5 {
		for i := range salts[k] {
			salts[k][i] = byte(k*19 + i*17)
		}
		want[k] = standardSingle(passwords[k], salts[k], 4)
	}
	var wg sync.WaitGroup
	for range 8 {
		wg.Go(func() {
			if got := Five(passwords, salts, 4); got != want {
				t.Error("concurrent checksum mismatch")
			}
		})
	}
	wg.Wait()
}

func TestFiveInvalidInputs(t *testing.T) {
	for name, sum := range map[string]func(){
		"low cost":      func() { Five([5][]byte{}, [5][16]byte{}, 3) },
		"high cost":     func() { Five([5][]byte{}, [5][16]byte{}, 17) },
		"long password": func() { Five([5][]byte{nil, nil, nil, nil, make([]byte, 73)}, [5][16]byte{}, 4) },
	} {
		t.Run(name, func(t *testing.T) {
			defer func() {
				if recover() == nil {
					t.Fatal("invalid input did not panic")
				}
			}()
			sum()
		})
	}
}

func BenchmarkFive(b *testing.B) {
	passwords := [5][]byte{[]byte("password123"), []byte("another"), []byte("third"), []byte("fourth"), []byte("fifth")}
	var salts [5][16]byte
	for k := range salts {
		for i := range salts[k] {
			salts[k][i] = byte(k*19 + i*17)
		}
	}
	for _, mode := range []struct {
		name string
		sum  func([5][]byte, [5][16]byte, uint) [5][23]byte
	}{{"go", Sum5}, {"asm", Five}} {
		b.Run(mode.name, func(b *testing.B) {
			b.ReportAllocs()
			start := processCPU()
			for b.Loop() {
				generatedWidthResult = mode.sum(passwords, salts, 10)
			}
			b.ReportMetric(float64(processCPU()-start)/float64(b.N*5), "cpu-ns/hash")
		})
	}
}
