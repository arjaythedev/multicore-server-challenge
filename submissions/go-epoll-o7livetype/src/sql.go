package main

// sql.go holds the prepared statements, one per endpoint. Read statements are
// prepared on read connections and write statements on write connections
// (db.go). Each statement below is documented with its parameters, in the
// order the plan functions in api.go add them, and its result columns, in the
// order the finish functions read them.

import "strings"

// Every endpoint is one prepared statement. Mutations fold their lookups,
// ownership checks and response reads into a single data-modifying CTE, so a
// write group is a flat run of Bind/Execute messages ending in one Sync.

// The list statements and the full-article select follow SPEC.md's reference SQL.
const (
	articleListSelect = `SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id=at.tag_id) AS name
              FROM article_tags at WHERE at.article_id=a.id ORDER BY name) AS tag_list,
       fav.n AS favorites_count, fav.favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
  CROSS JOIN LATERAL (SELECT count(*) AS n, COALESCE(bool_or(f.user_id=$1),false) AS favorited
                     FROM favorites f WHERE f.article_id=a.id) fav`

	articleFullSelect = `SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id=at.tag_id) AS name
              FROM article_tags at WHERE at.article_id=a.id ORDER BY name) AS tag_list,
       fav.n AS favorites_count, fav.favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
  CROSS JOIN LATERAL (SELECT count(*) AS n, COALESCE(bool_or(f.user_id=$1),false) AS favorited
                     FROM favorites f WHERE f.article_id=a.id) fav`

	listAll         = articleListSelect + ` WHERE a.id IN (SELECT * FROM (SELECT p.id FROM articles p ORDER BY p.id DESC LIMIT $2 OFFSET $3) page LIMIT 100) ORDER BY a.id DESC`
	countAll        = `SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s`
	listByTag       = articleListSelect + ` WHERE a.id IN (SELECT * FROM (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) page LIMIT 100)` + ` ORDER BY a.id DESC`
	countByTag      = `SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s`
	listByAuthor    = articleListSelect + ` WHERE a.id IN (SELECT * FROM (SELECT p.id FROM articles p WHERE p.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY p.id DESC LIMIT $2 OFFSET $3) page LIMIT 100) ORDER BY a.id DESC`
	countByAuthor   = `SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s`
	listByFavorite  = articleListSelect + ` WHERE a.id IN (SELECT * FROM (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) page LIMIT 100)` + ` ORDER BY a.id DESC`
	countByFavorite = `SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s`
	listFeed        = articleListSelect + ` WHERE a.id IN (SELECT * FROM (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT (LEAST($2::bigint::numeric + $3::bigint::numeric, 9223372036854775807)::bigint)) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) page LIMIT 100)` + ` ORDER BY a.id DESC`
	countFeed       = `SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s`

	articleBySlug = articleFullSelect + ` WHERE a.slug = $2`
	articleByID   = articleFullSelect + ` WHERE a.id = $2`
)

// Immutable SQL templates cache query text, not query results. Literal page caps
// make the API's <=100 bound visible to PostgreSQL's generic plan estimator.
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
	// Read connections.
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
	// Write connections.
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

// Parameter type codes, checked against the server's inferred types when each
// connection prepares its statements: i = int8, t = text, a = text[].
type stmtDef struct{ sql, params string }

// articleCols renders the full Article row layout over a row source whose
// columns are id, slug, title, description, body, created_at, updated_at and
// author_id. $v is the viewer. Layout: id, slug, title, description, body,
// created_at, updated_at, tags, favorites_count, favorited, username, bio,
// image, following.
func articleCols(src, viewer, count, favorited string) string {
	return src + `.id, ` + src + `.slug, ` + src + `.title, ` + src + `.description, ` + src + `.body, ` + src + `.created_at, ` + src + `.updated_at,
 ARRAY(SELECT (SELECT tg.name FROM tags tg WHERE tg.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = ` + src + `.id ORDER BY name),
 ` + count + `, ` + favorited + `,
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ` + viewer + ` AND fo.followee_id = ` + src + `.author_id)`
}

// feedStatement is the fused feed list with following fixed to true: every
// feed article's author is one the viewer follows in the same snapshot, so the
// per-row follows lookup always succeeds. Saves about 3% of the feed's
// PostgreSQL CPU (A/B against the EXISTS form, identical rows).
func feedStatement() string {
	const exists = `EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following`
	s := listStatements[listFeed]
	if strings.Count(s, exists) != 1 {
		panic("feed statement: following expression not found")
	}
	return strings.Replace(s, exists, "true AS following", 1)
}

const slugify = `trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g')))`

var stmts = [numStmts]stmtDef{
	// No parameters. Returns one row: all tag names, sorted.
	stTags: {`SELECT ARRAY(SELECT name FROM tags ORDER BY name)`, ""},
	// $1 user id. Returns username, email, bio, image.
	stUserByID: {`SELECT username, email, bio, image FROM users WHERE id = $1`, "i"},
	// $1 email. Returns id, username, email, bio, image, password_hash.
	stUserByEmail: {`SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1`, "t"},
	// $1 viewer, $2 username. Returns username, bio, image, following.
	stProfile: {`SELECT u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id)
FROM users u WHERE u.username = $2`, "it"},
	// Lists: $1 viewer, $2 limit, $3 offset, [$4 tag, author or favoriting username].
	// Every row starts with the capped total count (see listStatements).
	stListAll:      {listStatements[listAll], "iii"},
	stListTag:      {listStatements[listByTag], "iiit"},
	stListAuthor:   {listStatements[listByAuthor], "iiit"},
	stListFavorite: {listStatements[listByFavorite], "iiit"},
	stListFeed:     {feedStatement(), "iii"},
	// $1 viewer, $2 slug. Returns the full Article layout (articleCols).
	stArticleBySlug: {articleBySlug, "it"},
	// One row per comment; one null-comment row for an existing empty thread
	// and no rows for a missing article.
	// $1 viewer, $2 slug. Returns id, body, created_at, updated_at, username, bio,
	// image, following.
	stComments: {`SELECT c.id,c.body,c.created_at,c.updated_at,c.username,c.bio,c.image,COALESCE(c.following,false)
 FROM articles a LEFT JOIN LATERAL (
  SELECT c.id,c.body,c.created_at,c.updated_at,u.username,u.bio,u.image,
   EXISTS(SELECT 1 FROM follows fo WHERE fo.follower_id=$1 AND fo.followee_id=c.author_id) AS following
  FROM comments c JOIN users u ON u.id=c.author_id WHERE c.article_id=a.id
  ORDER BY c.created_at DESC,c.id DESC LIMIT 100
 ) c ON true WHERE a.slug=$2 ORDER BY c.created_at DESC,c.id DESC`, "it"},

	// A duplicate username or email inserts nothing and returns no row, so it
	// cannot abort the other requests sharing its group transaction.
	// $1 username, $2 email, $3 password hash. Returns id, username, email, bio, image.
	stRegister: {`INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)
ON CONFLICT DO NOTHING RETURNING id, username, email, bio, image`, "ttt"},
	// Row: clash, username, email, bio, image. A visible clash skips the update
	// (422); no user gives NULLs (401). A concurrent clash still raises 23505,
	// which the group retry maps to 422.
	// $1 user id, $2 email, $3 username, $4 password hash, $5 bio, $6 image; NULL
	// keeps the current value.
	stUserUpdate: {`WITH clash AS (SELECT EXISTS (SELECT 1 FROM users WHERE id <> $1 AND (email = $2 OR username = $3)) AS c),
 w AS (UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
       password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
       WHERE id = $1 AND NOT (SELECT c FROM clash) RETURNING username, email, bio, image)
SELECT clash.c, w.username, w.email, w.bio, w.image FROM clash LEFT JOIN w ON true`, "ittttt"},
	// Follow and unfollow: $1 viewer, $2 username. Return username, bio, image.
	stFollow: {`WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2),
 w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING)
SELECT username, bio, image FROM t`, "it"},
	stUnfollow: {`WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2),
 w AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM t))
SELECT username, bio, image FROM t`, "it"},
	// Article, tags and links in one statement. ON CONFLICT DO UPDATE returns
	// the id of a tag another transaction committed after this snapshot.
	// $1 author, $2 title, $3 description, $4 body, $5 tags. Returns the full Article.
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
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id)
FROM a JOIN users u ON u.id = a.author_id`, "ittta"},
	// Row: author_id, then the full Article layout (NULL unless updated). The
	// update changes no tags, favorites or author, so the statement snapshot
	// is current for those columns.
	// $1 slug, $2 title, $3 description, $4 body (NULL keeps the value), $5 viewer.
	stArticleUpdate: {`WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1),
 w AS (UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body),
       slug = CASE WHEN $2::text IS NULL THEN slug ELSE ` + slugify + ` || '-' || id END,
       updated_at = now()
       WHERE id = (SELECT id FROM t WHERE author_id = $5)
       RETURNING id, slug, title, description, body, created_at, updated_at, author_id)
SELECT t.author_id, ` + articleCols("w", "$5", `(SELECT count(*) FROM favorites f WHERE f.article_id = w.id)`,
		`EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = w.id AND f.user_id = $5)`) + `
FROM t LEFT JOIN w ON true LEFT JOIN users u ON u.id = w.author_id`, "tttti"},
	// $1 slug, $2 viewer. Returns the author_id, if the article exists.
	stArticleDelete: {`WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1),
 w AS (DELETE FROM articles WHERE id = (SELECT id FROM t WHERE author_id = $2))
SELECT author_id FROM t`, "ti"},
	// Mutation and response in one statement. CTE writes are invisible to the
	// statement's own snapshot, so the count adds this statement's change.
	// Favorite and unfavorite: $1 viewer, $2 slug. Return the full Article layout.
	stFavorite: {`WITH t AS (SELECT id, slug, title, description, body, created_at, updated_at, author_id FROM articles WHERE slug = $2),
 w AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING RETURNING 1)
SELECT ` + articleCols("t", "$1", `(SELECT count(*) FROM favorites f WHERE f.article_id = t.id) + (SELECT count(*) FROM w)`, `true`) + `
FROM t JOIN users u ON u.id = t.author_id`, "it"},
	stUnfavorite: {`WITH t AS (SELECT id, slug, title, description, body, created_at, updated_at, author_id FROM articles WHERE slug = $2),
 w AS (DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM t) RETURNING 1)
SELECT ` + articleCols("t", "$1", `(SELECT count(*) FROM favorites f WHERE f.article_id = t.id) - (SELECT count(*) FROM w)`, `false`) + `
FROM t JOIN users u ON u.id = t.author_id`, "it"},
	// $1 slug, $2 author, $3 body. Returns id, body, created_at, updated_at, username,
	// bio, image.
	stCommentCreate: {`WITH c AS (INSERT INTO comments (article_id, author_id, body) SELECT id, $2, $3 FROM articles WHERE slug = $1
           RETURNING id, body, created_at, updated_at, author_id)
SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
  FROM c JOIN users u ON u.id = c.author_id`, "tit"},
	// $1 comment id, $2 slug, $3 viewer. Returns the author_id, if the comment exists.
	stCommentDelete: {`WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
                WHERE c.id = $1 AND a.slug = $2),
 w AS (DELETE FROM comments WHERE id = (SELECT id FROM t WHERE author_id = $3))
SELECT author_id FROM t`, "iti"},
}
