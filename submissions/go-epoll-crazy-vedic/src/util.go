package main

// util.go has the small helpers shared by the request path: the request view of a
// parsed HTTP request (with a query string reader that does not build a map),
// zero-copy string/byte conversions, query and path parameter parsing, and
// reading JSON request bodies.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unsafe"

	"github.com/jackc/pgx/v5/pgconn"
)

// Request bytes remain owned by the job until its response is released. Socket
// state is only touched by the owning epoll loop, never by workers.
type request struct {
	ctx                  context.Context
	method, path, target string
	body, authHeader     []byte
	authCount            int
	slug, username, id   string
	args                 queryArgs
}

// queryArgs reads the query string without building a map. Strings that need
// unescaping (or contain ';') fall back to url.ParseQuery, unchanged semantics.
type queryArgs struct {
	raw    string
	values url.Values
	parsed bool
}

func (q *queryArgs) init(raw string) {
	q.raw, q.values, q.parsed = raw, nil, false
	if strings.ContainsAny(raw, "%+;") {
		q.values, _ = url.ParseQuery(raw)
		q.parsed = true
	}
}

// lookup returns the first value for key and whether key is present.
func (q *queryArgs) lookup(key string) (string, bool) {
	if q.parsed {
		v, ok := q.values[key]
		if !ok {
			return "", false
		}
		return v[0], true
	}
	for s := q.raw; s != ""; {
		var pair string
		pair, s, _ = strings.Cut(s, "&")
		if pair == "" {
			continue
		}
		k, v, _ := strings.Cut(pair, "=")
		if k == key {
			return v, true
		}
	}
	return "", false
}

func (q *queryArgs) Has(key string) bool    { _, ok := q.lookup(key); return ok }
func (q *queryArgs) Peek(key string) string { v, _ := q.lookup(key); return v }

func (r *request) QueryArgs() *queryArgs    { return &r.args }
func (r *request) PostBody() []byte         { return r.body }
func (r *request) Context() context.Context { return r.ctx }
func (r *request) PathValue(key string) string {
	switch key {
	case "slug":
		return r.slug
	case "username":
		return r.username
	case "id":
		return r.id
	}
	return ""
}

// setTarget fills method, path, target and query from the wire request without copying.
func (r *request) setTarget(method, target []byte) {
	r.method, r.target = bstr(method), bstr(target)
	r.path = r.target
	q := ""
	if i := strings.IndexByte(r.path, '?'); i >= 0 {
		r.path, q = r.path[:i], r.path[i+1:]
	}
	r.args.init(q)
}

type response struct {
	status int
	body   []byte
}

func (w *response) SetStatusCode(code int) { w.status = code }

type handler func(*response, *request)

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
	if v, present := q.lookup("limit"); present {
		n, valid := parseUint(v)
		if !valid || n < 1 || n > 100 {
			return 0, 0, false
		}
		limit = n
	}
	if v, present := q.lookup("offset"); present {
		n, valid := parseUint(v)
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
