package main

import (
	"encoding/json"
	"errors"
	"log"
	"net/url"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/jackc/pgx/v5/pgconn"
)

type reply struct {
	status int
	body   []byte
}

var (
	notFound     = reply{404, errJSON("not found")}
	unauthorized = reply{401, errJSON("unauthorized")}
	forbidden    = reply{403, errJSON("forbidden")}
	serverError  = reply{500, errJSON("internal error")}
)

func invalid(msg string) reply { return reply{422, errJSON(msg)} }

func handle(c *conn, rq *request) {
	r := serverError
	func() {
		defer func() {
			if e := recover(); e != nil {
				log.Printf("panic serving %s %s: %v", rq.method, rq.path, e)
			}
		}()
		r = route(rq)
	}()
	c.complete(response(r.status, r.body, rq.close), rq.close)
}

func route(rq *request) reply {
	p, ok := strings.CutPrefix(rq.path, "/api/")
	if !ok {
		return notFound
	}
	seg := strings.Split(p, "/")
	m := rq.method
	switch {
	case seg[0] == "tags" && len(seg) == 1 && m == "GET":
		return getTags()
	case seg[0] == "users" && len(seg) == 1 && m == "POST":
		return register(rq)
	case seg[0] == "users" && len(seg) == 2 && seg[1] == "login" && m == "POST":
		return login(rq)
	case seg[0] == "user" && len(seg) == 1 && (m == "GET" || m == "PUT"):
		return currentUser(rq)
	case seg[0] == "profiles" && (len(seg) == 2 || len(seg) == 3 && seg[2] == "follow"):
		name, ok := unescape(seg[1])
		switch {
		case len(seg) == 2 && m == "GET":
			return profile(rq, name, ok)
		case len(seg) == 3 && (m == "POST" || m == "DELETE"):
			return follow(rq, name, ok, m == "POST")
		}
	case seg[0] == "articles":
		if len(seg) == 1 {
			switch m {
			case "GET":
				return listArticles(rq)
			case "POST":
				return createArticle(rq)
			}
			break
		}
		if len(seg) == 2 && seg[1] == "feed" && m == "GET" {
			return feed(rq)
		}
		slug, ok := unescape(seg[1])
		switch {
		case len(seg) == 2:
			switch m {
			case "GET":
				return getArticle(rq, slug, ok)
			case "PUT":
				return updateArticle(rq, slug, ok)
			case "DELETE":
				return deleteArticle(rq, slug, ok)
			}
		case len(seg) == 3 && seg[2] == "favorite" && (m == "POST" || m == "DELETE"):
			return favorite(rq, slug, ok, m == "POST")
		case len(seg) == 3 && seg[2] == "comments" && m == "GET":
			return listComments(rq, slug, ok)
		case len(seg) == 3 && seg[2] == "comments" && m == "POST":
			return addComment(rq, slug, ok)
		case len(seg) == 4 && seg[2] == "comments" && m == "DELETE":
			return deleteComment(rq, slug, ok, seg[3])
		}
	}
	return notFound
}

// unescape decodes a path segment; ok is false when no row can match it (Postgres text holds
// neither NUL nor invalid UTF-8), so the caller answers "not found" without asking the database.
func unescape(s string) (string, bool) {
	s, err := url.PathUnescape(s)
	return s, err == nil && storable(s)
}

func storable(s string) bool { return utf8.ValidString(s) && !strings.ContainsRune(s, 0) }

// viewer returns the token's user id (0 = anonymous). ok is false for an invalid token, or a
// missing one when required.
func viewer(rq *request, required bool) (int64, bool) {
	if rq.auth == "" {
		return 0, !required
	}
	tok, found := strings.CutPrefix(rq.auth, "Token ")
	if !found {
		return 0, false
	}
	return verifyToken(tok)
}

func dbFailure(err error) reply {
	var pe *pgconn.PgError
	if errors.As(err, &pe) {
		switch pe.Code {
		case "23505":
			return invalid("already taken")
		case "23503": // a referenced row vanished: the viewer, or the target
			if strings.Contains(pe.ConstraintName, "author_id") || strings.Contains(pe.ConstraintName, "user_id") ||
				strings.Contains(pe.ConstraintName, "follower_id") {
				return unauthorized
			}
			return notFound
		}
	}
	log.Print("db: ", err)
	return serverError
}

func text(s *string) []byte {
	if s == nil {
		return nil
	}
	return []byte(*s)
}

func num(n int64) []byte { return strconv.AppendInt(nil, n, 10) }

// set reports whether a required string field is a non-empty storable string.
func set(s *string) bool { return s != nil && *s != "" && storable(*s) }

// optional reports whether an optional field is absent/null, or a storable string (non-empty if nonEmpty).
func optional(s *string, nonEmpty bool) bool {
	return s == nil || (!nonEmpty || *s != "") && storable(*s)
}

// ---------- users ----------

type userFields struct {
	Username, Email, Password, Bio, Image *string
}

func userBody(rq *request) (*userFields, bool) {
	var in struct{ User *userFields }
	if json.Unmarshal(rq.body, &in) != nil || in.User == nil {
		return nil, false
	}
	return in.User, true
}

func userReply(status int, j *job, token string) reply {
	return reply{status, closeUser(j.out, token)}
}

func register(rq *request) reply {
	u, ok := userBody(rq)
	if !ok || !set(u.Username) || !set(u.Email) || !set(u.Password) {
		return invalid("username, email and password are required")
	}
	if len(*u.Password) > 72 {
		return invalid("password is longer than 72 bytes")
	}
	h, err := hashPassword(*u.Password)
	if err != nil {
		return invalid("password not accepted")
	}
	j := write(`{"user":`, func(j *job, _ int, c [][]byte) { j.out, j.n = appendUser(j.out, c), i64(c[4]) },
		call{wRegister, [][]byte{text(u.Username), text(u.Email), []byte(h)}})
	switch {
	case j.err != nil:
		return dbFailure(j.err)
	case j.rows == 0:
		return invalid("username or email already taken")
	}
	return userReply(201, j, issueToken(j.n))
}

func login(rq *request) reply {
	u, ok := userBody(rq)
	if !ok || !set(u.Email) || !set(u.Password) {
		return invalid("email and password are required")
	}
	j := read(kLogin, 0, 0, 0, *u.Email)
	switch {
	case j.err != nil:
		return dbFailure(j.err)
	case j.rows == 0 || !passwordMatches(j.hash, *u.Password):
		return unauthorized
	}
	return userReply(200, j, issueToken(j.n))
}

func currentUser(rq *request) reply {
	id, ok := viewer(rq, true)
	if !ok {
		return unauthorized
	}
	token := rq.auth[len("Token "):]
	if rq.method == "GET" {
		j := read(kUser, id, 0, 0, "")
		switch {
		case j.err != nil:
			return dbFailure(j.err)
		case j.rows == 0:
			return unauthorized
		}
		return userReply(200, j, token)
	}
	u, ok := userBody(rq)
	if !ok || !optional(u.Email, true) || !optional(u.Username, true) || !optional(u.Password, true) ||
		!optional(u.Bio, false) || !optional(u.Image, false) {
		return invalid("invalid user fields")
	}
	var h []byte
	if u.Password != nil {
		if len(*u.Password) > 72 {
			return invalid("password is longer than 72 bytes")
		}
		s, err := hashPassword(*u.Password)
		if err != nil {
			return invalid("password not accepted")
		}
		h = []byte(s)
	}
	j := write(`{"user":`, func(j *job, _ int, c [][]byte) { j.out = appendUser(j.out, c) },
		call{wUser, [][]byte{num(id), text(u.Email), text(u.Username), h, text(u.Bio), text(u.Image)}})
	switch {
	case j.err != nil:
		return dbFailure(j.err)
	case j.rows == 0:
		return unauthorized
	}
	return userReply(200, j, token)
}

// ---------- profiles ----------

func profile(rq *request, name string, ok bool) reply {
	v, authOK := viewer(rq, false)
	if !authOK {
		return unauthorized
	}
	if !ok {
		return notFound
	}
	j := read(kProfile, v, 0, 0, name)
	switch {
	case j.err != nil:
		return dbFailure(j.err)
	case j.rows == 0:
		return notFound
	}
	return reply{200, j.out}
}

func follow(rq *request, name string, ok, on bool) reply {
	v, authOK := viewer(rq, true)
	if !authOK {
		return unauthorized
	}
	if !ok {
		return notFound
	}
	stmt := wUnfollow
	if on {
		stmt = wFollow
	}
	j := write(`{"profile":`, func(j *job, _ int, c [][]byte) { j.out = append(appendProfile(j.out, c, on), '}') },
		call{stmt, [][]byte{num(v), []byte(name)}})
	switch {
	case j.err != nil:
		return dbFailure(j.err)
	case j.rows == 0:
		return notFound
	}
	return reply{200, j.out}
}

// ---------- articles ----------

// page parses limit (1..100, default 20) and offset (>= 0) as plain decimal integers.
func page(q url.Values) (lim, off int64, ok bool) {
	lim = 20
	parse := func(key string, min, max int64, dst *int64) bool {
		vs, has := q[key]
		if !has {
			return true
		}
		s := vs[0]
		if s == "" || strings.TrimLeft(s, "0123456789") != "" {
			return false
		}
		n, err := strconv.ParseInt(s, 10, 64)
		if err != nil || n < min || n > max {
			return false
		}
		*dst = n
		return true
	}
	if !parse("limit", 1, 100, &lim) || !parse("offset", 0, 1<<63-1, &off) {
		return 0, 0, false
	}
	// Past every row either way; keeps lim + off in range.
	return lim, min(off, 1<<40), true
}

func listReply(j *job) reply {
	if j.err != nil {
		return dbFailure(j.err)
	}
	b := append(j.out, `],"articlesCount":`...)
	return reply{200, append(strconv.AppendInt(b, j.n, 10), '}')}
}

func emptyList() reply { return reply{200, []byte(`{"articles":[],"articlesCount":0}`)} }

func listArticles(rq *request) reply {
	v, ok := viewer(rq, false)
	if !ok {
		return unauthorized
	}
	q, err := url.ParseQuery(rq.query)
	if err != nil {
		return invalid("bad query string")
	}
	lim, off, ok := page(q)
	if !ok {
		return invalid("limit must be 1..100 and offset >= 0")
	}
	k, s := kAll, ""
	for _, f := range []struct {
		key  string
		kind int
	}{{"tag", kTag}, {"author", kAuthor}, {"favorited", kFav}} {
		if s = q.Get(f.key); s != "" {
			k = f.kind
			break
		}
	}
	if !storable(s) {
		return emptyList()
	}
	return listReply(read(k, v, lim, off, s))
}

func feed(rq *request) reply {
	v, ok := viewer(rq, true)
	if !ok {
		return unauthorized
	}
	q, err := url.ParseQuery(rq.query)
	if err != nil {
		return invalid("bad query string")
	}
	lim, off, ok := page(q)
	if !ok {
		return invalid("limit must be 1..100 and offset >= 0")
	}
	return listReply(read(kFeed, v, lim, off, ""))
}

func getArticle(rq *request, slug string, ok bool) reply {
	v, authOK := viewer(rq, false)
	if !authOK {
		return unauthorized
	}
	if !ok {
		return notFound
	}
	j := read(kArticle, v, 0, 0, slug)
	switch {
	case j.err != nil:
		return dbFailure(j.err)
	case j.rows == 0:
		return notFound
	}
	return reply{200, j.out}
}

type articleFields struct {
	Title, Description, Body *string
	TagList                  *[]string
}

func articleBody(rq *request) (*articleFields, bool) {
	var in struct{ Article *articleFields }
	if json.Unmarshal(rq.body, &in) != nil || in.Article == nil {
		return nil, false
	}
	return in.Article, true
}

func articleRow(j *job, _ int, c [][]byte) { j.out = append(appendArticle(j.out, c, true), '}') }

func createArticle(rq *request) reply {
	v, ok := viewer(rq, true)
	if !ok {
		return unauthorized
	}
	a, ok := articleBody(rq)
	if !ok || !set(a.Title) || !set(a.Description) || !set(a.Body) {
		return invalid("title, description and body are required")
	}
	calls := []call{{wArticle, [][]byte{num(v), text(a.Title), text(a.Description), text(a.Body)}}}
	if a.TagList != nil && len(*a.TagList) > 0 {
		tags := []byte{'{'}
		for i, t := range *a.TagList {
			if !set(&t) {
				return invalid("tags must be non-empty strings")
			}
			if i > 0 {
				tags = append(tags, ',')
			}
			tags = appendArrayString(tags, t)
		}
		tags = append(tags, '}')
		calls = append(calls, call{wTags, [][]byte{tags}}, call{wArticleTags, [][]byte{tags}})
	}
	calls = append(calls, call{wArticleNew, [][]byte{num(v)}})
	j := write(`{"article":`, articleRow, calls...)
	switch {
	case j.err != nil:
		return dbFailure(j.err)
	case j.rows == 0:
		return serverError
	}
	return reply{201, j.out}
}

// ownRow takes author_id, then (for updates) the Article if the viewer could change it.
func ownRow(j *job, _ int, c [][]byte) {
	j.n = i64(c[0])
	if len(c) > 1 && c[1] != nil {
		j.out = append(appendArticle(j.out, c[1:], true), '}')
		j.hash = "updated"
	}
}

// owned maps an ownership-checked write to its reply; ok means the viewer owned the row.
func owned(j *job, v int64) (reply, bool) {
	switch {
	case j.err != nil:
		return dbFailure(j.err), false
	case j.rows == 0:
		return notFound, false
	case j.n != v:
		return forbidden, false
	}
	return reply{}, true
}

func updateArticle(rq *request, slug string, ok bool) reply {
	v, authOK := viewer(rq, true)
	if !authOK {
		return unauthorized
	}
	a, bodyOK := articleBody(rq)
	if !bodyOK || !optional(a.Title, true) || !optional(a.Description, true) || !optional(a.Body, true) {
		return invalid("title, description and body must be non-empty strings")
	}
	if !ok {
		return notFound
	}
	j := write(`{"article":`, ownRow, call{wArticleUpdate, [][]byte{[]byte(slug), text(a.Title), text(a.Description), text(a.Body), num(v)}})
	if r, mine := owned(j, v); !mine {
		return r
	}
	if j.hash == "" {
		return notFound // deleted between the lookup and the update
	}
	return reply{200, j.out}
}

func deleteArticle(rq *request, slug string, ok bool) reply {
	v, authOK := viewer(rq, true)
	if !authOK {
		return unauthorized
	}
	if !ok {
		return notFound
	}
	j := write("", ownRow, call{wArticleDelete, [][]byte{[]byte(slug), num(v)}})
	if r, mine := owned(j, v); !mine {
		return r
	}
	return reply{204, nil}
}

func favorite(rq *request, slug string, ok, on bool) reply {
	v, authOK := viewer(rq, true)
	if !authOK {
		return unauthorized
	}
	if !ok {
		return notFound
	}
	stmt := wUnfavorite
	if on {
		stmt = wFavorite
	}
	j := write(`{"article":`, articleRow, call{stmt, [][]byte{num(v), []byte(slug)}})
	switch {
	case j.err != nil:
		return dbFailure(j.err)
	case j.rows == 0:
		return notFound
	}
	return reply{200, j.out}
}

// ---------- comments ----------

func listComments(rq *request, slug string, ok bool) reply {
	v, authOK := viewer(rq, false)
	if !authOK {
		return unauthorized
	}
	if !ok {
		return notFound
	}
	j := read(kComments, v, 0, 0, slug)
	switch {
	case j.err != nil:
		return dbFailure(j.err)
	case j.n == 0:
		return notFound
	}
	return reply{200, append(j.out, "]}"...)}
}

func addComment(rq *request, slug string, ok bool) reply {
	v, authOK := viewer(rq, true)
	if !authOK {
		return unauthorized
	}
	var in struct{ Comment *struct{ Body *string } }
	if json.Unmarshal(rq.body, &in) != nil || in.Comment == nil || !set(in.Comment.Body) {
		return invalid("body is required")
	}
	if !ok {
		return notFound
	}
	j := write(`{"comment":`, func(j *job, _ int, c [][]byte) { j.out = append(appendComment(j.out, c, false), '}') },
		call{wComment, [][]byte{[]byte(slug), num(v), text(in.Comment.Body)}})
	switch {
	case j.err != nil:
		return dbFailure(j.err)
	case j.rows == 0:
		return notFound
	}
	return reply{201, j.out}
}

func deleteComment(rq *request, slug string, ok bool, idText string) reply {
	v, authOK := viewer(rq, true)
	if !authOK {
		return unauthorized
	}
	id, err := strconv.ParseInt(idText, 10, 64)
	if !ok || err != nil || id <= 0 {
		return notFound
	}
	j := write("", ownRow, call{wCommentDelete, [][]byte{num(id), []byte(slug), num(v)}})
	if r, mine := owned(j, v); !mine {
		return r
	}
	return reply{204, nil}
}

func getTags() reply {
	j := read(kTags, 0, 0, 0, "")
	if j.err != nil || j.rows == 0 {
		return dbFailure(j.err)
	}
	return reply{200, j.out}
}
