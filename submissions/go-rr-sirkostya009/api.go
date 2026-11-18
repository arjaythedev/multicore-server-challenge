package main

import (
	"cmp"
	"errors"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"conduit/bcrypt4"
)

//go:generate go tool rr -nopathvalue $GOFILE

var (
	errUnauthorized = errors.New("unauthorized")
	errInvalid      = errors.New("invalid query")
)

var jwt *signer

//rr:api onerror=@handleError on400=@badRequest on404=@notFound
type Api struct {
	PublicApi
	AuthApi
}

// PublicApi serves the endpoints where a token is optional.
type PublicApi struct{ s *store }

// AuthApi serves the endpoints that need a token.
//
//rr:pre @requireAuth
type AuthApi struct{ s *store }

func requireAuth(w http.ResponseWriter, auth /* rr:header Authorization */ string) bool {
	if auth == "" {
		writeError(w, http.StatusUnauthorized, "missing token")
		return false
	}
	return true
}

// viewerID verifies an Authorization header. An absent header never gets here and binds as 0.
func viewerID(h string) (int64, error) {
	tok, ok := strings.CutPrefix(h, "Token ")
	if !ok {
		return 0, errUnauthorized
	}
	id, ok := jwt.verify(tok)
	if !ok {
		return 0, errUnauthorized
	}
	return id, nil
}

func handleError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, errNotFound):
		writeError(w, http.StatusNotFound, "not found")
	case errors.Is(err, errForbidden):
		writeError(w, http.StatusForbidden, "forbidden")
	case errors.Is(err, errUnauthorized):
		writeError(w, http.StatusUnauthorized, "unauthorized")
	case errors.Is(err, errTaken):
		writeError(w, http.StatusUnprocessableEntity, "has already been taken")
	case errors.Is(err, errInvalid):
		writeError(w, http.StatusUnprocessableEntity, "invalid")
	case errors.Is(err, bcrypt4.ErrBusy):
		writeError(w, http.StatusServiceUnavailable, "busy")
	default:
		log.Print(err)
		writeError(w, http.StatusInternalServerError, "internal error")
	}
}

func badRequest(w http.ResponseWriter, err error) {
	if errors.Is(err, errUnauthorized) {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	msg := "invalid body"
	if err != nil {
		msg = err.Error()
	}
	writeError(w, http.StatusUnprocessableEntity, msg)
}

func notFound(w http.ResponseWriter) {
	writeError(w, http.StatusNotFound, "not found")
}

func writeError(w http.ResponseWriter, code int, msg string) {
	var e errorBody
	e.Errors.Body[0] = msg
	var buf [256]byte
	b, _ := e.AppendJSON(buf[:0])
	w.Header()["Content-Type"] = jsonCT
	w.WriteHeader(code)
	_, _ = w.Write(b)
}

var jsonCT = []string{"application/json"}

func token(h string) string {
	return strings.TrimPrefix(h, "Token ")
}

func userResponse(u userRow, tok string) userEnvelope {
	return userEnvelope{User: User{Email: u.email, Token: tok, Username: u.username, Bio: u.bio, Image: u.image}}
}

func unescape(s string) string {
	if strings.IndexByte(s, '%') < 0 {
		return s
	}
	if u, err := url.PathUnescape(s); err == nil {
		return u
	}
	return s
}

//rr:route POST /api/users
func (a *PublicApi) Register(w http.ResponseWriter, body registerBody) (userEnvelope, error) {
	f := &body.User
	hash, err := hashPassword(f.Password)
	if err != nil {
		return userEnvelope{}, err
	}
	u, err := a.s.register(f.Username, f.Email, hash)
	if err != nil {
		return userEnvelope{}, err
	}
	w.WriteHeader(http.StatusCreated)
	return userResponse(u, jwt.sign(u.id)), nil
}

//rr:route POST /api/users/login
func (a *PublicApi) Login(body loginBody) (userEnvelope, error) {
	u, err := a.s.userByEmail.do(body.User.Email)
	if err != nil {
		return userEnvelope{}, err
	}
	if !u.ok {
		return userEnvelope{}, errUnauthorized
	}
	if ok, err := checkPassword(u.hash, body.User.Password); err != nil || !ok {
		return userEnvelope{}, cmp.Or(err, errUnauthorized)
	}
	return userResponse(u, jwt.sign(u.id)), nil
}

//rr:route GET /api/user
func (a *AuthApi) CurrentUser(viewer /* rr:header Authorization=@viewerID */ int64, auth /* rr:header Authorization */ string) (userEnvelope, error) {
	u, err := a.s.userByID.do(viewer)
	if err != nil {
		return userEnvelope{}, err
	}
	if !u.ok {
		return userEnvelope{}, errUnauthorized
	}
	return userResponse(u, token(auth)), nil
}

//rr:route PUT /api/user
func (a *AuthApi) UpdateUser(viewer /* rr:header Authorization=@viewerID */ int64, auth /* rr:header Authorization */ string, body updateUserBody) (userEnvelope, error) {
	f := &body.User
	var hash *string
	if f.Password != nil {
		h, err := hashPassword(*f.Password)
		if err != nil {
			return userEnvelope{}, err
		}
		hash = &h
	}
	u, err := a.s.updateUser(viewer, f, hash)
	if errors.Is(err, errNotFound) {
		return userEnvelope{}, errUnauthorized
	}
	if err != nil {
		return userEnvelope{}, err
	}
	return userResponse(u, token(auth)), nil
}

//rr:route GET /api/profiles/{username}
func (a *PublicApi) Profile(viewer /* rr:header Authorization=@viewerID */ int64, username string) (profileEnvelope, error) {
	p, err := a.s.profile.do(profileQuery{viewer: viewer, username: unescape(username)})
	if err != nil {
		return profileEnvelope{}, err
	}
	if !p.ok {
		return profileEnvelope{}, errNotFound
	}
	return profileEnvelope{Profile: p.v}, nil
}

//rr:route POST /api/profiles/{username}/follow
func (a *AuthApi) Follow(viewer /* rr:header Authorization=@viewerID */ int64, username string) (profileEnvelope, error) {
	p, err := a.s.follow(viewer, unescape(username), true)
	return profileEnvelope{Profile: p}, err
}

//rr:route DELETE /api/profiles/{username}/follow
func (a *AuthApi) Unfollow(viewer /* rr:header Authorization=@viewerID */ int64, username string) (profileEnvelope, error) {
	p, err := a.s.follow(viewer, unescape(username), false)
	return profileEnvelope{Profile: p}, err
}

//rr:route GET /api/articles
func (a *PublicApi) ListArticles(viewer /* rr:header Authorization=@viewerID */ int64, r *http.Request) (articleList, error) {
	q, err := parseListQuery(r.URL.RawQuery)
	if err != nil {
		return articleList{}, err
	}
	q.list.viewer = viewer
	switch {
	case q.tag != "":
		q.list.key = q.tag
		return a.s.list(readTag, q.list)
	case q.author != "":
		q.list.key = q.author
		return a.s.list(readAuthor, q.list)
	case q.favorited != "":
		q.list.key = q.favorited
		return a.s.list(readFavorited, q.list)
	}
	return a.s.list(readAll, q.list)
}

//rr:route GET /api/articles/feed
func (a *AuthApi) Feed(viewer /* rr:header Authorization=@viewerID */ int64, r *http.Request) (articleList, error) {
	q, err := parseListQuery(r.URL.RawQuery)
	if err != nil {
		return articleList{}, err
	}
	q.list.viewer = viewer
	return a.s.list(readFeed, q.list)
}

//rr:route POST /api/articles
func (a *AuthApi) CreateArticle(w http.ResponseWriter, viewer /* rr:header Authorization=@viewerID */ int64, body createArticleBody) (articleEnvelope, error) {
	art, err := a.s.createArticle(viewer, &body.Article)
	if err != nil {
		return articleEnvelope{}, err
	}
	w.WriteHeader(http.StatusCreated)
	return articleEnvelope{Article: art}, nil
}

//rr:route GET /api/articles/{slug}
func (a *PublicApi) Article(viewer /* rr:header Authorization=@viewerID */ int64, slug string) (articleEnvelope, error) {
	art, err := a.s.article(viewer, slug)
	if err != nil {
		return articleEnvelope{}, err
	}
	if !art.ok {
		return articleEnvelope{}, errNotFound
	}
	return articleEnvelope{Article: art.v}, nil
}

//rr:route PUT /api/articles/{slug}
func (a *AuthApi) UpdateArticle(viewer /* rr:header Authorization=@viewerID */ int64, slug string, body updateArticleBody) (articleEnvelope, error) {
	art, err := a.s.updateArticle(viewer, slug, &body.Article)
	return articleEnvelope{Article: art}, err
}

//rr:route DELETE /api/articles/{slug}
func (a *AuthApi) DeleteArticle(w http.ResponseWriter, viewer /* rr:header Authorization=@viewerID */ int64, slug string) error {
	if err := a.s.deleteArticle(viewer, slug); err != nil {
		return err
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}

//rr:route POST /api/articles/{slug}/favorite
func (a *AuthApi) Favorite(viewer /* rr:header Authorization=@viewerID */ int64, slug string) (articleEnvelope, error) {
	art, err := a.s.favorite(viewer, slug, true)
	return articleEnvelope{Article: art}, err
}

//rr:route DELETE /api/articles/{slug}/favorite
func (a *AuthApi) Unfavorite(viewer /* rr:header Authorization=@viewerID */ int64, slug string) (articleEnvelope, error) {
	art, err := a.s.favorite(viewer, slug, false)
	return articleEnvelope{Article: art}, err
}

//rr:route GET /api/articles/{slug}/comments
func (a *PublicApi) Comments(viewer /* rr:header Authorization=@viewerID */ int64, slug string) (commentList, error) {
	cs, err := a.s.comments(viewer, slug)
	if err != nil {
		return commentList{}, err
	}
	if !cs.ok {
		return commentList{}, errNotFound
	}
	return commentList{Comments: cs.v}, nil
}

//rr:route POST /api/articles/{slug}/comments
func (a *AuthApi) CreateComment(w http.ResponseWriter, viewer /* rr:header Authorization=@viewerID */ int64, slug string, body createCommentBody) (commentEnvelope, error) {
	c, err := a.s.createComment(viewer, slug, body.Comment.Body)
	if err != nil {
		return commentEnvelope{}, err
	}
	w.WriteHeader(http.StatusCreated)
	return commentEnvelope{Comment: c}, nil
}

//rr:route DELETE /api/articles/{slug}/comments/{id}
func (a *AuthApi) DeleteComment(w http.ResponseWriter, viewer /* rr:header Authorization=@viewerID */ int64, slug string, id int) error {
	if err := a.s.deleteComment(viewer, slug, int64(id)); err != nil {
		return err
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}

//rr:route GET /api/tags
func (a *PublicApi) Tags() (tagList, error) {
	tags, err := a.s.tags.do(struct{}{})
	return tagList{Tags: tags}, err
}

type listParams struct {
	list                   listQuery
	tag, author, favorited string
}

// maxOffset keeps limit + offset inside bigint. No table comes near it, so the page is empty either way.
const maxOffset = 1 << 53

// parseListQuery reads limit, offset and the filters. The first value of a repeated key wins, as with url.Values.Get.
func parseListQuery(raw string) (listParams, error) {
	p := listParams{list: listQuery{limit: 20}}
	var seen uint8
	for raw != "" {
		var kv string
		kv, raw, _ = strings.Cut(raw, "&")
		k, v, _ := strings.Cut(kv, "=")
		var bit uint8
		switch k {
		case "limit":
			bit = 1
		case "offset":
			bit = 2
		case "tag":
			bit = 4
		case "author":
			bit = 8
		case "favorited":
			bit = 16
		default:
			continue
		}
		if seen&bit != 0 {
			continue
		}
		seen |= bit
		switch bit {
		case 1:
			n, ok := digits(v)
			if !ok || n < 1 || n > 100 {
				return p, errInvalid
			}
			p.list.limit = n
		case 2:
			n, ok := digits(v)
			if !ok {
				return p, errInvalid
			}
			p.list.offset = min(n, maxOffset)
		case 4:
			p.tag = queryUnescape(v)
		case 8:
			p.author = queryUnescape(v)
		case 16:
			p.favorited = queryUnescape(v)
		}
	}
	return p, nil
}

func digits(s string) (int64, bool) {
	if s == "" {
		return 0, false
	}
	for i := range len(s) {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
	}
	n, err := strconv.ParseInt(s, 10, 64)
	return n, err == nil
}

func queryUnescape(s string) string {
	if strings.IndexByte(s, '%') < 0 && strings.IndexByte(s, '+') < 0 {
		return s
	}
	if u, err := url.QueryUnescape(s); err == nil {
		return u
	}
	return s
}
