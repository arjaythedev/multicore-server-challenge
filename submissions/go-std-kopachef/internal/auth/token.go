// Package auth signs and verifies the API's HS256 tokens.
package auth

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"hash"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Signer holds an immutable application key and reusable HMAC scratch state.
// Its zero value uses an empty key. A Signer must not be copied after use.
type Signer struct {
	secret []byte
	macs   sync.Pool
}

// NewSigner creates a signer. The caller must keep secret immutable.
func NewSigner(secret []byte) *Signer { return &Signer{secret: secret} }

const tokenTTL = 30 * 24 * time.Hour
const tokenHeader = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"

// Reuse the standard HMAC context and its key setup, resetting message state
// before returning it to the pool. Every token still gets a fresh digest and
// every authentication checks its signature and expiration.
type tokenMACState struct {
	mac    hash.Hash
	input  [256]byte
	digest [sha256.Size]byte
}

func (a *Signer) tokenMAC(message string) [sha256.Size]byte {
	state, _ := a.macs.Get().(*tokenMACState)
	if state == nil {
		state = &tokenMACState{mac: hmac.New(sha256.New, a.secret)}
	}
	if len(message) <= len(state.input) {
		n := copy(state.input[:], message)
		_, _ = state.mac.Write(state.input[:n])
	} else {
		// Valid tokens with extra claims retain the unbounded compatibility path.
		_, _ = state.mac.Write([]byte(message))
	}
	state.mac.Sum(state.digest[:0])
	digest := state.digest // Copy before another request can reuse the context.
	state.mac.Reset()
	a.macs.Put(state)
	return digest
}

// IssueToken signs a fresh token for id with the API's existing lifetime.
func (a *Signer) IssueToken(id int64) string {
	now := time.Now().Unix()
	claims := make([]byte, 0, 80)
	claims = append(claims, `{"sub":"`...)
	claims = strconv.AppendInt(claims, id, 10)
	claims = append(claims, `","iat":`...)
	claims = strconv.AppendInt(claims, now, 10)
	claims = append(claims, `,"exp":`...)
	claims = strconv.AppendInt(claims, now+int64(tokenTTL/time.Second), 10)
	claims = append(claims, '}')
	token := make([]byte, 0, len(tokenHeader)+1+base64.RawURLEncoding.EncodedLen(len(claims))+1+43)
	token = append(token, tokenHeader...)
	token = append(token, '.')
	token = base64.RawURLEncoding.AppendEncode(token, claims)
	signature := a.tokenMAC(string(token))
	token = append(token, '.')
	token = base64.RawURLEncoding.AppendEncode(token, signature[:])
	return string(token)
}

// AuthHeader verifies an Authorization value and returns its presented token.
// An id of zero means the header was missing or invalid.
func (a *Signer) AuthHeader(h string) (id int64, token string, present bool) {
	if h == "" {
		return 0, "", false
	}
	token, ok := strings.CutPrefix(h, "Token ")
	if !ok {
		return 0, "", true
	}
	first := strings.IndexByte(token, '.')
	last := strings.LastIndexByte(token, '.')
	if first <= 0 || last <= first+1 || last == len(token)-1 {
		return 0, "", true
	}
	if token[:first] != tokenHeader {
		// Exact comparison recognizes our fixed HS256 header without decoding
		// it. Other headers retain full JSON parsing and algorithm validation.
		header, err := base64.RawURLEncoding.DecodeString(token[:first])
		if err != nil {
			return 0, "", true
		}
		var hdr struct {
			Alg string `json:"alg"`
		}
		if json.Unmarshal(header, &hdr) != nil || hdr.Alg != "HS256" {
			return 0, "", true
		}
	}
	if len(token)-last-1 != base64.RawURLEncoding.EncodedLen(sha256.Size) {
		return 0, "", true
	}
	var signature [32]byte
	n, err := base64.RawURLEncoding.Decode(signature[:], []byte(token[last+1:]))
	if err != nil || n != len(signature) {
		return 0, "", true
	}
	expected := a.tokenMAC(token[:last])
	if !hmac.Equal(signature[:], expected[:]) {
		return 0, "", true
	}
	payload, err := base64.RawURLEncoding.DecodeString(token[first+1 : last])
	if err != nil {
		return 0, "", true
	}
	var claims struct {
		Sub string `json:"sub"`
		Exp int64  `json:"exp"`
	}
	if json.Unmarshal(payload, &claims) != nil || claims.Exp <= time.Now().Unix() {
		return 0, "", true
	}
	id, ok = parseUint(claims.Sub)
	if !ok || id <= 0 {
		return 0, "", true
	}
	return id, token, true
}

// parseUint accepts only ASCII digits (no sign, no spaces) that fit in an int64.
func parseUint(s string) (int64, bool) {
	if s == "" {
		return 0, false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
	}
	n, err := strconv.ParseInt(s, 10, 64)
	return n, err == nil
}
