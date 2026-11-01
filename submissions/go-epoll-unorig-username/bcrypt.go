package main

// bcrypt on BCRYPT_THREADS dedicated OS threads; a login or signup goroutine waits on a channel, never an
// event loop. One Blowfish round is a chain of dependent S-box loads, so a lone hash leaves the core mostly
// waiting. Up to four queued hashes run in lockstep, each its own complete EksBlowfish with all 2^cost
// rounds; the lanes only fill each other's load stalls.

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

type bfState [18 + 4*256]uint32 // P, then S-boxes 0-3

type bcJob struct {
	cost int
	salt [16]byte
	key  []byte
	out  chan [24]byte
}

var (
	bcB64  = base64.NewEncoding("./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789").WithPadding(base64.NoPadding)
	bcJobs = make(chan *bcJob, 1024)
	bcFill sync.Mutex
)

// startBcrypt runs the workers; one holding a job waits up to window for more to fill its four lanes.
func startBcrypt(threads int, window time.Duration) {
	for range threads {
		go func() {
			runtime.LockOSThread()
			for {
				bcFill.Lock()
				jobs := []*bcJob{<-bcJobs}
				t := time.NewTimer(window)
			fill:
				for len(jobs) < 4 {
					select {
					case j := <-bcJobs:
						jobs = append(jobs, j)
					case <-t.C:
						break fill
					}
				}
				t.Stop()
				bcFill.Unlock()
				slices.SortFunc(jobs, func(a, b *bcJob) int { return a.cost - b.cost })
				for len(jobs) > 0 {
					n := 1
					for n < len(jobs) && jobs[n].cost == jobs[0].cost {
						n++
					}
					eks(jobs[:n])
					jobs = jobs[n:]
				}
			}
		}()
	}
}

func bcryptRaw(cost int, salt [16]byte, pw string) [24]byte {
	key := append([]byte(pw), 0) // the password's bytes and a NUL, cut to 72 bytes
	j := &bcJob{cost, salt, key[:min(len(key), 72)], make(chan [24]byte, 1)}
	bcJobs <- j
	return <-j.out
}

func hashPassword(pw string) (string, error) {
	if len(pw) > 72 {
		return "", errors.New("password longer than 72 bytes")
	}
	var salt [16]byte
	rand.Read(salt[:])
	h := bcryptRaw(10, salt, pw)
	return "$2a$10$" + bcB64.EncodeToString(salt[:]) + bcB64.EncodeToString(h[:23]), nil
}

// passwordMatches checks pw against a stored $2a$, $2b$ or $2y$ hash.
func passwordMatches(hash, pw string) bool {
	if len(hash) != 60 || hash[:2] != "$2" || !strings.ContainsRune("aby", rune(hash[2])) || hash[3] != '$' || hash[6] != '$' {
		return false
	}
	cost, err := strconv.Atoi(hash[4:6])
	salt, err2 := bcB64.DecodeString(hash[7:29])
	if err != nil || err2 != nil || cost < 4 || cost > 31 {
		return false
	}
	h := bcryptRaw(cost, [16]byte(salt), pw)
	return subtle.ConstantTimeCompare([]byte(bcB64.EncodeToString(h[:23])), []byte(hash[29:])) == 1
}

func f(s *bfState, x uint32) uint32 {
	return (s[18+int(x>>24)] + s[274+int(byte(x>>16))] ^ s[530+int(byte(x>>8))]) + s[786+int(byte(x))]
}

// enc Blowfish-encrypts one block (l, r) in each of the four lanes, interleaved round by round.
func enc(st *[4]bfState, b *[8]uint32) {
	s0, s1, s2, s3 := &st[0], &st[1], &st[2], &st[3]
	l0, r0, l1, r1, l2, r2, l3, r3 := b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]
	for i := 0; i < 16; i += 2 {
		l0, l1, l2, l3 = l0^s0[i], l1^s1[i], l2^s2[i], l3^s3[i]
		r0, r1, r2, r3 = r0^f(s0, l0), r1^f(s1, l1), r2^f(s2, l2), r3^f(s3, l3)
		r0, r1, r2, r3 = r0^s0[i+1], r1^s1[i+1], r2^s2[i+1], r3^s3[i+1]
		l0, l1, l2, l3 = l0^f(s0, r0), l1^f(s1, r1), l2^f(s2, r2), l3^f(s3, r3)
	}
	*b = [8]uint32{r0 ^ s0[17], l0 ^ s0[16], r1 ^ s1[17], l1 ^ s1[16], r2 ^ s2[17], l2 ^ s2[16], r3 ^ s3[17], l3 ^ s3[16]}
}

// words18 is 18 big-endian words of b read cyclically (Blowfish's key stream).
func words18(b []byte) (w [18]uint32) {
	j := 0
	for i := range w {
		for range 4 {
			w[i] = w[i]<<8 | uint32(b[j])
			j = (j + 1) % len(b)
		}
	}
	return
}

// expand is ExpandKey: P ^= key stream, then re-encrypt P and the S-boxes in place, XORing in the salt
// words when given (the cost loop's ExpandKey(state, 0, key) has none).
func expand(st *[4]bfState, key, salt *[4][18]uint32) {
	for k := range st {
		for i := range 18 {
			st[k][i] ^= key[k][i]
		}
	}
	var b [8]uint32
	for i := 0; i < len(bfState{}); i += 2 {
		if salt != nil {
			for k := range 4 {
				b[2*k] ^= salt[k][i&3]
				b[2*k+1] ^= salt[k][i&3+1]
			}
		}
		enc(st, &b)
		for k := range st {
			st[k][i], st[k][i+1] = b[2*k], b[2*k+1]
		}
	}
}

// eks computes raw bcrypt (24 bytes) for up to four jobs of the same cost and hands each its result.
// ponytail: always four lanes (spare ones repeat a job), so a lone hash costs a full group; a 1-lane
// path would save that at low rates, where the CPU is idle anyway.
func eks(jobs []*bcJob) {
	st := new([4]bfState)
	var key, salt [4][18]uint32
	for k := range 4 {
		j := jobs[min(k, len(jobs)-1)]
		st[k], key[k], salt[k] = bfInit, words18(j.key), words18(j.salt[:])
	}
	expand(st, &key, &salt)
	for range 1 << jobs[0].cost {
		expand(st, &key, nil)
		expand(st, &salt, nil)
	}
	magic := [6]uint32{0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274} // "OrpheanBeholderScryDoubt"
	var c [3][8]uint32
	for i := range c {
		for k := range 4 {
			c[i][2*k], c[i][2*k+1] = magic[2*i], magic[2*i+1]
		}
		for range 64 {
			enc(st, &c[i])
		}
	}
	for k, j := range jobs {
		var out [24]byte
		for i := range c {
			binary.BigEndian.PutUint32(out[8*i:], c[i][2*k])
			binary.BigEndian.PutUint32(out[8*i+4:], c[i][2*k+1])
		}
		j.out <- out
	}
}
