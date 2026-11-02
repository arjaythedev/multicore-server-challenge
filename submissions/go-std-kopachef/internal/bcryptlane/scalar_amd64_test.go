//go:build !purego

package bcryptlane

import (
	"encoding/binary"
	"math/rand"
	"testing"
)

//go:noescape
func expandAsmBytes(c *state, words *[18]uint32)

func init() {
	scalarCandidates = append(scalarCandidates,
		scalarCandidate{"native", Single},
		scalarCandidate{"asm_shift", func(p []byte, s [16]byte, cost uint) [23]byte { return scalarAsm(p, s, cost, expandAsmShift) }},
		scalarCandidate{"asm_bytes", func(p []byte, s [16]byte, cost uint) [23]byte { return scalarAsm(p, s, cost, expandAsmBytes) }})
}

func scalarAsm(password []byte, salt [16]byte, cost uint, expand func(*state, *[18]uint32)) (result [23]byte) {
	if cost < 4 || cost > 16 || len(password) > 72 {
		panic("invalid scalar experiment input")
	}
	key := append(append([]byte(nil), password...), 0)
	words, salts := [1][18]uint32{keyWords(key)}, [1][18]uint32{keyWords(salt[:])}
	c := [1]state{{p: p, s0: s0, s1: s1, s2: s2, s3: s3}}
	expand1Salt(&c, &words, &salts)
	for rounds := 0; rounds < 1<<cost; rounds++ {
		expand(&c[0], &words[0])
		expand(&c[0], &salts[0])
	}
	text := [6]uint32{0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274}
	for block := range 3 {
		l, r := [1]uint32{text[2*block]}, [1]uint32{text[2*block+1]}
		for range 64 {
			encrypt1(&c, &l, &r)
		}
		text[2*block], text[2*block+1] = l[0], r[0]
	}
	var raw [24]byte
	for i, word := range text {
		binary.BigEndian.PutUint32(raw[i*4:], word)
	}
	copy(result[:], raw[:23])
	return
}

func TestAssemblyExpansion(t *testing.T) {
	// Exercise arbitrary changing state, not just the fixed initial constants.
	// Canaries also catch a wrong expansion length writing past the state.
	rng := rand.New(rand.NewSource(8912))
	for _, expand := range []func(*state, *[18]uint32){expandAsmShift, expandAsmBytes} {
		for range 20 {
			var got struct {
				before [8]uint64
				state  [1]state
				after  [8]uint64
			}
			for i := range got.before {
				got.before[i], got.after[i] = rng.Uint64(), rng.Uint64()
			}
			for _, words := range [][]uint32{got.state[0].p[:], got.state[0].s0[:], got.state[0].s1[:], got.state[0].s2[:], got.state[0].s3[:]} {
				for i := range words {
					words[i] = rng.Uint32()
				}
			}
			want := got
			for range 5 {
				var key [1][18]uint32
				for i := range key[0] {
					key[0][i] = rng.Uint32()
				}
				expand(&got.state[0], &key[0])
				expand1(&want.state, &key)
				if got != want {
					t.Fatal("assembly expansion differs from Go or overwrote canary")
				}
			}
		}
	}
}
