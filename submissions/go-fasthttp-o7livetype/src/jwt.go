package main

import (
	"time"

	"github.com/cristalhq/jwt/v5"
)

// jwtCodec signs and verifies HS256 tokens with cristalhq/jwt. It is safe for
// concurrent use: the library pools its HMAC state.
type jwtCodec struct {
	hs      *jwt.HSAlg
	builder *jwt.Builder
}

func newJWTCodec(secret []byte) *jwtCodec {
	hs, err := jwt.NewSignerHS(jwt.HS256, secret)
	if err != nil {
		panic(err)
	}
	return &jwtCodec{hs: hs, builder: jwt.NewBuilder(hs)}
}

// tokenClaims are the claims this server reads. Pointers distinguish absent
// claims; NumericDate rejects non-numeric values.
type tokenClaims struct {
	Subject   string           `json:"sub"`
	ExpiresAt *jwt.NumericDate `json:"exp"`
	NotBefore *jwt.NumericDate `json:"nbf"`
	IssuedAt  *jwt.NumericDate `json:"iat"`
}

// verify returns the subject id and whether the token is valid: HS256 with the
// secret, an exp in the future, nbf (if any) reached, and a positive decimal sub.
func (c *jwtCodec) verify(tok []byte) (int64, bool) {
	var cl tokenClaims
	if err := jwt.ParseClaims(tok, c.hs, &cl); err != nil {
		return 0, false
	}
	now := time.Now()
	// Match golang-jwt: dates are compared at one-second precision.
	if cl.ExpiresAt == nil || !now.Before(cl.ExpiresAt.Truncate(time.Second)) {
		return 0, false
	}
	if cl.NotBefore != nil && now.Before(cl.NotBefore.Truncate(time.Second)) {
		return 0, false
	}
	id, ok := parseUint(cl.Subject)
	return id, ok && id > 0
}

type issuedClaims struct {
	Subject   string `json:"sub"`
	ExpiresAt int64  `json:"exp"`
	IssuedAt  int64  `json:"iat"`
}

// appendToken signs {"sub":"<id>","exp":<now+30d>,"iat":<now>}.
func (c *jwtCodec) appendToken(dst []byte, id int64, now time.Time) []byte {
	t, err := c.builder.Build(issuedClaims{Subject: itoa(id), ExpiresAt: now.Add(tokenTTL).Unix(), IssuedAt: now.Unix()})
	if err != nil {
		panic(err)
	}
	return append(dst, t.Bytes()...)
}
