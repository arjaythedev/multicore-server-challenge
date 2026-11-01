package conduit

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"hash"
	"math"
	"strconv"
	"sync"
	"time"
	"unsafe"
)

// Tokens are checked as the reference app's golang-jwt v5.3.1 does with
// RegisteredClaims, WithValidMethods("HS256") and WithExpirationRequired:
//
//   - exactly three dot-separated parts, each unpadded base64url (lenient
//     about the trailing bits);
//   - a header that is a JSON object with a string "alg" equal to "HS256" (the
//     last "alg" wins) and no number too large for a float64;
//   - claims that are a JSON object whose members match RegisteredClaims'
//     fields by name, case folded: "iss", "sub" and "jti" strings or null;
//     "aud" a string, null or an array of strings; "exp", "nbf" and "iat" a
//     number, a string holding one, or null;
//   - a valid HMAC-SHA256 signature;
//   - now before exp, which is required, and not before nbf, if set; both are
//     truncated to the second;
//   - a "sub" that is a decimal int64 above zero (leading zeros allowed).
//
// The reference app accepts "007" as user 7, a fractional or string exp, and
// any claims beyond these; so does this.

// tokenTTL is the issued tokens' lifetime.
const tokenTTL = 30 * 24 * time.Hour

var b64 = base64.RawURLEncoding

// jwtHeader is the encoded {"alg":"HS256","typ":"JWT"}, what golang-jwt writes.
const jwtHeader = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"

// signer holds an HMAC keyed with the secret and scratch space; a pool of
// them keeps verification allocation-free.
type signer struct {
	mac hash.Hash
	sum [sha256.Size]byte
	sig [48]byte
	buf []byte
}

type tokens struct {
	pool sync.Pool
	now  func() time.Time
}

func newTokens(secret []byte) *tokens {
	key := bytes.Clone(secret)
	t := &tokens{now: time.Now}
	t.pool.New = func() any { return &signer{mac: hmac.New(sha256.New, key)} }
	return t
}

// macOf returns the HMAC-SHA256 of msg, valid until s goes back to the pool.
func (s *signer) macOf(msg []byte) []byte {
	s.mac.Reset()
	s.mac.Write(msg)
	return s.mac.Sum(s.sum[:0])
}

// sign appends a token for user id, issued at now.
func (t *tokens) sign(dst []byte, id int64, now time.Time) []byte {
	var claims [80]byte
	c := append(claims[:0], `{"sub":"`...)
	c = strconv.AppendInt(c, id, 10)
	c = append(c, `","exp":`...)
	c = strconv.AppendInt(c, now.Add(tokenTTL).Unix(), 10)
	c = append(c, `,"iat":`...)
	c = strconv.AppendInt(c, now.Unix(), 10)
	c = append(c, '}')

	start := len(dst)
	dst = append(dst, jwtHeader+"."...)
	dst = b64.AppendEncode(dst, c)
	s := t.pool.Get().(*signer)
	dst = append(dst, '.')
	dst = b64.AppendEncode(dst, s.macOf(dst[start:len(dst)-1]))
	t.pool.Put(s)
	return dst
}

// verify returns the user id of a valid token, or 0.
func (t *tokens) verify(tok []byte) int64 {
	d1 := bytes.IndexByte(tok, '.')
	if d1 < 0 {
		return 0
	}
	d2 := d1 + 1 + bytes.IndexByte(tok[d1+1:], '.')
	if d2 == d1 || bytes.IndexByte(tok[d2+1:], '.') >= 0 {
		return 0
	}
	hdr, claims, sig := tok[:d1], tok[d1+1:d2], tok[d2+1:]

	s := t.pool.Get().(*signer)
	defer t.pool.Put(s)
	hn, cn := b64.DecodedLen(len(hdr)), b64.DecodedLen(len(claims))
	if cap(s.buf) < hn+cn {
		s.buf = make([]byte, hn+cn)
	}
	h, err := decodeSeg(s.buf[:hn], hdr)
	if err != nil || !validJSON(h) || !headerOK(topValue(h)) {
		return 0
	}
	c, err := decodeSeg(s.buf[hn:hn+cn], claims)
	if err != nil || !validJSON(c) {
		return 0
	}
	sub, ok := claimsOK(topValue(c), t.now())
	if !ok {
		return 0
	}
	if b64.DecodedLen(len(sig)) > len(s.sig) {
		return 0
	}
	got, err := decodeSeg(s.sig[:], sig)
	if err != nil || !hmac.Equal(got, s.macOf(tok[:d2])) {
		return 0
	}
	id, ok := subjectID(sub)
	if !ok || id <= 0 {
		return 0
	}
	return id
}

// subjectID parses the quoted "sub" q.
func subjectID(q []byte) (int64, bool) {
	if q == nil {
		return 0, false
	}
	if verbatim(q) {
		return parseUint(q[1 : len(q)-1])
	}
	var buf [64]byte
	if unquotedLen(q) > len(buf) {
		return parseUint(appendUnquote(nil, q))
	}
	return parseUint(appendUnquote(buf[:0], q))
}

func decodeSeg(dst, src []byte) ([]byte, error) {
	n, err := b64.Decode(dst, src)
	return dst[:n], err
}

// headerOK checks the decoded header h, a valid JSON value. golang-jwt
// unmarshals it into a map[string]any: any object will do, as long as each
// number in it fits a float64.
func headerOK(h []byte) bool {
	m, ok := objectOf(h)
	if !ok || !numbersFit(h) {
		return false
	}
	var alg []byte
	for {
		name, val, ok := m.next()
		if !ok {
			break
		}
		if nameIs(name, "alg") {
			alg = val
		}
	}
	return isStr(alg) && nameIs(alg, "HS256")
}

// numbersFit reports whether every number in the valid JSON value v parses as
// a float64 without overflowing.
func numbersFit(v []byte) bool {
	for i := 0; i < len(v); {
		switch c := v[i]; {
		case c == '"':
			i = skipString(v, i)
		case c == '-' || '0' <= c && c <= '9':
			e := scanNumber(v, i)
			if !floatOK(v[i:e]) {
				return false
			}
			i = e
		default:
			i++
		}
	}
	return true
}

func floatOK(num []byte) bool {
	_, err := strconv.ParseFloat(unsafe.String(unsafe.SliceData(num), len(num)), 64)
	return err == nil
}

// claimsOK checks the decoded claims c, a valid JSON value, at time now, and
// returns the last non-null "sub", quoted.
func claimsOK(c []byte, now time.Time) (sub []byte, ok bool) {
	m, ok := objectOf(c)
	if !ok {
		return nil, false // null leaves the claims empty, so exp is missing
	}
	var subQ, exp, nbf []byte
	for {
		name, val, more := m.next()
		if !more {
			break
		}
		switch {
		case nameFolds(name, "sub"):
			if !isNull(val) {
				if !isStr(val) {
					return nil, false
				}
				subQ = val
			}
		case nameFolds(name, "iss"), nameFolds(name, "jti"):
			if !isNull(val) && !isStr(val) {
				return nil, false
			}
		case nameFolds(name, "aud"):
			if !audOK(val) {
				return nil, false
			}
		case nameFolds(name, "exp"):
			if exp, ok = dateOf(val); !ok {
				return nil, false
			}
		case nameFolds(name, "nbf"):
			if nbf, ok = dateOf(val); !ok {
				return nil, false
			}
		case nameFolds(name, "iat"):
			if _, ok = dateOf(val); !ok {
				return nil, false
			}
		}
	}
	if exp == nil || !now.Before(numericDate(exp)) {
		return nil, false
	}
	if nbf != nil && now.Before(numericDate(nbf)) {
		return nil, false
	}
	return subQ, true
}

func audOK(v []byte) bool {
	if isNull(v) || isStr(v) {
		return true
	}
	a, ok := arrayOf(v)
	if !ok {
		return false
	}
	for {
		e, more := a.next()
		if !more {
			return true
		}
		if !isStr(e) {
			return false
		}
	}
}

// dateOf checks a NumericDate value and returns its number, or nil for null.
func dateOf(v []byte) (num []byte, ok bool) {
	if isNull(v) {
		return nil, true
	}
	if isStr(v) {
		if !verbatim(v) {
			v = appendUnquote(nil, v)
		} else {
			v = v[1 : len(v)-1]
		}
		if !isNumber(v) {
			return nil, false
		}
	} else if v[0] != '-' && (v[0] < '0' || v[0] > '9') {
		return nil, false
	}
	if !floatOK(v) {
		return nil, false
	}
	return v, true
}

// numericDate converts a number of seconds as golang-jwt does.
func numericDate(num []byte) time.Time {
	f, _ := strconv.ParseFloat(unsafe.String(unsafe.SliceData(num), len(num)), 64)
	round, frac := math.Modf(f)
	return time.Unix(int64(round), int64(frac*1e9)).Truncate(time.Second)
}

// parseUint accepts only ASCII digits (no sign, no spaces) that fit in an int64.
func parseUint(s []byte) (int64, bool) {
	if len(s) == 0 {
		return 0, false
	}
	var n int64
	for _, c := range s {
		if c < '0' || c > '9' {
			return 0, false
		}
		d := int64(c - '0')
		if n > (math.MaxInt64-d)/10 {
			return 0, false
		}
		n = n*10 + d
	}
	return n, true
}
