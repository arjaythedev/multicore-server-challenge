package conduit

import (
	"bytes"
	"math"

	"multicorelab/http"
)

// Body fields, by index in request.f.
const (
	fUsername = iota
	fEmail
	fPassword
	fBio
	fImage
	fTitle
	fDescription
	fBody
	nFields
)

var fieldNames = [nFields]string{"username", "email", "password", "bio", "image", "title", "description", "body"}

// request is a parsed, validated request whose values still point into the
// request's bytes, undecoded; fill decodes them into the Op.
type request struct {
	ep        Endpoint
	viewer    int64
	token     []byte
	param     segment // the slug or username
	idSeg     segment // the comment id
	commentID int64
	limit     int64
	offset    int64
	filter    Filter
	filterRaw []byte          // still query-escaped
	f         [nFields][]byte // quoted JSON strings; nil when absent or null
	tags      []byte          // the tagList array; nil when absent or null
	err       []byte          // the response body when parse rejects the request
}

type authMode uint8

const (
	authNone authMode = iota
	authOptional
	authRequired
)

var authOf = [...]authMode{
	Register: authNone, Login: authNone, Tags: authNone,
	GetProfile: authOptional, ListArticles: authOptional, GetArticle: authOptional, ListComments: authOptional,
	GetUser: authRequired, UpdateUser: authRequired, Follow: authRequired, Unfollow: authRequired,
	Feed: authRequired, CreateArticle: authRequired, UpdateArticle: authRequired, DeleteArticle: authRequired,
	Favorite: authRequired, Unfavorite: authRequired, CreateComment: authRequired, DeleteComment: authRequired,
}

// Error bodies, with the reference's messages.
func errBody(msg string) []byte { return []byte(`{"errors":{"body":["` + msg + `"]}}`) }

var (
	errBadRequest   = errBody("bad request")
	errNotFound     = errBody("not found")
	errNoComment    = errBody("comment not found")
	errUnauthorized = errBody("unauthorized")
	errBadBody      = errBody("invalid body")
	errPaging       = errBody("limit must be 1-100 and offset >= 0")
	errRegister     = errBody("username, email and password are required")
	errLogin        = errBody("email and password are required")
	errUserFields   = errBody("invalid user fields")
	errPasswordLong = errBody("password is too long")
	errArticle      = errBody("title, description and body are required")
	errTagList      = errBody("tagList must be an array of non-empty strings")
	errArticleEdit  = errBody("title, description and body must be non-empty strings")
	errComment      = errBody("body is required")
	errNUL          = errBody("text must not contain NUL")
)

// maxPassword is bcrypt's limit: a longer new password is a 422
// (REFERENCE-QUIRKS #6). Login has no such check: bcrypt compares only the
// first 72 bytes.
const maxPassword = 72

// parse routes and validates a request into r. It returns 0 if the request is
// to be deferred, or the status to answer with r.err.
func (f *Front) parse(method, path, query, auth, body []byte, r *request) int {
	// net/http rejects a target it cannot parse before routing.
	if hasCTL(path) || hasCTL(query) || !escapesOK(path) {
		r.err = errBadRequest
		return 400
	}
	if !r.route(method, path) {
		r.err = errNotFound
		return 404
	}

	switch authOf[r.ep] {
	case authRequired:
		if r.viewer, r.token = f.authorize(auth); r.viewer == 0 {
			r.err = errUnauthorized
			return 401
		}
	case authOptional:
		// An empty header is no header (Header.Get returns "").
		if len(auth) > 0 {
			if r.viewer, r.token = f.authorize(auth); r.viewer == 0 {
				r.err = errUnauthorized
				return 401
			}
		}
	}

	switch r.ep {
	case ListArticles, Feed:
		var q queryValues
		q.parse(query)
		if !r.paging(&q) {
			r.err = errPaging
			return 422
		}
		if r.ep == ListArticles {
			// The first non-empty filter in the order tag, author, favorited applies.
			switch {
			case len(q.vals[qTag]) > 0:
				r.filter, r.filterRaw = ByTag, q.vals[qTag]
			case len(q.vals[qAuthor]) > 0:
				r.filter, r.filterRaw = ByAuthor, q.vals[qAuthor]
			case len(q.vals[qFavorited]) > 0:
				r.filter, r.filterRaw = ByFavorited, q.vals[qFavorited]
			}
		}
	case DeleteComment:
		id, ok := r.idSeg.uint()
		if !ok {
			r.err = errNoComment
			return 404
		}
		r.commentID = id
	case Register, Login, UpdateUser:
		return r.userBody(body)
	case CreateArticle, UpdateArticle:
		return r.articleBody(body)
	case CreateComment:
		return r.commentBody(body)
	}
	return 0
}

func (r *request) commentBody(body []byte) int {
	if !r.fields(body, "comment", wantComment) {
		r.err = errBadBody
		return 422
	}
	if !required(r.f[fBody]) {
		r.err = errComment
		return 422
	}
	return r.noNUL()
}

// authorize checks an Authorization header and returns the viewer, 0 if the
// header is not a valid "Token <jwt>", and the token.
func (f *Front) authorize(h []byte) (int64, []byte) {
	tok, ok := bytes.CutPrefix(h, []byte("Token "))
	if !ok {
		return 0, nil
	}
	return f.tokens.verify(tok), tok
}

func (r *request) paging(q *queryValues) bool {
	r.limit, r.offset = 20, 0
	if q.has[qLimit] {
		n, ok := queryUint(q.vals[qLimit])
		if !ok || n < 1 || n > 100 {
			return false
		}
		r.limit = n
	}
	if q.has[qOffset] {
		n, ok := queryUint(q.vals[qOffset])
		if !ok {
			return false
		}
		r.offset = n
	}
	return true
}

// The body fields each endpoint reads, as bits of fields' want.
const (
	wantTags     = 1 << nFields
	wantRegister = 1<<fUsername | 1<<fEmail | 1<<fPassword
	wantLogin    = 1<<fEmail | 1<<fPassword
	wantUser     = wantRegister | 1<<fBio | 1<<fImage
	wantArticle  = 1<<fTitle | 1<<fDescription | 1<<fBody
	wantComment  = 1 << fBody
)

// fields reads the wanted fields of the object under key, in a body
// {"<key>": {...}}, into r.f (and r.tags), keeping the last of each. It
// reports whether the body has that shape.
func (r *request) fields(body []byte, key string, want int) bool {
	if !validJSON(body) {
		return false
	}
	top, ok := objectOf(topValue(body))
	if !ok {
		return false
	}
	var inner []byte
	for {
		name, val, more := top.next()
		if !more {
			break
		}
		if nameIs(name, key) {
			inner = val
		}
	}
	m, ok := objectOf(inner)
	if !ok {
		return false // absent, null or not an object
	}
	for {
		name, val, more := m.next()
		if !more {
			break
		}
		if want&wantTags != 0 && nameIs(name, "tagList") {
			r.tags = val
			continue
		}
		for i := range fieldNames {
			if want&(1<<i) != 0 && nameIs(name, fieldNames[i]) {
				r.f[i] = val
				break
			}
		}
	}
	// Absent and null are the same to every endpoint.
	for i, v := range r.f {
		if v != nil && isNull(v) {
			r.f[i] = nil
		}
	}
	if r.tags != nil && isNull(r.tags) {
		r.tags = nil
	}
	return true
}

// required: a non-empty string.
func required(v []byte) bool { return v != nil && isStr(v) && !emptyStr(v) }

// optional: absent, null, or a string, non-empty if nonEmpty.
func optional(v []byte, nonEmpty bool) bool {
	return v == nil || isStr(v) && !(nonEmpty && emptyStr(v))
}

func (r *request) userBody(body []byte) int {
	want := wantUser
	switch r.ep {
	case Register:
		want = wantRegister
	case Login:
		want = wantLogin
	}
	if !r.fields(body, "user", want) {
		r.err = errBadBody
		return 422
	}
	f := &r.f
	switch r.ep {
	case Register:
		if !required(f[fUsername]) || !required(f[fEmail]) || !required(f[fPassword]) {
			r.err = errRegister
			return 422
		}
	case Login:
		if !required(f[fEmail]) || !required(f[fPassword]) {
			r.err = errLogin
			return 422
		}
	case UpdateUser:
		if !optional(f[fEmail], true) || !optional(f[fUsername], true) || !optional(f[fPassword], true) ||
			!optional(f[fBio], false) || !optional(f[fImage], false) {
			r.err = errUserFields
			return 422
		}
	}
	if r.ep != Login && f[fPassword] != nil && unquotedLen(f[fPassword]) > maxPassword {
		r.err = errPasswordLong
		return 422
	}
	return r.noNUL()
}

func (r *request) articleBody(body []byte) int {
	want := wantArticle
	if r.ep == CreateArticle {
		want |= wantTags
	}
	if !r.fields(body, "article", want) {
		r.err = errBadBody
		return 422
	}
	f := &r.f
	if r.ep == UpdateArticle {
		if !optional(f[fTitle], true) || !optional(f[fDescription], true) || !optional(f[fBody], true) {
			r.err = errArticleEdit
			return 422
		}
		return r.noNUL()
	}
	if !required(f[fTitle]) || !required(f[fDescription]) || !required(f[fBody]) {
		r.err = errArticle
		return 422
	}
	if r.tags != nil {
		a, ok := arrayOf(r.tags)
		if !ok {
			r.err = errTagList
			return 422
		}
		for {
			e, more := a.next()
			if !more {
				break
			}
			if !required(e) {
				r.err = errTagList
				return 422
			}
			if hasNUL(e) {
				r.err = errNUL
				return 422
			}
		}
	}
	return r.noNUL()
}

// noNUL rejects a body text with a NUL, which Postgres refuses (the
// reference's 500): REFERENCE-QUIRKS #7 has it rejected before any write.
func (r *request) noNUL() int {
	for _, v := range r.f {
		if v != nil && hasNUL(v) {
			r.err = errNUL
			return 422
		}
	}
	return 0
}

// store is where fill copies values: the Op.
type store interface {
	Keep(b []byte) []byte
	Alloc(n int) []byte
}

var _ store = (*http.Op)(nil)

// fill decodes r into c, copying every value into op.
func (r *request) fill(c *Call, op store) {
	*c = Call{Endpoint: r.ep, Viewer: r.viewer, TagList: c.TagList[:0]}
	switch r.ep {
	case GetUser, UpdateUser:
		c.Token = op.Keep(r.token)
	case GetProfile, Follow, Unfollow:
		c.Username = r.param.decode(op)
	case GetArticle, UpdateArticle, DeleteArticle, Favorite, Unfavorite, ListComments, CreateComment, DeleteComment:
		c.Slug = r.param.decode(op)
	}
	c.CommentID = r.commentID
	c.Limit, c.Offset, c.Filter = r.limit, r.offset, r.filter
	if r.filter != NoFilter {
		c.FilterValue = queryDecode(op.Alloc(queryDecodedLen(r.filterRaw))[:0], r.filterRaw)
	}
	opts := [nFields]*Opt{&c.NewUsername, &c.Email, &c.Password, &c.Bio, &c.Image, &c.Title, &c.Description, &c.Body}
	for i, v := range r.f {
		if v != nil {
			*opts[i] = Opt{keepString(op, v), true}
		}
	}
	if r.tags != nil {
		a, _ := arrayOf(r.tags)
		for {
			e, more := a.next()
			if !more {
				break
			}
			c.TagList = append(c.TagList, keepString(op, e))
		}
	}
}

// keepString copies the quoted JSON string q's value into op.
func keepString(op store, q []byte) []byte {
	if verbatim(q) {
		return op.Keep(q[1 : len(q)-1])
	}
	return appendUnquote(op.Alloc(unquotedLen(q))[:0], q)
}

// queryUint parses a query value as the reference's parseUint does after
// unescaping it: ASCII digits only, within int64.
func queryUint(v []byte) (int64, bool) { return digitsOf(v, true) }

// digitsOf parses a percent-encoded string of ASCII digits within int64,
// decoding as it goes ('+' is a space in a query, so never a digit).
func digitsOf(v []byte, query bool) (int64, bool) {
	if len(v) == 0 {
		return 0, false
	}
	var n int64
	for i := 0; i < len(v); i++ {
		c := v[i]
		if c == '%' {
			c = unhex(v[i+1])<<4 | unhex(v[i+2])
			i += 2
		} else if c == '+' && query {
			c = ' '
		}
		if c < '0' || c > '9' {
			return 0, false
		}
		d := int64(c - '0')
		if n > (math.MaxInt64-d)/10 {
			return 0, false
		}
		n = n*10 + d
	}
	return n, true
}
