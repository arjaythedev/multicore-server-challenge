// Package conduit is the Conduit API's front: it runs on the event loop and
// does all the per-request work that needs no database. For each request it
// routes, checks the token, and parses and validates the query and body;
// then it either answers at once (401, 404, 422) or fills a Call and defers
// the request. The database side reads the Call by the Op's ID.
//
// Every rule follows the reference app (the challenge's Go example: net/http's
// ServeMux, url.ParseQuery, encoding/json and golang-jwt), including the
// behaviors SPEC.md leaves unstated, so that a request gets the same status as
// there. The checks come in the reference's order: route, then token, then
// query or body; existence and ownership (404, 403) are the database side's.
package conduit

import (
	"time"

	"multicorelab/http"
	"multicorelab/http/jsonw"
)

// Endpoint names a route.
type Endpoint uint8

const (
	_ Endpoint = iota
	Register
	Login
	GetUser
	UpdateUser
	GetProfile
	Follow
	Unfollow
	ListArticles
	Feed
	CreateArticle
	GetArticle
	UpdateArticle
	DeleteArticle
	Favorite
	Unfavorite
	ListComments
	CreateComment
	DeleteComment
	Tags
)

var endpointNames = [...]string{"", "Register", "Login", "GetUser", "UpdateUser", "GetProfile",
	"Follow", "Unfollow", "ListArticles", "Feed", "CreateArticle", "GetArticle", "UpdateArticle",
	"DeleteArticle", "Favorite", "Unfavorite", "ListComments", "CreateComment", "DeleteComment", "Tags"}

func (e Endpoint) String() string {
	if int(e) < len(endpointNames) {
		return endpointNames[e]
	}
	return "Endpoint(?)"
}

// Filter is the one filter a ListArticles call applies.
type Filter uint8

const (
	NoFilter Filter = iota
	ByTag
	ByAuthor
	ByFavorited
)

// Opt is a request body string. Valid is false when the field was absent or
// null, which PUT treats as "unchanged".
type Opt struct {
	V     []byte
	Valid bool
}

// Call is a deferred request, validated, with every value decoded. Its byte
// slices belong to the Op and are valid until Op.Done.
type Call struct {
	Endpoint Endpoint
	// Viewer is the token's user id, 0 when anonymous.
	Viewer int64
	// Token is the token presented, for GetUser and UpdateUser to echo.
	Token []byte

	// Path parameters, decoded.
	Slug      []byte // articles/:slug
	Username  []byte // profiles/:username
	CommentID int64  // comments/:id, an int64 >= 0

	// ListArticles and Feed.
	Limit, Offset int64
	Filter        Filter
	FilterValue   []byte

	// Body fields, decoded. Register has NewUsername, Email and Password;
	// Login Email and Password; UpdateUser any of the five. CreateArticle has
	// Title, Description and Body, UpdateArticle any of them; CreateComment
	// has Body. Required fields are Valid and non-empty; so are UpdateUser's
	// and UpdateArticle's when Valid, except Bio and Image, which may be "".
	Email, Password, Bio, Image, NewUsername Opt
	Title, Description, Body                 Opt
	// TagList is CreateArticle's tagList: non-empty strings, in the order sent,
	// duplicates kept. Empty when absent, null or [].
	TagList [][]byte
}

// Front routes and validates requests and keeps the Calls of the deferred ones.
type Front struct {
	calls  []Call
	tokens *tokens
}

// New returns a Front for a server with ops Ops (http.Server.Ops) and the
// JWT secret. Its Handle is the server's Handler:
//
//	var f *conduit.Front
//	srv, _ := http.New(http.Config{Handler: func(q *http.Request, r *http.Response) { f.Handle(q, r) }, ...})
//	f = conduit.New(srv.Ops(), secret)
func New(ops int, secret []byte) *Front {
	return &Front{calls: make([]Call, ops), tokens: newTokens(secret)}
}

// Call returns the Call of a deferred request.
func (f *Front) Call(op *http.Op) *Call { return &f.calls[op.ID()] }

// Sign appends a new token for user id to dst: HS256, claims sub (decimal),
// iat (now) and exp (now + 30 days), as the reference issues them.
func (f *Front) Sign(dst []byte, id int64) []byte { return f.tokens.sign(dst, id, time.Now()) }

// Handle is the http.Handler.
func (f *Front) Handle(req *http.Request, resp *http.Response) {
	var r request
	if st := f.parse(req.Method, req.Path, req.Query, req.Auth, req.Body, &r); st != 0 {
		resp.Status = st
		resp.Body = r.err
		return
	}
	op := req.Defer()
	if op == nil {
		return // every Op is in flight: the server calls Handle again later
	}
	r.fill(&f.calls[op.ID()], op)
}

// Fail sets op's status and replaces its body with the reference's error
// shape, {"errors":{"body":[msg]}}. It does not call Done.
func Fail(op *http.Op, status int, msg string) {
	op.Status = status
	op.Resp = append(jsonw.String(append(op.Resp[:0], `{"errors":{"body":[`...), msg), "]}}"...)
}
