// Package bcryptx is a pure-Go bcrypt that hashes several passwords at once.
//
// Results are byte-compatible with golang.org/x/crypto/bcrypt. A Worker runs up
// to four same-cost requests in lockstep (see lanes_gen.go); unusual hash
// strings fall back to x/crypto unchanged.
package bcryptx

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/binary"
	"unsafe"

	xbcrypt "golang.org/x/crypto/bcrypt"
)

const (
	MaxLanes    = 4
	maxPassword = 72
	hashLen     = 60
)

type state struct {
	p              [18]uint32
	s0, s1, s2, s3 [256]uint32
}

// pairs views P followed by the four S-boxes as the 521 (l, r) slots that key
// expansion rewrites in order. The struct is five contiguous uint32 arrays.
func (s *state) pairs() *[521][2]uint32 { return (*[521][2]uint32)(unsafe.Pointer(s)) }

var initial = state{p: initP, s0: initS0, s1: initS1, s2: initS2, s3: initS3}

var b64 = base64.NewEncoding("./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789").WithPadding(base64.NoPadding)

// "OrpheanBeholderScryDoubt" as big-endian words.
var magic = [6]uint32{0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274}

// Request is one hash (Hash == nil) or one verification.
type Request struct {
	Password []byte
	Hash     []byte // existing hash to verify against
	Cost     int    // cost for a new hash

	Result [hashLen]byte // new hash
	OK     bool          // verification matched, or new hash succeeded

	fast bool
	cost int
	salt [16]byte
	key  [18]uint32
	skey [18]uint32
}

// Worker owns the Blowfish states, so steady-state hashing does not allocate.
type Worker struct {
	st   [MaxLanes]state
	fast [MaxLanes]*Request
}

// Process completes every request. Up to MaxLanes requests sharing a cost run
// interleaved; costs are almost always identical.
func (w *Worker) Process(reqs []*Request) {
	for _, r := range reqs {
		r.OK = false
		if !r.prepare() && r.Hash != nil {
			r.OK = xbcrypt.CompareHashAndPassword(r.Hash, r.Password) == nil
		}
	}
	for {
		n, cost := 0, -1
		for _, r := range reqs {
			if r.fast && (cost < 0 || r.cost == cost) && n < MaxLanes {
				cost = r.cost
				r.fast = false
				w.fast[n] = r
				n++
			}
		}
		if n == 0 {
			return
		}
		w.run(w.fast[:n])
	}
}

func (r *Request) prepare() bool {
	r.fast = false
	if r.Hash == nil {
		if len(r.Password) > maxPassword || r.Cost < xbcrypt.MinCost || r.Cost > xbcrypt.MaxCost {
			return false
		}
		if _, err := rand.Read(r.salt[:]); err != nil {
			return false
		}
		r.cost = r.Cost
	} else {
		h := r.Hash
		if len(h) != hashLen || h[0] != '$' || h[1] != '2' || (h[2] != 'a' && h[2] != 'b' && h[2] != 'y') || h[3] != '$' || h[6] != '$' ||
			h[4] < '0' || h[4] > '9' || h[5] < '0' || h[5] > '9' {
			return false
		}
		r.cost = int(h[4]-'0')*10 + int(h[5]-'0')
		if r.cost < xbcrypt.MinCost || r.cost > xbcrypt.MaxCost {
			return false
		}
		if n, err := b64.Decode(r.salt[:], h[7:29]); err != nil || n != 16 {
			return false
		}
	}
	// The key is the password plus its NUL terminator, cycled over 18 words.
	j, l := 0, len(r.Password)+1
	for i := range r.key {
		var x uint32
		for range 4 {
			var c byte
			if j < len(r.Password) {
				c = r.Password[j]
			}
			x = x<<8 | uint32(c)
			if j++; j == l {
				j = 0
			}
		}
		r.key[i] = x
	}
	for i := range r.skey {
		r.skey[i] = binary.BigEndian.Uint32(r.salt[4*(i&3):])
	}
	r.fast = true
	return true
}

func (w *Worker) run(g []*Request) {
	for k, r := range g {
		s := &w.st[k]
		*s = initial
		for i := range 18 {
			s.p[i] ^= r.key[i]
		}
		var l, rr uint32
		q := s.pairs()
		for i := range 521 {
			l ^= r.skey[(2*i)&3]
			rr ^= r.skey[(2*i+1)&3]
			l, rr = encrypt1(s, l, rr)
			q[i][0], q[i][1] = l, rr
		}
	}
	rounds := 1 << g[0].cost
	switch len(g) {
	case 1:
		for range rounds {
			expand1(&w.st[0], &g[0].key)
			expand1(&w.st[0], &g[0].skey)
		}
	case 2:
		for range rounds {
			expand2(&w.st[0], &w.st[1], &g[0].key, &g[1].key)
			expand2(&w.st[0], &w.st[1], &g[0].skey, &g[1].skey)
		}
	case 3:
		for range rounds {
			expand3(&w.st[0], &w.st[1], &w.st[2], &g[0].key, &g[1].key, &g[2].key)
			expand3(&w.st[0], &w.st[1], &w.st[2], &g[0].skey, &g[1].skey, &g[2].skey)
		}
	case 4:
		for range rounds {
			expand4(&w.st[0], &w.st[1], &w.st[2], &w.st[3], &g[0].key, &g[1].key, &g[2].key, &g[3].key)
			expand4(&w.st[0], &w.st[1], &w.st[2], &w.st[3], &g[0].skey, &g[1].skey, &g[2].skey, &g[3].skey)
		}
	}
	for k, r := range g {
		s := &w.st[k]
		c := magic
		for b := 0; b < 6; b += 2 {
			for range 64 {
				c[b], c[b+1] = encrypt1(s, c[b], c[b+1])
			}
		}
		var raw [24]byte
		for i, v := range c {
			binary.BigEndian.PutUint32(raw[4*i:], v)
		}
		var enc [31]byte
		b64.Encode(enc[:], raw[:23]) // bcrypt encodes 23 of the 24 bytes
		if r.Hash != nil {
			r.OK = subtle.ConstantTimeCompare(enc[:], r.Hash[29:]) == 1
			continue
		}
		out := r.Result[:0]
		out = append(out, '$', '2', 'a', '$', byte('0'+r.cost/10), byte('0'+r.cost%10), '$')
		out = out[:29]
		b64.Encode(out[7:29], r.salt[:])
		copy(r.Result[29:], enc[:])
		r.OK = true
	}
}
