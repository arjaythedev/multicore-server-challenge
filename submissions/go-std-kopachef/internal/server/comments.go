package server

import (
	"errors"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
)

type commentJSON struct {
	ID        int64       `json:"id"`
	CreatedAt timestamp   `json:"createdAt"`
	UpdatedAt timestamp   `json:"updatedAt"`
	Body      string      `json:"body"`
	Author    profileJSON `json:"author"`
}

// The outer article lookup preserves 404. An article with no comments returns
// a single NULL comment row, which commentScanner identifies as an empty thread.
const commentsSelect = `SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id)
  FROM articles a
  LEFT JOIN LATERAL (
    SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id
      FROM comments c WHERE c.article_id = a.id
     ORDER BY c.created_at DESC, c.id DESC LIMIT 100
  ) c ON true
  LEFT JOIN users u ON u.id = c.author_id
 WHERE a.slug = $2
 ORDER BY c.created_at DESC, c.id DESC`

// Reuse scan destinations across a result set. Only nullable profile fields
// need pointers in the response; the empty-thread sentinel is checked before
// scanning the non-null comment fields. The optional ordinal is prepended by
// numberedRow for queued reads.
type commentScanner struct {
	value            commentJSON
	created, updated time.Time
	dest             [8]any
	emptyDest        [8]any
}

func newCommentScanner() *commentScanner {
	s := new(commentScanner)
	s.dest = [8]any{&s.value.ID, &s.value.Body, &s.created, &s.updated,
		&s.value.Author.Username, &s.value.Author.Bio, &s.value.Author.Image, &s.value.Author.Following}
	return s
}

func (s *commentScanner) scan(row pgx.CollectableRow) (commentJSON, bool, error) {
	values := row.RawValues()
	if values[len(values)-len(s.dest)] == nil {
		return commentJSON{}, false, row.Scan(s.emptyDest[:]...)
	}
	if err := row.Scan(s.dest[:]...); err != nil {
		return commentJSON{}, false, err
	}
	s.value.CreatedAt, s.value.UpdatedAt = ts(s.created), ts(s.updated)
	return s.value, true, nil
}

// GET /api/articles/{slug}/comments
func (a *app) listComments(w http.ResponseWriter, r *http.Request, viewer int64, _ string) {
	if a.reads != nil {
		a.serveQueuedRead(w, r, readComments, viewer)
		return
	}
	rows, err := a.pool.Query(r.Context(), commentsSelect, viewer, r.PathValue("slug"))
	if err != nil {
		internalError(w, err)
		return
	}
	comments := []commentJSON{}
	found := false
	scanner := newCommentScanner()
	for rows.Next() {
		found = true
		var comment commentJSON
		var present bool
		if comment, present, err = scanner.scan(rows); err != nil {
			break
		}
		if present {
			comments = append(comments, comment)
		}
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		internalError(w, err)
		return
	}
	if !found {
		writeError(w, http.StatusNotFound, "article not found")
		return
	}
	writeJSON(w, http.StatusOK, struct {
		Comments []commentJSON `json:"comments"`
	}{comments})
}

// POST /api/articles/{slug}/comments
func (a *app) createComment(w http.ResponseWriter, r *http.Request, viewer int64, _ string) {
	m, err := readWrapper(r, "comment")
	if err != nil {
		writeError(w, http.StatusUnprocessableEntity, "invalid body")
		return
	}
	body, err := reqString(m, "body")
	if err != nil {
		writeError(w, http.StatusUnprocessableEntity, "body is required")
		return
	}
	var query string
	var args []any
	if writeSlugLookup && a.writes != nil {
		query, args = insertCommentBySlugSQL, []any{r.PathValue("slug"), viewer, body}
	} else {
		id, ok := a.articleID(w, r)
		if !ok {
			return
		}
		query, args = insertCommentByIDSQL, []any{id, viewer, body}
	}
	var c commentJSON
	var created, updated time.Time
	err = a.scanWrite(r.Context(), query, args, []any{&c.ID, &c.Body, &created, &updated, &c.Author.Username, &c.Author.Bio, &c.Author.Image})
	if errors.Is(err, pgx.ErrNoRows) && writeSlugLookup && a.writes != nil {
		writeError(w, http.StatusNotFound, "article not found")
		return
	}
	if err != nil {
		internalError(w, err)
		return
	}
	c.CreatedAt, c.UpdatedAt = ts(created), ts(updated)
	writeJSON(w, http.StatusCreated, struct {
		Comment commentJSON `json:"comment"`
	}{c})
}

// DELETE /api/articles/{slug}/comments/{id}
func (a *app) deleteComment(w http.ResponseWriter, r *http.Request, viewer int64, _ string) {
	id, ok := parseUint(r.PathValue("id"))
	if !ok {
		writeError(w, http.StatusNotFound, "comment not found")
		return
	}
	var authorID int64
	err := a.pool.QueryRow(r.Context(), `SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
 WHERE c.id = $1 AND a.slug = $2`, id, r.PathValue("slug")).Scan(&authorID)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "comment not found")
		return
	}
	if err != nil {
		internalError(w, err)
		return
	}
	if authorID != viewer {
		writeError(w, http.StatusForbidden, "not the author")
		return
	}
	if err := a.execWrite(r.Context(), `DELETE FROM comments WHERE id = $1`, id); err != nil {
		internalError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
