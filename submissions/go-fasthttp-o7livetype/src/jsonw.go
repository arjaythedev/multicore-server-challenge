package main

import (
	"encoding/binary"
	"strconv"
	"time"

	"github.com/segmentio/encoding/json"
)

// Response bodies are appended straight from PostgreSQL's binary row values
// into a buffer owned by the job, so requests do not build intermediate structs
// or run reflection-based encoding. Escaping comes from segmentio/encoding,
// which matches encoding/json.Marshal byte for byte.

const oidText = 25

func appendJSONString(dst, s []byte) []byte {
	return json.AppendEscape(dst, bstr(s), json.EscapeHTML)
}

// appendNullableString writes JSON null for a SQL NULL.
func appendNullableString(dst, v []byte) []byte {
	if v == nil {
		return append(dst, "null"...)
	}
	return json.AppendEscape(dst, bstr(v), json.EscapeHTML)
}

func appendBool(dst, v []byte) []byte {
	if len(v) == 1 && v[0] != 0 {
		return append(dst, "true"...)
	}
	return append(dst, "false"...)
}

func int8Value(v []byte) int64 {
	if len(v) != 8 {
		return 0
	}
	return int64(binary.BigEndian.Uint64(v))
}

func appendInt8(dst, v []byte) []byte { return strconv.AppendInt(dst, int8Value(v), 10) }

// PostgreSQL's binary timestamptz is microseconds since 2000-01-01T00:00:00Z.
var pgEpochMicros = time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC).UnixMicro()

// appendTimestamp writes RFC 3339 UTC with exactly three fractional digits,
// truncated (not rounded).
func appendTimestamp(dst, v []byte) []byte {
	dst = append(dst, '"')
	dst = time.UnixMicro(pgEpochMicros+int8Value(v)).UTC().AppendFormat(dst, "2006-01-02T15:04:05.000Z")
	return append(dst, '"')
}

// appendTextArray writes a binary one-dimensional text[] as a JSON string
// array. An empty or malformed array writes [].
func appendTextArray(dst, v []byte) []byte {
	dst = append(dst, '[')
	if len(v) >= 20 && binary.BigEndian.Uint32(v) == 1 {
		n := int(int32(binary.BigEndian.Uint32(v[12:])))
		p := 20
		for i := 0; i < n && p+4 <= len(v); i++ {
			l := int(int32(binary.BigEndian.Uint32(v[p:])))
			p += 4
			if i > 0 {
				dst = append(dst, ',')
			}
			if l < 0 || p+l > len(v) {
				dst = append(dst, "null"...)
				continue
			}
			dst = appendJSONString(dst, v[p:p+l])
			p += l
		}
	}
	return append(dst, ']')
}

// ---------- binary parameter encoders ----------

func putInt8(b *[8]byte, v int64) []byte {
	binary.BigEndian.PutUint64(b[:], uint64(v))
	return b[:]
}

// appendTextArrayParam encodes a binary text[] parameter.
func appendTextArrayParam(dst []byte, items []string) []byte {
	dst = binary.BigEndian.AppendUint32(dst, uint32(min(len(items), 1))) // dimensions
	dst = binary.BigEndian.AppendUint32(dst, 0)                          // no NULLs
	dst = binary.BigEndian.AppendUint32(dst, oidText)
	if len(items) == 0 {
		return dst
	}
	dst = binary.BigEndian.AppendUint32(dst, uint32(len(items)))
	dst = binary.BigEndian.AppendUint32(dst, 1) // lower bound
	for _, s := range items {
		dst = binary.BigEndian.AppendUint32(dst, uint32(len(s)))
		dst = append(dst, s...)
	}
	return dst
}

// ---------- fixed error bodies ----------

func errorJSON(msg string) []byte {
	b := json.AppendEscape([]byte(`{"errors":{"body":[`), msg, json.EscapeHTML)
	return append(b, "]}}"...)
}

var (
	errUnauthorized  = errorJSON("unauthorized")
	errNotFound      = errorJSON("not found")
	errArticle404    = errorJSON("article not found")
	errProfile404    = errorJSON("profile not found")
	errComment404    = errorJSON("comment not found")
	errNotAuthor     = errorJSON("not the author")
	errInvalidBody   = errorJSON("invalid body")
	errInternal      = errorJSON("internal error")
	errBusy          = errorJSON("server busy")
	errLimitOffset   = errorJSON("limit must be 1-100 and offset >= 0")
	errLogin         = errorJSON("invalid email or password")
	errTaken         = errorJSON("username or email is already taken")
	errPasswordLong  = errorJSON("password is too long")
	errRegisterBody  = errorJSON("username, email and password are required")
	errLoginBody     = errorJSON("email and password are required")
	errUserFields    = errorJSON("invalid user fields")
	errArticleBody   = errorJSON("title, description and body are required")
	errArticleFields = errorJSON("title, description and body must be non-empty strings")
	errTagList       = errorJSON("tagList must be an array of non-empty strings")
	errCommentBody   = errorJSON("body is required")
	errBadRequest    = errorJSON("invalid request")
)
