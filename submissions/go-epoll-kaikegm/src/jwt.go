package main

// jwt.go signs and verifies HS256 tokens using github.com/KaikeGM/zerojwt/v2
// (0 B/op, 0 allocs/op, precomputed SHA-256 ipad/opad states). Tokens outside
// the fast path's standard shape fall back to golang-jwt/jwt/v5 so unusual
// conformance test tokens get the exact reference decision.

import (
	"errors"
	"strconv"
	"time"

	"github.com/KaikeGM/zerojwt/v2"
	"github.com/golang-jwt/jwt/v5"
)

type jwtCodec struct {
	secret  []byte
	v       *zerojwt.Verifier
	scratch *zerojwt.Scratch
	claims  zerojwt.Claims
}

func newJWTCodec(secret []byte) *jwtCodec {
	v, err := zerojwt.New(secret, zerojwt.Options{
		AllowShortSecret: true,
	})
	if err != nil {
		panic(err)
	}
	return &jwtCodec{
		secret:  secret,
		v:       v,
		scratch: v.NewScratch(),
	}
}

// verify returns the subject id and whether the token is valid.
func (c *jwtCodec) verify(tok []byte) (int64, bool) {
	err := c.v.VerifyWithScratch(tok, time.Now().Unix(), &c.claims, c.scratch)
	if err == nil {
		sub := c.claims.Subject()
		if c.claims.HasSub && c.claims.SubjectID > 0 && len(sub) > 0 && sub[0] != '0' {
			return c.claims.SubjectID, true
		}
		return 0, false
	}
	if errors.Is(err, zerojwt.ErrInvalidSignature) ||
		errors.Is(err, zerojwt.ErrTokenExpired) ||
		errors.Is(err, zerojwt.ErrTokenNotValidYet) ||
		errors.Is(err, zerojwt.ErrMissingExp) {
		return 0, false
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

// appendToken signs {"sub":"<id>","exp":<now+30d>,"iat":<now>} using zerojwt/v2.
func (c *jwtCodec) appendToken(dst []byte, id int64, now time.Time) []byte {
	var claims [96]byte
	cl := append(claims[:0], `{"sub":"`...)
	cl = strconv.AppendInt(cl, id, 10)
	cl = append(cl, `","exp":`...)
	cl = strconv.AppendInt(cl, now.Add(tokenTTL).Unix(), 10)
	cl = append(cl, `,"iat":`...)
	cl = strconv.AppendInt(cl, now.Unix(), 10)
	cl = append(cl, '}')
	out, err := c.v.SignWithScratch(dst, cl, c.scratch)
	if err != nil {
		return dst
	}
	return out
}
