//go:build amd64 && !purego

package bcryptlane

import (
	"math/rand"
	"testing"
)

func TestInterleavedAssembly(t *testing.T) {
	rng := rand.New(rand.NewSource(3612))
	for range 12 {
		var got struct {
			before [8]uint64
			states [4]state
			after  [8]uint64
		}
		for i := range got.before {
			got.before[i], got.after[i] = rng.Uint64(), rng.Uint64()
		}
		var keys [4][18]uint32
		for k := range 4 {
			for _, words := range [][]uint32{got.states[k].p[:], got.states[k].s0[:], got.states[k].s1[:], got.states[k].s2[:], got.states[k].s3[:]} {
				for i := range words {
					words[i] = rng.Uint32()
				}
			}
			for i := range keys[k] {
				keys[k][i] = rng.Uint32()
			}
		}
		want := got
		expandAsm4(&got.states, &keys)
		expand4(&want.states, &keys)
		if got != want {
			t.Fatal("four-lane expansion mismatch or canary corruption")
		}
		two, twoWant := [2]state{got.states[0], got.states[1]}, [2]state{got.states[0], got.states[1]}
		twoKeys := [2][18]uint32{keys[0], keys[1]}
		expandAsm2(&two, &twoKeys)
		expand2(&twoWant, &twoKeys)
		if two != twoWant {
			t.Fatal("two-lane expansion mismatch")
		}
	}
	for _, cost := range []uint{4, 5, 10} {
		passwords := [4][]byte{nil, {0, 255, 128, 0}, make([]byte, 72), []byte("password123")}
		var salts [4][16]byte
		for k := range salts {
			for i := range salts[k] {
				salts[k][i] = byte(rng.Uint32())
			}
		}
		got := sumAsm4(passwords, salts, cost)
		if got != Sum4(passwords, salts, cost) {
			t.Fatal("four-lane hash mismatch")
		}
		if Pair([2][]byte{passwords[0], passwords[1]}, [2][16]byte{salts[0], salts[1]}, cost) != Sum2([2][]byte{passwords[0], passwords[1]}, [2][16]byte{salts[0], salts[1]}, cost) {
			t.Fatal("two-lane hash mismatch")
		}
		for k := range passwords {
			if got[k] != standardSingle(passwords[k], salts[k], cost) {
				t.Fatal("standard bcrypt mismatch")
			}
		}
	}
}

var interleaveResult [4][23]byte

func BenchmarkInterleavedAssembly(b *testing.B) {
	passwords := [4][]byte{[]byte("password123"), []byte("another"), []byte("third"), []byte("fourth")}
	var salts [4][16]byte
	for _, mode := range []string{"go2", "asm2", "go4", "asm4"} {
		b.Run(mode, func(b *testing.B) {
			b.ReportAllocs()
			width := 4
			if mode == "go2" || mode == "asm2" {
				width = 2
			}
			start := processCPU()
			for b.Loop() {
				switch mode {
				case "go2":
					r := Sum2([2][]byte{passwords[0], passwords[1]}, [2][16]byte{salts[0], salts[1]}, 10)
					interleaveResult[0], interleaveResult[1] = r[0], r[1]
				case "asm2":
					r := Pair([2][]byte{passwords[0], passwords[1]}, [2][16]byte{salts[0], salts[1]}, 10)
					interleaveResult[0], interleaveResult[1] = r[0], r[1]
				case "go4":
					interleaveResult = Sum4(passwords, salts, 10)
				case "asm4":
					interleaveResult = sumAsm4(passwords, salts, 10)
				}
			}
			b.ReportMetric(float64(processCPU()-start)/float64(b.N*width), "cpu-ns/hash")
		})
	}
}
