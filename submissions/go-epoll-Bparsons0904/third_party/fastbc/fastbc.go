// Package fastbc is a no-cgo bcrypt verifier with N-way interleaved EksBlowfish
// kernels. Three kernel families share one driver:
//
//   - go:      plain Go, fully unrolled rounds (go_gen.go, widths 1-8)
//   - asm:     Go assembly, baseline x86-64 (eks_amd64.s, widths 1-8)
//   - asmbmi2: Go assembly using RORX (BMI2, x86-64-v3); asmbmi2s is its single-body form
//
// All code under *_gen.go and eks_amd64.s is written by ../gen.py.
package fastbc

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/binary"
)

// lstate is one Blowfish state. P comes first so that the EksBlowfish
// ExpandKey refill (9 encryptions into P, 512 into S) is one run of 521
// consecutive pairs; the padding makes the stride 4224 bytes.
type lstate struct {
	P [18]uint32
	S [4][256]uint32
	_ [14]uint32
}

// Job is one prepared bcrypt computation.
type Job struct {
	Key  [2][18]uint32 // the two ExpandKey(state, 0, .) inputs: cyclic password words, then cyclic salt words
	Salt [4]uint32
	Out  [6]uint32
}

// kernel runs n iterations of the EksBlowfish cost loop on len(st) lanes.
type kernel func(st []lstate, jobs []Job, n uint64)

// Impl selects a kernel family.
type Impl struct {
	Name  string
	k     [9]kernel
	chunk uint64 // max iterations per kernel call; asm is not async-preemptible
}

// Widths lists the widths an Impl supports.
func (im *Impl) Widths() []int {
	var w []int
	for i, k := range im.k {
		if k != nil {
			w = append(w, i)
		}
	}
	return w
}

var (
	Go      = &Impl{Name: "go", k: goKernels, chunk: 1 << 31}
	Asm     = &Impl{Name: "asm", k: asmKernels, chunk: 64}
	AsmBMI2 = &Impl{Name: "asmbmi2", k: bmi2Kernels, chunk: 64}
	// AsmBMI2S is AsmBMI2 without the 2x unrolled fill loop (half the code size).
	AsmBMI2S = &Impl{Name: "asmbmi2s", k: bmi2sKernels, chunk: 64}
	// Rolled forms: a loop over the 16 rounds, n rounds per iteration (smaller code).
	AsmBMI2SR8 = &Impl{Name: "asmbmi2sr8", k: bmi2sr8Kernels, chunk: 64}
	AsmBMI2SR4 = &Impl{Name: "asmbmi2sr4", k: bmi2sr4Kernels, chunk: 64}
	AsmBMI2SR2 = &Impl{Name: "asmbmi2sr2", k: bmi2sr2Kernels, chunk: 64}
	AsmSR4     = &Impl{Name: "asmsr4", k: asmsr4Kernels, chunk: 64}
	GoR        = &Impl{Name: "gor", k: gorKernels, chunk: 1 << 31}
)

var magic = [6]uint32{0x4F727068, 0x65616E42, 0x65686F6C, 0x64657253, 0x63727944, 0x6F756274}

func (s *lstate) f(x uint32) uint32 {
	return ((s.S[0][x>>24] + s.S[1][x>>16&255]) ^ s.S[2][x>>8&255]) + s.S[3][x&255]
}

func (s *lstate) enc(l, r uint32) (uint32, uint32) {
	l ^= s.P[0]
	for i := 1; i < 16; i += 2 {
		r ^= s.f(l) ^ s.P[i]
		l ^= s.f(r) ^ s.P[i+1]
	}
	return r ^ s.P[17], l
}

// expandSalted is the first, salted ExpandKey of EksBlowfishSetup.
func (s *lstate) expandSalted(j *Job) {
	s.P = initP
	s.S = initS
	for i := range s.P {
		s.P[i] ^= j.Key[0][i]
	}
	var l, r uint32
	for i := 0; i < 18; i += 2 {
		l, r = s.enc(l^j.Salt[i&2], r^j.Salt[i&2+1])
		s.P[i], s.P[i+1] = l, r
	}
	// 18 salt words consumed so far: the cycle resumes at word 2
	for b := range s.S {
		for i := 0; i < 256; i += 2 {
			l, r = s.enc(l^j.Salt[(i+2)&2], r^j.Salt[(i+2)&2+1])
			s.S[b][i], s.S[b][i+1] = l, r
		}
	}
}

func (s *lstate) final(j *Job) {
	for b := 0; b < 3; b++ {
		l, r := magic[2*b], magic[2*b+1]
		for i := 0; i < 64; i++ {
			l, r = s.enc(l, r)
		}
		j.Out[2*b], j.Out[2*b+1] = l, r
	}
}

// Run computes len(jobs) (1..8, a width the Impl supports) jobs at once.
func (im *Impl) Run(jobs []Job, cost uint) {
	var sts [8]lstate
	st := sts[:len(jobs)]
	for i := range st {
		st[i].expandSalted(&jobs[i])
	}
	k := im.k[len(jobs)]
	for n := uint64(1) << cost; n > 0; {
		c := min(n, im.chunk)
		k(st, jobs, c)
		n -= c
	}
	for i := range st {
		st[i].final(&jobs[i])
	}
}

// Prepare fills j from a salt and password (password+NUL, cycled, truncated to 72 bytes).
func Prepare(j *Job, salt *[16]byte, pw []byte) {
	var key [72]byte
	klen := copy(key[:71], pw) + 1 // key[klen-1] == 0 is the NUL terminator
	if len(pw) >= 72 {
		klen = 72
		copy(key[:], pw[:72])
	}
	p := 0
	for i := 0; i < 18; i++ {
		var w uint32
		for b := 0; b < 4; b++ {
			w = w<<8 | uint32(key[p])
			if p++; p == klen {
				p = 0
			}
		}
		j.Key[0][i] = w
	}
	for i := 0; i < 4; i++ {
		j.Salt[i] = binary.BigEndian.Uint32(salt[4*i:])
	}
	for i := 0; i < 18; i++ {
		j.Key[1][i] = j.Salt[i&3]
	}
}

func (j *Job) raw() (r [24]byte) {
	for i := 0; i < 6; i++ {
		binary.BigEndian.PutUint32(r[4*i:], j.Out[i])
	}
	return
}

const alpha = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

var dec [256]int8

func init() {
	for i := range dec {
		dec[i] = -1
	}
	for i := 0; i < 64; i++ {
		dec[alpha[i]] = int8(i)
	}
}

// b64dec decodes bcrypt's base64 (no padding) into dst; src must hold enough characters.
func b64dec(dst []byte, src []byte) bool {
	var acc uint32
	bits, o := 0, 0
	for _, c := range src {
		v := dec[c]
		if v < 0 {
			return false
		}
		acc = acc<<6 | uint32(v)
		if bits += 6; bits >= 8 {
			bits -= 8
			dst[o] = byte(acc >> bits)
			if o++; o == len(dst) {
				return true
			}
		}
	}
	return false
}

func b64enc(dst []byte, src []byte) []byte {
	var acc uint32
	bits := 0
	for _, b := range src {
		acc = acc<<8 | uint32(b)
		for bits += 8; bits >= 6; {
			bits -= 6
			dst = append(dst, alpha[acc>>bits&63])
		}
	}
	if bits > 0 {
		dst = append(dst, alpha[acc<<(6-bits)&63])
	}
	return dst
}

// Parse splits a 60-byte $2a$/$2b$/$2y$ hash into salt, wanted 23 bytes and cost.
func Parse(h []byte) (salt [16]byte, want [23]byte, cost uint, ok bool) {
	if len(h) != 60 || h[0] != '$' || h[1] != '2' || h[3] != '$' || h[6] != '$' ||
		h[4] < '0' || h[4] > '3' || h[5] < '0' || h[5] > '9' {
		return
	}
	cost = uint(h[4]-'0')*10 + uint(h[5]-'0')
	if cost < 4 || cost > 31 || !b64dec(salt[:], h[7:29]) || !b64dec(want[:], h[29:60]) {
		return
	}
	return salt, want, cost, true
}

// Verifier verifies up to 8 hashes at once.
type Verifier struct {
	Impl *Impl
	jobs [8]Job
	want [8][23]byte
}

// Verify checks len(hashes) pairs together; false if any hash is malformed or costs differ.
func (v *Verifier) Verify(hashes, pws [][]byte, ok []bool) bool {
	n := len(hashes)
	var cost uint
	for i := 0; i < n; i++ {
		salt, want, c, good := Parse(hashes[i])
		if !good || (i > 0 && c != cost) {
			return false
		}
		cost = c
		v.want[i] = want
		Prepare(&v.jobs[i], &salt, pws[i])
	}
	v.Impl.Run(v.jobs[:n], cost)
	for i := 0; i < n; i++ {
		r := v.jobs[i].raw()
		ok[i] = subtle.ConstantTimeCompare(r[:23], v.want[i][:]) == 1
	}
	return true
}

// Hash creates a $2a$ hash with a random salt (single lane).
func (im *Impl) Hash(pw []byte, cost int) []byte {
	var salt [16]byte
	rand.Read(salt[:])
	var j [1]Job
	Prepare(&j[0], &salt, pw)
	im.Run(j[:], uint(cost))
	out := []byte{'$', '2', 'a', '$', byte('0' + cost/10), byte('0' + cost%10), '$'}
	out = b64enc(out, salt[:])
	r := j[0].raw()
	return b64enc(out, r[:23])
}
