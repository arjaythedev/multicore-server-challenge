package server

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"sync"
	"time"

	"conduit/internal/auth"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

type app struct {
	pool      *pgxpool.Pool
	tokens    *auth.Signer
	reads     *readQueue
	passwords *passwordQueue
	writes    *writeQueue
}

// ---------- responses ----------

var jsonBuffers = sync.Pool{New: func() any { return bytes.NewBuffer(make([]byte, 0, 4096)) }}
var apiJSONBuffers = sync.Pool{New: func() any { b := make([]byte, 0, 4096); return &b }}

func writeJSON(w http.ResponseWriter, status int, v any) {
	if responseEncoding != "standard" {
		buffer := apiJSONBuffers.Get().(*[]byte)
		dst := (*buffer)[:0]
		var compact *compactResponse
		if compactPrefixResponses {
			compact, _ = w.(*compactResponse)
			if compact != nil {
				if cap(dst) < responseHeadReserve {
					dst = make([]byte, 0, 4096)
				}
				dst = dst[:responseHeadReserve]
			}
		}
		body, ok := appendAPIJSON(dst, v)
		if ok {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(status)
			if compact != nil {
				_, _ = compact.writePrefixed(body, responseHeadReserve)
			} else {
				_, _ = w.Write(body)
			}
		}
		if cap(body) <= 256<<10 {
			*buffer = body[:0]
			apiJSONBuffers.Put(buffer)
		}
		if ok {
			return
		}
	}
	buf := jsonBuffers.Get().(*bytes.Buffer)
	buf.Reset()
	defer func() {
		if buf.Cap() <= 256<<10 {
			jsonBuffers.Put(buf)
		}
	}()
	if err := json.NewEncoder(buf).Encode(v); err != nil {
		log.Printf("encode response: %v", err)
		status = http.StatusInternalServerError
		buf.Reset()
		buf.WriteString(`{"errors":{"body":["internal error"]}}`)
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(buf.Bytes())
}

type errorBody struct {
	Errors struct {
		Body []string `json:"body"`
	} `json:"errors"`
}

func writeError(w http.ResponseWriter, status int, msg string) {
	var e errorBody
	e.Errors.Body = []string{msg}
	writeJSON(w, status, e)
}

func internalError(w http.ResponseWriter, err error) {
	log.Printf("error: %v", err)
	writeError(w, http.StatusInternalServerError, "internal error")
}

func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}

type timestamp string

// Format at row materialization so all responses using this batch's immutable
// metadata share the same UTC millisecond text. JSON treats it as a string.
func ts(t time.Time) timestamp {
	return timestamp(t.UTC().Format("2006-01-02T15:04:05.000Z"))
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
func limitOffset(q url.Values) (limit, offset int64, ok bool) {
	limit, offset = 20, 0
	if vs, present := q["limit"]; present {
		n, valid := parseUint(vs[0])
		if !valid || n < 1 || n > 100 {
			return 0, 0, false
		}
		limit = n
	}
	if vs, present := q["offset"]; present {
		n, valid := parseUint(vs[0])
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
func readWrapper(r *http.Request, key string) (map[string]json.RawMessage, error) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		return nil, errBadBody
	}
	if requestDecoding == "stream" {
		return decodeRequestFields(body, key)
	}
	return decodeRequestFieldsStandard(body, key)
}

func decodeRequestFieldsStandard(body []byte, key string) (map[string]json.RawMessage, error) {
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
