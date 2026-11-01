// Package bcrypt4 computes bcrypt ($2a$/$2b$, output identical to golang.org/x/crypto/bcrypt) four
// hashes at a time. Blowfish is bound by the latency of its dependent S-box loads, so four
// independent lanes run in roughly the time of one or two.
package bcrypt4

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"strconv"
	"time"
	"unsafe"
)

//go:generate python3 gen.py

const (
	stateWords = 18 + 4*256
	saltLen    = 16
	hashLen    = 23
	maxKey     = 72
)

var (
	ErrMismatch = errors.New("bcrypt4: hash and password do not match")
	ErrHash     = errors.New("bcrypt4: malformed hash")
	ErrTooLong  = errors.New("bcrypt4: password longer than 72 bytes")
	ErrBusy     = errors.New("bcrypt4: queued for too long")
)

var enc = base64.NewEncoding("./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789").WithPadding(base64.NoPadding)

// magic is "OrpheanBeholderScryDoubt" as big-endian words.
var magic = [6]uint32{0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274}

type state struct {
	p              [18]uint32
	s0, s1, s2, s3 [256]uint32
}

func (c *state) flat() *[stateWords]uint32 { return (*[stateWords]uint32)(unsafe.Pointer(c)) }

func (c *state) reset() {
	c.p, c.s0, c.s1, c.s2, c.s3 = p, s0, s1, s2, s3
}

func (c *state) encrypt(l, r uint32) (uint32, uint32) {
	l ^= c.p[0]
	for i := 1; i < 17; i += 2 {
		r ^= ((c.s0[byte(l>>24)] + c.s1[byte(l>>16)]) ^ c.s2[byte(l>>8)]) + c.s3[byte(l)] ^ c.p[i]
		l ^= ((c.s0[byte(r>>24)] + c.s1[byte(r>>16)]) ^ c.s2[byte(r>>8)]) + c.s3[byte(r)] ^ c.p[i+1]
	}
	r ^= c.p[17]
	return r, l
}

// words cycles b into the 18 big-endian words the key schedule XORs into P.
func words(b []byte) (w [18]uint32) {
	j := 0
	for i := range w {
		for range 4 {
			w[i] = w[i]<<8 | uint32(b[j])
			if j++; j == len(b) {
				j = 0
			}
		}
	}
	return w
}

type lane struct {
	key  [18]uint32
	salt [18]uint32
	sw   [4]uint32
}

func newLane(password []byte, salt *[saltLen]byte) lane {
	var ck [maxKey + 1]byte
	n := copy(ck[:], password[:min(len(password), maxKey)])
	var l lane
	l.key = words(ck[:n+1])
	l.salt = words(salt[:])
	copy(l.sw[:], l.salt[:4])
	return l
}

// run computes the 23 hash bytes of four lanes.
func run(ls *[4]lane, cost uint, out *[4][hashLen]byte) {
	var c [4]state
	var sw [4][4]uint32
	for k := range c {
		c[k].reset()
		for i := range 18 {
			c[k].p[i] ^= ls[k].key[i]
		}
		sw[k] = ls[k].sw
	}
	fillSalted4(&c, &sw)
	for range 1 << cost {
		for k := range c {
			for i := range 18 {
				c[k].p[i] ^= ls[k].key[i]
			}
		}
		fill4(&c)
		for k := range c {
			for i := range 18 {
				c[k].p[i] ^= ls[k].salt[i]
			}
		}
		fill4(&c)
	}
	for k := range c {
		d := magic
		for i := 0; i < 6; i += 2 {
			for range 64 {
				d[i], d[i+1] = c[k].encrypt(d[i], d[i+1])
			}
		}
		var b [24]byte
		for i, w := range d {
			b[4*i], b[4*i+1], b[4*i+2], b[4*i+3] = byte(w>>24), byte(w>>16), byte(w>>8), byte(w)
		}
		copy(out[k][:], b[:hashLen])
	}
}

type job struct {
	lane lane
	cost uint
	at   time.Time
	out  [hashLen]byte
	err  error
	done chan struct{}
}

// Hasher gathers concurrent hashes into groups of four. A group that is not full after the wait
// runs anyway, its spare lanes repeating the first job. A job that queued for longer than shed
// fails with ErrBusy without being hashed: by then its caller has likely given up.
type Hasher struct {
	jobs chan *job
	wait time.Duration
	shed time.Duration
}

// New starts workers goroutines, each running one group at a time. A zero shed never sheds.
func New(workers int, wait, shed time.Duration) *Hasher {
	h := &Hasher{jobs: make(chan *job, 4096), wait: wait, shed: shed}
	for range workers {
		go h.work()
	}
	return h
}

func (h *Hasher) work() {
	var group [4]*job
	t := time.NewTimer(time.Hour)
	t.Stop()
	for {
		group[0] = <-h.jobs
		if h.stale(group[0]) {
			continue
		}
		n := 1
		t.Reset(h.wait)
	gather:
		for n < 4 {
			select {
			case j := <-h.jobs:
				if h.stale(j) {
					continue
				}
				if j.cost != group[0].cost {
					runOne(j)
					continue
				}
				group[n] = j
				n++
			case <-t.C:
				break gather
			}
		}
		t.Stop()
		var ls [4]lane
		for k := range ls {
			ls[k] = group[min(k, n-1)].lane
		}
		var out [4][hashLen]byte
		run(&ls, group[0].cost, &out)
		for k := range n {
			group[k].out = out[k]
			group[k].done <- struct{}{}
		}
		clear(group[:])
	}
}

func (h *Hasher) stale(j *job) bool {
	if h.shed == 0 || time.Since(j.at) < h.shed {
		return false
	}
	j.err = ErrBusy
	j.done <- struct{}{}
	return true
}

func runOne(j *job) {
	ls := [4]lane{j.lane, j.lane, j.lane, j.lane}
	var out [4][hashLen]byte
	run(&ls, j.cost, &out)
	j.out = out[0]
	j.done <- struct{}{}
}

func (h *Hasher) do(password []byte, salt *[saltLen]byte, cost uint) ([hashLen]byte, error) {
	j := &job{lane: newLane(password, salt), cost: cost, at: time.Now(), done: make(chan struct{}, 1)}
	h.jobs <- j
	<-j.done
	return j.out, j.err
}

// Generate hashes password with a fresh salt, as $2a$ like x/crypto/bcrypt.
func (h *Hasher) Generate(password []byte, cost int) (string, error) {
	if len(password) > maxKey {
		return "", ErrTooLong
	}
	var salt [saltLen]byte
	if _, err := rand.Read(salt[:]); err != nil {
		return "", err
	}
	sum, err := h.do(password, &salt, uint(cost))
	if err != nil {
		return "", err
	}
	b := make([]byte, 0, 60)
	b = append(b, "$2a$"...)
	if cost < 10 {
		b = append(b, '0')
	}
	b = strconv.AppendInt(b, int64(cost), 10)
	b = append(b, '$')
	b = enc.AppendEncode(b, salt[:])
	b = enc.AppendEncode(b, sum[:])
	return unsafe.String(unsafe.SliceData(b), len(b)), nil
}

// Compare checks password against a $2a$/$2b$/$2y$ hash.
func (h *Hasher) Compare(hash string, password []byte) error {
	if len(hash) != 60 || hash[0] != '$' || hash[1] != '2' || hash[3] != '$' || hash[6] != '$' {
		return ErrHash
	}
	switch hash[2] {
	case 'a', 'b', 'y':
	default:
		return ErrHash
	}
	cost, err := strconv.Atoi(hash[4:6])
	if err != nil || cost < 4 || cost > 31 {
		return ErrHash
	}
	var salt [saltLen + 1]byte
	if n, err := enc.Decode(salt[:], []byte(hash[7:29])); err != nil || n != saltLen {
		return ErrHash
	}
	sum, err := h.do(password, (*[saltLen]byte)(salt[:saltLen]), uint(cost))
	if err != nil {
		return err
	}
	var want [hashLen + 1]byte
	if n, err := enc.Decode(want[:], []byte(hash[29:])); err != nil || n != hashLen {
		return ErrHash
	}
	if subtle.ConstantTimeCompare(sum[:], want[:hashLen]) != 1 {
		return ErrMismatch
	}
	return nil
}
