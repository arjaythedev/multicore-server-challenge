package bcryptlane

import (
	"fmt"
	"testing"
)

func generatedWidth(n int, p [5][]byte, s [5][16]byte, cost uint) (out [5][23]byte) {
	if n == 3 {
		v := Sum3([3][]byte(p[:3]), [3][16]byte(s[:3]), cost)
		copy(out[:], v[:])
	} else {
		out = Sum5(p, s, cost)
	}
	return
}

func TestGeneratedWidths(t *testing.T) {
	passwords := [5][]byte{nil, {0, 255, 128, 0}, make([]byte, 72), []byte("password123"), []byte("fifth")}
	for i := range passwords[2] {
		passwords[2][i] = byte(i * 31)
	}
	var salts [5][16]byte
	for k := range salts {
		for i := range salts[k] {
			salts[k][i] = byte(k*19 + i*17)
		}
	}
	for _, n := range []int{3, 5} {
		for _, cost := range []uint{4, 5, 10} {
			got := generatedWidth(n, passwords, salts, cost)
			for k := range n {
				if want := standardSingle(passwords[k], salts[k], cost); got[k] != want {
					t.Fatalf("width %d lane %d cost %d: standard bcrypt mismatch", n, k, cost)
				}
			}
		}
	}
}

var generatedWidthResult [5][23]byte

func BenchmarkGeneratedWidths(b *testing.B) {
	passwords := [5][]byte{[]byte("password123"), []byte("another"), []byte("third"), []byte("fourth"), []byte("fifth")}
	var salts [5][16]byte
	for _, n := range []int{3, 5} {
		b.Run(fmt.Sprint(n), func(b *testing.B) {
			b.ReportAllocs()
			start := processCPU()
			for b.Loop() {
				generatedWidthResult = generatedWidth(n, passwords, salts, 10)
			}
			b.ReportMetric(float64(processCPU()-start)/float64(b.N*n), "cpu-ns/hash")
		})
	}
}
