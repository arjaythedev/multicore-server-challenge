package server

import (
	"errors"
	"net/http"

	"github.com/jackc/pgx/v5"
	"golang.org/x/crypto/bcrypt"
)

const bcryptCost = 10

type userJSON struct {
	Email    string  `json:"email"`
	Token    string  `json:"token"`
	Username string  `json:"username"`
	Bio      *string `json:"bio"`
	Image    *string `json:"image"`
}

type profileJSON struct {
	Username  string  `json:"username"`
	Bio       *string `json:"bio"`
	Image     *string `json:"image"`
	Following bool    `json:"following"`
}

func writeUser(w http.ResponseWriter, status int, u userJSON) {
	writeJSON(w, status, struct {
		User userJSON `json:"user"`
	}{u})
}

func writeProfile(w http.ResponseWriter, p profileJSON) {
	writeJSON(w, http.StatusOK, struct {
		Profile profileJSON `json:"profile"`
	}{p})
}

// POST /api/users
func (a *app) register(w http.ResponseWriter, r *http.Request) {
	m, err := readWrapper(r, "user")
	if err != nil {
		writeError(w, http.StatusUnprocessableEntity, "invalid body")
		return
	}
	username, err1 := reqString(m, "username")
	email, err2 := reqString(m, "email")
	password, err3 := reqString(m, "password")
	if err1 != nil || err2 != nil || err3 != nil {
		writeError(w, http.StatusUnprocessableEntity, "username, email and password are required")
		return
	}
	hash, err := a.hashPassword(r.Context(), password)
	if err != nil {
		if r.Context().Err() != nil {
			return
		}
		if errors.Is(err, bcrypt.ErrPasswordTooLong) {
			writeError(w, http.StatusUnprocessableEntity, "password is too long")
		} else {
			internalError(w, err)
		}
		return
	}
	var id int64
	var u userJSON
	err = a.pool.QueryRow(r.Context(), `INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)
RETURNING id, username, email, bio, image`, username, email, hash).Scan(&id, &u.Username, &u.Email, &u.Bio, &u.Image)
	if isUniqueViolation(err) {
		writeError(w, http.StatusUnprocessableEntity, "username or email is already taken")
		return
	}
	if err != nil {
		internalError(w, err)
		return
	}
	u.Token = a.issueToken(id)
	writeUser(w, http.StatusCreated, u)
}

// POST /api/users/login
func (a *app) login(w http.ResponseWriter, r *http.Request) {
	m, err := readWrapper(r, "user")
	if err != nil {
		writeError(w, http.StatusUnprocessableEntity, "invalid body")
		return
	}
	email, err1 := reqString(m, "email")
	password, err2 := reqString(m, "password")
	if err1 != nil || err2 != nil {
		writeError(w, http.StatusUnprocessableEntity, "email and password are required")
		return
	}
	var id int64
	var u userJSON
	var hash string
	err = a.pool.QueryRow(r.Context(), `SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1`,
		email).Scan(&id, &u.Username, &u.Email, &u.Bio, &u.Image, &hash)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusUnauthorized, "invalid email or password")
		return
	}
	if err != nil {
		internalError(w, err)
		return
	}
	if a.checkPassword(r.Context(), hash, password) != nil {
		if r.Context().Err() != nil {
			return
		}
		writeError(w, http.StatusUnauthorized, "invalid email or password")
		return
	}
	u.Token = a.issueToken(id)
	writeUser(w, http.StatusOK, u)
}

// GET /api/user
func (a *app) currentUser(w http.ResponseWriter, r *http.Request, viewer int64, token string) {
	if a.reads != nil && userReadBatching {
		call := &queuedRead{ctx: r.Context(), kind: readUser, viewer: viewer,
			filter: token, done: make(chan struct{})}
		a.serveReadCall(w, r, call)
		return
	}
	var id int64
	u := userJSON{Token: token}
	err := a.pool.QueryRow(r.Context(), `SELECT id, username, email, bio, image FROM users WHERE id = $1`,
		viewer).Scan(&id, &u.Username, &u.Email, &u.Bio, &u.Image)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if err != nil {
		internalError(w, err)
		return
	}
	writeUser(w, http.StatusOK, u)
}

// PUT /api/user
func (a *app) updateUser(w http.ResponseWriter, r *http.Request, viewer int64, token string) {
	m, err := readWrapper(r, "user")
	if err != nil {
		writeError(w, http.StatusUnprocessableEntity, "invalid body")
		return
	}
	email, err1 := optString(m, "email", true)
	username, err2 := optString(m, "username", true)
	password, err3 := optString(m, "password", true)
	bio, err4 := optString(m, "bio", false)
	image, err5 := optString(m, "image", false)
	if err1 != nil || err2 != nil || err3 != nil || err4 != nil || err5 != nil {
		writeError(w, http.StatusUnprocessableEntity, "invalid user fields")
		return
	}
	var hash *string
	if password != nil {
		h, err := a.hashPassword(r.Context(), *password)
		if err != nil {
			if r.Context().Err() != nil {
				return
			}
			if errors.Is(err, bcrypt.ErrPasswordTooLong) {
				writeError(w, http.StatusUnprocessableEntity, "password is too long")
			} else {
				internalError(w, err)
			}
			return
		}
		hash = &h
	}
	var id int64
	u := userJSON{Token: token}
	err = a.pool.QueryRow(r.Context(), `UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
                 password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
 WHERE id = $1
RETURNING id, username, email, bio, image`, viewer, email, username, hash, bio, image).Scan(&id, &u.Username, &u.Email, &u.Bio, &u.Image)
	if isUniqueViolation(err) {
		writeError(w, http.StatusUnprocessableEntity, "username or email is already taken")
		return
	}
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if err != nil {
		internalError(w, err)
		return
	}
	writeUser(w, http.StatusOK, u)
}

// GET /api/profiles/{username}
const profileSelect = `SELECT u.id, u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following
  FROM users u WHERE u.username = $2`

func (a *app) getProfile(w http.ResponseWriter, r *http.Request, viewer int64, _ string) {
	if a.reads != nil && profileReadBatching {
		call := &queuedRead{ctx: r.Context(), kind: readProfile, viewer: viewer,
			filter: r.PathValue("username"), done: make(chan struct{})}
		a.serveReadCall(w, r, call)
		return
	}
	var id int64
	var p profileJSON
	err := a.pool.QueryRow(r.Context(), profileSelect, viewer, r.PathValue("username")).Scan(&id, &p.Username, &p.Bio, &p.Image, &p.Following)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "profile not found")
		return
	}
	if err != nil {
		internalError(w, err)
		return
	}
	writeProfile(w, p)
}

// POST and DELETE /api/profiles/{username}/follow
func (a *app) follow(follow bool) authed {
	return func(w http.ResponseWriter, r *http.Request, viewer int64, _ string) {
		var id int64
		var p profileJSON
		err := a.pool.QueryRow(r.Context(), `SELECT id, username, bio, image FROM users WHERE username = $1`,
			r.PathValue("username")).Scan(&id, &p.Username, &p.Bio, &p.Image)
		if err == nil {
			if follow {
				err = a.execWrite(r.Context(), `INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`, viewer, id)
			} else {
				err = a.execWrite(r.Context(), `DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2`, viewer, id)
			}
		}
		if errors.Is(err, pgx.ErrNoRows) {
			writeError(w, http.StatusNotFound, "profile not found")
			return
		}
		if err != nil {
			internalError(w, err)
			return
		}
		p.Following = follow
		writeProfile(w, p)
	}
}

// GET /api/tags
func (a *app) tags(w http.ResponseWriter, r *http.Request) {
	if a.reads != nil {
		a.serveQueuedRead(w, r, readTags, 0)
		return
	}
	rows, _ := a.pool.Query(r.Context(), `SELECT name FROM tags ORDER BY name`)
	names, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		internalError(w, err)
		return
	}
	if names == nil {
		names = []string{}
	}
	writeJSON(w, http.StatusOK, struct {
		Tags []string `json:"tags"`
	}{names})
}
