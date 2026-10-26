package main

// handlers.go: routing, authentication, request validation and the per-endpoint logic.

import (
	"bytes"
	"encoding/json"
	"errors"
	"net"
	"strings"
	"unicode/utf8"
)

// validText reports whether s can be a Postgres text value (UTF-8 without NUL).
func validText(s string) bool {
	return utf8.ValidString(s) && strings.IndexByte(s, 0) < 0
}

type app struct {
	db  *db
	sig *signer
	bc  *bcryptPool
}

// connState is per-connection scratch reused across its requests.
type connState struct {
	done chan struct{}
	req  dbReq
}

// handle serves one request and returns false if the connection should be closed.
func (a *app) handle(c net.Conn, cs *connState, r *request) bool {
	path := r.path
	if !strings.HasPrefix(path, "/api/") {
		return a.errResp(c, r, 404, "not found")
	}
	rest := path[5:]
	seg1, rest := cut(rest)
	switch seg1 {
	case "tags":
		if rest == "" && r.method == "GET" {
			return a.tags(c, cs, r)
		}
	case "users":
		if r.method == "POST" {
			if rest == "" {
				return a.register(c, cs, r)
			}
			if rest == "login" {
				return a.login(c, cs, r)
			}
		}
	case "user":
		if rest == "" {
			switch r.method {
			case "GET":
				return a.currentUser(c, cs, r)
			case "PUT":
				return a.updateUser(c, cs, r)
			}
		}
	case "profiles":
		name, rest := cut(rest)
		if name == "" {
			break
		}
		name = unescape(name)
		if !validText(name) {
			break
		}
		if rest == "" && r.method == "GET" {
			return a.profile(c, cs, r, name)
		}
		if rest == "follow" {
			switch r.method {
			case "POST":
				return a.follow(c, cs, r, name, true)
			case "DELETE":
				return a.follow(c, cs, r, name, false)
			}
		}
	case "articles":
		if rest == "" {
			switch r.method {
			case "GET":
				return a.listArticles(c, cs, r)
			case "POST":
				return a.createArticle(c, cs, r)
			}
			break
		}
		slug, rest := cut(rest)
		if slug == "feed" && rest == "" && r.method == "GET" {
			return a.feed(c, cs, r)
		}
		slug = unescape(slug)
		if !validText(slug) {
			break
		}
		if rest == "" {
			switch r.method {
			case "GET":
				return a.getArticle(c, cs, r, slug)
			case "PUT":
				return a.updateArticle(c, cs, r, slug)
			case "DELETE":
				return a.deleteArticle(c, cs, r, slug)
			}
			break
		}
		sub, rest := cut(rest)
		switch sub {
		case "favorite":
			if rest == "" {
				switch r.method {
				case "POST":
					return a.favorite(c, cs, r, slug, true)
				case "DELETE":
					return a.favorite(c, cs, r, slug, false)
				}
			}
		case "comments":
			if rest == "" {
				switch r.method {
				case "GET":
					return a.listComments(c, cs, r, slug)
				case "POST":
					return a.createComment(c, cs, r, slug)
				}
				break
			}
			id, rest := cut(rest)
			if rest == "" && r.method == "DELETE" {
				return a.deleteComment(c, cs, r, slug, id)
			}
		}
	}
	if r.method == "HEAD" {
		r.close = true // the 404 carries a body
	}
	return a.errResp(c, r, 404, "not found")
}

// cut splits off the first path segment.
func cut(p string) (string, string) {
	if i := strings.IndexByte(p, '/'); i >= 0 {
		return p[:i], p[i+1:]
	}
	return p, ""
}

func unhex(c byte) (byte, bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

// unescape decodes %XX sequences (path segments).
func unescape(s string) string {
	if strings.IndexByte(s, '%') < 0 {
		return s
	}
	b := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		if s[i] == '%' && i+2 < len(s) {
			h, ok1 := unhex(s[i+1])
			l, ok2 := unhex(s[i+2])
			if ok1 && ok2 {
				b = append(b, h<<4|l)
				i += 2
				continue
			}
		}
		b = append(b, s[i])
	}
	return string(b)
}

// unescapeQuery decodes %XX and '+' (query values).
func unescapeQuery(s string) string {
	if strings.IndexByte(s, '%') < 0 && strings.IndexByte(s, '+') < 0 {
		return s
	}
	b := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		switch {
		case s[i] == '+':
			b = append(b, ' ')
		case s[i] == '%' && i+2 < len(s):
			h, ok1 := unhex(s[i+1])
			l, ok2 := unhex(s[i+2])
			if ok1 && ok2 {
				b = append(b, h<<4|l)
				i += 2
				continue
			}
			b = append(b, s[i])
		default:
			b = append(b, s[i])
		}
	}
	return string(b)
}

// queryParam returns the first value of key in the query string and whether it was present.
func queryParam(q, key string) (string, bool) {
	for q != "" {
		var kv string
		kv, q, _ = strings.Cut(q, "&")
		k, v, _ := strings.Cut(kv, "=")
		if k == key {
			return unescapeQuery(v), true
		}
	}
	return "", false
}

// limitOffset reads limit (default 20, 1..100) and offset (default 0, >= 0); ok=false means 422.
func limitOffset(q string) (limit, offset int64, ok bool) {
	limit, offset = 20, 0
	if v, present := queryParam(q, "limit"); present {
		n, valid := parseUint(v)
		if !valid || n < 1 || n > 100 {
			return 0, 0, false
		}
		limit = n
	}
	if v, present := queryParam(q, "offset"); present {
		n, valid := parseUint(v)
		if !valid {
			return 0, 0, false
		}
		offset = n
	}
	return limit, offset, true
}

// ---------- responses ----------

func (a *app) errResp(c net.Conn, r *request, status int, msg string) bool {
	bp := getBuf()
	b := append(*bp, `{"errors":{"body":[`...)
	b = appendJSONStr(b, msg)
	*bp = append(b, "]}}"...)
	ok := writeResponse(c, status, bp, r.close)
	putBuf(bp)
	return ok
}

var statusMessages = map[int]string{
	401: "unauthorized", 403: "forbidden", 404: "not found", 422: "unprocessable", 500: "internal error",
}

// finishReq sends the result of a database request: the rendered body, or the error its status maps to.
func (a *app) finishReq(c net.Conn, r *request, q *dbReq, okStatus int) bool {
	defer putBuf(q.buf)
	if q.err != nil {
		return a.errResp(c, r, 500, "internal error")
	}
	status := q.status
	if status == 0 {
		status = okStatus
	}
	if status >= 400 {
		return a.errResp(c, r, status, statusMessages[status])
	}
	return writeResponse(c, status, q.buf, r.close)
}

// ---------- auth ----------

// auth returns the viewer id (0 if none) and whether an Authorization header was present.
func (a *app) auth(r *request) (int64, bool) {
	if r.auth == nil {
		return 0, false
	}
	if !bytes.HasPrefix(r.auth, []byte("Token ")) {
		return 0, true
	}
	return a.sig.verify(r.auth[6:]), true
}

func (a *app) required(c net.Conn, r *request) (int64, bool) {
	id, _ := a.auth(r)
	if id == 0 {
		a.errResp(c, r, 401, "unauthorized")
		return 0, false
	}
	return id, true
}

func (a *app) optional(c net.Conn, r *request) (int64, bool) {
	id, present := a.auth(r)
	if present && id == 0 {
		a.errResp(c, r, 401, "unauthorized")
		return 0, false
	}
	return id, true
}

// ---------- database request helpers ----------

func (cs *connState) newReq() *dbReq {
	q := &cs.req
	*q = dbReq{buf: getBuf(), done: cs.done}
	return q
}

func (a *app) read(q *dbReq) {
	a.db.reads.submit(q)
	<-q.done
}

func (a *app) write(q *dbReq) {
	a.db.writes.submit(q)
	<-q.done
}

// ---------- request bodies ----------

var errBadBody = errors.New("invalid body")

// readWrapper parses the body as {"<key>": {...}} and returns the inner object's raw fields.
func readWrapper(body []byte, key string) (map[string]json.RawMessage, error) {
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
func optString(m map[string]json.RawMessage, k string, nonEmpty bool) (*string, error) {
	raw, ok := m[k]
	if !ok || isNull(raw) {
		return nil, nil
	}
	var s string
	if err := json.Unmarshal(raw, &s); err != nil || !validText(s) {
		return nil, errBadBody
	}
	if nonEmpty && s == "" {
		return nil, errBadBody
	}
	return &s, nil
}

func reqString(m map[string]json.RawMessage, k string) (string, error) {
	p, err := optString(m, k, true)
	if err != nil || p == nil {
		return "", errBadBody
	}
	return *p, nil
}

func textOrNull(p *string) []byte {
	if p == nil {
		return nil
	}
	return []byte(*p)
}

// ---------- bcrypt ----------

func (a *app) hashPassword(pw string) ([]byte, error) { return a.bc.hash([]byte(pw), 10) }

func (a *app) checkPassword(hash []byte, pw string) bool { return a.bc.verify(hash, []byte(pw)) }

// ---------- endpoints ----------

func (a *app) tags(c net.Conn, cs *connState, r *request) bool {
	q := cs.newReq()
	q.kind = kTags
	a.read(q)
	return a.finishReq(c, r, q, 200)
}

func appendToken(q *dbReq, tok []byte) {
	b := append(*q.buf, `,"token":`...)
	b = appendJSONString(b, tok)
	*q.buf = append(b, "}}"...)
}

func (a *app) register(c net.Conn, cs *connState, r *request) bool {
	m, err := readWrapper(r.body, "user")
	if err != nil {
		return a.errResp(c, r, 422, "invalid body")
	}
	username, e1 := reqString(m, "username")
	email, e2 := reqString(m, "email")
	password, e3 := reqString(m, "password")
	if e1 != nil || e2 != nil || e3 != nil || len(password) > 72 {
		return a.errResp(c, r, 422, "username, email and password are required")
	}
	hash, err := a.hashPassword(password)
	if err != nil {
		return a.errResp(c, r, 422, "invalid password")
	}
	q := cs.newReq()
	q.stmt = wRegister
	q.params = [][]byte{[]byte(username), []byte(email), hash}
	a.write(q)
	if q.err == nil && q.status == 201 {
		appendToken(q, []byte(a.sig.issue(q.id)))
	}
	return a.finishReq(c, r, q, 201)
}

func (a *app) login(c net.Conn, cs *connState, r *request) bool {
	m, err := readWrapper(r.body, "user")
	if err != nil {
		return a.errResp(c, r, 422, "invalid body")
	}
	email, e1 := reqString(m, "email")
	password, e2 := reqString(m, "password")
	if e1 != nil || e2 != nil {
		return a.errResp(c, r, 422, "email and password are required")
	}
	q := cs.newReq()
	q.kind = kLogin
	q.s = email
	a.read(q)
	if q.err == nil && q.status == 0 {
		if !a.checkPassword(q.hash, password) {
			q.status = 401
		} else {
			appendToken(q, []byte(a.sig.issue(q.id)))
		}
	}
	return a.finishReq(c, r, q, 200)
}

func (a *app) currentUser(c net.Conn, cs *connState, r *request) bool {
	viewer, ok := a.required(c, r)
	if !ok {
		return true
	}
	q := cs.newReq()
	q.kind = kUser
	q.id = viewer
	a.read(q)
	if q.err == nil && q.status == 0 {
		appendToken(q, r.auth[6:])
	}
	return a.finishReq(c, r, q, 200)
}

func (a *app) updateUser(c net.Conn, cs *connState, r *request) bool {
	viewer, ok := a.required(c, r)
	if !ok {
		return true
	}
	m, err := readWrapper(r.body, "user")
	if err != nil {
		return a.errResp(c, r, 422, "invalid body")
	}
	email, e1 := optString(m, "email", true)
	username, e2 := optString(m, "username", true)
	password, e3 := optString(m, "password", true)
	bio, e4 := optString(m, "bio", false)
	image, e5 := optString(m, "image", false)
	if e1 != nil || e2 != nil || e3 != nil || e4 != nil || e5 != nil {
		return a.errResp(c, r, 422, "invalid fields")
	}
	var hash []byte
	if password != nil {
		if len(*password) > 72 {
			return a.errResp(c, r, 422, "invalid password")
		}
		hash, err = a.hashPassword(*password)
		if err != nil {
			return a.errResp(c, r, 422, "invalid password")
		}
	}
	q := cs.newReq()
	q.stmt = wUserUpdate
	q.params = [][]byte{encInt8(viewer), textOrNull(email), textOrNull(username), hash, textOrNull(bio), textOrNull(image)}
	a.write(q)
	if q.err == nil && q.status == 0 {
		appendToken(q, r.auth[6:])
	}
	return a.finishReq(c, r, q, 200)
}

func (a *app) profile(c net.Conn, cs *connState, r *request, name string) bool {
	viewer, ok := a.optional(c, r)
	if !ok {
		return true
	}
	q := cs.newReq()
	q.kind = kProfile
	q.viewer = viewer
	q.s = name
	a.read(q)
	return a.finishReq(c, r, q, 200)
}

func (a *app) follow(c net.Conn, cs *connState, r *request, name string, follow bool) bool {
	viewer, ok := a.required(c, r)
	if !ok {
		return true
	}
	q := cs.newReq()
	q.stmt = wUnfollow
	if follow {
		q.stmt = wFollow
	}
	q.params = [][]byte{encInt8(viewer), []byte(name)}
	a.write(q)
	return a.finishReq(c, r, q, 200)
}

func (a *app) listArticles(c net.Conn, cs *connState, r *request) bool {
	viewer, ok := a.optional(c, r)
	if !ok {
		return true
	}
	limit, offset, ok := limitOffset(r.query)
	if !ok {
		return a.errResp(c, r, 422, "limit must be 1-100 and offset >= 0")
	}
	q := cs.newReq()
	q.viewer, q.lim, q.off = viewer, limit, offset
	q.kind = kListAll
	if v, _ := queryParam(r.query, "tag"); v != "" {
		q.kind, q.s = kListTag, v
	} else if v, _ := queryParam(r.query, "author"); v != "" {
		q.kind, q.s = kListAuthor, v
	} else if v, _ := queryParam(r.query, "favorited"); v != "" {
		q.kind, q.s = kListFav, v
	}
	if !validText(q.s) {
		putBuf(q.buf)
		return a.errResp(c, r, 422, "invalid filter")
	}
	a.read(q)
	return a.finishReq(c, r, q, 200)
}

func (a *app) feed(c net.Conn, cs *connState, r *request) bool {
	viewer, ok := a.required(c, r)
	if !ok {
		return true
	}
	limit, offset, ok := limitOffset(r.query)
	if !ok {
		return a.errResp(c, r, 422, "limit must be 1-100 and offset >= 0")
	}
	q := cs.newReq()
	q.kind = kFeed
	q.viewer, q.lim, q.off = viewer, limit, offset
	a.read(q)
	return a.finishReq(c, r, q, 200)
}

func (a *app) getArticle(c net.Conn, cs *connState, r *request, slug string) bool {
	viewer, ok := a.optional(c, r)
	if !ok {
		return true
	}
	q := cs.newReq()
	q.kind = kArticle
	q.viewer, q.s = viewer, slug
	a.read(q)
	return a.finishReq(c, r, q, 200)
}

func (a *app) createArticle(c net.Conn, cs *connState, r *request) bool {
	viewer, ok := a.required(c, r)
	if !ok {
		return true
	}
	m, err := readWrapper(r.body, "article")
	if err != nil {
		return a.errResp(c, r, 422, "invalid body")
	}
	title, e1 := reqString(m, "title")
	description, e2 := reqString(m, "description")
	body, e3 := reqString(m, "body")
	if e1 != nil || e2 != nil || e3 != nil {
		return a.errResp(c, r, 422, "title, description and body are required")
	}
	var tagList []string
	if raw, ok := m["tagList"]; ok && !isNull(raw) {
		var items []json.RawMessage
		if err := json.Unmarshal(raw, &items); err != nil {
			return a.errResp(c, r, 422, "tagList must be an array of non-empty strings")
		}
		for _, it := range items {
			var s string
			if isNull(it) || json.Unmarshal(it, &s) != nil || s == "" || !validText(s) {
				return a.errResp(c, r, 422, "tagList must be an array of non-empty strings")
			}
			tagList = append(tagList, s)
		}
	}
	q := cs.newReq()
	q.stmt = wArticleCreate
	q.viewer = viewer
	q.params = [][]byte{encInt8(viewer), []byte(title), []byte(description), []byte(body), encTextArray(tagList)}
	a.write(q)
	return a.finishReq(c, r, q, 201)
}

func (a *app) updateArticle(c net.Conn, cs *connState, r *request, slug string) bool {
	viewer, ok := a.required(c, r)
	if !ok {
		return true
	}
	m, err := readWrapper(r.body, "article")
	if err != nil {
		return a.errResp(c, r, 422, "invalid body")
	}
	title, e1 := optString(m, "title", true)
	description, e2 := optString(m, "description", true)
	body, e3 := optString(m, "body", true)
	if e1 != nil || e2 != nil || e3 != nil {
		return a.errResp(c, r, 422, "title, description and body must be non-empty strings")
	}
	q := cs.newReq()
	q.stmt = wArticleUpdate
	q.viewer = viewer
	q.params = [][]byte{[]byte(slug), textOrNull(title), textOrNull(description), textOrNull(body), encInt8(viewer)}
	a.write(q)
	return a.finishReq(c, r, q, 200)
}

func (a *app) deleteArticle(c net.Conn, cs *connState, r *request, slug string) bool {
	viewer, ok := a.required(c, r)
	if !ok {
		return true
	}
	q := cs.newReq()
	q.stmt = wArticleDelete
	q.viewer = viewer
	q.params = [][]byte{[]byte(slug), encInt8(viewer)}
	a.write(q)
	return a.finishReq(c, r, q, 204)
}

func (a *app) favorite(c net.Conn, cs *connState, r *request, slug string, fav bool) bool {
	viewer, ok := a.required(c, r)
	if !ok {
		return true
	}
	q := cs.newReq()
	q.stmt = wUnfavorite
	if fav {
		q.stmt = wFavorite
	}
	q.viewer = viewer
	q.params = [][]byte{encInt8(viewer), []byte(slug)}
	a.write(q)
	return a.finishReq(c, r, q, 200)
}

func (a *app) listComments(c net.Conn, cs *connState, r *request, slug string) bool {
	viewer, ok := a.optional(c, r)
	if !ok {
		return true
	}
	q := cs.newReq()
	q.kind = kComments
	q.viewer, q.s = viewer, slug
	a.read(q)
	return a.finishReq(c, r, q, 200)
}

func (a *app) createComment(c net.Conn, cs *connState, r *request, slug string) bool {
	viewer, ok := a.required(c, r)
	if !ok {
		return true
	}
	m, err := readWrapper(r.body, "comment")
	if err != nil {
		return a.errResp(c, r, 422, "invalid body")
	}
	body, err := reqString(m, "body")
	if err != nil {
		return a.errResp(c, r, 422, "body is required")
	}
	q := cs.newReq()
	q.stmt = wComment
	q.viewer = viewer
	q.params = [][]byte{[]byte(slug), encInt8(viewer), []byte(body)}
	a.write(q)
	return a.finishReq(c, r, q, 201)
}

func (a *app) deleteComment(c net.Conn, cs *connState, r *request, slug, idStr string) bool {
	viewer, ok := a.required(c, r)
	if !ok {
		return true
	}
	id, valid := parseUint(idStr)
	if !valid {
		return a.errResp(c, r, 404, "not found")
	}
	q := cs.newReq()
	q.stmt = wCommentDelete
	q.viewer = viewer
	q.params = [][]byte{encInt8(id), []byte(slug), encInt8(viewer)}
	a.write(q)
	return a.finishReq(c, r, q, 204)
}
