package main

// sql.go holds the prepared statements: single-request read statements,
// coalesced batched read statements (stBatch*), shared-enrichment list
// statements (stShare*), and group-committed write statements.

import "strings"

const (
	articleListSelect = `SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
              FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       ($1::bigint <> 0 AND EXISTS (SELECT 1 FROM favorites f WHERE f.user_id = $1 AND f.article_id = a.id)) AS favorited,
       u.username, u.bio, u.image,
       ($1::bigint <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id)) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id`

	articleFullSelect = `SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
              FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       ($1::bigint <> 0 AND EXISTS (SELECT 1 FROM favorites f WHERE f.user_id = $1 AND f.article_id = a.id)) AS favorited,
       u.username, u.bio, u.image,
       ($1::bigint <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id)) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id`

	listAll        = articleListSelect + ` WHERE a.id IN (SELECT * FROM (SELECT p.id FROM articles p ORDER BY p.id DESC LIMIT $2 OFFSET $3) page LIMIT 100) ORDER BY a.id DESC`
	countAll       = `SELECT CASE WHEN EXISTS (SELECT 1 FROM articles a ORDER BY a.id OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM articles a) END AS count`
	listByTag      = articleListSelect + ` WHERE a.id IN (SELECT * FROM (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) page LIMIT 100) ORDER BY a.id DESC`
	countByTag     = `SELECT count(*) AS count FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s`
	listByAuthor   = articleListSelect + ` WHERE a.id IN (SELECT * FROM (SELECT p.id FROM articles p WHERE p.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY p.id DESC LIMIT $2 OFFSET $3) page LIMIT 100) ORDER BY a.id DESC`
	countByAuthor  = `SELECT count(*) AS count FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s`
	listByFavorite = `SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
              FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       ($1::bigint <> 0 AND a.id = ANY(ARRAY(SELECT vf.article_id FROM favorites vf WHERE vf.user_id = $1))) AS favorited,
       u.username, u.bio, u.image,
       ($1::bigint <> 0 AND a.author_id = ANY(ARRAY(SELECT vo.followee_id FROM follows vo WHERE vo.follower_id = $1))) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
  WHERE a.id IN (SELECT * FROM (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) page LIMIT 100) ORDER BY a.id DESC`
	countByFavorite = `SELECT count(*) AS count FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s`
	listFeed        = articleListSelect + ` WHERE a.id IN (SELECT * FROM (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT (LEAST($2::bigint::numeric + $3::bigint::numeric, 9223372036854775807)::bigint)) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) page LIMIT 100) ORDER BY a.id DESC`
	countFeed       = `SELECT count(*) AS count FROM (SELECT 1 FROM articles a WHERE a.author_id = ANY(ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1)) ORDER BY a.author_id, a.id DESC LIMIT 1000) s`

	articleBySlug = articleFullSelect + ` WHERE a.slug = $2`
	articleByID   = articleFullSelect + ` WHERE a.id = $2`
)

var listStatements = func() map[string]string {
	statements := make(map[string]string, 5)
	for _, pair := range [][2]string{{listAll, countAll}, {listByTag, countByTag}, {listByAuthor, countByAuthor}, {listByFavorite, countByFavorite}, {listFeed, countFeed}} {
		count := pair[1]
		if count != countAll && count != countFeed {
			count = strings.ReplaceAll(count, "$1", "$4")
		}
		statements[pair[0]] = `WITH total AS (` + count + `) SELECT total.count,page.* FROM total LEFT JOIN LATERAL (` + pair[0] + `) page ON true ORDER BY page.id DESC`
	}
	return statements
}()

type stmtID uint8

const (
	// Single-request read statements.
	stTags stmtID = iota
	stUserByID
	stUserByEmail
	stProfile
	stListAll
	stListTag
	stListAuthor
	stListFavorite
	stListFeed
	stArticleBySlug
	stComments

	// Coalesced batch read statements (unnest WITH ORDINALITY + CROSS JOIN LATERAL).
	stBatchUserByID
	stBatchUserByEmail
	stBatchProfile
	stBatchListAll
	stBatchListTag
	stBatchListAuthor
	stBatchListFavorite
	stBatchListFeed
	stBatchArticleBySlug
	stBatchComments

	// Shared-enrichment list statements (deduplicated count, page, and article enrichment).
	stShareListAll
	stShareListTag
	stShareListAuthor
	stShareListFavorite

	// Write statements.
	stRegister
	stUserUpdate
	stFollow
	stUnfollow
	stArticleCreate
	stArticleUpdate
	stArticleDelete
	stFavorite
	stUnfavorite
	stCommentCreate
	stCommentDelete
	numStmts

	firstWriteStmt = stRegister
)

// Parameter type codes: i = int8, t = text, a = text[], I = int8[].
type stmtDef struct{ sql, params string }

func articleCols(src, viewer, count, favorited string) string {
	return src + `.id, ` + src + `.slug, ` + src + `.title, ` + src + `.description, ` + src + `.body, ` + src + `.created_at, ` + src + `.updated_at,
 ARRAY(SELECT (SELECT tg.name FROM tags tg WHERE tg.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = ` + src + `.id ORDER BY name),
 ` + count + `, ` + favorited + `,
 u.username, u.bio, u.image,
 (` + viewer + `::bigint <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ` + viewer + ` AND fo.followee_id = ` + src + `.author_id))`
}

func feedStatement() string {
	const exists = `($1::bigint <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id)) AS following`
	s := listStatements[listFeed]
	if strings.Count(s, exists) != 1 {
		panic("feed statement: following expression not found")
	}
	return strings.Replace(s, exists, "true AS following", 1)
}

// lateralize replaces $1, $2, ... in sql with r.p1, r.p2, ...
func lateralize(sql string) string {
	var b strings.Builder
	b.Grow(len(sql) + 32)
	for i := 0; i < len(sql); i++ {
		if sql[i] == '$' && i+1 < len(sql) && sql[i+1] >= '1' && sql[i+1] <= '9' {
			b.WriteString("r.p")
		} else {
			b.WriteByte(sql[i])
		}
	}
	return b.String()
}

// makeBatchStmt wraps a single-request read query into a multi-request unnest query
// returning r.ord::bigint as the final column.
func makeBatchStmt(singleSQL, params, orderTail string) stmtDef {
	var args, names, batchParams strings.Builder
	for i := 0; i < len(params); i++ {
		if i > 0 {
			args.WriteByte(',')
			names.WriteByte(',')
		}
		idx := string(rune('1' + i))
		if params[i] == 'i' {
			args.WriteString("$" + idx + "::bigint[]")
			batchParams.WriteByte('I')
		} else {
			args.WriteString("$" + idx + "::text[]")
			batchParams.WriteByte('a')
		}
		names.WriteString("p" + idx)
	}
	q := `SELECT q.*, r.ord::bigint FROM unnest(` + args.String() + `) WITH ORDINALITY AS r(` + names.String() + `, ord) CROSS JOIN LATERAL (` + lateralize(singleSQL) + `) q ORDER BY r.ord`
	if orderTail != "" {
		q += ", " + orderTail
	}
	return stmtDef{sql: q, params: batchParams.String()}
}

const sharedEnrichedTail = `article_ids AS MATERIALIZED (SELECT DISTINCT id FROM counted_pages WHERE id IS NOT NULL),
 article_tag_arrays AS MATERIALIZED (
  SELECT at.article_id, array_agg(t.name ORDER BY t.name) AS tags
  FROM article_ids i
  JOIN article_tags at ON at.article_id = i.id
  JOIN tags t ON t.id = at.tag_id
  GROUP BY at.article_id),
 enriched AS MATERIALIZED (
  SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id,
         COALESCE(ata.tags, ARRAY[]::text[]) AS tags,
         (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fc,
         u.username, u.bio, u.image
  FROM article_ids i
  JOIN articles a ON a.id = i.id
  JOIN users u ON u.id = a.author_id
  LEFT JOIN article_tag_arrays ata ON ata.article_id = a.id)`

func makeShareListAll() stmtDef {
	sql := `WITH requests AS MATERIALIZED (
  SELECT r.p1, r.p2, r.p3, r.ord,
         CASE WHEN r.p1 = 0 THEN ARRAY[]::bigint[] ELSE ARRAY(SELECT vf.article_id FROM favorites vf WHERE vf.user_id = r.p1) END AS favs,
         CASE WHEN r.p1 = 0 THEN ARRAY[]::bigint[] ELSE ARRAY(SELECT vo.followee_id FROM follows vo WHERE vo.follower_id = r.p1) END AS fols
  FROM unnest($1::bigint[], $2::bigint[], $3::bigint[]) WITH ORDINALITY AS r(p1, p2, p3, ord)),
 total AS MATERIALIZED (
  SELECT CASE WHEN EXISTS (SELECT 1 FROM articles a ORDER BY a.id OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM articles a) END AS n),
 distinct_pages AS MATERIALIZED (
  SELECT DISTINCT p2, p3 FROM requests),
 counted_pages AS MATERIALIZED (
  SELECT dp.p2, dp.p3, p.id FROM distinct_pages dp
  LEFT JOIN LATERAL (SELECT id FROM (SELECT a2.id FROM articles a2 ORDER BY a2.id DESC LIMIT 100 OFFSET dp.p3) b ORDER BY id DESC LIMIT dp.p2) p ON true),
 ` + sharedEnrichedTail + `
 SELECT total.n, e.id, e.slug, e.title, e.description, e.created_at, e.updated_at,
        COALESCE(e.tags, ARRAY[]::text[]), COALESCE(e.fc, 0::bigint),
        COALESCE(e.id = ANY(r.favs), false),
        e.username, e.bio, e.image,
        COALESCE(e.author_id = ANY(r.fols), false),
        r.ord::bigint
 FROM requests r
 CROSS JOIN total
 JOIN counted_pages cp ON cp.p2 = r.p2 AND cp.p3 = r.p3
 LEFT JOIN enriched e ON e.id = cp.id
 ORDER BY r.ord, e.id DESC`
	return stmtDef{sql: sql, params: "III"}
}

func makeShareListFiltered(resolveSQL, countSQL, pageSQL string) stmtDef {
	sql := `WITH requests AS MATERIALIZED (
  SELECT r.p1, r.p2, r.p3, r.p4, r.ord,
         CASE WHEN r.p1 = 0 THEN ARRAY[]::bigint[] ELSE ARRAY(SELECT vf.article_id FROM favorites vf WHERE vf.user_id = r.p1) END AS favs,
         CASE WHEN r.p1 = 0 THEN ARRAY[]::bigint[] ELSE ARRAY(SELECT vo.followee_id FROM follows vo WHERE vo.follower_id = r.p1) END AS fols
  FROM unnest($1::bigint[], $2::bigint[], $3::bigint[], $4::text[]) WITH ORDINALITY AS r(p1, p2, p3, p4, ord)),
 distinct_filters AS MATERIALIZED (
  SELECT f.p4, f.fid,
         CASE WHEN f.fid IS NULL THEN 0::bigint ELSE ` + countSQL + ` END AS n
  FROM (SELECT p4, (` + resolveSQL + `) AS fid FROM (SELECT DISTINCT p4 FROM requests) d) f),
 distinct_pages AS MATERIALIZED (
  SELECT DISTINCT r.p2, r.p3, r.p4, df.fid, df.n
  FROM requests r JOIN distinct_filters df ON df.p4 = r.p4),
 counted_pages AS MATERIALIZED (
  SELECT dp.p2, dp.p3, dp.p4, dp.n, p.id FROM distinct_pages dp
  LEFT JOIN LATERAL (` + pageSQL + `) p ON dp.fid IS NOT NULL),
 ` + sharedEnrichedTail + `
 SELECT cp.n, e.id, e.slug, e.title, e.description, e.created_at, e.updated_at,
        COALESCE(e.tags, ARRAY[]::text[]), COALESCE(e.fc, 0::bigint),
        COALESCE(e.id = ANY(r.favs), false),
        e.username, e.bio, e.image,
        COALESCE(e.author_id = ANY(r.fols), false),
        r.ord::bigint
 FROM requests r
 JOIN counted_pages cp ON cp.p2 = r.p2 AND cp.p3 = r.p3 AND cp.p4 = r.p4
 LEFT JOIN enriched e ON e.id = cp.id
 ORDER BY r.ord, e.id DESC`
	return stmtDef{sql: sql, params: "IIIa"}
}

const slugify = `trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g')))`

const (
	sqlUserByID    = `SELECT username, email, bio, image FROM users WHERE id = $1`
	sqlUserByEmail = `SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1`
	sqlProfile     = `SELECT u.username, u.bio, u.image,
 ($1::bigint <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id))
FROM users u WHERE u.username = $2`
	sqlComments = `SELECT c.id,c.body,c.created_at,c.updated_at,c.username,c.bio,c.image,COALESCE(c.following,false)
 FROM articles a LEFT JOIN LATERAL (
  SELECT c.id,c.body,c.created_at,c.updated_at,u.username,u.bio,u.image,
   ($1::bigint <> 0 AND c.author_id IN (SELECT vo.followee_id FROM follows vo WHERE vo.follower_id = $1)) AS following
  FROM comments c JOIN users u ON u.id=c.author_id WHERE c.article_id=a.id
  ORDER BY c.created_at DESC,c.id DESC LIMIT 100
 ) c ON true WHERE a.slug=$2 ORDER BY c.created_at DESC,c.id DESC`
)

var stmts = [numStmts]stmtDef{
	stTags:          {`SELECT ARRAY(SELECT name FROM tags ORDER BY name)`, ""},
	stUserByID:      {sqlUserByID, "i"},
	stUserByEmail:   {sqlUserByEmail, "t"},
	stProfile:       {sqlProfile, "it"},
	stListAll:       {listStatements[listAll], "iii"},
	stListTag:       {listStatements[listByTag], "iiit"},
	stListAuthor:    {listStatements[listByAuthor], "iiit"},
	stListFavorite:  {listStatements[listByFavorite], "iiit"},
	stListFeed:      {feedStatement(), "iii"},
	stArticleBySlug: {articleBySlug, "it"},
	stComments:      {sqlComments, "it"},

	// Coalesced batch statements.
	stBatchUserByID:      makeBatchStmt(sqlUserByID, "i", ""),
	stBatchUserByEmail:   makeBatchStmt(sqlUserByEmail, "t", ""),
	stBatchProfile:       makeBatchStmt(sqlProfile, "it", ""),
	stBatchListAll:       makeBatchStmt(listStatements[listAll], "iii", "q.id DESC"),
	stBatchListTag:       makeBatchStmt(listStatements[listByTag], "iiit", "q.id DESC"),
	stBatchListAuthor:    makeBatchStmt(listStatements[listByAuthor], "iiit", "q.id DESC"),
	stBatchListFavorite:  makeBatchStmt(listStatements[listByFavorite], "iiit", "q.id DESC"),
	stBatchListFeed:      makeBatchStmt(feedStatement(), "iii", "q.id DESC"),
	stBatchArticleBySlug: makeBatchStmt(articleBySlug, "it", ""),
	stBatchComments:      makeBatchStmt(sqlComments, "it", "q.created_at DESC, q.id DESC"),

	// Shared-enrichment list statements.
	stShareListAll: makeShareListAll(),
	stShareListTag: makeShareListFiltered(
		`SELECT t.id FROM tags t WHERE t.name = d.p4`,
		`(SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = f.fid LIMIT 1000) s)`,
		`SELECT id FROM (SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = dp.fid ORDER BY at.article_id DESC LIMIT 100 OFFSET dp.p3) b ORDER BY id DESC LIMIT dp.p2`,
	),
	stShareListAuthor: makeShareListFiltered(
		`SELECT u.id FROM users u WHERE u.username = d.p4`,
		`(SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = f.fid LIMIT 1000) s)`,
		`SELECT id FROM (SELECT a2.id FROM articles a2 WHERE a2.author_id = dp.fid ORDER BY a2.id DESC LIMIT 100 OFFSET dp.p3) b ORDER BY id DESC LIMIT dp.p2`,
	),
	stShareListFavorite: makeShareListFiltered(
		`SELECT u.id FROM users u WHERE u.username = d.p4`,
		`(SELECT count(*) FROM (SELECT 1 FROM favorites fv WHERE fv.user_id = f.fid LIMIT 1000) s)`,
		`SELECT id FROM (SELECT fv.article_id AS id FROM favorites fv WHERE fv.user_id = dp.fid ORDER BY fv.article_id DESC LIMIT 100 OFFSET dp.p3) b ORDER BY id DESC LIMIT dp.p2`,
	),

	// Write statements.
	stRegister: {`INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)
ON CONFLICT DO NOTHING RETURNING id, username, email, bio, image`, "ttt"},
	stUserUpdate: {`WITH clash AS (SELECT EXISTS (SELECT 1 FROM users WHERE id <> $1 AND (email = $2 OR username = $3)) AS c),
 w AS (UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
       password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
       WHERE id = $1 AND NOT (SELECT c FROM clash) RETURNING username, email, bio, image)
SELECT clash.c, w.username, w.email, w.bio, w.image FROM clash LEFT JOIN w ON true`, "ittttt"},
	stFollow: {`WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2),
 w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING)
SELECT username, bio, image FROM t`, "it"},
	stUnfollow: {`WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2),
 w AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM t))
SELECT username, bio, image FROM t`, "it"},
	stArticleCreate: {`WITH n AS (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id),
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
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
 ARRAY(SELECT name FROM all_tags ORDER BY name), 0::bigint, false,
 u.username, u.bio, u.image,
 ($1::bigint <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id))
FROM a JOIN users u ON u.id = a.author_id`, "ittta"},
	stArticleUpdate: {`WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1),
 w AS (UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body),
       slug = CASE WHEN $2::text IS NULL THEN slug ELSE ` + slugify + ` || '-' || id END,
       updated_at = now()
       WHERE id = (SELECT id FROM t WHERE author_id = $5)
       RETURNING id, slug, title, description, body, created_at, updated_at, author_id)
SELECT t.author_id, ` + articleCols("w", "$5", `(SELECT count(*) FROM favorites f WHERE f.article_id = w.id)`,
		`($5::bigint <> 0 AND EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = w.id AND f.user_id = $5))`) + `
FROM t LEFT JOIN w ON true LEFT JOIN users u ON u.id = w.author_id`, "tttti"},
	stArticleDelete: {`WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1),
 w AS (DELETE FROM articles WHERE id = (SELECT id FROM t WHERE author_id = $2))
SELECT author_id FROM t`, "ti"},
	stFavorite: {`WITH t AS (SELECT id, slug, title, description, body, created_at, updated_at, author_id FROM articles WHERE slug = $2),
 w AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING RETURNING 1)
SELECT ` + articleCols("t", "$1", `(SELECT count(*) FROM favorites f WHERE f.article_id = t.id) + (SELECT count(*) FROM w)`, `true`) + `
FROM t JOIN users u ON u.id = t.author_id`, "it"},
	stUnfavorite: {`WITH t AS (SELECT id, slug, title, description, body, created_at, updated_at, author_id FROM articles WHERE slug = $2),
 w AS (DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM t) RETURNING 1)
SELECT ` + articleCols("t", "$1", `(SELECT count(*) FROM favorites f WHERE f.article_id = t.id) - (SELECT count(*) FROM w)`, `false`) + `
FROM t JOIN users u ON u.id = t.author_id`, "it"},
	stCommentCreate: {`WITH c AS (INSERT INTO comments (article_id, author_id, body) SELECT id, $2, $3 FROM articles WHERE slug = $1
           RETURNING id, body, created_at, updated_at, author_id)
SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
  FROM c JOIN users u ON u.id = c.author_id`, "tit"},
	stCommentDelete: {`WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
                WHERE c.id = $1 AND a.slug = $2),
 w AS (DELETE FROM comments WHERE id = (SELECT id FROM t WHERE author_id = $3))
SELECT author_id FROM t`, "iti"},
}

// batchStmtFor maps a single-request read statement ID to its batched counterpart.
func batchStmtFor(st stmtID) (stmtID, bool) {
	if st >= stUserByID && st <= stComments {
		return stBatchUserByID + (st - stUserByID), true
	}
	return 0, false
}

// shareStmtFor maps a list read statement ID to its shared-enrichment counterpart.
func shareStmtFor(st stmtID) (stmtID, bool) {
	if st >= stListAll && st <= stListFavorite {
		return stShareListAll + (st - stListAll), true
	}
	return 0, false
}
