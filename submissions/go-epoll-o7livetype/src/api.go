package main

import (
	"encoding/json"
	"log"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5/pgconn"
)

// Each request is planned once on the worker that dequeues it: routing,
// authentication, validation and parameter encoding. A planned request is one
// prepared statement; its result rows are written straight into JSON by finish.

type route uint8

const (
	rNotFound route = iota
	rTags
	rRegister
	rLogin
	rCurrentUser
	rUpdateUser
	rProfile
	rFollow
	rUnfollow
	rList
	rFeed
	rArticle
	rCreateArticle
	rUpdateArticle
	rDeleteArticle
	rFavorite
	rUnfavorite
	rComments
	rCreateComment
	rDeleteComment
)

type action uint8

const (
	actDone   action = iota // response is ready
	actQuery                // run the planned statement
	actHash                 // hash the password, then return to the write queue
	actVerify               // verify the password, then respond
)

// jobClass picks the queue: GET/HEAD and login read; everything else writes.
type jobClass uint8

const (
	classRead jobClass = iota
	classWrite
)

func classify(method, target []byte) jobClass {
	if string(method) == "GET" || string(method) == "HEAD" {
		return classRead
	}
	path := target
	if i := strings.IndexByte(bstr(target), '?'); i >= 0 {
		path = target[:i]
	}
	if string(method) == "POST" && string(path) == "/api/users/login" {
		return classRead
	}
	return classWrite
}

// dbJob is per-request state for the database dispatcher. It lives in the job
// slot; out and args keep their capacity across requests.
type dbJob struct {
	route   route
	stmt    stmtID
	stage   uint8
	nparams int
	viewer  int64
	userID  int64
	params  [6][]byte
	ints    [6][8]byte
	args    []byte // encoded text[] parameter
	str     [5]string
	set     uint8 // bit i: str[i] is non-NULL
	tags    []string
	token   []byte
	hash    [60]byte
	hashLen int
	out     []byte
	next    action
}

const maxRetainedBuffer = 64 << 10

func (d *dbJob) reset() {
	out, args := d.out[:0], d.args[:0]
	if cap(out) > maxRetainedBuffer {
		out = nil
	}
	if cap(args) > maxRetainedBuffer {
		args = nil
	}
	*d = dbJob{out: out, args: args}
}

func (d *dbJob) addInt(v int64) {
	d.params[d.nparams] = putInt8(&d.ints[d.nparams], v)
	d.nparams++
}

func (d *dbJob) addText(s string) {
	d.params[d.nparams] = sbytes(s)
	d.nparams++
}

func (d *dbJob) addOptText(i int) {
	if d.set&(1<<i) != 0 {
		d.params[d.nparams] = sbytes(d.str[i])
	} else {
		d.params[d.nparams] = nil
	}
	d.nparams++
}

func (d *dbJob) setStr(i int, p *string) {
	if p != nil {
		d.str[i] = *p
		d.set |= 1 << i
	}
}

func respond(j *reactorJob, status int, body []byte) action {
	j.response.status, j.response.body = status, body
	return actDone
}

func (j *reactorJob) body(status int) action {
	j.response.status, j.response.body = status, j.db.out
	return actDone
}

// textOK reports whether PostgreSQL can accept s as text: valid UTF-8, no NUL.
// A path or filter that fails can match no row, so it is answered directly.
func textOK(s string) bool { return utf8.ValidString(s) && strings.IndexByte(s, 0) < 0 }

// ---------- routing ----------

func routeOf(r *request) route {
	method, path := r.method, r.path
	switch path {
	case "/api/users":
		if method == "POST" {
			return rRegister
		}
	case "/api/users/login":
		if method == "POST" {
			return rLogin
		}
	case "/api/user":
		switch method {
		case "GET", "HEAD":
			return rCurrentUser
		case "PUT":
			return rUpdateUser
		}
	case "/api/articles":
		switch method {
		case "GET", "HEAD":
			return rList
		case "POST":
			return rCreateArticle
		}
	case "/api/articles/feed":
		if method == "GET" || method == "HEAD" {
			return rFeed
		}
	case "/api/tags":
		if method == "GET" || method == "HEAD" {
			return rTags
		}
	default:
		// Split before unescaping each segment: an encoded slash must not
		// become an extra routing separator.
		if rest, ok := strings.CutPrefix(path, "/api/profiles/"); ok {
			name, tail, more := strings.Cut(rest, "/")
			r.username = unescapeSegment(name)
			if name != "" {
				if !more && (method == "GET" || method == "HEAD") {
					return rProfile
				}
				if tail == "follow" {
					switch method {
					case "POST":
						return rFollow
					case "DELETE":
						return rUnfollow
					}
				}
			}
		} else if rest, ok := strings.CutPrefix(path, "/api/articles/"); ok {
			slug, tail, more := strings.Cut(rest, "/")
			r.slug = unescapeSegment(slug)
			if slug != "" {
				switch {
				case !more:
					switch method {
					case "GET", "HEAD":
						return rArticle
					case "PUT":
						return rUpdateArticle
					case "DELETE":
						return rDeleteArticle
					}
				case tail == "favorite":
					switch method {
					case "POST":
						return rFavorite
					case "DELETE":
						return rUnfavorite
					}
				case tail == "comments":
					switch method {
					case "GET", "HEAD":
						return rComments
					case "POST":
						return rCreateComment
					}
				default:
					if id, ok := strings.CutPrefix(tail, "comments/"); ok && id != "" && !strings.Contains(id, "/") && method == "DELETE" {
						r.id = unescapeSegment(id)
						return rDeleteComment
					}
				}
			}
		}
	}
	return rNotFound
}

type authMode uint8

const (
	authNone authMode = iota
	authOptional
	authRequired
)

var routeAuth = [rDeleteComment + 1]authMode{
	rCurrentUser: authRequired, rUpdateUser: authRequired, rProfile: authOptional, rFollow: authRequired,
	rUnfollow: authRequired, rList: authOptional, rFeed: authRequired, rArticle: authOptional,
	rCreateArticle: authRequired, rUpdateArticle: authRequired, rDeleteArticle: authRequired,
	rFavorite: authRequired, rUnfavorite: authRequired, rComments: authOptional,
	rCreateComment: authRequired, rDeleteComment: authRequired,
}

var routeStmt = [rDeleteComment + 1]stmtID{
	rProfile: stProfile, rFollow: stFollow, rUnfollow: stUnfollow,
	rArticle: stArticleBySlug, rFavorite: stFavorite, rUnfavorite: stUnfavorite, rComments: stComments,
}

// authenticate applies the endpoint's auth mode. A present but invalid header
// is 401 even where auth is optional.
func authenticate(w *worker, j *reactorJob, mode authMode) bool {
	r := &j.req
	if mode == authNone {
		return true
	}
	if r.authCount == 0 {
		return mode == authOptional
	}
	if r.authCount != 1 {
		return false
	}
	token, ok := strings.CutPrefix(bstr(r.authHeader), "Token ")
	if !ok {
		return false
	}
	id, valid := w.jwt.verify(sbytes(token))
	if !valid {
		return false
	}
	j.db.viewer = id
	j.db.token = sbytes(token)
	return true
}

// ---------- planning ----------

func (w *worker) plan(j *reactorJob) action {
	d := &j.db
	r := &j.req
	if d.stage == 0 {
		d.route = routeOf(r)
		if d.route == rNotFound {
			return respond(j, 404, errNotFound)
		}
		if !authenticate(w, j, routeAuth[d.route]) {
			return respond(j, 401, errUnauthorized)
		}
	}
	d.nparams = 0
	switch d.route {
	case rTags:
		d.stmt = stTags
	case rCurrentUser:
		d.stmt = stUserByID
		d.addInt(d.viewer)
	case rProfile, rFollow, rUnfollow:
		if !textOK(r.username) {
			return respond(j, 404, errProfile404)
		}
		d.stmt = routeStmt[d.route]
		d.addInt(d.viewer)
		d.addText(r.username)
	case rList, rFeed:
		limit, offset, ok := limitOffset(r)
		if !ok {
			return respond(j, 422, errLimitOffset)
		}
		filter := ""
		d.stmt = stListAll
		if d.route == rFeed {
			d.stmt = stListFeed
		} else {
			q := r.QueryArgs()
			if v := q.Peek("tag"); v != "" {
				d.stmt, filter = stListTag, v
			} else if v := q.Peek("author"); v != "" {
				d.stmt, filter = stListAuthor, v
			} else if v := q.Peek("favorited"); v != "" {
				d.stmt, filter = stListFavorite, v
			}
			if filter != "" && !textOK(filter) {
				d.out = append(d.out[:0], `{"articles":[],"articlesCount":0}`...)
				return j.body(200)
			}
		}
		d.addInt(d.viewer)
		d.addInt(limit)
		d.addInt(offset)
		if filter != "" {
			d.addText(filter)
		}
	case rArticle, rFavorite, rUnfavorite, rComments:
		if !textOK(r.slug) {
			return respond(j, 404, errArticle404)
		}
		d.stmt = routeStmt[d.route]
		d.addInt(d.viewer)
		d.addText(r.slug)
	case rDeleteArticle:
		if !textOK(r.slug) {
			return respond(j, 404, errArticle404)
		}
		d.stmt = stArticleDelete
		d.addText(r.slug)
		d.addInt(d.viewer)
	case rDeleteComment:
		id, ok := parseUint(r.id)
		if !ok || !textOK(r.slug) {
			return respond(j, 404, errComment404)
		}
		d.stmt = stCommentDelete
		d.addInt(id)
		d.addText(r.slug)
		d.addInt(d.viewer)
	case rLogin:
		return w.planLogin(j)
	case rRegister:
		return w.planRegister(j)
	case rUpdateUser:
		return w.planUpdateUser(j)
	case rCreateArticle:
		return w.planCreateArticle(j)
	case rUpdateArticle:
		return w.planUpdateArticle(j)
	case rCreateComment:
		return w.planCreateComment(j)
	}
	return actQuery
}

// bodyText rejects strings PostgreSQL cannot store (NUL) before they reach a
// shared group transaction. JSON decoding already guarantees valid UTF-8.
func bodyText(ss ...*string) bool {
	for _, s := range ss {
		if s != nil && strings.IndexByte(*s, 0) >= 0 {
			return false
		}
	}
	return true
}

func (w *worker) planLogin(j *reactorJob) action {
	d := &j.db
	m, err := readWrapper(&j.req, "user")
	if err != nil {
		return respond(j, 422, errInvalidBody)
	}
	email, err1 := reqString(m, "email")
	password, err2 := reqString(m, "password")
	if err1 != nil || err2 != nil {
		return respond(j, 422, errLoginBody)
	}
	if !textOK(email) {
		return respond(j, 401, errLogin)
	}
	d.str[0], d.str[1] = email, password
	d.stmt = stUserByEmail
	d.addText(email)
	return actQuery
}

func (w *worker) planRegister(j *reactorJob) action {
	d := &j.db
	if d.stage == 0 {
		m, err := readWrapper(&j.req, "user")
		if err != nil {
			return respond(j, 422, errInvalidBody)
		}
		username, err1 := reqString(m, "username")
		email, err2 := reqString(m, "email")
		password, err3 := reqString(m, "password")
		if err1 != nil || err2 != nil || err3 != nil {
			return respond(j, 422, errRegisterBody)
		}
		if !bodyText(&username, &email) {
			return respond(j, 422, errRegisterBody)
		}
		if len(password) > 72 {
			return respond(j, 422, errPasswordLong)
		}
		d.str[0], d.str[1], d.str[2] = username, email, password
		return actHash
	}
	d.stmt = stRegister
	d.addText(d.str[0])
	d.addText(d.str[1])
	d.params[d.nparams] = d.hash[:d.hashLen]
	d.nparams++
	return actQuery
}

func (w *worker) planUpdateUser(j *reactorJob) action {
	d := &j.db
	if d.stage == 0 {
		m, err := readWrapper(&j.req, "user")
		if err != nil {
			return respond(j, 422, errInvalidBody)
		}
		email, err1 := optString(m, "email", true)
		username, err2 := optString(m, "username", true)
		password, err3 := optString(m, "password", true)
		bio, err4 := optString(m, "bio", false)
		image, err5 := optString(m, "image", false)
		if err1 != nil || err2 != nil || err3 != nil || err4 != nil || err5 != nil || !bodyText(email, username, bio, image) {
			return respond(j, 422, errUserFields)
		}
		d.setStr(0, email)
		d.setStr(1, username)
		d.setStr(2, password)
		d.setStr(3, bio)
		d.setStr(4, image)
		if password != nil {
			if len(*password) > 72 {
				return respond(j, 422, errPasswordLong)
			}
			return actHash
		}
	}
	d.stmt = stUserUpdate
	d.addInt(d.viewer)
	d.addOptText(0)
	d.addOptText(1)
	if d.set&(1<<2) != 0 {
		d.params[d.nparams] = d.hash[:d.hashLen]
	} else {
		d.params[d.nparams] = nil
	}
	d.nparams++
	d.addOptText(3)
	d.addOptText(4)
	return actQuery
}

func (w *worker) planCreateArticle(j *reactorJob) action {
	d := &j.db
	m, err := readWrapper(&j.req, "article")
	if err != nil {
		return respond(j, 422, errInvalidBody)
	}
	title, err1 := reqString(m, "title")
	description, err2 := reqString(m, "description")
	body, err3 := reqString(m, "body")
	if err1 != nil || err2 != nil || err3 != nil || !bodyText(&title, &description, &body) {
		return respond(j, 422, errArticleBody)
	}
	tags := d.tags[:0]
	if raw, ok := m["tagList"]; ok && !isNull(raw) {
		var items []json.RawMessage
		if err := json.Unmarshal(raw, &items); err != nil {
			return respond(j, 422, errTagList)
		}
		for _, it := range items {
			var s string
			if isNull(it) || json.Unmarshal(it, &s) != nil || s == "" || !bodyText(&s) {
				return respond(j, 422, errTagList)
			}
			tags = append(tags, s)
		}
	}
	d.tags = tags
	d.str[0], d.str[1], d.str[2] = title, description, body
	d.stmt = stArticleCreate
	d.addInt(d.viewer)
	d.addText(title)
	d.addText(description)
	d.addText(body)
	d.args = appendTextArrayParam(d.args[:0], tags)
	d.params[d.nparams] = d.args
	d.nparams++
	return actQuery
}

func (w *worker) planUpdateArticle(j *reactorJob) action {
	d := &j.db
	m, err := readWrapper(&j.req, "article")
	if err != nil {
		return respond(j, 422, errInvalidBody)
	}
	title, err1 := optString(m, "title", true)
	description, err2 := optString(m, "description", true)
	body, err3 := optString(m, "body", true)
	if err1 != nil || err2 != nil || err3 != nil || !bodyText(title, description, body) {
		return respond(j, 422, errArticleFields)
	}
	if !textOK(j.req.slug) {
		return respond(j, 404, errArticle404)
	}
	d.setStr(0, title)
	d.setStr(1, description)
	d.setStr(2, body)
	d.stmt = stArticleUpdate
	d.addText(j.req.slug)
	d.addOptText(0)
	d.addOptText(1)
	d.addOptText(2)
	d.addInt(d.viewer)
	return actQuery
}

func (w *worker) planCreateComment(j *reactorJob) action {
	d := &j.db
	m, err := readWrapper(&j.req, "comment")
	if err != nil {
		return respond(j, 422, errInvalidBody)
	}
	body, err := reqString(m, "body")
	if err != nil || !bodyText(&body) {
		return respond(j, 422, errCommentBody)
	}
	if !textOK(j.req.slug) {
		return respond(j, 404, errArticle404)
	}
	d.str[0] = body
	d.stmt = stCommentCreate
	d.addText(j.req.slug)
	d.addInt(d.viewer)
	d.addText(body)
	return actQuery
}

// ---------- results ----------

// Full Article layout offsets from base: id, slug, title, description, body,
// created_at, updated_at, tags, count, favorited, username, bio, image, following.
// List rows omit body.
func appendArticle(dst []byte, v [][]byte, base int, body bool) []byte {
	i := base + 1
	dst = append(dst, `{"slug":`...)
	dst = appendJSONString(dst, v[i])
	dst = append(dst, `,"title":`...)
	dst = appendJSONString(dst, v[i+1])
	dst = append(dst, `,"description":`...)
	dst = appendJSONString(dst, v[i+2])
	i += 3
	if body {
		dst = append(dst, `,"body":`...)
		dst = appendJSONString(dst, v[i])
		i++
	}
	dst = append(dst, `,"tagList":`...)
	dst = appendTextArray(dst, v[i+2])
	dst = append(dst, `,"createdAt":`...)
	dst = appendTimestamp(dst, v[i])
	dst = append(dst, `,"updatedAt":`...)
	dst = appendTimestamp(dst, v[i+1])
	dst = append(dst, `,"favorited":`...)
	dst = appendBool(dst, v[i+4])
	dst = append(dst, `,"favoritesCount":`...)
	dst = appendInt8(dst, v[i+3])
	dst = append(dst, `,"author":`...)
	dst = appendProfile(dst, v[i+5], v[i+6], v[i+7], v[i+8])
	return append(dst, '}')
}

// Binary bool values for computed columns.
var sqlTrue, sqlFalse = []byte{1}, []byte{0}

func appendProfile(dst, username, bio, image, following []byte) []byte {
	dst = append(dst, `{"username":`...)
	dst = appendJSONString(dst, username)
	dst = append(dst, `,"bio":`...)
	dst = appendNullableString(dst, bio)
	dst = append(dst, `,"image":`...)
	dst = appendNullableString(dst, image)
	dst = append(dst, `,"following":`...)
	if following == nil {
		dst = append(dst, "false"...)
	} else {
		dst = appendBool(dst, following)
	}
	return append(dst, '}')
}

// appendUserFields writes {"user":{"email":..,"username":..,"bio":..,"image":..,"token":"
// leaving the token and closing to the caller.
func appendUserFields(dst, username, email, bio, image []byte) []byte {
	dst = append(dst, `{"user":{"email":`...)
	dst = appendJSONString(dst, email)
	dst = append(dst, `,"username":`...)
	dst = appendJSONString(dst, username)
	dst = append(dst, `,"bio":`...)
	dst = appendNullableString(dst, bio)
	dst = append(dst, `,"image":`...)
	dst = appendNullableString(dst, image)
	return append(dst, `,"token":"`...)
}

func appendComment(dst []byte, v [][]byte, following []byte) []byte {
	dst = append(dst, `{"id":`...)
	dst = appendInt8(dst, v[0])
	dst = append(dst, `,"createdAt":`...)
	dst = appendTimestamp(dst, v[2])
	dst = append(dst, `,"updatedAt":`...)
	dst = appendTimestamp(dst, v[3])
	dst = append(dst, `,"body":`...)
	dst = appendJSONString(dst, v[1])
	dst = append(dst, `,"author":`...)
	dst = appendProfile(dst, v[4], v[5], v[6], following)
	return append(dst, '}')
}

// finish consumes the statement's rows, writes the response and returns what
// happens next. A non-nil error leaves the response to the caller.
func (w *worker) finish(j *reactorJob, rr *pgconn.ResultReader) (action, error) {
	d := &j.db
	out := d.out[:0]
	rows := 0
	status, next := 200, actDone
	var fixed []byte // a fixed error body instead of out
	switch d.route {
	case rTags:
		for rr.NextRow() {
			out = append(out, `{"tags":`...)
			out = appendTextArray(out, rr.Values()[0])
			out = append(out, '}')
			rows++
		}
		if rows == 0 {
			out = append(out, `{"tags":[]}`...)
		}
	case rCurrentUser:
		for rr.NextRow() {
			v := rr.Values()
			out = appendUserFields(out[:0], v[0], v[1], v[2], v[3])
			out = append(out, d.token...)
			out = append(out, `"}}`...)
			rows++
		}
		if rows == 0 {
			status, fixed = 401, errUnauthorized
		}
	case rLogin:
		for rr.NextRow() {
			v := rr.Values()
			d.userID = int8Value(v[0])
			out = appendUserFields(out[:0], v[1], v[2], v[3], v[4])
			d.hashLen = copy(d.hash[:], v[5])
			if len(v[5]) > len(d.hash) {
				d.hashLen = 0 // unexpected hash: verification fails closed
			}
			rows++
		}
		if rows == 0 {
			status, fixed = 401, errLogin
		} else {
			next = actVerify
		}
	case rRegister:
		for rr.NextRow() {
			v := rr.Values()
			out = appendUserFields(out[:0], v[1], v[2], v[3], v[4])
			out = w.jwt.appendToken(out, int8Value(v[0]), time.Now())
			out = append(out, `"}}`...)
			rows++
		}
		status = 201
		if rows == 0 {
			status, fixed = 422, errTaken
		}
	case rUpdateUser:
		clash := false
		for rr.NextRow() {
			v := rr.Values()
			clash = len(v[0]) == 1 && v[0][0] != 0
			if v[1] != nil {
				out = appendUserFields(out[:0], v[1], v[2], v[3], v[4])
				out = append(out, d.token...)
				out = append(out, `"}}`...)
				rows++
			}
		}
		if clash {
			status, fixed = 422, errTaken
		} else if rows == 0 {
			status, fixed = 401, errUnauthorized
		}
	case rProfile:
		for rr.NextRow() {
			v := rr.Values()
			out = append(out[:0], `{"profile":`...)
			out = appendProfile(out, v[0], v[1], v[2], v[3])
			out = append(out, '}')
			rows++
		}
		if rows == 0 {
			status, fixed = 404, errProfile404
		}
	case rFollow, rUnfollow:
		following := sqlFalse
		if d.route == rFollow {
			following = sqlTrue
		}
		for rr.NextRow() {
			v := rr.Values()
			out = append(out[:0], `{"profile":`...)
			out = appendProfile(out, v[0], v[1], v[2], following)
			out = append(out, '}')
			rows++
		}
		if rows == 0 {
			status, fixed = 404, errProfile404
		}
	case rList, rFeed:
		out = append(out, `{"articles":[`...)
		var count []byte
		for rr.NextRow() {
			v := rr.Values()
			if count == nil {
				count = append(d.ints[5][:0], v[0]...)
			}
			if v[1] == nil {
				continue
			}
			if rows > 0 {
				out = append(out, ',')
			}
			out = appendArticle(out, v, 1, false)
			rows++
		}
		out = append(out, `],"articlesCount":`...)
		out = appendInt8(out, count)
		out = append(out, '}')
	case rArticle, rFavorite, rUnfavorite, rCreateArticle:
		for rr.NextRow() {
			out = append(out[:0], `{"article":`...)
			out = appendArticle(out, rr.Values(), 0, true)
			out = append(out, '}')
			rows++
		}
		if d.route == rCreateArticle {
			status = 201
			if rows == 0 {
				status, fixed = 500, errInternal
			}
		} else if rows == 0 {
			status, fixed = 404, errArticle404
		}
	case rUpdateArticle:
		status, fixed = 404, errArticle404
		for rr.NextRow() {
			v := rr.Values()
			switch {
			case int8Value(v[0]) != d.viewer:
				status, fixed = 403, errNotAuthor
			case v[1] == nil: // deleted concurrently
			default:
				out = append(out[:0], `{"article":`...)
				out = appendArticle(out, v, 1, true)
				out = append(out, '}')
				status, fixed = 200, nil
			}
		}
	case rDeleteArticle, rDeleteComment:
		status, fixed = 404, errArticle404
		if d.route == rDeleteComment {
			fixed = errComment404
		}
		for rr.NextRow() {
			if int8Value(rr.Values()[0]) != d.viewer {
				status, fixed = 403, errNotAuthor
			} else {
				status, fixed = 204, nil
			}
		}
	case rComments:
		out = append(out, `{"comments":[`...)
		exists := false
		for rr.NextRow() {
			exists = true
			v := rr.Values()
			if v[0] == nil {
				continue
			}
			if rows > 0 {
				out = append(out, ',')
			}
			out = appendComment(out, v, v[7])
			rows++
		}
		out = append(out, "]}"...)
		if !exists {
			status, fixed = 404, errArticle404
		}
	case rCreateComment:
		for rr.NextRow() {
			out = append(out[:0], `{"comment":`...)
			out = appendComment(out, rr.Values(), nil)
			out = append(out, '}')
			rows++
		}
		status = 201
		if rows == 0 {
			status, fixed = 404, errArticle404
		}
	}
	d.out = out
	if _, err := rr.Close(); err != nil {
		return actDone, err
	}
	switch {
	case fixed != nil:
		respond(j, status, fixed)
	case status == 204:
		respond(j, 204, nil)
	default:
		j.body(status)
	}
	return next, nil
}

// fail answers a request whose statement failed on its own (not as part of a group).
func (w *worker) fail(j *reactorJob, err error) {
	if (j.db.route == rRegister || j.db.route == rUpdateUser) && isUniqueViolation(err) {
		respond(j, 422, errTaken)
		return
	}
	log.Printf("error: route=%d: %v", j.db.route, err)
	respond(j, 500, errInternal)
}

// ---------- password stage ----------

// completeLogin runs on a bcrypt worker after verification.
func completeLogin(c *jwtCodec, j *reactorJob, ok bool) {
	d := &j.db
	if !ok {
		respond(j, 401, errLogin)
		return
	}
	d.out = c.appendToken(d.out, d.userID, time.Now())
	d.out = append(d.out, `"}}`...)
	j.body(200)
}
