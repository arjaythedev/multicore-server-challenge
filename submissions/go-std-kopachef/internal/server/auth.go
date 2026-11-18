package server

import "net/http"

func (a *app) issueToken(id int64) string { return a.tokens.IssueToken(id) }

// auth inspects the request's Authorization header.
func (a *app) auth(r *http.Request) (id int64, token string, present bool) {
	return a.authHeader(r.Header.Get("Authorization"))
}

func (a *app) authHeader(header string) (id int64, token string, present bool) {
	return a.tokens.AuthHeader(header)
}

type authed func(w http.ResponseWriter, r *http.Request, viewer int64, token string)

// required: a missing or invalid token gives 401.
func (a *app) required(next authed) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, token, _ := a.auth(r)
		if id == 0 {
			writeError(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		next(w, r, id, token)
	}
}

// optional: no header means viewer 0; a header that is present but invalid gives 401.
func (a *app) optional(next authed) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, token, present := a.auth(r)
		if present && id == 0 {
			writeError(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		next(w, r, id, token)
	}
}
