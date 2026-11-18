//go:build !purego

package bcryptlane

import "encoding/binary"

// expandAsmShift updates the complete P array and four S-boxes in order. It
// handles one key expansion, returning to Go between every pair of expansions
// so the cost loop remains preemptible. All instructions work on baseline amd64.
//
//go:noescape
func expandAsmShift(c *state, words *[18]uint32)

// Single computes one complete bcrypt checksum using the amd64 expansion kernel.
func Single(password []byte, salt [16]byte, cost uint) (result [23]byte) {
	if cost < 4 || cost > 16 || len(password) > 72 {
		panic("bcrypt lane cost must be 4..16 and password <=72 bytes")
	}
	var key [73]byte
	copy(key[:], password)
	words := [1][18]uint32{keyWords(key[:len(password)+1])}
	salts := [1][18]uint32{keyWords(salt[:])}
	c := [1]state{{p: p, s0: s0, s1: s1, s2: s2, s3: s3}}
	expand1Salt(&c, &words, &salts)
	for rounds := 0; rounds < 1<<cost; rounds++ {
		expandAsmShift(&c[0], &words[0])
		expandAsmShift(&c[0], &salts[0])
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
