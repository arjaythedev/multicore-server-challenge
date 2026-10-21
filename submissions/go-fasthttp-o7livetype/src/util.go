package main

// util.go has the small helpers shared by the request path: the request view of a
// fasthttp request, zero-copy string/byte conversions, query and path parameter
// parsing, and reading JSON request bodies.

import (
	"bytes"
	"errors"
	"net/url"
	"strconv"
	"time"
	"unsafe"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/segmentio/encoding/json"
	"github.com/valyala/fasthttp"
)

// request views the fasthttp request for the duration of the handler.
type request struct {
	method, path       string
	body, authHeader   []byte
	authCount          int
	slug, username, id string
	args               *fasthttp.Args
}

func (r *request) QueryArgs() *fasthttp.Args { return r.args }
func (r *request) PostBody() []byte          { return r.body }

// bstr views bytes as a string. The bytes must outlive and never change under it.
func bstr(b []byte) string { return unsafe.String(unsafe.SliceData(b), len(b)) }

var emptyBytes = []byte{}

// sbytes views a string as a parameter value. Empty strings stay non-NULL.
func sbytes(s string) []byte {
	if s == "" {
		return emptyBytes
	}
	return unsafe.Slice(unsafe.StringData(s), len(s))
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}

func unescapeSegment(s string) string {
	v, err := url.PathUnescape(s)
	if err != nil {
		return ""
	}
	return v
}

// ---------- query parameters ----------

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

// limitOffset reads limit (default 20, 1..100) and offset (default 0, >= 0).
// A parameter that is present (even empty) must be valid.
func limitOffset(r *request) (limit, offset int64, ok bool) {
	q := r.QueryArgs()
	limit, offset = 20, 0
	if q.Has("limit") {
		n, valid := parseUint(bstr(q.Peek("limit")))
		if !valid || n < 1 || n > 100 {
			return 0, 0, false
		}
		limit = n
	}
	if q.Has("offset") {
		n, valid := parseUint(bstr(q.Peek("offset")))
		if !valid {
			return 0, 0, false
		}
		offset = n
	}
	return limit, offset, true
}

// ---------- request bodies ----------

var errBadBody = errors.New("invalid body")

// readWrapper parses the body as a JSON object and returns the object under key as raw fields.
// Matching is case-sensitive; unknown fields are ignored.
func readWrapper(r *request, key string) (map[string]json.RawMessage, error) {
	body := r.PostBody()
	if len(body) > 1<<20 {
		return nil, errBadBody
	}
	var top map[string]json.RawMessage
	if err := json.Unmarshal(body, &top); err != nil || top == nil {
		return nil, errBadBody
	}
	raw, ok := top[key]
	if !ok {
		return nil, errBadBody
	}
	var inner map[string]json.RawMessage
	if err := json.Unmarshal(raw, &inner); err != nil || inner == nil {
		return nil, errBadBody
	}
	return inner, nil
}

func isNull(raw json.RawMessage) bool { return bytes.Equal(bytes.TrimSpace(raw), []byte("null")) }

// optString: absent or null gives nil; a string gives a pointer to it; anything else is an error.
// With nonEmpty, an empty string is an error too.
func optString(m map[string]json.RawMessage, k string, nonEmpty bool) (*string, error) {
	raw, ok := m[k]
	if !ok || isNull(raw) {
		return nil, nil
	}
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return nil, errBadBody
	}
	if nonEmpty && s == "" {
		return nil, errBadBody
	}
	return &s, nil
}

// reqString: must be present and a non-empty string.
func reqString(m map[string]json.RawMessage, k string) (string, error) {
	p, err := optString(m, k, true)
	if err != nil || p == nil {
		return "", errBadBody
	}
	return *p, nil
}

const tokenTTL = 30 * 24 * time.Hour
