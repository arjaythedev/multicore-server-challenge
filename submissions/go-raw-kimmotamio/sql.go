package main

// sql.go: the statements and the functions that render their rows as JSON.
//
// Read statements take arrays: $1 is the request ordinal, the rest are the per-request parameters,
// and every row starts with the ordinal. The per-request SQL is the reference SQL from SPEC.md with
// the page cut before the per-article work.

// articleCols renders the Article columns for row source a (with alias u for its author):
// slug, title, description, [body,] created_at, updated_at, tags, favorites_count, favorited,
// username, bio, image, following. v is the viewer expression.
func articleCols(a, v string, body bool) string {
	s := a + `.slug, ` + a + `.title, ` + a + `.description, `
	if body {
		s += a + `.body, `
	}
	return s + a + `.created_at, ` + a + `.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = ` + a + `.id ORDER BY name),
 (SELECT count(*) FROM favorites f WHERE f.article_id = ` + a + `.id),
 (` + v + ` <> 0 AND EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = ` + a + `.id AND f.user_id = ` + v + `)),
 u.username, u.bio, u.image,
 (` + v + ` <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ` + v + ` AND fo.followee_id = ` + a + `.author_id))`
}

// listSQL builds a batched list statement from a capped-count expression and a page-of-ids source,
// both of which may refer to r.v, r.s, r.lim and r.off. The count sits behind OFFSET 0 so the planner
// cannot pull it up and evaluate it once per article row; a count that uses no request parameter
// becomes an InitPlan, evaluated once per statement. Every request yields at least one row (the
// count), with NULL article columns when the page is empty.
func listSQL(withStr bool, countSrc, pageSrc, following string) string {
	params := `unnest($1::int4[], $2::int8[], $3::int8[], $4::int8[]) AS r(i, v, lim, off)`
	if withStr {
		params = `unnest($1::int4[], $2::int8[], $3::int8[], $4::int8[], $5::text[]) AS r(i, v, lim, off, s)`
	}
	cols := articleCols("a", "r.v", false)
	if following != "" {
		// Replace the trailing following expression.
		i := len(cols) - 1
		depth := 0
		for ; i >= 0; i-- {
			if cols[i] == ')' {
				depth++
			} else if cols[i] == '(' {
				depth--
				if depth == 0 {
					break
				}
			}
		}
		cols = cols[:i] + following
	}
	return `SELECT r.i, c.n, x.* FROM ` + params + `
 CROSS JOIN LATERAL (SELECT ` + countSrc + ` AS n OFFSET 0) c
 LEFT JOIN LATERAL (
   SELECT ` + cols + `
   FROM (` + pageSrc + `) p JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id
   ORDER BY a.id DESC) x ON true`
}

// cappedCount is SPEC.md's count(*) over (src LIMIT 1000).
func cappedCount(src string) string {
	return `(SELECT count(*) FROM (` + src + ` LIMIT 1000) s)`
}

// cappedCountBig is the same value for sources that usually exceed the cap: a 1,000th row proves the
// cap without aggregating; otherwise the (small) set is counted.
func cappedCountBig(src string) string {
	return `(CASE WHEN EXISTS (` + src + ` OFFSET 999) THEN 1000::bigint ELSE (SELECT count(*) FROM (` + src + `) s) END)`
}

const slugify = `trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g')))`

var readSpecs = [nReadKinds]kindSpec{
	kTags: {
		// The tag list depends on no request parameter, so Postgres evaluates it once per statement
		// (an InitPlan) for the requests in it.
		sql: `SELECT r.i, (SELECT array_agg(t.name ORDER BY t.name) FROM tags t)
 FROM unnest($1::int4[]) AS r(i)`,
		row: func(r *dbReq, v [][]byte) {
			b := *r.buf
			b = append(b, `{"tags":`...)
			if v[0] == nil {
				b = append(b, "[]"...)
			} else {
				b = appendTextArrayJSON(b, v[0])
			}
			*r.buf = append(b, '}')
		},
		finish: func(r *dbReq) {
			if r.rows == 0 {
				r.status = 500
			}
		},
	},
	kArticle: {
		sql: `SELECT r.i, ` + articleCols("a", "r.v", true) + `
 FROM unnest($1::int4[], $2::int8[], $3::text[]) AS r(i, v, s)
 JOIN articles a ON a.slug = r.s JOIN users u ON u.id = a.author_id`,
		params: []paramKind{pViewer, pStr},
		row:    rowArticleWrapped,
		finish: finish404,
	},
	kComments: {
		sql: `SELECT r.i, c.id, c.body, c.created_at, c.updated_at, c.username, c.bio, c.image, c.following
 FROM unnest($1::int4[], $2::int8[], $3::text[]) AS r(i, v, s)
 JOIN articles a ON a.slug = r.s
 LEFT JOIN LATERAL (
   SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
          (r.v <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = c.author_id)) AS following
     FROM comments c JOIN users u ON u.id = c.author_id
    WHERE c.article_id = a.id
    ORDER BY c.created_at DESC, c.id DESC
    LIMIT 100) c ON true`,
		params: []paramKind{pViewer, pStr},
		row: func(r *dbReq, v [][]byte) {
			b := *r.buf
			if r.rows == 1 {
				b = append(b, `{"comments":[`...)
			}
			if v[0] != nil {
				if r.flag {
					b = append(b, ',')
				}
				r.flag = true
				b = appendComment(b, v)
			}
			*r.buf = b
		},
		finish: func(r *dbReq) {
			if r.rows == 0 {
				r.status = 404
				return
			}
			*r.buf = append(*r.buf, "]}"...)
		},
	},
	kProfile: {
		sql: `SELECT r.i, u.username, u.bio, u.image,
        (r.v <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = u.id))
 FROM unnest($1::int4[], $2::int8[], $3::text[]) AS r(i, v, s)
 JOIN users u ON u.username = r.s`,
		params: []paramKind{pViewer, pStr},
		row: func(r *dbReq, v [][]byte) {
			b := append(*r.buf, `{"profile":`...)
			b = appendProfile(b, v[0], v[1], v[2], decBool(v[3]))
			*r.buf = append(b, '}')
		},
		finish: finish404,
	},
	kUser: {
		sql: `SELECT r.i, u.username, u.email, u.bio, u.image
 FROM unnest($1::int4[], $2::int8[]) AS r(i, id) JOIN users u ON u.id = r.id`,
		params: []paramKind{pID},
		row: func(r *dbReq, v [][]byte) {
			*r.buf = appendUserOpen(*r.buf, v[0], v[1], v[2], v[3])
		},
		finish: func(r *dbReq) {
			if r.rows == 0 {
				r.status = 401
			}
		},
	},
	kLogin: {
		sql: `SELECT r.i, u.id, u.username, u.email, u.bio, u.image, u.password_hash
 FROM unnest($1::int4[], $2::text[]) AS r(i, s) JOIN users u ON u.email = r.s`,
		params: []paramKind{pStr},
		row: func(r *dbReq, v [][]byte) {
			r.id = decInt8(v[0])
			r.hash = append(r.hash[:0], v[5]...)
			*r.buf = appendUserOpen(*r.buf, v[1], v[2], v[3], v[4])
		},
		finish: func(r *dbReq) {
			if r.rows == 0 {
				r.status = 401
			}
		},
	},
	kListAll: {
		// The global count depends on no request parameter: one evaluation per statement.
		sql: listSQL(false,
			cappedCountBig(`SELECT 1 FROM articles a`),
			`SELECT a.id FROM articles a ORDER BY a.id DESC LIMIT r.lim OFFSET r.off`, ""),
		params: []paramKind{pViewer, pLim, pOff},
		row:    rowList, finish: finishList,
	},
	kListTag: {
		sql: listSQL(true,
			cappedCountBig(`SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.s)`),
			`SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.s) ORDER BY at.article_id DESC LIMIT r.lim OFFSET r.off`, ""),
		params: []paramKind{pViewer, pLim, pOff, pStr},
		row:    rowList, finish: finishList,
	},
	kListAuthor: {
		sql: listSQL(true,
			cappedCount(`SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = r.s)`),
			`SELECT a.id FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = r.s) ORDER BY a.id DESC LIMIT r.lim OFFSET r.off`, ""),
		params: []paramKind{pViewer, pLim, pOff, pStr},
		row:    rowList, finish: finishList,
	},
	kListFav: {
		sql: listSQL(true,
			cappedCount(`SELECT 1 FROM favorites f WHERE f.user_id = (SELECT u.id FROM users u WHERE u.username = r.s)`),
			`SELECT f.article_id AS id FROM favorites f WHERE f.user_id = (SELECT u.id FROM users u WHERE u.username = r.s) ORDER BY f.article_id DESC LIMIT r.lim OFFSET r.off`, ""),
		params: []paramKind{pViewer, pLim, pOff, pStr},
		row:    rowList, finish: finishList,
	},
	kFeed: {
		// Every feed article's author is followed by the viewer in the same snapshot, so following is true.
		sql: listSQL(false,
			cappedCountBig(`SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v)`),
			`SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT (r.lim + r.off)) x WHERE fo.follower_id = r.v ORDER BY x.id DESC LIMIT r.lim OFFSET r.off`,
			"true"),
		params: []paramKind{pViewer, pLim, pOff},
		row:    rowList, finish: finishList,
	},
}

func finish404(r *dbReq) {
	if r.rows == 0 {
		r.status = 404
	}
}

// appendArticle renders an Article object from the articleCols layout (v[0] = slug).
func appendArticle(b []byte, v [][]byte, body bool) []byte {
	b = append(b, `{"slug":`...)
	b = appendJSONString(b, v[0])
	b = append(b, `,"title":`...)
	b = appendJSONString(b, v[1])
	b = append(b, `,"description":`...)
	b = appendJSONString(b, v[2])
	i := 3
	if body {
		b = append(b, `,"body":`...)
		b = appendJSONString(b, v[3])
		i = 4
	}
	b = append(b, `,"createdAt":`...)
	b = appendTimestamp(b, v[i])
	b = append(b, `,"updatedAt":`...)
	b = appendTimestamp(b, v[i+1])
	b = append(b, `,"tagList":`...)
	b = appendTextArrayJSON(b, v[i+2])
	b = append(b, `,"favoritesCount":`...)
	b = appendInt(b, decInt8(v[i+3]))
	b = append(b, `,"favorited":`...)
	b = appendBool(b, decBool(v[i+4]))
	b = append(b, `,"author":`...)
	b = appendProfile(b, v[i+5], v[i+6], v[i+7], decBool(v[i+8]))
	return append(b, '}')
}

func appendProfile(b []byte, username, bio, image []byte, following bool) []byte {
	b = append(b, `{"username":`...)
	b = appendJSONString(b, username)
	b = append(b, `,"bio":`...)
	b = appendJSONNullable(b, bio)
	b = append(b, `,"image":`...)
	b = appendJSONNullable(b, image)
	b = append(b, `,"following":`...)
	b = appendBool(b, following)
	return append(b, '}')
}

// appendUserOpen starts a {"user":{...}} object, leaving it open for the handler to add the token.
func appendUserOpen(b []byte, username, email, bio, image []byte) []byte {
	b = append(b, `{"user":{"username":`...)
	b = appendJSONString(b, username)
	b = append(b, `,"email":`...)
	b = appendJSONString(b, email)
	b = append(b, `,"bio":`...)
	b = appendJSONNullable(b, bio)
	b = append(b, `,"image":`...)
	b = appendJSONNullable(b, image)
	return b
}

// appendComment renders a Comment from id, body, created_at, updated_at, username, bio, image, following.
func appendComment(b []byte, v [][]byte) []byte {
	b = append(b, `{"id":`...)
	b = appendInt(b, decInt8(v[0]))
	b = append(b, `,"createdAt":`...)
	b = appendTimestamp(b, v[2])
	b = append(b, `,"updatedAt":`...)
	b = appendTimestamp(b, v[3])
	b = append(b, `,"body":`...)
	b = appendJSONString(b, v[1])
	b = append(b, `,"author":`...)
	b = appendProfile(b, v[4], v[5], v[6], v[7] != nil && decBool(v[7]))
	return append(b, '}')
}

func rowArticleWrapped(r *dbReq, v [][]byte) {
	b := append(*r.buf, `{"article":`...)
	b = appendArticle(b, v, true)
	*r.buf = append(b, '}')
}

// rowList: v[0] = count, v[1..] = list columns (NULL slug = empty page).
func rowList(r *dbReq, v [][]byte) {
	b := *r.buf
	if r.rows == 1 {
		r.count = decInt8(v[0])
		b = append(b, `{"articles":[`...)
	}
	if v[1] != nil {
		if r.flag {
			b = append(b, ',')
		}
		r.flag = true
		b = appendArticle(b, v[1:], false)
	}
	*r.buf = b
}

func finishList(r *dbReq) {
	if r.rows == 0 {
		r.status = 500
		return
	}
	b := append(*r.buf, `],"articlesCount":`...)
	b = appendInt(b, r.count)
	*r.buf = append(b, '}')
}

// ---------- writes ----------

var writeSpecs = [nWriteStmts]wSpec{
	// $1 username, $2 email, $3 hash. A duplicate inserts nothing (no row -> 422) instead of aborting the group.
	wRegister: {
		sql: `INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)
 ON CONFLICT DO NOTHING RETURNING id, username, email, bio, image`,
		oids: []uint32{oidText, oidText, oidText},
		row: func(r *dbReq, v [][]byte) {
			r.id = decInt8(v[0])
			*r.buf = appendUserOpen(*r.buf, v[1], v[2], v[3], v[4])
		},
		finish: func(r *dbReq) {
			if r.rows == 0 {
				r.status = 422
			} else {
				r.status = 201
			}
		},
	},
	// $1 id, $2 email, $3 username, $4 hash, $5 bio, $6 image (NULL keeps the value).
	// Row: clash, username, email, bio, image. A visible clash skips the update (422); a race still
	// raises 23505, which the single retry maps to 422.
	wUserUpdate: {
		sql: `WITH clash AS (SELECT EXISTS (SELECT 1 FROM users WHERE id <> $1 AND (email = $2 OR username = $3)) AS c),
 w AS (UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
       password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
       WHERE id = $1 AND NOT (SELECT c FROM clash) RETURNING username, email, bio, image)
 SELECT clash.c, w.username, w.email, w.bio, w.image FROM clash LEFT JOIN w ON true`,
		oids: []uint32{oidInt8, oidText, oidText, oidText, oidText, oidText},
		row: func(r *dbReq, v [][]byte) {
			if decBool(v[0]) {
				r.flag = true
				return
			}
			if v[1] == nil {
				return
			}
			r.id = 1
			*r.buf = appendUserOpen(*r.buf, v[1], v[2], v[3], v[4])
		},
		finish: func(r *dbReq) {
			switch {
			case r.flag:
				r.status = 422
			case r.id == 0:
				r.status = 401
			}
		},
	},
	// $1 viewer, $2 username. Returns username, bio, image (no row -> 404).
	wFollow: {
		sql: `WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2),
 w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING)
 SELECT username, bio, image FROM t`,
		oids:   []uint32{oidInt8, oidText},
		row:    func(r *dbReq, v [][]byte) { rowProfileConst(r, v, true) },
		finish: finish404,
	},
	wUnfollow: {
		sql: `WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2),
 w AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM t))
 SELECT username, bio, image FROM t`,
		oids:   []uint32{oidInt8, oidText},
		row:    func(r *dbReq, v [][]byte) { rowProfileConst(r, v, false) },
		finish: finish404,
	},
	// $1 author, $2 title, $3 description, $4 body, $5 tags. Article, tags and links in one statement;
	// the new article has no favorites yet. ON CONFLICT DO UPDATE returns the id of a tag another
	// transaction committed after this snapshot; existing tags are read without an update.
	wArticleCreate: {
		sql: `WITH n AS (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id),
 a AS (INSERT INTO articles (id, slug, author_id, title, description, body)
       SELECT n.id, ` + slugify + ` || '-' || n.id, $1, $2, $3, $4 FROM n
       RETURNING id, slug, title, description, body, created_at, updated_at, author_id),
 existing AS MATERIALIZED (SELECT id, name FROM tags WHERE name = ANY($5::text[])),
 t AS (INSERT INTO tags (name)
       SELECT name FROM (SELECT DISTINCT unnest($5::text[]) AS name) names
       WHERE NOT EXISTS (SELECT 1 FROM existing e WHERE e.name = names.name)
       ORDER BY name ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id, name),
 all_tags AS (SELECT id, name FROM existing UNION ALL SELECT id, name FROM t),
 x AS (INSERT INTO article_tags (article_id, tag_id) SELECT a.id, all_tags.id FROM a, all_tags)
 SELECT a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
   ARRAY(SELECT name FROM all_tags ORDER BY name), 0::bigint, false,
   u.username, u.bio, u.image,
   EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id)
 FROM a JOIN users u ON u.id = a.author_id`,
		oids: []uint32{oidInt8, oidText, oidText, oidText, oidTextArray},
		row:  rowArticleWrapped,
		finish: func(r *dbReq) {
			if r.rows == 0 {
				r.status = 500
			} else {
				r.status = 201
			}
		},
	},
	// $1 slug, $2 title, $3 description, $4 body (NULL keeps the value), $5 viewer.
	// Row: author_id, then the Article (NULL unless the viewer is the author).
	wArticleUpdate: {
		sql: `WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1),
 w AS (UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body),
       slug = CASE WHEN $2::text IS NULL THEN slug ELSE ` + slugify + ` || '-' || id END,
       updated_at = now()
       WHERE id = (SELECT id FROM t WHERE author_id = $5)
       RETURNING id, slug, title, description, body, created_at, updated_at, author_id)
 SELECT t.author_id, ` + articleCols("w", "$5", true) + `
 FROM t LEFT JOIN w ON true LEFT JOIN users u ON u.id = w.author_id`,
		oids:   []uint32{oidText, oidText, oidText, oidText, oidInt8},
		row:    rowOwnArticle,
		finish: finishOwn,
	},
	// $1 slug, $2 viewer. Returns the author_id if the article exists; deletes only the viewer's own.
	wArticleDelete: {
		sql: `WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1),
 w AS (DELETE FROM articles WHERE id = (SELECT id FROM t WHERE author_id = $2))
 SELECT author_id FROM t`,
		oids:   []uint32{oidText, oidInt8},
		row:    rowOwnArticle,
		finish: finishOwn,
	},
	// $1 viewer, $2 slug. The statement's own insert is invisible to its snapshot, so it is added to the count.
	wFavorite: {
		sql: `WITH t AS (SELECT id, slug, title, description, body, created_at, updated_at, author_id FROM articles WHERE slug = $2),
 w AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING RETURNING 1)
 SELECT t.slug, t.title, t.description, t.body, t.created_at, t.updated_at,
   ARRAY(SELECT (SELECT tg.name FROM tags tg WHERE tg.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = t.id ORDER BY name),
   (SELECT count(*) FROM favorites f WHERE f.article_id = t.id) + (SELECT count(*) FROM w), true,
   u.username, u.bio, u.image,
   EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = t.author_id)
 FROM t JOIN users u ON u.id = t.author_id`,
		oids:   []uint32{oidInt8, oidText},
		row:    rowArticleWrapped,
		finish: finish404,
	},
	wUnfavorite: {
		sql: `WITH t AS (SELECT id, slug, title, description, body, created_at, updated_at, author_id FROM articles WHERE slug = $2),
 w AS (DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM t) RETURNING 1)
 SELECT t.slug, t.title, t.description, t.body, t.created_at, t.updated_at,
   ARRAY(SELECT (SELECT tg.name FROM tags tg WHERE tg.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = t.id ORDER BY name),
   (SELECT count(*) FROM favorites f WHERE f.article_id = t.id) - (SELECT count(*) FROM w), false,
   u.username, u.bio, u.image,
   EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = t.author_id)
 FROM t JOIN users u ON u.id = t.author_id`,
		oids:   []uint32{oidInt8, oidText},
		row:    rowArticleWrapped,
		finish: finish404,
	},
	// $1 slug, $2 author, $3 body. Returns id, body, created_at, updated_at, username, bio, image.
	wComment: {
		sql: `WITH c AS (INSERT INTO comments (article_id, author_id, body) SELECT id, $2, $3 FROM articles WHERE slug = $1
           RETURNING id, body, created_at, updated_at, author_id)
 SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
   FROM c JOIN users u ON u.id = c.author_id`,
		oids: []uint32{oidText, oidInt8, oidText},
		row: func(r *dbReq, v [][]byte) {
			b := append(*r.buf, `{"comment":`...)
			b = appendComment(b, append(v, nil))
			*r.buf = append(b, '}')
		},
		finish: func(r *dbReq) {
			if r.rows == 0 {
				r.status = 404
			} else {
				r.status = 201
			}
		},
	},
	// $1 comment id, $2 slug, $3 viewer. Returns the author_id if the comment exists on that article.
	wCommentDelete: {
		sql: `WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
                WHERE c.id = $1 AND a.slug = $2),
 w AS (DELETE FROM comments WHERE id = (SELECT id FROM t WHERE author_id = $3))
 SELECT author_id FROM t`,
		oids:   []uint32{oidInt8, oidText, oidInt8},
		row:    rowOwnArticle,
		finish: finishOwn,
	},
}

func rowProfileConst(r *dbReq, v [][]byte, following bool) {
	b := append(*r.buf, `{"profile":`...)
	b = appendProfile(b, v[0], v[1], v[2], following)
	*r.buf = append(b, '}')
}

// rowOwnArticle: v[0] = author_id of the target; r.viewer must match. If more columns follow and
// the slug is non-NULL, the updated article is rendered.
func rowOwnArticle(r *dbReq, v [][]byte) {
	if decInt8(v[0]) != r.viewer {
		r.flag = true // forbidden
		return
	}
	if len(v) > 1 && v[1] != nil {
		rowArticleWrapped(r, v[1:])
		r.id = 1
	}
}

func finishOwn(r *dbReq) {
	switch {
	case r.rows == 0:
		r.status = 404
	case r.flag:
		r.status = 403
	case r.stmt == wArticleDelete || r.stmt == wCommentDelete:
		r.status = 204
	case r.id == 0:
		r.status = 404 // the row vanished between the lookup and the update
	}
}
