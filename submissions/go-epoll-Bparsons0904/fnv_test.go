package main

import (
	"hash/fnv"
	"testing"
)

func TestFnvAddMatchesStdlib(t *testing.T) {
	for _, in := range [][]byte{nil, []byte("a"), []byte("how-to-train-your-dragon-17"), {0, 255, 1, 128}} {
		h := fnv.New32a()
		h.Write(in)
		h.Write(in)
		if got := fnvAdd(fnvAdd(fnvInit, in), in); got != h.Sum32() {
			t.Fatalf("%q: got %d, want %d", in, got, h.Sum32())
		}
	}
}
