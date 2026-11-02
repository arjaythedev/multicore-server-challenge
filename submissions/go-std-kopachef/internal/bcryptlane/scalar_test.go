package bcryptlane

import (
	"encoding/base64"
	"fmt"
	"syscall"
	"testing"

	"golang.org/x/crypto/bcrypt"
)

type scalarCandidate struct {
	name string
	sum  func([]byte, [16]byte, uint) [23]byte
}

var scalarCandidates = []scalarCandidate{
	{"standard", standardSingle},
	{"generated_one", func(p []byte, s [16]byte, cost uint) [23]byte { return Sum1([1][]byte{p}, [1][16]byte{s}, cost)[0] }},
	{"register", scalarRegs},
	{"inline", scalarInline},
	{"boxes_register", scalarBoxes},
	{"boxes_inline", scalarBoxesInline},
}

func TestScalarCandidates(t *testing.T) {
	b64 := base64.NewEncoding("./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789").WithPadding(base64.NoPadding)
	for _, candidate := range scalarCandidates {
		t.Run(candidate.name, func(t *testing.T) {
			for n, size := range []int{0, 1, 7, 16, 32, 55, 71, 72} {
				password := make([]byte, size)
				for i := range password {
					password[i] = byte(i*31 + n*57) // Includes NUL and high-bit bytes.
				}
				var salt [16]byte
				for i := range salt {
					salt[i] = byte(i*17 + n*61)
				}
				for _, cost := range []uint{4, 5} {
					got := candidate.sum(password, salt, cost)
					want := standardSingle(password, salt, cost)
					if got != want {
						t.Fatalf("length %d, cost %d: checksum mismatch", size, cost)
					}
					hash := fmt.Sprintf("$2a$%02d$%s%s", cost, b64.EncodeToString(salt[:]), b64.EncodeToString(got[:]))
					if err := bcrypt.CompareHashAndPassword([]byte(hash), password); err != nil {
						t.Fatal(err)
					}
				}
			}
			raw, err := b64.DecodeString("XajjQvNhvvRt5GSeFk1xFe")
			if err != nil {
				t.Fatal(err)
			}
			var salt [16]byte
			copy(salt[:], raw)
			got := candidate.sum([]byte("allmine"), salt, 10)
			if b64.EncodeToString(got[:]) != "yqRrsxkhBkUiQeg0dt.wU1qD4aFDcga" {
				t.Fatal("known cost-10 checksum mismatch")
			}
		})
	}
}

func processCPU() int64 {
	var r syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &r); err != nil {
		panic(err)
	}
	return (r.Utime.Sec+r.Stime.Sec)*1e9 + (r.Utime.Usec+r.Stime.Usec)*1e3
}

var scalarBenchmarkResult [23]byte

func BenchmarkScalar(b *testing.B) {
	password := []byte("password123")
	var salt [16]byte
	for i := range salt {
		salt[i] = byte(i * 17)
	}
	for _, candidate := range scalarCandidates {
		b.Run(candidate.name, func(b *testing.B) {
			b.ReportAllocs()
			b.ResetTimer()
			startCPU := processCPU()
			for range b.N {
				scalarBenchmarkResult = candidate.sum(password, salt, 10)
			}
			elapsedCPU := processCPU() - startCPU
			b.StopTimer()
			b.ReportMetric(float64(elapsedCPU)/float64(b.N), "cpu-ns/hash")
		})
	}
}
