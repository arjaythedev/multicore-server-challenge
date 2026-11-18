package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"hash"
	"strconv"
	"strings"
	"sync"
	"time"

	"conduit/bcrypt4"
)

const (
	bcryptCost = 10
	tokenTTL   = 30 * 24 * time.Hour
	// base64url of {"alg":"HS256","typ":"JWT"}
	jwtHeader = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
)

var b64 = base64.RawURLEncoding

type signer struct {
	pool sync.Pool
}

func newSigner(secret string) *signer {
	key := []byte(secret)
	return &signer{pool: sync.Pool{New: func() any { return hmac.New(sha256.New, key) }}}
}

func (s *signer) mac(dst []byte, msg string) []byte {
	h := s.pool.Get().(hash.Hash)
	h.Reset()
	h.Write(unsafeBytes(msg))
	dst = h.Sum(dst)
	s.pool.Put(h)
	return dst
}

func (s *signer) sign(id int64) string {
	now := time.Now().Unix()
	var claims [96]byte
	c := append(claims[:0], `{"sub":"`...)
	c = strconv.AppendInt(c, id, 10)
	c = append(c, `","iat":`...)
	c = strconv.AppendInt(c, now, 10)
	c = append(c, `,"exp":`...)
	c = strconv.AppendInt(c, now+int64(tokenTTL/time.Second), 10)
	c = append(c, '}')

	buf := make([]byte, 0, len(jwtHeader)+1+b64.EncodedLen(len(c))+1+43)
	buf = append(buf, jwtHeader...)
	buf = append(buf, '.')
	buf = b64.AppendEncode(buf, c)
	var sum [sha256.Size]byte
	mac := s.mac(sum[:0], unsafeString(buf))
	buf = append(buf, '.')
	buf = b64.AppendEncode(buf, mac)
	return unsafeString(buf)
}

// verify checks the signature, alg and exp of token and returns its subject.
func (s *signer) verify(token string) (int64, bool) {
	dot1 := strings.IndexByte(token, '.')
	if dot1 <= 0 {
		return 0, false
	}
	dot2 := strings.IndexByte(token[dot1+1:], '.')
	if dot2 <= 0 {
		return 0, false
	}
	dot2 += dot1 + 1
	sig := token[dot2+1:]
	if b64.DecodedLen(len(sig)) != sha256.Size {
		return 0, false
	}
	var got, want [sha256.Size]byte
	if n, err := b64.Decode(got[:], unsafeBytes(sig)); err != nil || n != sha256.Size {
		return 0, false
	}
	if !hmac.Equal(s.mac(want[:0], token[:dot2]), got[:]) {
		return 0, false
	}

	var buf [256]byte
	hdr, ok := decodeSegment(buf[:0], token[:dot1])
	if !ok {
		return 0, false
	}
	h, _, err := jwtHead{}.DecodeFrom(hdr)
	if err != nil || h.Alg != "HS256" {
		return 0, false
	}
	payload, ok := decodeSegment(buf[:0], token[dot1+1:dot2])
	if !ok {
		return 0, false
	}
	c, _, err := jwtClaims{}.DecodeFrom(payload)
	if err != nil || c.Exp == nil || *c.Exp <= time.Now().Unix() {
		return 0, false
	}
	id, err := strconv.ParseInt(c.Sub, 10, 64)
	if err != nil || id <= 0 {
		return 0, false
	}
	return id, true
}

func decodeSegment(dst []byte, seg string) ([]byte, bool) {
	if b64.DecodedLen(len(seg)) > cap(dst) {
		return nil, false
	}
	n, err := b64.Decode(dst[:cap(dst)], unsafeBytes(seg))
	if err != nil {
		return nil, false
	}
	return dst[:n], true
}

// hasher runs bcrypt four passwords at a time on a couple of goroutines, so hashing can't take
// over the cores the requests around it need.
var hasher *bcrypt4.Hasher

func hashPassword(pw string) (string, error) {
	return hasher.Generate(unsafeBytes(pw), bcryptCost)
}

// checkPassword reports a mismatch as false and anything else, like a shed job, as an error.
func checkPassword(hash, pw string) (bool, error) {
	switch err := hasher.Compare(hash, unsafeBytes(pw)); err {
	case nil:
		return true, nil
	case bcrypt4.ErrMismatch, bcrypt4.ErrHash:
		return false, nil
	default:
		return false, err
	}
}
