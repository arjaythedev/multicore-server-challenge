package main

import (
	"context"
	"errors"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
)

const slugify = `trim(both '-' from lower(regexp_replace(%s, '[^A-Za-z0-9]+', '-', 'g')))`

// articleCols selects one article of alias a joined to its author u, for viewer v.
func articleCols(v string, body bool) string {
	b := ""
	if body {
		b = "a.body, "
	}
	return `a.id, a.slug, a.title, a.description, ` + b + `a.created_at, a.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = ` + v + ` OFFSET 0),
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ` + v + ` AND fo.followee_id = a.author_id OFFSET 0)`
}

func articleDest(a *Article, id *int64, body bool) []any {
	d := make([]any, 0, 15)
	d = append(d, id, &a.Slug, &a.Title, &a.Description)
	if body {
		d = append(d, &a.Body)
	}
	return append(d, &a.CreatedAt, &a.UpdatedAt, &a.TagList, &a.FavoritesCount, &a.Favorited,
		&a.Author.Username, &a.Author.Bio, &a.Author.Image, &a.Author.Following)
}

type store struct {
	writes writers
	fast   readers
	slow   readers

	userByID    batcher[int64, userRow]
	userByEmail batcher[string, userRow]
	profile     batcher[profileQuery, found[Profile]]
	tags        batcher[struct{}, []string]
	articles    articles
}

type found[T any] struct {
	v  T
	ok bool
}

type userRow struct {
	id       int64
	username string
	email    string
	bio      *string
	image    *string
	hash     string
	ok       bool
}

type profileQuery struct {
	viewer   int64
	username string
}

type listQuery struct {
	viewer int64
	limit  int64
	offset int64
	key    string
}

func newPool(ctx context.Context, dsn string, conns int32) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, err
	}
	cfg.MaxConns = conns
	cfg.MinConns = conns
	cfg.MaxConnIdleTime = time.Hour
	cfg.HealthCheckPeriod = time.Minute
	cfg.AfterConnect = func(ctx context.Context, c *pgx.Conn) error {
		c.TypeMap().RegisterType(&pgtype.Type{Name: "timestamptz", OID: pgtype.TimestamptzOID, Codec: &pgtype.TimestamptzCodec{ScanLocation: time.UTC}})
		_, err := c.Exec(ctx, "SET jit = off; SET max_parallel_workers_per_gather = 0; SET plan_cache_mode = force_generic_plan; SET enable_memoize = off")
		return err
	}
	return pgxpool.NewWithConfig(ctx, cfg)
}

// newStore reads on two lanes: fast for the cheap lookups, slow for the articles statement, whose
// batches start at least gap apart so they share more.
func newStore(ctx context.Context, dsn string, fastConns, slowConns, writeConns int, gap time.Duration) (*store, error) {
	rp, err := newPool(ctx, dsn, int32(fastConns+slowConns))
	if err != nil {
		return nil, err
	}
	wp, err := newPool(ctx, dsn, int32(writeConns))
	if err != nil {
		return nil, err
	}
	s := &store{
		writes: writers{pool: wp},
		fast:   readers{pool: rp, sig: make(chan struct{}, 1)},
		slow:   readers{pool: rp, sig: make(chan struct{}, 1), gap: gap},
	}
	s.setup()
	s.fast.kinds = []kind{&s.tags, &s.userByID, &s.userByEmail, &s.profile}
	s.slow.kinds = []kind{&s.articles}
	for _, r := range []*readers{&s.fast, &s.slow} {
		for _, k := range r.kinds {
			k.bind(r.wake)
		}
	}
	s.fast.start(fastConns)
	s.slow.start(slowConns)
	s.writes.start(writeConns)
	return s, nil
}

const maxBatch = 1024

func (s *store) setup() {
	s.userByID = batcher[int64, userRow]{
		max: maxBatch,
		sql: `SELECT r.i, u.username, u.email, u.bio, u.image
  FROM unnest($1::bigint[]) WITH ORDINALITY AS r(id, i)
  JOIN users u ON u.id = r.id`,
		args: func(cs []*call[int64, userRow]) []any {
			ids := make([]int64, len(cs))
			for i, c := range cs {
				ids[i] = c.q
			}
			return []any{ids}
		},
		scan: func(rows pgx.Rows, cs []*call[int64, userRow]) error {
			for rows.Next() {
				var i int
				var u userRow
				if err := rows.Scan(&i, &u.username, &u.email, &u.bio, &u.image); err != nil {
					return err
				}
				u.ok = true
				u.id = cs[i-1].q
				cs[i-1].r = u
			}
			return nil
		},
	}

	s.userByEmail = batcher[string, userRow]{
		max: maxBatch,
		sql: `SELECT r.i, u.id, u.username, u.email, u.bio, u.image, u.password_hash
  FROM unnest($1::text[]) WITH ORDINALITY AS r(email, i)
  JOIN users u ON u.email = r.email`,
		args: func(cs []*call[string, userRow]) []any {
			emails := make([]string, len(cs))
			for i, c := range cs {
				emails[i] = c.q
			}
			return []any{emails}
		},
		scan: func(rows pgx.Rows, cs []*call[string, userRow]) error {
			for rows.Next() {
				var i int
				var u userRow
				if err := rows.Scan(&i, &u.id, &u.username, &u.email, &u.bio, &u.image, &u.hash); err != nil {
					return err
				}
				u.ok = true
				cs[i-1].r = u
			}
			return nil
		},
	}

	s.profile = batcher[profileQuery, found[Profile]]{
		max: maxBatch,
		sql: `SELECT r.i, u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.viewer AND fo.followee_id = u.id OFFSET 0)
  FROM unnest($1::bigint[], $2::text[]) WITH ORDINALITY AS r(viewer, username, i)
  JOIN users u ON u.username = r.username`,
		args: func(cs []*call[profileQuery, found[Profile]]) []any {
			viewers, names := make([]int64, len(cs)), make([]string, len(cs))
			for i, c := range cs {
				viewers[i], names[i] = c.q.viewer, c.q.username
			}
			return []any{viewers, names}
		},
		scan: func(rows pgx.Rows, cs []*call[profileQuery, found[Profile]]) error {
			for rows.Next() {
				var i int
				var p Profile
				if err := rows.Scan(&i, &p.Username, &p.Bio, &p.Image, &p.Following); err != nil {
					return err
				}
				cs[i-1].r = found[Profile]{p, true}
			}
			return nil
		},
	}

	s.tags = batcher[struct{}, []string]{
		max:  1 << 20, // every call shares the one result
		sql:  `SELECT name FROM tags ORDER BY name`,
		args: func([]*call[struct{}, []string]) []any { return nil },
		scan: func(rows pgx.Rows, cs []*call[struct{}, []string]) error {
			tags := make([]string, 0, 256)
			for rows.Next() {
				var t string
				if err := rows.Scan(&t); err != nil {
					return err
				}
				tags = append(tags, t)
			}
			for _, c := range cs {
				c.r = tags
			}
			return nil
		},
	}
}

func sortComments(cs []Comment) {
	less := func(a, b Comment) int {
		if c := b.CreatedAt.Compare(a.CreatedAt); c != 0 {
			return c
		}
		return int(b.ID - a.ID)
	}
	if !slices.IsSortedFunc(cs, less) {
		slices.SortFunc(cs, less)
	}
}

var (
	errNotFound  = errors.New("not found")
	errForbidden = errors.New("forbidden")
	errTaken     = errors.New("taken")
)

func isUniqueViolation(err error) bool {
	var pe *pgconn.PgError
	return errors.As(err, &pe) && pe.Code == "23505"
}

func (s *store) register(username, email, hash string) (userRow, error) {
	u := userRow{username: username, email: email, ok: true}
	var ok bool
	err := s.writes.do(func(b *pgx.Batch) {
		b.Queue(`INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING RETURNING id, bio, image`,
			username, email, hash).QueryRow(func(r pgx.Row) error { return row(r.Scan(&u.id, &u.bio, &u.image), &ok) })
	})
	if err == nil && !ok {
		err = errTaken
	}
	return u, err
}

func (s *store) updateUser(id int64, f *updateUserFields, hash *string) (userRow, error) {
	u := userRow{id: id, ok: true}
	var ok bool
	err := s.writes.do(func(b *pgx.Batch) {
		b.Queue(`UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
       password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
 WHERE id = $1
RETURNING username, email, bio, image`, id, f.Email, f.Username, hash, f.Bio, f.Image).
			QueryRow(func(r pgx.Row) error { return row(r.Scan(&u.username, &u.email, &u.bio, &u.image), &ok) })
	})
	switch {
	case isUniqueViolation(err):
		return u, errTaken
	case err == nil && !ok:
		return u, errNotFound
	}
	return u, err
}

func (s *store) follow(viewer int64, username string, on bool) (Profile, error) {
	var q string
	if on {
		q = `WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),
     f AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM u ON CONFLICT DO NOTHING)
SELECT username, bio, image FROM u`
	} else {
		q = `WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),
     f AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM u))
SELECT username, bio, image FROM u`
	}
	p := Profile{Following: on}
	var ok bool
	err := s.writes.do(func(b *pgx.Batch) {
		b.Queue(q, viewer, username).QueryRow(func(r pgx.Row) error { return row(r.Scan(&p.Username, &p.Bio, &p.Image), &ok) })
	})
	if err == nil && !ok {
		err = errNotFound
	}
	return p, err
}

var (
	sqlArticleByID = `SELECT ` + articleCols("$1", true) + `
  FROM articles a JOIN users u ON u.id = a.author_id
 WHERE a.id = (SELECT currval(pg_get_serial_sequence('articles', 'id')))`
	sqlArticleBySlug = `SELECT ` + articleCols("$1", true) + `
  FROM articles a JOIN users u ON u.id = a.author_id
 WHERE a.slug = $2`
)

func (s *store) createArticle(viewer int64, f *createArticleFields) (Article, error) {
	var a Article
	var id int64
	err := s.writes.do(func(b *pgx.Batch) {
		b.Queue(`INSERT INTO articles (id, slug, author_id, title, description, body)
SELECT n.id, `+strings.Replace(slugify, "%s", "$2", 1)+` || '-' || n.id, $1, $2, $3, $4
  FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n`, viewer, f.Title, f.Description, f.Body)
		if len(f.TagList) > 0 {
			b.Queue(`INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING`, f.TagList)
			b.Queue(`INSERT INTO article_tags (article_id, tag_id)
SELECT currval(pg_get_serial_sequence('articles', 'id')), t.id FROM tags t WHERE t.name = ANY($1::text[])`, f.TagList)
		}
		b.Queue(sqlArticleByID, viewer).QueryRow(func(r pgx.Row) error { return r.Scan(articleDest(&a, &id, true)...) })
	})
	return a, err
}

func (s *store) updateArticle(viewer int64, slug string, f *updateArticleFields) (Article, error) {
	var author int64
	var id pgtype.Int8
	var a Article
	var ok bool
	err := s.writes.do(func(b *pgx.Batch) {
		b.Queue(`WITH a0 AS (SELECT id, author_id FROM articles WHERE slug = $2),
     a AS (UPDATE articles SET title = COALESCE($3, title), description = COALESCE($4, description), body = COALESCE($5, body),
                  slug = CASE WHEN $3::text IS NULL THEN slug ELSE `+strings.Replace(slugify, "%s", "$3", 1)+` || '-' || id END,
                  updated_at = now()
            WHERE id = (SELECT id FROM a0 WHERE author_id = $1)
        RETURNING id, slug, title, description, body, created_at, updated_at, author_id)
SELECT a0.author_id, x.* FROM a0 LEFT JOIN LATERAL (
  SELECT `+articleCols("$1", true)+` FROM a JOIN users u ON u.id = a.author_id) x ON true`,
			viewer, slug, f.Title, f.Description, f.Body).
			QueryRow(func(r pgx.Row) error { return row(r.Scan(append([]any{&author}, articleDestNull(&a, &id)...)...), &ok) })
	})
	switch {
	case err != nil:
		return a, err
	case !ok:
		return a, errNotFound
	case author != viewer || !id.Valid:
		return a, errForbidden
	}
	return a, nil
}

// articleDestNull scans an article that may be all NULL, which leaves id invalid.
func articleDestNull(a *Article, id *pgtype.Int8) []any {
	return []any{id, nullString{&a.Slug}, nullString{&a.Title}, nullString{&a.Description}, nullString{&a.Body},
		nullTime{&a.CreatedAt}, nullTime{&a.UpdatedAt}, &a.TagList, nullInt{&a.FavoritesCount}, nullBool{&a.Favorited},
		nullString{&a.Author.Username}, &a.Author.Bio, &a.Author.Image, nullBool{&a.Author.Following}}
}

func (s *store) deleteArticle(viewer int64, slug string) error {
	return s.deleteOwned(`WITH a AS (SELECT id, author_id FROM articles WHERE slug = $2),
     d AS (DELETE FROM articles WHERE id = (SELECT id FROM a WHERE author_id = $1))
SELECT author_id FROM a`, viewer, slug)
}

func (s *store) deleteComment(viewer int64, slug string, id int64) error {
	return s.deleteOwned(`WITH c AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
            WHERE c.id = $3 AND a.slug = $2),
     d AS (DELETE FROM comments WHERE id = (SELECT id FROM c WHERE author_id = $1))
SELECT author_id FROM c`, viewer, slug, id)
}

func (s *store) deleteOwned(q string, viewer int64, args ...any) error {
	var author int64
	var ok bool
	err := s.writes.do(func(b *pgx.Batch) {
		b.Queue(q, append([]any{viewer}, args...)...).QueryRow(func(r pgx.Row) error { return row(r.Scan(&author), &ok) })
	})
	switch {
	case err != nil:
		return err
	case !ok:
		return errNotFound
	case author != viewer:
		return errForbidden
	}
	return nil
}

func (s *store) favorite(viewer int64, slug string, on bool) (Article, error) {
	var a Article
	var id int64
	var ok bool
	err := s.writes.do(func(b *pgx.Batch) {
		if on {
			b.Queue(`INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM articles WHERE slug = $2 ON CONFLICT DO NOTHING`, viewer, slug)
		} else {
			b.Queue(`DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM articles WHERE slug = $2)`, viewer, slug)
		}
		b.Queue(sqlArticleBySlug, viewer, slug).QueryRow(func(r pgx.Row) error { return row(r.Scan(articleDest(&a, &id, true)...), &ok) })
	})
	if err == nil && !ok {
		err = errNotFound
	}
	return a, err
}

func (s *store) createComment(viewer int64, slug, body string) (Comment, error) {
	var c Comment
	var ok bool
	err := s.writes.do(func(b *pgx.Batch) {
		b.Queue(`WITH a AS (SELECT id FROM articles WHERE slug = $2),
     c AS (INSERT INTO comments (article_id, author_id, body) SELECT a.id, $1, $3 FROM a
           RETURNING id, body, created_at, updated_at, author_id)
SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image FROM c JOIN users u ON u.id = c.author_id`,
			viewer, slug, body).QueryRow(func(r pgx.Row) error {
			return row(r.Scan(&c.ID, &c.Body, &c.CreatedAt, &c.UpdatedAt, &c.Author.Username, &c.Author.Bio, &c.Author.Image), &ok)
		})
	})
	if err == nil && !ok {
		err = errNotFound
	}
	return c, err
}

type (
	nullString struct{ p *string }
	nullTime   struct{ p *time.Time }
	nullInt    struct{ p *int64 }
	nullBool   struct{ p *bool }
)

func (n nullString) Scan(src any) error {
	if v, ok := src.(string); ok {
		*n.p = v
	}
	return nil
}

func (n nullTime) Scan(src any) error {
	if v, ok := src.(time.Time); ok {
		*n.p = v.UTC()
	}
	return nil
}

func (n nullInt) Scan(src any) error {
	if v, ok := src.(int64); ok {
		*n.p = v
	}
	return nil
}

func (n nullBool) Scan(src any) error {
	if v, ok := src.(bool); ok {
		*n.p = v
	}
	return nil
}
