package main

// jwt.go: HS256 JSON Web Tokens with exactly the claims {sub, iat, exp}. Every token presented is
// verified (signature, alg, exp) on every request; nothing is remembered between requests.

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"hash"
	"math"
	"strconv"
	"sync"
	"time"
)

const tokenTTL = 30 * 24 * 3600

// The header golang-jwt and most libraries emit; anything else is parsed as JSON.
const jwtHeaderB64 = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"

var b64 = base64.RawURLEncoding

var hmacPool = sync.Pool{}

type signer struct{ secret []byte }

func (s *signer) mac() hash.Hash {
	if h, ok := hmacPool.Get().(hash.Hash); ok {
		h.Reset()
		return h
	}
	return hmac.New(sha256.New, s.secret)
}

func (s *signer) release(h hash.Hash) { hmacPool.Put(h) }

// issue mints a token for user id, valid 30 days.
func (s *signer) issue(id int64) string {
	now := time.Now().Unix()
	payload := make([]byte, 0, 64)
	payload = append(payload, `{"sub":"`...)
	payload = strconv.AppendInt(payload, id, 10)
	payload = append(payload, `","iat":`...)
	payload = strconv.AppendInt(payload, now, 10)
	payload = append(payload, `,"exp":`...)
	payload = strconv.AppendInt(payload, now+tokenTTL, 10)
	payload = append(payload, '}')

	tok := make([]byte, 0, len(jwtHeaderB64)+1+b64.EncodedLen(len(payload))+1+43)
	tok = append(tok, jwtHeaderB64...)
	tok = append(tok, '.')
	tok = b64.AppendEncode(tok, payload)
	h := s.mac()
	h.Write(tok)
	var sum [32]byte
	sig := h.Sum(sum[:0])
	s.release(h)
	tok = append(tok, '.')
	tok = b64.AppendEncode(tok, sig)
	return string(tok)
}

// verify checks an HS256 token and returns its subject (user id > 0), or 0 if invalid.
func (s *signer) verify(tok []byte) int64 {
	d1 := bytes.IndexByte(tok, '.')
	if d1 < 0 {
		return 0
	}
	d2 := bytes.IndexByte(tok[d1+1:], '.')
	if d2 < 0 {
		return 0
	}
	d2 += d1 + 1
	header, payload, sig := tok[:d1], tok[d1+1:d2], tok[d2+1:]
	if len(sig) != 43 {
		return 0
	}
	var want [32]byte
	if _, err := b64.Decode(want[:], sig); err != nil {
		return 0
	}
	h := s.mac()
	h.Write(tok[:d2])
	var sum [32]byte
	got := h.Sum(sum[:0])
	s.release(h)
	if subtle.ConstantTimeCompare(got, want[:]) != 1 {
		return 0
	}
	// Signature is good; now the header's alg must be HS256 and the claims must be sane.
	if string(header) != jwtHeaderB64 {
		var hb [256]byte
		if len(header) > b64.EncodedLen(len(hb)) {
			return 0
		}
		n, err := b64.Decode(hb[:], header)
		if err != nil {
			return 0
		}
		var hd struct {
			Alg string `json:"alg"`
		}
		if json.Unmarshal(hb[:n], &hd) != nil || hd.Alg != "HS256" {
			return 0
		}
	}
	var pb [512]byte
	var pl []byte
	if len(payload) <= b64.EncodedLen(len(pb)) {
		n, err := b64.Decode(pb[:], payload)
		if err != nil {
			return 0
		}
		pl = pb[:n]
	} else {
		var err error
		pl, err = b64.DecodeString(string(payload))
		if err != nil {
			return 0
		}
	}
	sub, exp, ok := parseClaims(pl)
	if !ok {
		// Fall back to a full JSON parse for unusual layouts.
		var c struct {
			Sub json.RawMessage `json:"sub"`
			Exp json.RawMessage `json:"exp"`
		}
		if json.Unmarshal(pl, &c) != nil || c.Sub == nil || c.Exp == nil {
			return 0
		}
		var subStr string
		if json.Unmarshal(c.Sub, &subStr) != nil {
			return 0
		}
		var expF float64
		if json.Unmarshal(c.Exp, &expF) != nil {
			return 0
		}
		id, ok := parseUint(subStr)
		if !ok || id <= 0 {
			return 0
		}
		sub, exp = id, int64(expF)
	}
	if exp <= time.Now().Unix() {
		return 0
	}
	return sub
}

// parseClaims reads "sub" (a decimal string) and "exp" (an integer) from a flat JSON object
// of string and number members. It returns ok=false for anything it does not understand.
func parseClaims(p []byte) (sub, exp int64, ok bool) {
	var haveSub, haveExp bool
	i := 0
	skipWS := func() {
		for i < len(p) && (p[i] == ' ' || p[i] == '\n' || p[i] == '\t' || p[i] == '\r') {
			i++
		}
	}
	skipWS()
	if i >= len(p) || p[i] != '{' {
		return 0, 0, false
	}
	i++
	for {
		skipWS()
		if i >= len(p) {
			return 0, 0, false
		}
		if p[i] == '}' {
			break
		}
		if p[i] != '"' {
			return 0, 0, false
		}
		i++
		ks := i
		for i < len(p) && p[i] != '"' {
			if p[i] == '\\' {
				return 0, 0, false
			}
			i++
		}
		if i >= len(p) {
			return 0, 0, false
		}
		key := p[ks:i]
		i++
		skipWS()
		if i >= len(p) || p[i] != ':' {
			return 0, 0, false
		}
		i++
		skipWS()
		if i >= len(p) {
			return 0, 0, false
		}
		switch p[i] {
		case '"':
			i++
			vs := i
			for i < len(p) && p[i] != '"' {
				if p[i] == '\\' {
					return 0, 0, false
				}
				i++
			}
			if i >= len(p) {
				return 0, 0, false
			}
			if string(key) == "sub" {
				v, good := parseUint(string(p[vs:i]))
				if !good || v <= 0 {
					return 0, 0, false
				}
				sub, haveSub = v, true
			} else if string(key) == "exp" {
				return 0, 0, false
			}
			i++
		default:
			vs := i
			for i < len(p) && p[i] != ',' && p[i] != '}' && p[i] != ' ' {
				i++
			}
			if string(key) == "exp" {
				v, err := strconv.ParseInt(string(p[vs:i]), 10, 64)
				if err != nil {
					return 0, 0, false
				}
				exp, haveExp = v, true
			} else if string(key) == "sub" {
				return 0, 0, false
			}
		}
		skipWS()
		if i < len(p) && p[i] == ',' {
			i++
			continue
		}
	}
	return sub, exp, haveSub && haveExp
}

// parseUint accepts only ASCII digits that fit in an int64.
func parseUint(s string) (int64, bool) {
	if s == "" || len(s) > 19 {
		return 0, false
	}
	var n int64
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
		d := int64(s[i] - '0')
		if n > (math.MaxInt64-d)/10 {
			return 0, false // overflow
		}
		n = n*10 + d
	}
	return n, true
}
