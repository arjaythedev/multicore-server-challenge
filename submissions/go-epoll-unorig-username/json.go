package main

// json.go: JSON output straight from Postgres binary values, and HS256 tokens.

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"hash"
	"strconv"
	"strings"
	"sync"
	"time"
)

const hexDigits = "0123456789abcdef"

func appendStr[T string | []byte](b []byte, s T) []byte {
	b = append(b, '"')
	start := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 0x20 && c != '"' && c != '\\' {
			continue
		}
		b = append(b, s[start:i]...)
		switch c {
		case '"', '\\':
			b = append(b, '\\', c)
		case '\n':
			b = append(b, '\\', 'n')
		case '\r':
			b = append(b, '\\', 'r')
		case '\t':
			b = append(b, '\\', 't')
		default:
			b = append(b, '\\', 'u', '0', '0', hexDigits[c>>4], hexDigits[c&15])
		}
		start = i + 1
	}
	b = append(b, s[start:]...)
	return append(b, '"')
}

func appendNullable(b, s []byte) []byte {
	if s == nil {
		return append(b, "null"...)
	}
	return appendStr(b, s)
}

func appendBool(b []byte, v bool) []byte {
	if v {
		return append(b, "true"...)
	}
	return append(b, "false"...)
}

func i64(c []byte) int64 { return int64(binary.BigEndian.Uint64(c)) }

// appendTime renders a binary timestamptz (microseconds since 2000-01-01 UTC), truncated to ms.
func appendTime(b, c []byte) []byte {
	t := time.UnixMicro(i64(c) + 946684800_000000).UTC()
	b = append(b, '"')
	b = t.AppendFormat(b, "2006-01-02T15:04:05.000Z")
	return append(b, '"')
}

// appendTextArray renders a binary one-dimensional text[] (no NULLs) as a JSON array.
func appendTextArray(b, c []byte) []byte {
	b = append(b, '[')
	if len(c) >= 20 && binary.BigEndian.Uint32(c) == 1 {
		n, p := int(binary.BigEndian.Uint32(c[12:])), 20
		for i := range n {
			l := int(binary.BigEndian.Uint32(c[p:]))
			if i > 0 {
				b = append(b, ',')
			}
			b = appendStr(b, c[p+4:p+4+l])
			p += 4 + l
		}
	}
	return append(b, ']')
}

// appendArticle: slug, title, description, [body], created_at, updated_at, tags, favorites_count,
// favorited, username, bio, image, following.
func appendArticle(b []byte, c [][]byte, body bool) []byte {
	b = append(b, `{"slug":`...)
	b = appendStr(b, c[0])
	b = append(b, `,"title":`...)
	b = appendStr(b, c[1])
	b = append(b, `,"description":`...)
	b = appendStr(b, c[2])
	c = c[3:]
	if body {
		b = append(b, `,"body":`...)
		b = appendStr(b, c[0])
		c = c[1:]
	}
	b = append(b, `,"createdAt":`...)
	b = appendTime(b, c[0])
	b = append(b, `,"updatedAt":`...)
	b = appendTime(b, c[1])
	b = append(b, `,"tagList":`...)
	b = appendTextArray(b, c[2])
	b = append(b, `,"favoritesCount":`...)
	b = strconv.AppendInt(b, i64(c[3]), 10)
	b = append(b, `,"favorited":`...)
	b = appendBool(b, c[4][0] == 1)
	b = append(b, `,"author":`...)
	return append(appendProfile(b, c[5:8], c[8][0] == 1), '}')
}

// appendProfile: c = username, bio, image.
func appendProfile(b []byte, c [][]byte, following bool) []byte {
	b = append(b, `{"username":`...)
	b = appendStr(b, c[0])
	b = append(b, `,"bio":`...)
	b = appendNullable(b, c[1])
	b = append(b, `,"image":`...)
	b = appendNullable(b, c[2])
	b = append(b, `,"following":`...)
	return append(appendBool(b, following), '}')
}

// appendComment: c = id, created_at, updated_at, body, username, bio, image.
func appendComment(b []byte, c [][]byte, following bool) []byte {
	b = append(b, `{"id":`...)
	b = strconv.AppendInt(b, i64(c[0]), 10)
	b = append(b, `,"createdAt":`...)
	b = appendTime(b, c[1])
	b = append(b, `,"updatedAt":`...)
	b = appendTime(b, c[2])
	b = append(b, `,"body":`...)
	b = appendStr(b, c[3])
	b = append(b, `,"author":`...)
	return append(appendProfile(b, c[4:7], following), '}')
}

// appendUser opens a User from username, email, bio, image; closeUser adds the token.
func appendUser(b []byte, c [][]byte) []byte {
	b = append(b, `{"username":`...)
	b = appendStr(b, c[0])
	b = append(b, `,"email":`...)
	b = appendStr(b, c[1])
	b = append(b, `,"bio":`...)
	b = appendNullable(b, c[2])
	b = append(b, `,"image":`...)
	b = appendNullable(b, c[3])
	return b
}

func closeUser(b []byte, token string) []byte {
	b = append(b, `,"token":`...)
	return append(appendStr(b, token), "}}"...)
}

func errJSON(msg string) []byte {
	return append(appendStr([]byte(`{"errors":{"body":[`), msg), "]}}"...)
}

// ---------- JWT HS256 ----------

var (
	secret  []byte
	macs    = sync.Pool{New: func() any { return hmac.New(sha256.New, secret) }}
	b64     = base64.RawURLEncoding
	jwtHead = b64.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`))
)

func sign(msg string) []byte {
	m := macs.Get().(hash.Hash)
	m.Reset()
	m.Write([]byte(msg))
	sum := m.Sum(nil)
	macs.Put(m)
	return sum
}

func issueToken(id int64) string {
	now := time.Now().Unix()
	p := `{"sub":"` + strconv.FormatInt(id, 10) + `","iat":` + strconv.FormatInt(now, 10) +
		`,"exp":` + strconv.FormatInt(now+30*24*3600, 10) + `}`
	s := jwtHead + "." + b64.EncodeToString([]byte(p))
	return s + "." + b64.EncodeToString(sign(s))
}

// verifyToken checks the signature, alg = HS256, a future exp and a decimal-string sub, every time.
func verifyToken(tok string) (int64, bool) {
	dot := strings.LastIndexByte(tok, '.')
	if dot < 0 {
		return 0, false
	}
	sig, err := b64.DecodeString(tok[dot+1:])
	if err != nil || !hmac.Equal(sig, sign(tok[:dot])) {
		return 0, false
	}
	h, p, ok := strings.Cut(tok[:dot], ".")
	if !ok {
		return 0, false
	}
	if h != jwtHead {
		var hd struct{ Alg string }
		raw, err := b64.DecodeString(h)
		if err != nil || json.Unmarshal(raw, &hd) != nil || hd.Alg != "HS256" {
			return 0, false
		}
	}
	raw, err := b64.DecodeString(p)
	if err != nil {
		return 0, false
	}
	var cl struct {
		Sub *string
		Exp *float64
	}
	if json.Unmarshal(raw, &cl) != nil || cl.Sub == nil || cl.Exp == nil || *cl.Exp <= float64(time.Now().Unix()) {
		return 0, false
	}
	id, err := strconv.ParseInt(*cl.Sub, 10, 64)
	if err != nil || id <= 0 || (*cl.Sub)[0] == '+' {
		return 0, false
	}
	return id, true
}
