package main

// api.go implements the 19 Conduit endpoints.
//
// Every request goes through the same steps:
//
//  1. plan    (handler goroutine) Find the route, check the token, validate the
//             body and fill in the parameters of the route's one prepared
//             statement.
//  2. query   (database worker)   Run that statement, batched with others.
//  3. finish  (database worker)   Write the JSON response straight from the
//             result rows.
//
// Three routes also need bcrypt, which runs on the handler goroutine (server.go):
// register and update-user hash the new password between plan and query (the
// route is planned again with hashed set), and login verifies the password after
// its query has loaded the stored hash.
//
// The endpoints table below says, for each route, who may call it and which
// plan and finish functions handle it. The functions follow in the same order.

import (
	"errors"
	"log/slog"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/segmentio/encoding/json"
)

// ---------- routes and the endpoint table ----------

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
	numRoutes
)

// action is what the handler does next with a request.
type action uint8

const (
	actDone   action = iota // the response is ready
	actQuery                // run the planned statement on a database worker
	actHash                 // hash the new password, then plan the route again
	actVerify               // verify the login password, then respond
)

type authMode uint8

const (
	authNone     authMode = iota // no token needed
	authOptional                 // anonymous without a header; a bad header is still 401
	authRequired                 // a valid token is required
)

type endpoint struct {
	auth   authMode
	plan   func(j *job) action
	finish func(w *worker, j *job, rr *pgconn.ResultReader) reply
}

var endpoints = [numRoutes]endpoint{
	rTags:          {authNone, planTags, finishTags},
	rRegister:      {authNone, planRegister, finishRegister},
	rLogin:         {authNone, planLogin, finishLogin},
	rCurrentUser:   {authRequired, planCurrentUser, finishCurrentUser},
	rUpdateUser:    {authRequired, planUpdateUser, finishUpdateUser},
	rProfile:       {authOptional, planByUsername(stProfile), finishProfile},
	rFollow:        {authRequired, planByUsername(stFollow), finishFollow(true)},
	rUnfollow:      {authRequired, planByUsername(stUnfollow), finishFollow(false)},
	rList:          {authOptional, planList, finishArticleList},
	rFeed:          {authRequired, planFeed, finishArticleList},
	rArticle:       {authOptional, planBySlug(stArticleBySlug), finishArticle(200)},
	rCreateArticle: {authRequired, planCreateArticle, finishArticle(201)},
	rUpdateArticle: {authRequired, planUpdateArticle, finishUpdateArticle},
	rDeleteArticle: {authRequired, planDeleteArticle, finishDelete(errArticle404)},
	rFavorite:      {authRequired, planBySlug(stFavorite), finishArticle(200)},
	rUnfavorite:    {authRequired, planBySlug(stUnfavorite), finishArticle(200)},
	rComments:      {authOptional, planBySlug(stComments), finishComments},
	rCreateComment: {authRequired, planCreateComment, finishCreateComment},
	rDeleteComment: {authRequired, planDeleteComment, finishDelete(errComment404)},
}

// routeOf matches the method and path. Path segments are split before they are
// unescaped, so an encoded slash cannot act as a separator.
func routeOf(r *request) route {
	method, path := r.method, r.path
	read := method == "GET" || method == "HEAD"

	// Fixed paths. A fixed path with another method is 404, even where it also
	// looks like /api/articles/:slug (the feed).
	switch path {
	case "/api/users":
		return pick(method == "POST", rRegister)
	case "/api/users/login":
		return pick(method == "POST", rLogin)
	case "/api/user":
		if read {
			return rCurrentUser
		}
		return pick(method == "PUT", rUpdateUser)
	case "/api/articles":
		if read {
			return rList
		}
		return pick(method == "POST", rCreateArticle)
	case "/api/articles/feed":
		return pick(read, rFeed)
	case "/api/tags":
		return pick(read, rTags)
	}

	// /api/profiles/:username[/follow]
	if rest, ok := strings.CutPrefix(path, "/api/profiles/"); ok {
		name, tail, more := strings.Cut(rest, "/")
		r.username = unescapeSegment(name)
		switch {
		case name == "":
		case !more && read:
			return rProfile
		case tail == "follow" && method == "POST":
			return rFollow
		case tail == "follow" && method == "DELETE":
			return rUnfollow
		}
		return rNotFound
	}

	// /api/articles/:slug[/favorite | /comments | /comments/:id]
	if rest, ok := strings.CutPrefix(path, "/api/articles/"); ok {
		slug, tail, more := strings.Cut(rest, "/")
		r.slug = unescapeSegment(slug)
		if slug == "" {
			return rNotFound
		}
		switch {
		case !more && read:
			return rArticle
		case !more && method == "PUT":
			return rUpdateArticle
		case !more && method == "DELETE":
			return rDeleteArticle
		case tail == "favorite" && method == "POST":
			return rFavorite
		case tail == "favorite" && method == "DELETE":
			return rUnfavorite
		case tail == "comments" && read:
			return rComments
		case tail == "comments" && method == "POST":
			return rCreateComment
		}
		id, isComment := strings.CutPrefix(tail, "comments/")
		if isComment && id != "" && !strings.Contains(id, "/") && method == "DELETE" {
			r.id = unescapeSegment(id)
			return rDeleteComment
		}
	}
	return rNotFound
}

// pick returns r if cond holds, otherwise rNotFound.
func pick(cond bool, r route) route {
	if cond {
		return r
	}
	return rNotFound
}

// ---------- request state ----------

// dbJob is one request's state from plan to finish. It lives in a pooled job;
// out and args keep their capacity between requests.
type dbJob struct {
	route  route
	stmt   stmtID // the prepared statement to run
	viewer int64  // the authenticated user's id; 0 when anonymous
	token  []byte // the presented token, echoed back by user endpoints
	in     input  // the validated request body
	hashed bool   // the new password has been hashed into hash
	next   action // set by finish: what happens after the statement

	// Statement parameters in PostgreSQL's binary format.
	params  [6][]byte
	nparams int
	ints    [6][8]byte // backing storage for int8 parameters
	args    []byte     // backing storage for the text[] tag list

	// Passwords: the new hash (register, update) or the stored one (login).
	hash    [60]byte
	hashLen int
	userID  int64 // login: the user whose password is being checked

	out []byte // the JSON response being built
}

// input holds the validated fields of a request body. Optional fields are nil
// when they were absent or null.
type input struct {
	email, username, password, bio, image *string
	title, description, body              *string
	tags                                  []string
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

// addOptText adds a text parameter that is NULL when s is nil.
func (d *dbJob) addOptText(s *string) {
	d.params[d.nparams] = nil
	if s != nil {
		d.params[d.nparams] = sbytes(*s)
	}
	d.nparams++
}

func (d *dbJob) addBytes(b []byte) {
	d.params[d.nparams] = b
	d.nparams++
}

// newHash is the hashed password parameter, or NULL when no password was given.
func (d *dbJob) newHash() []byte {
	if !d.hashed {
		return nil
	}
	return d.hash[:d.hashLen]
}

// respond sets a fixed response; body writes the JSON built in d.out.
func respond(j *job, status int, body []byte) action {
	j.status, j.resp = status, body
	return actDone
}

func (j *job) body(status int) action {
	j.status, j.resp = status, j.db.out
	return actDone
}

// textOK reports whether PostgreSQL can accept s as text: valid UTF-8, no NUL.
// A path parameter or filter that fails cannot match any row.
func textOK(s string) bool { return utf8.ValidString(s) && strings.IndexByte(s, 0) < 0 }

// ---------- step 1: plan ----------

// plan routes and authenticates a request (the first time), then calls the
// route's plan function.
func (s *server) plan(j *job) action {
	d := &j.db
	if !d.hashed {
		d.route = routeOf(&j.req)
		if d.route == rNotFound {
			return respond(j, 404, errNotFound)
		}
		if !s.authenticate(j, endpoints[d.route].auth) {
			return respond(j, 401, errUnauthorized)
		}
	}
	d.nparams = 0
	return endpoints[d.route].plan(j)
}

// authenticate checks the Authorization header ("Token <jwt>") for the mode.
func (s *server) authenticate(j *job, mode authMode) bool {
	r := &j.req
	switch {
	case mode == authNone:
		return true
	case r.authCount == 0:
		return mode == authOptional
	case r.authCount > 1:
		return false
	}
	token, ok := strings.CutPrefix(bstr(r.authHeader), "Token ")
	if !ok {
		return false
	}
	id, valid := s.jwt.verify(sbytes(token))
	if !valid {
		return false
	}
	j.db.viewer = id
	j.db.token = sbytes(token)
	return true
}

func planTags(j *job) action {
	j.db.stmt = stTags
	return actQuery
}

func planCurrentUser(j *job) action {
	d := &j.db
	d.stmt = stUserByID
	d.addInt(d.viewer)
	return actQuery
}

// planByUsername plans profile, follow and unfollow: (viewer, username).
func planByUsername(stmt stmtID) func(j *job) action {
	return func(j *job) action {
		d := &j.db
		if !textOK(j.req.username) {
			return respond(j, 404, errProfile404)
		}
		d.stmt = stmt
		d.addInt(d.viewer)
		d.addText(j.req.username)
		return actQuery
	}
}

// planBySlug plans article, favorite, unfavorite and comments: (viewer, slug).
func planBySlug(stmt stmtID) func(j *job) action {
	return func(j *job) action {
		d := &j.db
		if !textOK(j.req.slug) {
			return respond(j, 404, errArticle404)
		}
		d.stmt = stmt
		d.addInt(d.viewer)
		d.addText(j.req.slug)
		return actQuery
	}
}

// planList plans GET /api/articles: (viewer, limit, offset[, filter]), with at
// most one of the tag, author or favorited filters, in that order of priority.
func planList(j *job) action {
	d := &j.db
	limit, offset, ok := limitOffset(&j.req)
	if !ok {
		return respond(j, 422, errLimitOffset)
	}
	q := j.req.QueryArgs()
	d.stmt = stListAll
	filter := ""
	if v := bstr(q.Peek("tag")); v != "" {
		d.stmt, filter = stListTag, v
	} else if v := bstr(q.Peek("author")); v != "" {
		d.stmt, filter = stListAuthor, v
	} else if v := bstr(q.Peek("favorited")); v != "" {
		d.stmt, filter = stListFavorite, v
	}
	if filter != "" && !textOK(filter) {
		d.out = append(d.out[:0], `{"articles":[],"articlesCount":0}`...)
		return j.body(200)
	}
	d.addInt(d.viewer)
	d.addInt(limit)
	d.addInt(offset)
	if filter != "" {
		d.addText(filter)
	}
	return actQuery
}

// planFeed plans GET /api/articles/feed: (viewer, limit, offset).
func planFeed(j *job) action {
	d := &j.db
	limit, offset, ok := limitOffset(&j.req)
	if !ok {
		return respond(j, 422, errLimitOffset)
	}
	d.stmt = stListFeed
	d.addInt(d.viewer)
	d.addInt(limit)
	d.addInt(offset)
	return actQuery
}

// planLogin plans POST /api/users/login: load the user by email; finishLogin
// then asks for the password to be verified.
func planLogin(j *job) action {
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
	d.in.email, d.in.password = &email, &password
	d.stmt = stUserByEmail
	d.addText(email)
	return actQuery
}

// planRegister plans POST /api/users in two passes: validate and ask for the
// password to be hashed, then (hashed) insert the user.
func planRegister(j *job) action {
	d := &j.db
	if d.hashed {
		d.stmt = stRegister
		d.addText(*d.in.username)
		d.addText(*d.in.email)
		d.addBytes(d.newHash())
		return actQuery
	}
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
	if e := firstError(ruleUsername.check(&username), checkEmail(&email)); e != nil {
		return respond(j, 422, e)
	}
	if len(password) > 72 {
		return respond(j, 422, errPasswordLong)
	}
	d.in.username, d.in.email, d.in.password = &username, &email, &password
	return actHash
}

// planUpdateUser plans PUT /api/user. Every field is optional; a new password
// is hashed first, like registration.
func planUpdateUser(j *job) action {
	d := &j.db
	if !d.hashed {
		m, err := readWrapper(&j.req, "user")
		if err != nil {
			return respond(j, 422, errInvalidBody)
		}
		in := &d.in
		var errs [5]error
		in.email, errs[0] = optString(m, "email", true)
		in.username, errs[1] = optString(m, "username", true)
		in.password, errs[2] = optString(m, "password", true)
		in.bio, errs[3] = optString(m, "bio", false)
		in.image, errs[4] = optString(m, "image", false)
		if errors.Join(errs[:]...) != nil {
			return respond(j, 422, errUserFields)
		}
		e := firstError(checkEmail(in.email), ruleUsername.check(in.username),
			ruleBio.check(in.bio), ruleImage.check(in.image))
		if e != nil {
			return respond(j, 422, e)
		}
		if in.password != nil {
			if len(*in.password) > 72 {
				return respond(j, 422, errPasswordLong)
			}
			return actHash
		}
	}
	d.stmt = stUserUpdate
	d.addInt(d.viewer)
	d.addOptText(d.in.email)
	d.addOptText(d.in.username)
	d.addBytes(d.newHash())
	d.addOptText(d.in.bio)
	d.addOptText(d.in.image)
	return actQuery
}

// planCreateArticle plans POST /api/articles: (author, title, description,
// body, tags).
func planCreateArticle(j *job) action {
	d := &j.db
	m, err := readWrapper(&j.req, "article")
	if err != nil {
		return respond(j, 422, errInvalidBody)
	}
	title, err1 := reqString(m, "title")
	description, err2 := reqString(m, "description")
	body, err3 := reqString(m, "body")
	if err1 != nil || err2 != nil || err3 != nil {
		return respond(j, 422, errArticleBody)
	}
	e := firstError(ruleTitle.check(&title), ruleDescription.check(&description), ruleArticleBody.check(&body))
	if e != nil {
		return respond(j, 422, e)
	}
	tags, e := readTags(m)
	if e != nil {
		return respond(j, 422, e)
	}
	d.stmt = stArticleCreate
	d.addInt(d.viewer)
	d.addText(title)
	d.addText(description)
	d.addText(body)
	d.args = appendTextArrayParam(d.args[:0], tags)
	d.addBytes(d.args)
	return actQuery
}

// readTags reads the optional tagList: an array of non-empty strings.
func readTags(m map[string]json.RawMessage) ([]string, []byte) {
	raw, ok := m["tagList"]
	if !ok || isNull(raw) {
		return nil, nil
	}
	var items []json.RawMessage
	if err := json.Unmarshal(raw, &items); err != nil {
		return nil, errTagList
	}
	if len(items) > maxTags {
		return nil, errTooManyTags
	}
	tags := make([]string, 0, len(items))
	for _, it := range items {
		var s string
		if isNull(it) || json.Unmarshal(it, &s) != nil || s == "" {
			return nil, errTagList
		}
		if e := ruleTag.check(&s); e != nil {
			return nil, e
		}
		tags = append(tags, s)
	}
	return tags, nil
}

// planUpdateArticle plans PUT /api/articles/:slug: (slug, title, description,
// body, viewer); a nil field keeps its value.
func planUpdateArticle(j *job) action {
	d := &j.db
	m, err := readWrapper(&j.req, "article")
	if err != nil {
		return respond(j, 422, errInvalidBody)
	}
	title, err1 := optString(m, "title", true)
	description, err2 := optString(m, "description", true)
	body, err3 := optString(m, "body", true)
	if err1 != nil || err2 != nil || err3 != nil {
		return respond(j, 422, errArticleFields)
	}
	e := firstError(ruleTitle.check(title), ruleDescription.check(description), ruleArticleBody.check(body))
	if e != nil {
		return respond(j, 422, e)
	}
	if !textOK(j.req.slug) {
		return respond(j, 404, errArticle404)
	}
	d.stmt = stArticleUpdate
	d.addText(j.req.slug)
	d.addOptText(title)
	d.addOptText(description)
	d.addOptText(body)
	d.addInt(d.viewer)
	return actQuery
}

// planDeleteArticle plans DELETE /api/articles/:slug: (slug, viewer).
func planDeleteArticle(j *job) action {
	d := &j.db
	if !textOK(j.req.slug) {
		return respond(j, 404, errArticle404)
	}
	d.stmt = stArticleDelete
	d.addText(j.req.slug)
	d.addInt(d.viewer)
	return actQuery
}

// planCreateComment plans POST /api/articles/:slug/comments: (slug, author, body).
func planCreateComment(j *job) action {
	d := &j.db
	m, err := readWrapper(&j.req, "comment")
	if err != nil {
		return respond(j, 422, errInvalidBody)
	}
	body, err := reqString(m, "body")
	if err != nil {
		return respond(j, 422, errCommentBody)
	}
	if e := ruleCommentBody.check(&body); e != nil {
		return respond(j, 422, e)
	}
	if !textOK(j.req.slug) {
		return respond(j, 404, errArticle404)
	}
	d.stmt = stCommentCreate
	d.addText(j.req.slug)
	d.addInt(d.viewer)
	d.addText(body)
	return actQuery
}

// planDeleteComment plans DELETE /api/articles/:slug/comments/:id: (id, slug, viewer).
func planDeleteComment(j *job) action {
	d := &j.db
	id, ok := parseUint(j.req.id)
	if !ok || !textOK(j.req.slug) {
		return respond(j, 404, errComment404)
	}
	d.stmt = stCommentDelete
	d.addInt(id)
	d.addText(j.req.slug)
	d.addInt(d.viewer)
	return actQuery
}

// ---------- step 3: finish ----------

// reply is a finish function's decision: the status, and either a fixed body
// (an error) or the JSON written into d.out. next is actDone except for login.
type reply struct {
	status int
	fixed  []byte
	next   action
}

func replyJSON(status int) reply               { return reply{status: status} }
func replyError(status int, body []byte) reply { return reply{status: status, fixed: body} }

// finish reads the statement's result through the route's finish function and
// sets the response. An error (from reading the rows) leaves the response to
// the caller.
func (w *worker) finish(j *job, rr *pgconn.ResultReader) (action, error) {
	d := &j.db
	d.out = d.out[:0]
	r := endpoints[d.route].finish(w, j, rr)
	if _, err := rr.Close(); err != nil {
		return actDone, err
	}
	switch {
	case r.fixed != nil:
		respond(j, r.status, r.fixed)
	case r.status == 204:
		respond(j, 204, nil)
	default:
		j.body(r.status)
	}
	return r.next, nil
}

// Result rows are read with rr.Values(): one []byte per column, binary format,
// nil for NULL. Column order is set by the statements in sql.go.

// finishTags: one row, (tags text[]).
func finishTags(_ *worker, j *job, rr *pgconn.ResultReader) reply {
	d := &j.db
	d.out = append(d.out, `{"tags":`...)
	if rr.NextRow() {
		d.out = appendTextArray(d.out, rr.Values()[0])
	} else {
		d.out = append(d.out, `[]`...)
	}
	d.out = append(d.out, '}')
	return replyJSON(200)
}

// finishCurrentUser: (username, email, bio, image); no row means the user is gone.
func finishCurrentUser(_ *worker, j *job, rr *pgconn.ResultReader) reply {
	d := &j.db
	if !rr.NextRow() {
		return replyError(401, errUnauthorized)
	}
	v := rr.Values()
	d.out = appendUser(d.out, v[0], v[1], v[2], v[3], d.token)
	return replyJSON(200)
}

// finishLogin: (id, username, email, bio, image, password_hash). The response
// is built now; the token is added once the password checks out.
func finishLogin(_ *worker, j *job, rr *pgconn.ResultReader) reply {
	d := &j.db
	if !rr.NextRow() {
		return replyError(401, errLogin)
	}
	v := rr.Values()
	d.userID = int8Value(v[0])
	d.out = appendUserFields(d.out, v[1], v[2], v[3], v[4])
	d.hashLen = copy(d.hash[:], v[5])
	if len(v[5]) > len(d.hash) {
		d.hashLen = 0 // not a bcrypt hash: verification fails closed
	}
	return reply{status: 200, next: actVerify}
}

// completeLogin finishes a login after bcrypt has checked the password.
func completeLogin(c *jwtCodec, j *job, passwordOK bool) {
	d := &j.db
	if !passwordOK {
		respond(j, 401, errLogin)
		return
	}
	d.out = c.appendToken(d.out, d.userID, time.Now())
	d.out = append(d.out, `"}}`...)
	j.body(200)
}

// finishRegister: (id, username, email, bio, image); no row means the username
// or email is taken (the insert uses ON CONFLICT DO NOTHING).
func finishRegister(w *worker, j *job, rr *pgconn.ResultReader) reply {
	d := &j.db
	if !rr.NextRow() {
		return replyError(422, errTaken)
	}
	v := rr.Values()
	d.out = appendUserFields(d.out, v[1], v[2], v[3], v[4])
	d.out = w.d.jwt.appendToken(d.out, int8Value(v[0]), time.Now())
	d.out = append(d.out, `"}}`...)
	return replyJSON(201)
}

// finishUpdateUser: (clash bool, username, email, bio, image). clash means the
// new username or email belongs to someone else, and nothing was updated.
func finishUpdateUser(_ *worker, j *job, rr *pgconn.ResultReader) reply {
	d := &j.db
	clash, found := false, false
	for rr.NextRow() {
		v := rr.Values()
		clash = len(v[0]) == 1 && v[0][0] != 0
		if v[1] != nil {
			d.out = appendUser(d.out[:0], v[1], v[2], v[3], v[4], d.token)
			found = true
		}
	}
	switch {
	case clash:
		return replyError(422, errTaken)
	case !found:
		return replyError(401, errUnauthorized)
	}
	return replyJSON(200)
}

// finishProfile: (username, bio, image, following).
func finishProfile(_ *worker, j *job, rr *pgconn.ResultReader) reply {
	d := &j.db
	if !rr.NextRow() {
		return replyError(404, errProfile404)
	}
	v := rr.Values()
	d.out = append(d.out, `{"profile":`...)
	d.out = appendProfile(d.out, v[0], v[1], v[2], v[3])
	d.out = append(d.out, '}')
	return replyJSON(200)
}

// finishFollow: (username, bio, image); following is known from the route.
func finishFollow(following bool) func(*worker, *job, *pgconn.ResultReader) reply {
	flag := sqlFalse
	if following {
		flag = sqlTrue
	}
	return func(_ *worker, j *job, rr *pgconn.ResultReader) reply {
		d := &j.db
		if !rr.NextRow() {
			return replyError(404, errProfile404)
		}
		v := rr.Values()
		d.out = append(d.out, `{"profile":`...)
		d.out = appendProfile(d.out, v[0], v[1], v[2], flag)
		d.out = append(d.out, '}')
		return replyJSON(200)
	}
}

// finishArticleList: (count, article columns without body). Every row carries
// the total count; a page past the end is one row with NULL article columns.
func finishArticleList(_ *worker, j *job, rr *pgconn.ResultReader) reply {
	d := &j.db
	d.out = append(d.out, `{"articles":[`...)
	var count []byte
	n := 0
	for rr.NextRow() {
		v := rr.Values()
		if count == nil {
			count = append(d.ints[5][:0], v[0]...) // rows are reused; keep a copy
		}
		if v[1] == nil {
			continue
		}
		if n > 0 {
			d.out = append(d.out, ',')
		}
		d.out = appendArticle(d.out, v, 1, false)
		n++
	}
	d.out = append(d.out, `],"articlesCount":`...)
	d.out = appendInt8(d.out, count)
	d.out = append(d.out, '}')
	return replyJSON(200)
}

// finishArticle: one full article. No row means the slug does not exist (for a
// create, which always returns a row, that would be a server error).
func finishArticle(status int) func(*worker, *job, *pgconn.ResultReader) reply {
	return func(_ *worker, j *job, rr *pgconn.ResultReader) reply {
		d := &j.db
		if !rr.NextRow() {
			if status == 201 {
				return replyError(500, errInternal)
			}
			return replyError(404, errArticle404)
		}
		d.out = append(d.out, `{"article":`...)
		d.out = appendArticle(d.out, rr.Values(), 0, true)
		d.out = append(d.out, '}')
		return replyJSON(status)
	}
}

// finishUpdateArticle: (author id, article columns). No row: no such slug. A
// different author: 403. NULL article columns: deleted meanwhile, so 404.
func finishUpdateArticle(_ *worker, j *job, rr *pgconn.ResultReader) reply {
	d := &j.db
	r := replyError(404, errArticle404)
	for rr.NextRow() {
		v := rr.Values()
		switch {
		case int8Value(v[0]) != d.viewer:
			r = replyError(403, errNotAuthor)
		case v[1] == nil:
		default:
			d.out = append(d.out[:0], `{"article":`...)
			d.out = appendArticle(d.out, v, 1, true)
			d.out = append(d.out, '}')
			r = replyJSON(200)
		}
	}
	return r
}

// finishDelete (article or comment): (author id). No row: not found. Only the
// author's own row was deleted.
func finishDelete(notFound []byte) func(*worker, *job, *pgconn.ResultReader) reply {
	return func(_ *worker, j *job, rr *pgconn.ResultReader) reply {
		r := replyError(404, notFound)
		for rr.NextRow() {
			if int8Value(rr.Values()[0]) != j.db.viewer {
				r = replyError(403, errNotAuthor)
			} else {
				r = replyJSON(204)
			}
		}
		return r
	}
}

// finishComments: (id, body, created, updated, username, bio, image, following).
// No row at all: no such article. An article without comments is one row with
// NULL comment columns.
func finishComments(_ *worker, j *job, rr *pgconn.ResultReader) reply {
	d := &j.db
	d.out = append(d.out, `{"comments":[`...)
	exists, n := false, 0
	for rr.NextRow() {
		exists = true
		v := rr.Values()
		if v[0] == nil {
			continue
		}
		if n > 0 {
			d.out = append(d.out, ',')
		}
		d.out = appendComment(d.out, v, v[7])
		n++
	}
	d.out = append(d.out, "]}"...)
	if !exists {
		return replyError(404, errArticle404)
	}
	return replyJSON(200)
}

// finishCreateComment: one comment row; no row means no such article.
func finishCreateComment(_ *worker, j *job, rr *pgconn.ResultReader) reply {
	d := &j.db
	if !rr.NextRow() {
		return replyError(404, errArticle404)
	}
	d.out = append(d.out, `{"comment":`...)
	d.out = appendComment(d.out, rr.Values(), nil)
	d.out = append(d.out, '}')
	return replyJSON(201)
}

// fail answers a request whose statement failed on its own (not as part of a group).
func (w *worker) fail(j *job, err error) {
	if (j.db.route == rRegister || j.db.route == rUpdateUser) && isUniqueViolation(err) {
		respond(j, 422, errTaken)
		return
	}
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		slog.Error("statement failed", "route", j.db.route.String(),
			"sqlstate", pgErr.Code, "err", pgErr.Message, "detail", pgErr.Detail)
	} else {
		slog.Error("statement failed", "route", j.db.route.String(), "err", err)
	}
	respond(j, 500, errInternal)
}

// ---------- JSON building blocks ----------

// Binary bool values for computed columns.
var sqlTrue, sqlFalse = []byte{1}, []byte{0}

// appendArticle writes one Article. Columns from base: id, slug, title,
// description, [body,] created_at, updated_at, tags, favorites_count,
// favorited, username, bio, image, following. List rows have no body.
func appendArticle(dst []byte, v [][]byte, base int, body bool) []byte {
	i := base + 1 // skip id
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
	created, updated, tags, count, favorited := v[i], v[i+1], v[i+2], v[i+3], v[i+4]
	dst = append(dst, `,"tagList":`...)
	dst = appendTextArray(dst, tags)
	dst = append(dst, `,"createdAt":`...)
	dst = appendTimestamp(dst, created)
	dst = append(dst, `,"updatedAt":`...)
	dst = appendTimestamp(dst, updated)
	dst = append(dst, `,"favorited":`...)
	dst = appendBool(dst, favorited)
	dst = append(dst, `,"favoritesCount":`...)
	dst = appendInt8(dst, count)
	dst = append(dst, `,"author":`...)
	dst = appendProfile(dst, v[i+5], v[i+6], v[i+7], v[i+8])
	return append(dst, '}')
}

// appendProfile writes one Profile; a NULL following is false.
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

// appendUserFields writes {"user":{...,"token":" and leaves the token and the
// closing "}} to the caller.
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

// appendUser writes a complete {"user":...} with the given token.
func appendUser(dst, username, email, bio, image, token []byte) []byte {
	dst = appendUserFields(dst, username, email, bio, image)
	dst = append(dst, token...)
	return append(dst, `"}}`...)
}

// appendComment writes one Comment: id, body, created, updated, then the
// author's username, bio and image.
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
