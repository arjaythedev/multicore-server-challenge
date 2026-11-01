package main

import (
	"slices"

	"multicorelab/http/conduit"
)

// slugify is SPEC.md's SLUGIFY applied to a parameter.
func slugify(p string) string {
	return `trim(both '-' from lower(regexp_replace(` + p + `, '[^A-Za-z0-9]+', '-', 'g')))`
}

// Every write is one statement (or three for CreateArticle) that checks for
// itself what the reference checks in separate statements, so a group of them
// never fails over a 404 or 403 and one transaction can hold many requests.
var (
	sqlRegister = `INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)
ON CONFLICT DO NOTHING RETURNING id, username, email, bio, image`

	sqlUpdateUser = `UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
                 password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
 WHERE id = $1
RETURNING id, username, email, bio, image`

	sqlFollow = `WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $1),
     w AS (INSERT INTO follows (follower_id, followee_id) SELECT $2::bigint, id FROM u ON CONFLICT DO NOTHING)
SELECT id, username, bio, image FROM u`

	sqlUnfollow = `WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $1),
     w AS (DELETE FROM follows WHERE follower_id = $2::bigint AND followee_id IN (SELECT id FROM u))
SELECT id, username, bio, image FROM u`

	// The update and create statements return the article as the response shows it, so no read follows the commit.
	// Counts and flags are computed from the statement's snapshot and adjusted by what the statement itself wrote.
	// The favorite and unfavorite statements return a zero count: the count of a popular article is dear, so it is
	// read after the commit, once per article for the whole flush (qFavSettle).
	artRet = `a.id, a.author_id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id WHERE at.article_id = a.id ORDER BY t.name)`
	artRetTail = `u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $2::bigint AND fo.followee_id = a.author_id)
  FROM a JOIN users u ON u.id = a.author_id`
	artHead = `a AS (SELECT id, slug, title, description, body, created_at, updated_at, author_id FROM articles WHERE slug = $1)`

	sqlFavorite = `WITH ` + artHead + `,
     w AS (INSERT INTO favorites (user_id, article_id) SELECT $2::bigint, id FROM a ON CONFLICT DO NOTHING RETURNING 1)
SELECT ` + artRet + `, 0::bigint, true,
       ` + artRetTail

	sqlUnfavorite = `WITH ` + artHead + `,
     w AS (DELETE FROM favorites WHERE user_id = $2::bigint AND article_id IN (SELECT id FROM a) RETURNING 1)
SELECT ` + artRet + `, 0::bigint, false,
       ` + artRetTail

	// The same two with the count inside the transaction, for a flush that holds several favorite and unfavorite
	// requests of one viewer for one article: each must see the others' effect in its count.
	sqlFavoriteCounted = `WITH ` + artHead + `,
     w AS (INSERT INTO favorites (user_id, article_id) SELECT $2::bigint, id FROM a ON CONFLICT DO NOTHING RETURNING 1)
SELECT ` + artRet + `, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) + (SELECT count(*) FROM w), true,
       ` + artRetTail

	sqlUnfavoriteCounted = `WITH ` + artHead + `,
     w AS (DELETE FROM favorites WHERE user_id = $2::bigint AND article_id IN (SELECT id FROM a) RETURNING 1)
SELECT ` + artRet + `, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) - (SELECT count(*) FROM w), false,
       ` + artRetTail

	sqlDeleteArticle = `WITH a AS (SELECT id, author_id FROM articles WHERE slug = $1),
     w AS (DELETE FROM articles WHERE id IN (SELECT id FROM a) AND author_id = $2::bigint)
SELECT id, author_id FROM a`

	// A request by someone else updates nothing: the w columns come back NULL (COALESCEd) and the author id tells.
	sqlUpdateArticle = `WITH a AS (SELECT id, author_id FROM articles WHERE slug = $1),
     w AS (UPDATE articles SET title = COALESCE($3, title), description = COALESCE($4, description),
                  body = COALESCE($5, body),
                  slug = CASE WHEN $3::text IS NULL THEN slug ELSE ` + slugify("$3") + ` || '-' || id END,
                  updated_at = clock_timestamp()
            WHERE id IN (SELECT id FROM a) AND author_id = $2::bigint
        RETURNING id, slug, title, description, body, created_at, updated_at)
SELECT a.id, a.author_id, COALESCE(w.slug, ''), COALESCE(w.title, ''), COALESCE(w.description, ''), COALESCE(w.body, ''),
       COALESCE(w.created_at, now()), COALESCE(w.updated_at, now()),
       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id WHERE at.article_id = a.id ORDER BY t.name),
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $2::bigint),
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $2::bigint AND fo.followee_id = a.author_id)
  FROM a LEFT JOIN w ON true JOIN users u ON u.id = a.author_id`

	sqlInsertTags = `INSERT INTO tags (name) SELECT DISTINCT n FROM unnest($1::text[]) n ORDER BY n ON CONFLICT (name) DO NOTHING`

	// The article and its tag links in one statement (the tags themselves were inserted earlier in the
	// transaction); $5 is the tag list, possibly empty. $1 is the author, as $2 is the viewer elsewhere.
	sqlCreateArticle = `WITH a AS (INSERT INTO articles (id, slug, author_id, title, description, body, created_at, updated_at)
SELECT n.id, ` + slugify("$2::text") + ` || '-' || n.id, $1, $2, $3, $4, n.ts, n.ts
  FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id, clock_timestamp() AS ts) n
RETURNING id, slug, title, description, body, created_at, updated_at, author_id),
     lk AS (INSERT INTO article_tags (article_id, tag_id) SELECT a.id, t.id FROM a, tags t WHERE t.name = ANY($5::text[]) RETURNING 1)
SELECT a.id, a.author_id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
       ARRAY(SELECT t.name FROM tags t WHERE t.name = ANY($5::text[]) ORDER BY t.name), 0::bigint, false,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1::bigint AND fo.followee_id = a.author_id)
  FROM a JOIN users u ON u.id = a.author_id`

	sqlCreateComment = `WITH a AS (SELECT id FROM articles WHERE slug = $1),
     c AS (INSERT INTO comments (article_id, author_id, body, created_at, updated_at)
           SELECT a.id, $2::bigint, $3, n.ts, n.ts FROM a, (SELECT clock_timestamp() AS ts) n
           RETURNING id, body, created_at, updated_at, author_id)
SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
  FROM c JOIN users u ON u.id = c.author_id`

	sqlDeleteComment = `WITH c AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
                WHERE c.id = $1 AND a.slug = $2),
     w AS (DELETE FROM comments WHERE id IN (SELECT id FROM c) AND author_id = $3::bigint)
SELECT author_id FROM c`
)

func optStr(o conduit.Opt) any {
	if !o.Valid {
		return nil
	}
	return string(o.V)
}

// queueWrite adds the statements of one write request to sb. The readers
// store what comes back in s.
func (w *worker) queueWrite(sb *stmtBatch, s *opState) {
	c := s.c
	switch c.Endpoint {
	case conduit.Register:
		sb.query(sqlRegister, []any{string(c.NewUsername.V), string(c.Email.V), string(s.hash)}, readUser(s))
	case conduit.UpdateUser:
		var hash any
		if c.Password.Valid {
			hash = string(s.hash)
		}
		sb.query(sqlUpdateUser, []any{c.Viewer, optStr(c.Email), optStr(c.NewUsername), hash, optStr(c.Bio), optStr(c.Image)}, readUser(s))
	case conduit.Follow, conduit.Unfollow:
		q := sqlFollow
		if c.Endpoint == conduit.Unfollow {
			q = sqlUnfollow
		}
		sb.query(q, []any{string(c.Username), c.Viewer}, readUser(s))
	case conduit.Favorite, conduit.Unfavorite:
		q := sqlFavorite
		if c.Endpoint == conduit.Unfavorite {
			q = sqlUnfavorite
		}
		if s.inTxCount {
			q = sqlFavoriteCounted
			if c.Endpoint == conduit.Unfavorite {
				q = sqlUnfavoriteCounted
			}
		}
		sb.query(q, []any{string(c.Slug), c.Viewer}, readArticle(s))
	case conduit.DeleteArticle:
		sb.query(sqlDeleteArticle, []any{string(c.Slug), c.Viewer}, readIDAuthor(s))
	case conduit.UpdateArticle:
		sb.query(sqlUpdateArticle, []any{string(c.Slug), c.Viewer, optStr(c.Title), optStr(c.Description), optStr(c.Body)}, readArticle(s))
	case conduit.CreateArticle:
		tags := make([]string, len(c.TagList))
		for i, t := range c.TagList {
			tags[i] = string(t)
		}
		if len(tags) > 0 {
			sb.exec(sqlInsertTags, tags)
		}
		sb.query(sqlCreateArticle, []any{c.Viewer, string(c.Title.V), string(c.Description.V), string(c.Body.V), tags}, readArticle(s))
	case conduit.CreateComment:
		sb.query(sqlCreateComment, []any{string(c.Slug), c.Viewer, string(c.Body.V)}, func(rows *pgRows) error {
			if !rows.Next() {
				return nil
			}
			s.found = true
			s.com = commRow{id: rows.i64(0), body: rows.str(1), created: rows.micros(2), updated: rows.micros(3),
				username: rows.str(4), bio: rows.nstr(5), image: rows.nstr(6)}
			return rows.err
		})
	case conduit.DeleteComment:
		sb.query(sqlDeleteComment, []any{c.CommentID, string(c.Slug), c.Viewer}, func(rows *pgRows) error {
			if rows.Next() {
				s.found = true
				s.authorID = rows.i64(0)
				return rows.err
			}
			return nil
		})
	}
}

func readUser(s *opState) func(*pgRows) error {
	return func(rows *pgRows) error {
		if rows.Next() {
			s.found = true
			u := &s.user
			if s.c.Endpoint == conduit.Follow || s.c.Endpoint == conduit.Unfollow {
				*u = userRow{id: rows.i64(0), username: rows.str(1), bio: rows.nstr(2), image: rows.nstr(3)}
			} else {
				*u = userRow{id: rows.i64(0), username: rows.str(1), email: rows.str(2), bio: rows.nstr(3), image: rows.nstr(4)}
			}
			return rows.err
		}
		return nil
	}
}

// readArticle reads the article row that favorite, unfavorite, update and create return.
func readArticle(s *opState) func(*pgRows) error {
	return func(rows *pgRows) error {
		if !rows.Next() {
			return nil
		}
		s.found = true
		s.art = artRow{id: rows.i64(0), slug: rows.str(2), title: rows.str(3), desc: rows.str(4), body: rows.str(5),
			created: rows.micros(6), updated: rows.micros(7), tags: rows.texts(8), favCount: rows.i64(9),
			favorited: rows.boolean(10), username: rows.str(11), bio: rows.nstr(12), image: rows.nstr(13),
			following: rows.boolean(14)}
		s.authorID = rows.i64(1)
		return rows.err
	}
}

func readIDAuthor(s *opState) func(*pgRows) error {
	return func(rows *pgRows) error {
		if rows.Next() {
			s.found = true
			s.id, s.authorID = rows.i64(0), rows.i64(1)
			return rows.err
		}
		return nil
	}
}

// writeTx runs writes in one transaction. A group of one is the retry of a
// request that failed inside a group.
func (w *worker) writeTx(writes []*opState) error {
	for _, s := range writes {
		s.found, s.id, s.authorID = false, 0, 0
	}
	sb := &stmtBatch{}
	sb.exec("BEGIN")
	for _, s := range writes {
		w.queueWrite(sb, s)
	}
	sb.exec("COMMIT")
	t0 := statNow()
	err := w.run1(sb)
	statTx(t0)
	if err != nil {
		w.rollback()
	}
	return err
}

// writePhase commits the writes, then answers those that need no read and
// returns those that do.
func (w *worker) writePhase(writes []*opState) (reads []*opState) {
	markRepeatedFavs(writes)
	if err := w.writeTx(writes); err != nil {
		if len(writes) == 1 {
			w.settleFailed(writes[0], err)
			return nil
		}
		statGroupFail()
		// Something failed in the group: nothing of it was committed, so
		// run each request alone and let only the guilty one fail.
		for _, s := range writes {
			var err error
			for try := 0; try < 3; try++ {
				if err = w.writeTx([]*opState{s}); err == nil || !retryable(err) {
					break
				}
			}
			if err != nil {
				w.settleFailed(s, err)
				continue
			}
			reads = w.settle(s, reads)
		}
		return reads
	}
	for _, s := range writes {
		reads = w.settle(s, reads)
	}
	return reads
}

func retryable(err error) bool {
	c := pgCode(err)
	return c == "40P01" || c == "40001"
}

// settleFailed answers a write that Postgres refused.
func (w *worker) settleFailed(s *opState, err error) {
	op := s.op
	switch {
	case pgCode(err) == "23505":
		conduit.Fail(op, 422, "already taken")
	default:
		conduit.Fail(op, 500, "internal error")
	}
	s.done()
}

// settle answers a committed write, or returns it for the read that answers it.
func (w *worker) settle(s *opState, reads []*opState) []*opState {
	op, c := s.op, s.c
	fail := func(status int, msg string) []*opState {
		conduit.Fail(op, status, msg)
		s.done()
		return reads
	}
	switch c.Endpoint {
	case conduit.Register:
		if !s.found {
			return fail(422, "username or email already taken")
		}
		w.db.respondUser(s, 201, true)
	case conduit.UpdateUser:
		if !s.found {
			return fail(401, "user not found")
		}
		w.db.respondUser(s, 200, false)
	case conduit.Follow, conduit.Unfollow:
		if !s.found {
			return fail(404, "profile not found")
		}
		op.Resp = append(op.Resp, `{"profile":`...)
		op.Resp = appendProfile(op.Resp, &s.user, c.Endpoint == conduit.Follow)
		op.Resp = append(op.Resp, '}')
	case conduit.Favorite, conduit.Unfavorite:
		if !s.found {
			return fail(404, "article not found")
		}
		if s.inTxCount {
			respondArticle(s, 200)
			break
		}
		return append(reads, s) // answered by the post-commit read of its article's favorite count
	case conduit.UpdateArticle:
		if !s.found {
			return fail(404, "article not found")
		}
		if s.authorID != c.Viewer {
			return fail(403, "forbidden")
		}
		respondArticle(s, 200)
	case conduit.CreateArticle:
		if !s.found {
			return fail(500, "internal error")
		}
		respondArticle(s, 201)
	case conduit.DeleteArticle:
		if !s.found {
			return fail(404, "article not found")
		}
		if s.authorID != c.Viewer {
			return fail(403, "forbidden")
		}
		op.Status = 204
	case conduit.CreateComment:
		if !s.found {
			return fail(404, "article not found")
		}
		op.Status = 201
		op.Resp = append(op.Resp, `{"comment":`...)
		op.Resp = appendComment(op.Resp, &s.com, false)
		op.Resp = append(op.Resp, '}')
	case conduit.DeleteComment:
		if !s.found {
			return fail(404, "comment not found")
		}
		if s.authorID != c.Viewer {
			return fail(403, "forbidden")
		}
		op.Status = 204
	}
	s.done()
	return reads
}

func respondArticle(s *opState, status int) {
	op := s.op
	op.Status = status
	op.Resp = append(op.Resp, `{"article":`...)
	op.Resp = appendArticle(op.Resp, &s.art, true)
	op.Resp = append(op.Resp, '}')
}

// qFavSettle answers committed favorites and unfavorites. The statements left the favorite count out; it is read here,
// after the commit and in the flush's read round trip, once per distinct article. Nothing outlives the flush.
func (w *worker) qFavSettle(sb *stmtBatch, ops []*opState) func() {
	ids := favArticleIDs(ops)
	counts := make(map[int64]int64, len(ids))
	sb.query(sqlFavCounts, []any{ids}, readFavCounts(counts))
	return func() {
		for _, s := range ops {
			s.art.favCount = counts[s.art.id] // an article with no favorites has no row
			respondArticle(s, 200)
			s.done()
		}
	}
}

// favArticleIDs lists the distinct article ids of ops.
func favArticleIDs(ops []*opState) []int64 {
	ids := make([]int64, 0, len(ops))
	for _, s := range ops {
		ids = append(ids, s.art.id)
	}
	slices.Sort(ids)
	return slices.Compact(ids)
}

// readFavCounts collects sqlFavCounts rows (article id, count) into counts.
func readFavCounts(counts map[int64]int64) func(*pgRows) error {
	return func(rows *pgRows) error {
		for rows.Next() {
			counts[rows.i64(0)] = rows.i64(1)
		}
		return rows.err
	}
}

// markRepeatedFavs flags the favorite and unfavorite requests that share a (viewer, article) with another one in
// writes, or all of them when writes also update or delete an article: their count stays inside the transaction, so each sees the effect of the ones before it. The mark outlives
// the group's retries, which run each request alone.
func markRepeatedFavs(writes []*opState) {
	n, rewrites := 0, false
	for _, s := range writes {
		switch s.c.Endpoint {
		case conduit.Favorite, conduit.Unfavorite:
			n++
		case conduit.UpdateArticle, conduit.DeleteArticle:
			rewrites = true
		}
	}
	if rewrites { // a rename or a delete in the flush changes which article, or whether one, a later count would find
		for _, s := range writes {
			if e := s.c.Endpoint; e == conduit.Favorite || e == conduit.Unfavorite {
				s.inTxCount = true
			}
		}
		return
	}
	if n < 2 {
		return
	}
	type key struct {
		viewer int64
		slug   string
	}
	seen := make(map[key]*opState, n)
	for _, s := range writes {
		if e := s.c.Endpoint; e != conduit.Favorite && e != conduit.Unfavorite {
			continue
		}
		k := key{s.c.Viewer, string(s.c.Slug)}
		if first, ok := seen[k]; ok {
			first.inTxCount, s.inTxCount = true, true
		} else {
			seen[k] = s
		}
	}
}
