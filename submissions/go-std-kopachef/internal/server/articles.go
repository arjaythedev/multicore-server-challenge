package server

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
)

// Preserve the reference response shape and ordering. Each article has only a
// few tags; scalar primary-key lookups avoid a tag-table scan per article.
const (
	articleTagNames = `ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
              FROM article_tags at WHERE at.article_id = a.id ORDER BY name)`

	articleListSelect = `SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       ` + articleTagNames + ` AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id`

	articleFullSelect = `SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
       ` + articleTagNames + ` AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id`

	// Select page IDs before enrichment so OFFSET rows never fetch tags,
	// favorite counts, or profiles. The same boundary applies to author pages.
	listAll         = articleListSelect + ` WHERE a.id IN (SELECT a2.id FROM articles a2 ORDER BY a2.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC`
	countAll        = `SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s`
	listByTag       = articleListSelect + ` WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3)` + ` ORDER BY a.id DESC`
	countByTag      = `SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s`
	listByAuthor    = articleListSelect + ` WHERE a.id IN (SELECT a2.id FROM articles a2 WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a2.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC`
	countByAuthor   = `SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s`
	listByFavorite  = articleListSelect + ` WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3)` + ` ORDER BY a.id DESC`
	countByFavorite = `SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s`
	listFeed        = articleListSelect + ` WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3)` + ` ORDER BY a.id DESC`
	countFeed       = `SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s`

	articleBySlug = articleFullSelect + ` WHERE a.slug = $2`
	articleByID   = articleFullSelect + ` WHERE a.id = $2`

	insertArticle = `INSERT INTO articles (id, slug, author_id, title, description, body)
SELECT n.id, trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id, $1, $2, $3, $4
  FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
RETURNING id`
	insertTags        = `INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING`
	insertArticleTags = `INSERT INTO article_tags (article_id, tag_id) SELECT $1, t.id FROM tags t WHERE t.name = ANY($2::text[])`

	updateArticle = `UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body),
       slug = CASE WHEN $2::text IS NULL THEN slug ELSE trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END,
       updated_at = now()
 WHERE id = $1`
)

type articleJSON struct {
	Slug           string      `json:"slug"`
	Title          string      `json:"title"`
	Description    string      `json:"description"`
	Body           *string     `json:"body,omitempty"`
	TagList        []string    `json:"tagList"`
	CreatedAt      timestamp   `json:"createdAt"`
	UpdatedAt      timestamp   `json:"updatedAt"`
	Favorited      bool        `json:"favorited"`
	FavoritesCount int64       `json:"favoritesCount"`
	Author         profileJSON `json:"author"`
}

func scanListArticle(row pgx.CollectableRow) (articleJSON, error) {
	var x articleJSON
	var id int64
	var created, updated time.Time
	err := row.Scan(&id, &x.Slug, &x.Title, &x.Description, &created, &updated, &x.TagList, &x.FavoritesCount,
		&x.Favorited, &x.Author.Username, &x.Author.Bio, &x.Author.Image, &x.Author.Following)
	x.CreatedAt, x.UpdatedAt = ts(created), ts(updated)
	if x.TagList == nil {
		x.TagList = []string{}
	}
	return x, err
}

func scanFullArticle(row pgx.CollectableRow) (articleJSON, error) {
	var x articleJSON
	var id int64
	var body string
	var created, updated time.Time
	err := row.Scan(&id, &x.Slug, &x.Title, &x.Description, &body, &created, &updated, &x.TagList, &x.FavoritesCount,
		&x.Favorited, &x.Author.Username, &x.Author.Bio, &x.Author.Image, &x.Author.Following)
	x.Body = &body
	x.CreatedAt, x.UpdatedAt = ts(created), ts(updated)
	if x.TagList == nil {
		x.TagList = []string{}
	}
	return x, err
}

func writeArticle(w http.ResponseWriter, status int, x articleJSON) {
	writeJSON(w, status, struct {
		Article articleJSON `json:"article"`
	}{x})
}

// The mutation has already committed. Its response can join a fresh active
// read batch without another slug lookup or an independent enrichment query.
func (a *app) writeArticleID(w http.ResponseWriter, r *http.Request, status int, viewer, id int64) {
	if a.reads == nil {
		a.writeFullArticle(w, r, status, articleByID, viewer, id)
		return
	}
	a.serveReadCall(w, r, &queuedRead{ctx: r.Context(), kind: readArticle, viewer: viewer,
		articleIDs: []int64{id}, status: status, done: make(chan struct{})})
}

// writeFullArticle runs ARTICLE_FULL_SELECT with the given WHERE query and writes it, or 404.
func (a *app) writeFullArticle(w http.ResponseWriter, r *http.Request, status int, query string, viewer int64, key any) {
	rows, _ := a.pool.Query(r.Context(), query, viewer, key)
	x, err := pgx.CollectExactlyOneRow(rows, scanFullArticle)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "article not found")
		return
	}
	if err != nil {
		internalError(w, err)
		return
	}
	writeArticle(w, status, x)
}

func (a *app) writeList(w http.ResponseWriter, r *http.Request, list, count string, viewer, limit, offset int64, filter any) {
	if a.reads != nil {
		kind := readGlobal
		switch count {
		case countByTag:
			kind = readTag
		case countByAuthor:
			kind = readAuthor
		case countByFavorite:
			kind = readFavorite
		case countFeed:
			kind = readFeed
		}
		call := &queuedRead{ctx: r.Context(), kind: kind, viewer: viewer, limit: limit, offset: offset, done: make(chan struct{})}
		if filter != nil {
			call.filter = filter.(string)
		}
		a.serveReadCall(w, r, call)
		return
	}
	args := []any{viewer, limit, offset}
	if filter != nil {
		args = append(args, filter)
	}
	// A page and its capped count are independent reads. Send both in one
	// protocol batch to save a network round trip on every list/feed request.
	var batch pgx.Batch
	batch.Queue(list, args...)
	if filter != nil {
		batch.Queue(count, filter)
	} else if count == countFeed {
		batch.Queue(count, viewer)
	} else {
		batch.Queue(count)
	}
	results := a.pool.SendBatch(r.Context(), &batch)
	rows, err := results.Query()
	if err != nil {
		_ = results.Close()
		internalError(w, err)
		return
	}
	// The validated page limit is at most 100. Allocate its bounded output
	// once instead of repeatedly growing and copying article structs.
	articles, err := pgx.AppendRows(make([]articleJSON, 0, int(limit)), rows, scanListArticle)
	if err != nil {
		_ = results.Close()
		internalError(w, err)
		return
	}
	var n int64
	err = results.QueryRow().Scan(&n)
	if err != nil {
		_ = results.Close()
		internalError(w, err)
		return
	}
	if err := results.Close(); err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, struct {
		Articles      []articleJSON `json:"articles"`
		ArticlesCount int64         `json:"articlesCount"`
	}{articles, n})
}

// GET /api/articles
func (a *app) listArticles(w http.ResponseWriter, r *http.Request, viewer int64, _ string) {
	q := r.URL.Query()
	limit, offset, ok := limitOffset(q)
	if !ok {
		writeError(w, http.StatusUnprocessableEntity, "limit must be 1-100 and offset >= 0")
		return
	}
	// The first non-empty filter in the order tag, author, favorited applies.
	switch {
	case q.Get("tag") != "":
		a.writeList(w, r, listByTag, countByTag, viewer, limit, offset, q.Get("tag"))
	case q.Get("author") != "":
		a.writeList(w, r, listByAuthor, countByAuthor, viewer, limit, offset, q.Get("author"))
	case q.Get("favorited") != "":
		a.writeList(w, r, listByFavorite, countByFavorite, viewer, limit, offset, q.Get("favorited"))
	default:
		a.writeList(w, r, listAll, countAll, viewer, limit, offset, nil)
	}
}

// GET /api/articles/feed
func (a *app) feed(w http.ResponseWriter, r *http.Request, viewer int64, _ string) {
	limit, offset, ok := limitOffset(r.URL.Query())
	if !ok {
		writeError(w, http.StatusUnprocessableEntity, "limit must be 1-100 and offset >= 0")
		return
	}
	a.writeList(w, r, listFeed, countFeed, viewer, limit, offset, nil)
}

// GET /api/articles/{slug}
func (a *app) getArticle(w http.ResponseWriter, r *http.Request, viewer int64, _ string) {
	if a.reads != nil {
		a.serveQueuedRead(w, r, readArticle, viewer)
		return
	}
	a.writeFullArticle(w, r, http.StatusOK, articleBySlug, viewer, r.PathValue("slug"))
}

// POST /api/articles
func (a *app) createArticle(w http.ResponseWriter, r *http.Request, viewer int64, _ string) {
	m, err := readWrapper(r, "article")
	if err != nil {
		writeError(w, http.StatusUnprocessableEntity, "invalid body")
		return
	}
	title, err1 := reqString(m, "title")
	description, err2 := reqString(m, "description")
	body, err3 := reqString(m, "body")
	if err1 != nil || err2 != nil || err3 != nil {
		writeError(w, http.StatusUnprocessableEntity, "title, description and body are required")
		return
	}
	var tagList []string
	if raw, ok := m["tagList"]; ok && !isNull(raw) {
		var items []json.RawMessage
		if err := json.Unmarshal(raw, &items); err != nil {
			writeError(w, http.StatusUnprocessableEntity, "tagList must be an array of non-empty strings")
			return
		}
		for _, it := range items {
			var s string
			if isNull(it) || json.Unmarshal(it, &s) != nil || s == "" {
				writeError(w, http.StatusUnprocessableEntity, "tagList must be an array of non-empty strings")
				return
			}
			tagList = append(tagList, s)
		}
	}

	ctx := r.Context()
	tx, err := a.pool.Begin(ctx)
	if err != nil {
		internalError(w, err)
		return
	}
	defer tx.Rollback(ctx)
	var id int64
	if err := tx.QueryRow(ctx, insertArticle, viewer, title, description, body).Scan(&id); err != nil {
		internalError(w, err)
		return
	}
	if len(tagList) > 0 {
		if _, err := tx.Exec(ctx, insertTags, tagList); err != nil {
			internalError(w, err)
			return
		}
		if _, err := tx.Exec(ctx, insertArticleTags, id, tagList); err != nil {
			internalError(w, err)
			return
		}
	}
	if err := tx.Commit(ctx); err != nil {
		internalError(w, err)
		return
	}
	a.writeArticleID(w, r, http.StatusCreated, viewer, id)
}

// ownArticle looks up the article by slug: 404 if missing, 403 if the viewer isn't its author.
func (a *app) ownArticle(w http.ResponseWriter, r *http.Request, viewer int64) (int64, bool) {
	var id, authorID int64
	err := a.pool.QueryRow(r.Context(), `SELECT id, author_id FROM articles WHERE slug = $1`, r.PathValue("slug")).Scan(&id, &authorID)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "article not found")
		return 0, false
	}
	if err != nil {
		internalError(w, err)
		return 0, false
	}
	if authorID != viewer {
		writeError(w, http.StatusForbidden, "not the author")
		return 0, false
	}
	return id, true
}

// PUT /api/articles/{slug}
func (a *app) updateArticle(w http.ResponseWriter, r *http.Request, viewer int64, _ string) {
	m, err := readWrapper(r, "article")
	if err != nil {
		writeError(w, http.StatusUnprocessableEntity, "invalid body")
		return
	}
	title, err1 := optString(m, "title", true)
	description, err2 := optString(m, "description", true)
	body, err3 := optString(m, "body", true)
	if err1 != nil || err2 != nil || err3 != nil {
		writeError(w, http.StatusUnprocessableEntity, "title, description and body must be non-empty strings")
		return
	}
	id, ok := a.ownArticle(w, r, viewer)
	if !ok {
		return
	}
	if _, err := a.pool.Exec(r.Context(), updateArticle, id, title, description, body); err != nil {
		internalError(w, err)
		return
	}
	a.writeArticleID(w, r, http.StatusOK, viewer, id)
}

// DELETE /api/articles/{slug}
func (a *app) deleteArticle(w http.ResponseWriter, r *http.Request, viewer int64, _ string) {
	id, ok := a.ownArticle(w, r, viewer)
	if !ok {
		return
	}
	if _, err := a.pool.Exec(r.Context(), `DELETE FROM articles WHERE id = $1`, id); err != nil {
		internalError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// articleID: SELECT id FROM articles WHERE slug = $1 → 404.
func (a *app) articleID(w http.ResponseWriter, r *http.Request) (int64, bool) {
	var id int64
	err := a.pool.QueryRow(r.Context(), `SELECT id FROM articles WHERE slug = $1`, r.PathValue("slug")).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "article not found")
		return 0, false
	}
	if err != nil {
		internalError(w, err)
		return 0, false
	}
	return id, true
}

const insertFavoriteSQL = `INSERT INTO favorites (user_id, article_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`
const deleteFavoriteSQL = `DELETE FROM favorites WHERE user_id = $1 AND article_id = $2`

func favoriteStatement(insert bool) string {
	if insert {
		return insertFavoriteSQL
	}
	return deleteFavoriteSQL
}

// POST and DELETE /api/articles/{slug}/favorite
func (a *app) favorite(fav bool) authed {
	return func(w http.ResponseWriter, r *http.Request, viewer int64, _ string) {
		var id int64
		var err error
		if writeSlugLookup && a.writes != nil {
			err = a.scanWrite(r.Context(), favoriteBySlugStatement(fav),
				[]any{viewer, r.PathValue("slug")}, []any{&id})
			if errors.Is(err, pgx.ErrNoRows) {
				writeError(w, http.StatusNotFound, "article not found")
				return
			}
		} else {
			var ok bool
			id, ok = a.articleID(w, r)
			if !ok {
				return
			}
			err = a.execWrite(r.Context(), favoriteStatement(fav), viewer, id)
		}
		if err != nil {
			internalError(w, err)
			return
		}
		a.writeArticleID(w, r, http.StatusOK, viewer, id)
	}
}
