package main

// jwt.go signs and verifies HS256 tokens. Tokens in the standard shape this
// server issues ({"alg":"HS256","typ":"JWT"} header, sub/iat/exp claims) are
// verified by a fast path that allocates nothing; anything else is decided by
// golang-jwt, so unusual tokens get exactly the library's answer.

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"hash"
	"strconv"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// jwtHeader is base64url({"alg":"HS256","typ":"JWT"}), the header golang-jwt,
// the load generator and this server all emit.
const jwtHeader = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"

// jwtCodec signs and verifies HS256 tokens without allocating. It is owned by
// one goroutine. Tokens outside the fast path's narrow, fully-understood shape
// are decided by golang-jwt exactly as before, so acceptance is unchanged.
type jwtCodec struct {
	secret []byte
	mac    hash.Hash
	sum    [sha256.Size]byte
}

func newJWTCodec(secret []byte) *jwtCodec {
	return &jwtCodec{secret: secret, mac: hmac.New(sha256.New, secret)}
}

// verify returns the subject id and whether the token is valid.
func (c *jwtCodec) verify(tok []byte) (int64, bool) {
	id, ok, decided := c.fastVerify(tok, time.Now().UnixNano())
	if decided {
		return id, ok
	}
	return c.slowVerify(string(tok))
}

func (c *jwtCodec) slowVerify(token string) (int64, bool) {
	var claims jwt.RegisteredClaims
	_, err := jwt.ParseWithClaims(token, &claims, func(*jwt.Token) (any, error) { return c.secret, nil },
		jwt.WithValidMethods([]string{"HS256"}), jwt.WithExpirationRequired())
	if err != nil {
		return 0, false
	}
	id, ok := parseUint(claims.Subject)
	return id, ok && id > 0
}

func (c *jwtCodec) fastVerify(tok []byte, now int64) (id int64, ok, decided bool) {
	d1 := bytes.IndexByte(tok, '.')
	if d1 < 0 {
		return 0, false, true
	}
	d2 := bytes.IndexByte(tok[d1+1:], '.')
	if d2 < 0 {
		return 0, false, true
	}
	d2 += d1 + 1
	if string(tok[:d1]) != jwtHeader {
		return 0, false, false
	}
	sig := tok[d2+1:]
	if len(sig) != 43 {
		return 0, false, true // golang-jwt: undecodable or wrong-length signature
	}
	var raw [33]byte
	if n, err := base64.RawURLEncoding.Decode(raw[:], sig); err != nil || n != sha256.Size {
		return 0, false, true
	}
	c.mac.Reset()
	c.mac.Write(tok[:d2])
	if !hmac.Equal(c.mac.Sum(c.sum[:0]), raw[:sha256.Size]) {
		return 0, false, true
	}
	payload := tok[d1+1 : d2]
	var buf [256]byte
	if base64.RawURLEncoding.DecodedLen(len(payload)) > len(buf) {
		return 0, false, false
	}
	n, err := base64.RawURLEncoding.Decode(buf[:], payload)
	if err != nil {
		return 0, false, true
	}
	cl, parsed := parseClaims(buf[:n])
	if !parsed {
		return 0, false, false
	}
	if !cl.hasExp || now >= cl.exp*1e9 || cl.hasNbf && now < cl.nbf*1e9 {
		return 0, false, true
	}
	id, ok = parseUint(string(cl.sub))
	return id, ok && id > 0 && cl.hasSub, true
}

type fastClaims struct {
	sub                         []byte
	exp, nbf                    int64
	hasSub, hasExp, hasNbf, iat bool
}

// parseClaims accepts only a flat object whose keys are exactly sub (string),
// exp, nbf or iat (non-negative integers), each at most once, with no escapes.
// Anything else returns false and is left to golang-jwt.
func parseClaims(b []byte) (c fastClaims, ok bool) {
	i := skipJSONSpace(b, 0)
	if i >= len(b) || b[i] != '{' {
		return c, false
	}
	i = skipJSONSpace(b, i+1)
	if i < len(b) && b[i] == '}' {
		return c, skipJSONSpace(b, i+1) == len(b)
	}
	for {
		key, j, good := jsonPlainString(b, i)
		if !good {
			return c, false
		}
		i = skipJSONSpace(b, j)
		if i >= len(b) || b[i] != ':' {
			return c, false
		}
		i = skipJSONSpace(b, i+1)
		switch string(key) {
		case "sub":
			if c.hasSub {
				return c, false
			}
			c.sub, i, good = jsonPlainString(b, i)
			c.hasSub = true
		case "exp", "nbf", "iat":
			var v int64
			v, i, good = jsonPlainInt(b, i)
			switch key[0] {
			case 'e':
				good = good && !c.hasExp
				c.exp, c.hasExp = v, true
			case 'n':
				good = good && !c.hasNbf
				c.nbf, c.hasNbf = v, true
			default:
				good = good && !c.iat
				c.iat = true
			}
		default:
			return c, false
		}
		if !good {
			return c, false
		}
		i = skipJSONSpace(b, i)
		if i >= len(b) {
			return c, false
		}
		if b[i] == '}' {
			return c, skipJSONSpace(b, i+1) == len(b)
		}
		if b[i] != ',' {
			return c, false
		}
		i = skipJSONSpace(b, i+1)
	}
}

func skipJSONSpace(b []byte, i int) int {
	for i < len(b) && (b[i] == ' ' || b[i] == '\t' || b[i] == '\n' || b[i] == '\r') {
		i++
	}
	return i
}

// jsonPlainString reads a string without escapes or control characters.
func jsonPlainString(b []byte, i int) ([]byte, int, bool) {
	if i >= len(b) || b[i] != '"' {
		return nil, i, false
	}
	for j := i + 1; j < len(b); j++ {
		switch c := b[j]; {
		case c == '"':
			return b[i+1 : j], j + 1, true
		case c == '\\' || c < 0x20 || c >= 0x80:
			return nil, j, false
		}
	}
	return nil, i, false
}

// jsonPlainInt reads a non-negative JSON integer of at most 12 digits.
func jsonPlainInt(b []byte, i int) (int64, int, bool) {
	j := i
	for j < len(b) && b[j] >= '0' && b[j] <= '9' {
		j++
	}
	if j == i || j-i > 12 || (b[i] == '0' && j-i > 1) {
		return 0, j, false
	}
	if j < len(b) && (b[j] == '.' || b[j] == 'e' || b[j] == 'E') {
		return 0, j, false
	}
	v, err := strconv.ParseInt(string(b[i:j]), 10, 64)
	return v, j, err == nil
}

// appendToken signs {"sub":"<id>","exp":<now+30d>,"iat":<now>}, the claim
// order golang-jwt's RegisteredClaims produced.
func (c *jwtCodec) appendToken(dst []byte, id int64, now time.Time) []byte {
	var claims [96]byte
	cl := append(claims[:0], `{"sub":"`...)
	cl = strconv.AppendInt(cl, id, 10)
	cl = append(cl, `","exp":`...)
	cl = strconv.AppendInt(cl, now.Add(tokenTTL).Unix(), 10)
	cl = append(cl, `,"iat":`...)
	cl = strconv.AppendInt(cl, now.Unix(), 10)
	cl = append(cl, '}')
	start := len(dst)
	dst = append(dst, jwtHeader...)
	dst = append(dst, '.')
	dst = base64.RawURLEncoding.AppendEncode(dst, cl)
	c.mac.Reset()
	c.mac.Write(dst[start:])
	sum := c.mac.Sum(c.sum[:0])
	dst = append(dst, '.')
	return base64.RawURLEncoding.AppendEncode(dst, sum)
}
