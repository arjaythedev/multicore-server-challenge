package main

// bcrypt.go: bcrypt (cost 10, $2a$/$2b$/$2y$) with the Blowfish key schedule run for up to four
// independent hashes at once (bcrypt_lanes.go, generated). Every hash does every one of its 2^cost
// rounds; interleaving only hides the latency of one lane's dependent table loads behind the others'.
// The algorithm and constants are those of golang.org/x/crypto/bcrypt and blowfish, which the tests
// compare against.

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"sync/atomic"
	"time"
)

type bfState struct {
	p              [18]uint32
	s0, s1, s2, s3 [256]uint32
}

// bfInit is the initial cipher state: the P-array and S-boxes from bcrypt_pi.go.
var bfInit = func() (st bfState) {
	st.p = piP
	st.s0, st.s1, st.s2, st.s3 = piS0, piS1, piS2, piS3
	return st
}()

const bcAlphabet = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

var bcEncoding = base64.NewEncoding(bcAlphabet).WithPadding(base64.NoPadding)

var errBadHash = errors.New("bcrypt: malformed hash")

// keyWords returns the 18 key words ExpandKey derives by cycling through key.
func keyWords(key []byte) (w [18]uint32) {
	j := 0
	for i := 0; i < 18; i++ {
		var d uint32
		for k := 0; k < 4; k++ {
			d = d<<8 | uint32(key[j])
			j++
			if j >= len(key) {
				j = 0
			}
		}
		w[i] = d
	}
	return w
}

// setupSalted is blowfish.NewSaltedCipher: init, then one expansion mixing key and salt.
func setupSalted(st *bfState, key, salt []byte) {
	*st = bfInit
	j := 0
	next := func(b []byte, pos *int) uint32 {
		var w uint32
		p := *pos
		for i := 0; i < 4; i++ {
			w = w<<8 | uint32(b[p])
			p++
			if p >= len(b) {
				p = 0
			}
		}
		*pos = p
		return w
	}
	for i := 0; i < 18; i++ {
		st.p[i] ^= next(key, &j)
	}
	j = 0
	var l, r uint32
	for i := 0; i < 18; i += 2 {
		l ^= next(salt, &j)
		r ^= next(salt, &j)
		l, r = encrypt1(st, l, r)
		st.p[i], st.p[i+1] = l, r
	}
	for _, box := range []*[256]uint32{&st.s0, &st.s1, &st.s2, &st.s3} {
		for i := 0; i < 256; i += 2 {
			l ^= next(salt, &j)
			r ^= next(salt, &j)
			l, r = encrypt1(st, l, r)
			box[i], box[i+1] = l, r
		}
	}
}

func encrypt1(c *bfState, l, r uint32) (uint32, uint32) {
	xl, xr := l, r
	xl ^= c.p[0]
	xr ^= ((c.s0[byte(xl>>24)] + c.s1[byte(xl>>16)]) ^ c.s2[byte(xl>>8)]) + c.s3[byte(xl)] ^ c.p[1]
	xl ^= ((c.s0[byte(xr>>24)] + c.s1[byte(xr>>16)]) ^ c.s2[byte(xr>>8)]) + c.s3[byte(xr)] ^ c.p[2]
	xr ^= ((c.s0[byte(xl>>24)] + c.s1[byte(xl>>16)]) ^ c.s2[byte(xl>>8)]) + c.s3[byte(xl)] ^ c.p[3]
	xl ^= ((c.s0[byte(xr>>24)] + c.s1[byte(xr>>16)]) ^ c.s2[byte(xr>>8)]) + c.s3[byte(xr)] ^ c.p[4]
	xr ^= ((c.s0[byte(xl>>24)] + c.s1[byte(xl>>16)]) ^ c.s2[byte(xl>>8)]) + c.s3[byte(xl)] ^ c.p[5]
	xl ^= ((c.s0[byte(xr>>24)] + c.s1[byte(xr>>16)]) ^ c.s2[byte(xr>>8)]) + c.s3[byte(xr)] ^ c.p[6]
	xr ^= ((c.s0[byte(xl>>24)] + c.s1[byte(xl>>16)]) ^ c.s2[byte(xl>>8)]) + c.s3[byte(xl)] ^ c.p[7]
	xl ^= ((c.s0[byte(xr>>24)] + c.s1[byte(xr>>16)]) ^ c.s2[byte(xr>>8)]) + c.s3[byte(xr)] ^ c.p[8]
	xr ^= ((c.s0[byte(xl>>24)] + c.s1[byte(xl>>16)]) ^ c.s2[byte(xl>>8)]) + c.s3[byte(xl)] ^ c.p[9]
	xl ^= ((c.s0[byte(xr>>24)] + c.s1[byte(xr>>16)]) ^ c.s2[byte(xr>>8)]) + c.s3[byte(xr)] ^ c.p[10]
	xr ^= ((c.s0[byte(xl>>24)] + c.s1[byte(xl>>16)]) ^ c.s2[byte(xl>>8)]) + c.s3[byte(xl)] ^ c.p[11]
	xl ^= ((c.s0[byte(xr>>24)] + c.s1[byte(xr>>16)]) ^ c.s2[byte(xr>>8)]) + c.s3[byte(xr)] ^ c.p[12]
	xr ^= ((c.s0[byte(xl>>24)] + c.s1[byte(xl>>16)]) ^ c.s2[byte(xl>>8)]) + c.s3[byte(xl)] ^ c.p[13]
	xl ^= ((c.s0[byte(xr>>24)] + c.s1[byte(xr>>16)]) ^ c.s2[byte(xr>>8)]) + c.s3[byte(xr)] ^ c.p[14]
	xr ^= ((c.s0[byte(xl>>24)] + c.s1[byte(xl>>16)]) ^ c.s2[byte(xl>>8)]) + c.s3[byte(xl)] ^ c.p[15]
	xl ^= ((c.s0[byte(xr>>24)] + c.s1[byte(xr>>16)]) ^ c.s2[byte(xr>>8)]) + c.s3[byte(xr)] ^ c.p[16]
	xr ^= c.p[17]
	return xr, xl
}

// bcryptJob is one hash computation: password (without the NUL), 16-byte raw salt and cost; out
// receives the 23-byte raw hash.
type bcryptJob struct {
	password []byte
	salt     [16]byte
	cost     uint32
	out      [23]byte
	done     chan struct{}
}

var magicCipherData = [24]byte{'O', 'r', 'p', 'h', 'e', 'a', 'n', 'B', 'e', 'h', 'o', 'l', 'd', 'e', 'r', 'S', 'c', 'r', 'y', 'D', 'o', 'u', 'b', 't'}

// bcryptLanes computes up to four jobs together. Jobs must share a cost.
func bcryptLanes(jobs []*bcryptJob) {
	n := len(jobs)
	var states [4]bfState
	var cs [4]*bfState
	var kw, sw [4][18]uint32
	for i, j := range jobs {
		key := append(j.password[:len(j.password):len(j.password)], 0)
		setupSalted(&states[i], key, j.salt[:])
		cs[i] = &states[i]
		kw[i] = keyWords(key)
		sw[i] = keyWords(j.salt[:])
	}
	rounds := uint64(1) << jobs[0].cost
	switch n {
	case 1:
		c := [1]*bfState{cs[0]}
		k, s := [1][18]uint32{kw[0]}, [1][18]uint32{sw[0]}
		for i := uint64(0); i < rounds; i++ {
			expandKey1(&c, &k)
			expandKey1(&c, &s)
		}
	case 2:
		c := [2]*bfState{cs[0], cs[1]}
		k, s := [2][18]uint32{kw[0], kw[1]}, [2][18]uint32{sw[0], sw[1]}
		for i := uint64(0); i < rounds; i++ {
			expandKey2(&c, &k)
			expandKey2(&c, &s)
		}
	case 3:
		c := [3]*bfState{cs[0], cs[1], cs[2]}
		k, s := [3][18]uint32{kw[0], kw[1], kw[2]}, [3][18]uint32{sw[0], sw[1], sw[2]}
		for i := uint64(0); i < rounds; i++ {
			expandKey3(&c, &k)
			expandKey3(&c, &s)
		}
	default:
		for i := uint64(0); i < rounds; i++ {
			expandKey4(&cs, &kw)
			expandKey4(&cs, &sw)
		}
	}
	for i, j := range jobs {
		data := magicCipherData
		for b := 0; b < 24; b += 8 {
			l := uint32(data[b])<<24 | uint32(data[b+1])<<16 | uint32(data[b+2])<<8 | uint32(data[b+3])
			r := uint32(data[b+4])<<24 | uint32(data[b+5])<<16 | uint32(data[b+6])<<8 | uint32(data[b+7])
			for k := 0; k < 64; k++ {
				l, r = encrypt1(cs[i], l, r)
			}
			data[b], data[b+1], data[b+2], data[b+3] = byte(l>>24), byte(l>>16), byte(l>>8), byte(l)
			data[b+4], data[b+5], data[b+6], data[b+7] = byte(r>>24), byte(r>>16), byte(r>>8), byte(r)
		}
		copy(j.out[:], data[:23])
	}
}

// bcryptPool runs hashes on a few worker goroutines. One collector goroutine groups queued jobs of
// the same cost into batches of up to `lanes` (waiting at most `wait` after the first job of a
// batch, longer only while every worker is busy) so that each batch is one interleaved run.
type bcryptPool struct {
	queue   chan *bcryptJob
	batches chan []*bcryptJob
	lanes   int
	wait    time.Duration
	runs    atomic.Int64 // interleaved runs started (for tests)
}

func newBcryptPool(workers, lanes int, wait time.Duration) *bcryptPool {
	p := &bcryptPool{queue: make(chan *bcryptJob, 4096), batches: make(chan []*bcryptJob), lanes: lanes, wait: wait}
	for i := 0; i < workers; i++ {
		go p.worker()
	}
	go p.collector()
	return p
}

func (p *bcryptPool) worker() {
	for jobs := range p.batches {
		p.runs.Add(1)
		bcryptLanes(jobs)
		for _, j := range jobs {
			j.done <- struct{}{}
		}
	}
}

func (p *bcryptPool) collector() {
	var pending *bcryptJob
	timer := time.NewTimer(time.Hour)
	for {
		jobs := make([]*bcryptJob, 0, p.lanes)
		if pending != nil {
			jobs, pending = append(jobs, pending), nil
		} else {
			jobs = append(jobs, <-p.queue)
		}
		if !timer.Stop() {
			select {
			case <-timer.C:
			default:
			}
		}
		timer.Reset(p.wait)
		expired := false
		for jobs != nil && len(jobs) < p.lanes {
			var j *bcryptJob
			if expired {
				// Hand the batch to the first free worker; keep collecting until one is.
				select {
				case p.batches <- jobs:
					jobs = nil
					continue
				case j = <-p.queue:
				}
			} else {
				select {
				case j = <-p.queue:
				case <-timer.C:
					expired = true
					continue
				}
			}
			if j.cost != jobs[0].cost {
				pending = j
				break
			}
			jobs = append(jobs, j)
		}
		if jobs != nil {
			p.batches <- jobs
		}
	}
}

func (p *bcryptPool) run(j *bcryptJob) {
	j.done = make(chan struct{}, 1)
	p.queue <- j
	<-j.done
}

// calibrateLanes times 1..4 interleaved lanes at a low cost and returns the lane count with the
// lowest time per hash (register pressure decides whether 4 lanes beat 2 on a given CPU).
func calibrateLanes() int {
	const cost = 7
	best, bestPer := 1, time.Duration(0)
	pw := []byte("calibration")
	for lanes := 1; lanes <= 4; lanes++ {
		jobs := make([]*bcryptJob, lanes)
		for i := range jobs {
			jobs[i] = &bcryptJob{password: pw, cost: cost}
			jobs[i].salt[0] = byte(i)
		}
		var per time.Duration
		for rep := 0; rep < 3; rep++ {
			t := time.Now()
			bcryptLanes(jobs)
			if d := time.Since(t) / time.Duration(lanes); rep == 0 || d < per {
				per = d
			}
		}
		if lanes == 1 || per < bestPer {
			best, bestPer = lanes, per
		}
	}
	return best
}

// hash returns a new "$2a$<cost>$..." hash of password with a fresh random salt.
func (p *bcryptPool) hash(password []byte, cost int) ([]byte, error) {
	if len(password) > 72 {
		return nil, errors.New("bcrypt: password longer than 72 bytes")
	}
	j := &bcryptJob{password: password, cost: uint32(cost)}
	if _, err := rand.Read(j.salt[:]); err != nil {
		return nil, err
	}
	p.run(j)
	out := make([]byte, 0, 60)
	out = append(out, '$', '2', 'a', '$', byte('0'+cost/10), byte('0'+cost%10), '$')
	out = bcEncoding.AppendEncode(out, j.salt[:])
	out = bcEncoding.AppendEncode(out, j.out[:])
	return out, nil
}

// verify recomputes the hash with the stored salt and cost and compares in constant time.
func (p *bcryptPool) verify(hash, password []byte) bool {
	if len(hash) != 60 || hash[0] != '$' || hash[1] != '2' || hash[3] != '$' || hash[6] != '$' {
		return false
	}
	cost := int(hash[4]-'0')*10 + int(hash[5]-'0')
	if hash[4] < '0' || hash[4] > '9' || hash[5] < '0' || hash[5] > '9' || cost < 4 || cost > 31 {
		return false
	}
	if len(password) > 72 {
		return false
	}
	j := &bcryptJob{password: password, cost: uint32(cost)}
	var salt [16]byte
	if n, err := bcEncoding.Decode(salt[:], hash[7:29]); err != nil || n != 16 {
		return false
	}
	j.salt = salt
	p.run(j)
	var enc [31]byte
	bcEncoding.Encode(enc[:], j.out[:])
	return subtle.ConstantTimeCompare(enc[:], hash[29:60]) == 1
}
