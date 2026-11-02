//go:build amd64 && !purego

package bcryptlane

import (
	"math/rand"
	"testing"
)

func TestFiveAssemblyExpansion(t *testing.T) {
	rng := rand.New(rand.NewSource(84511))
	for range 32 {
		var got struct {
			before [8]uint64
			states [5]state
			after  [8]uint64
		}
		for i := range got.before {
			got.before[i], got.after[i] = rng.Uint64(), rng.Uint64()
		}
		var keys [5][18]uint32
		for k := range 5 {
			for _, words := range [][]uint32{got.states[k].p[:], got.states[k].s0[:], got.states[k].s1[:], got.states[k].s2[:], got.states[k].s3[:]} {
				for i := range words {
					words[i] = rng.Uint32()
				}
			}
			for i := range keys[k] {
				keys[k][i] = rng.Uint32()
			}
		}
		want, originalKeys := got, keys
		for range 3 {
			expandFiveAsm(&got.states, &keys)
			expand5(&want.states, &keys)
			if got != want {
				t.Fatal("state mismatch or canary corruption")
			}
			if keys != originalKeys {
				t.Fatal("key input was modified")
			}
		}
	}
}
