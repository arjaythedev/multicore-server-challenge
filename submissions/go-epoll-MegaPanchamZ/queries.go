package main

type sqlOp uint8

const (
	opTags sqlOp = iota
	opUserByID
	opUserByEmail
	opProfile
	opArticle
	opComments
	opListAll
	opListTag
	opListAuthor
	opListFav
	opListFeed

	opFollow
	opUnfollow
	opFavorite
	opUnfavorite
	opCommentCreate
	opArticleCreate
	opArticleUpdate
	opArticleDelete
	opCommentDelete
	opRegister
	opUserUpdate

	opUserByIDBatch
	opUserByEmailBatch
	opProfileBatch
	opArticleBatch
	opCommentsBatch
	opListAllBatch
	opListTagBatch
	opListAuthorBatch
	opListFavBatch
	opListFeedBatch

	opFollowBatch
	opUnfollowBatch
	opFavoriteBatch
	opUnfavoriteBatch
	opCommentCreateBatch

	sqlOpCount
	firstWriteOp      = opFollow
	firstBatchReadOp  = opUserByIDBatch
	firstBatchWriteOp = opFollowBatch
)

const (
	pgOIDInt8 uint32 = 20
	pgOIDText uint32 = 25
)

var (
	readBatchOIDs = [firstWriteOp][]uint32{
		opTags:        nil,
		opUserByID:    {pgOIDInt8},
		opUserByEmail: {pgOIDText},
		opProfile:     {pgOIDInt8, pgOIDText},
		opArticle:     {pgOIDInt8, pgOIDText},
		opComments:    {pgOIDInt8, pgOIDText},
		opListAll:     {pgOIDInt8, pgOIDInt8, pgOIDInt8},
		opListTag:     {pgOIDInt8, pgOIDInt8, pgOIDInt8, pgOIDText},
		opListAuthor:  {pgOIDInt8, pgOIDInt8, pgOIDInt8, pgOIDText},
		opListFav:     {pgOIDInt8, pgOIDInt8, pgOIDInt8, pgOIDText},
		opListFeed:    {pgOIDInt8, pgOIDInt8, pgOIDInt8},
	}
	commentBatchOIDs = [3]uint32{pgOIDText, pgOIDInt8, pgOIDText}
)

func toBatchReadOp(op sqlOp) sqlOp {
	return opUserByIDBatch + (op - opUserByID)
}

func isBatchableWriteOp(op sqlOp) bool {
	return op >= opFollow && op <= opCommentCreate
}

func toBatchWriteOp(op sqlOp) sqlOp {
	return opFollowBatch + (op - opFollow)
}

func writeBatchOIDs(op sqlOp) []uint32 {
	if op >= opFollow && op <= opUnfavorite {
		return readBatchOIDs[opProfile]
	}
	if op == opCommentCreate {
		return commentBatchOIDs[:]
	}
	return nil
}

const sqlArticleMetaCols = `
  ARRAY(
    SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id)
    FROM article_tags at
    WHERE at.article_id = a.id
    ORDER BY 1
  ) AS tags,
  (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
  ($1::bigint <> 0 AND EXISTS (
    SELECT 1 FROM favorites f
    WHERE f.user_id = $1::bigint AND f.article_id = a.id
  )) AS favorited,
  u.username,
  u.bio,
  u.image,
  ($1::bigint <> 0 AND EXISTS (
    SELECT 1 FROM follows fo
    WHERE fo.follower_id = $1::bigint AND fo.followee_id = a.author_id
  )) AS following`

const sqlFeedMetaCols = `
  ARRAY(
    SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id)
    FROM article_tags at
    WHERE at.article_id = a.id
    ORDER BY 1
  ) AS tags,
  (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
  EXISTS (
    SELECT 1 FROM favorites f
    WHERE f.user_id = $1::bigint AND f.article_id = a.id
  ) AS favorited,
  u.username,
  u.bio,
  u.image,
  true AS following`

const sqlArticleSummaryProj = `
SELECT
  a.slug,
  a.title,
  a.description,
  a.created_at,
  a.updated_at,` + sqlArticleMetaCols

const sqlFeedSummaryProj = `
SELECT
  a.slug,
  a.title,
  a.description,
  a.created_at,
  a.updated_at,` + sqlFeedMetaCols

const sqlSingleArticleProj = `
SELECT
  a.slug,
  a.title,
  a.description,
  a.body,
  a.created_at,
  a.updated_at,` + sqlArticleMetaCols + `
FROM articles a
JOIN users u ON u.id = a.author_id`

func buildListSQL(countSQL, pageSQL string) string {
	return `WITH c AS (SELECT ` + countSQL + ` AS n)` +
		` SELECT c.n, x.* FROM c LEFT JOIN LATERAL (` +
		sqlArticleSummaryProj +
		` FROM (SELECT * FROM (` + pageSQL + `) page LIMIT 100) p` +
		` JOIN articles a ON a.id = p.id` +
		` JOIN users u ON u.id = a.author_id` +
		` ORDER BY p.id DESC) x ON true`
}

func buildFeedSQL(countSQL, pageSQL string) string {
	return `WITH vf AS MATERIALIZED (` +
		`SELECT ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1::bigint ORDER BY fo.followee_id) AS fols` +
		`)` +
		` SELECT c.n, x.* FROM vf CROSS JOIN LATERAL (SELECT ` + countSQL + ` AS n LIMIT 1) c LEFT JOIN LATERAL (` +
		sqlFeedSummaryProj +
		` FROM (` + pageSQL + `) p` +
		` JOIN articles a ON a.id = p.id` +
		` JOIN users u ON u.id = a.author_id` +
		` ORDER BY p.id DESC) x ON true`
}

const (
	sqlCountAll = `(CASE WHEN EXISTS (SELECT 1 FROM articles ORDER BY id OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM articles) END)`

	sqlCountByTag = `((
  WITH t_target AS (SELECT t.id FROM tags t WHERE t.name = $4)
  SELECT CASE WHEN (SELECT id FROM t_target) IS NULL THEN 0::bigint
              WHEN EXISTS (
                SELECT 1 FROM article_tags at
                WHERE at.tag_id = (SELECT id FROM t_target)
                ORDER BY at.article_id ASC
                OFFSET 999 LIMIT 1
              ) THEN 1000::bigint
              ELSE (
                SELECT count(*) FROM article_tags at
                WHERE at.tag_id = (SELECT id FROM t_target)
              )
         END
))`

	sqlCountByAuthor = `(SELECT count(*) FROM (
  SELECT 1 FROM articles a
  WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $4)
  LIMIT 1000
) s)`

	sqlCountByFav = `(SELECT count(*) FROM (
  SELECT 1 FROM favorites f
  WHERE f.user_id = (SELECT u.id FROM users u WHERE u.username = $4)
  LIMIT 1000
) s)`

	sqlCountByFeed = `(SELECT count(*) FROM (
  SELECT 1 FROM articles a
  WHERE a.author_id = ANY(vf.fols)
  LIMIT 1000
) s)`

	sqlTagMapCTE = `tmap AS MATERIALIZED (
	   SELECT COALESCE(
	     CASE WHEN count(*) = max(id) THEN array_agg(name)
	          ELSE (SELECT array_agg(t2.name ORDER BY s.id) FROM generate_series(1, max(t.id)) s(id) LEFT JOIN tags t2 ON t2.id = s.id)
	     END,
	     '{}'::text[]
	   ) AS names
	   FROM (SELECT id, name FROM tags ORDER BY id) t
	 )`

	sqlPageAll = `SELECT a.id FROM articles a ORDER BY a.id DESC LIMIT $2 OFFSET $3`

	sqlPageByTag = `SELECT at.article_id AS id
FROM article_tags at
WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4)
ORDER BY at.article_id DESC
LIMIT $2 OFFSET $3`

	sqlPageByAuthor = `SELECT a.id
FROM articles a
WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $4)
ORDER BY a.id DESC
LIMIT $2 OFFSET $3`

	sqlPageByFav = `SELECT f.article_id AS id
FROM favorites f
WHERE f.user_id = (SELECT u.id FROM users u WHERE u.username = $4)
ORDER BY f.article_id DESC
LIMIT $2 OFFSET $3`

	sqlPageByFeed = `SELECT fa.id
FROM unnest(vf.fols) AS fo(followee_id)
CROSS JOIN LATERAL (
  SELECT a.id
  FROM articles a
  WHERE a.author_id = fo.followee_id
  ORDER BY a.id DESC
  LIMIT ($2 + LEAST($3, 9000000000000000000))
) fa
ORDER BY fa.id DESC
LIMIT LEAST($2, 100) OFFSET $3`
)

var sqlCatalog = [sqlOpCount]struct{ id, query string }{
	opTags: {
		"q0",
		`SELECT ARRAY(SELECT name FROM tags ORDER BY name)`,
	},
	opUserByID: {
		"q1",
		`SELECT username, email, bio, image FROM users WHERE id = $1`,
	},
	opUserByEmail: {
		"q2",
		`SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1`,
	},
	opProfile: {
		"q3",
		`SELECT u.username, u.bio, u.image,
		        ($1::bigint <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1::bigint AND fo.followee_id = u.id))
		 FROM users u WHERE u.username = $2`,
	},
	opArticle: {
		"q4",
		sqlSingleArticleProj + ` WHERE a.slug = $2`,
	},
	opComments: {
		"q5",
		`SELECT c.id, c.body, c.created_at, c.updated_at,
		        u.username, u.bio, u.image,
		        CASE WHEN c.id IS NULL OR $1::bigint = 0 THEN false
		             ELSE EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1::bigint AND fo.followee_id = c.author_id)
		        END
		 FROM articles a
		 LEFT JOIN LATERAL (
		   SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id
		   FROM comments c
		   WHERE c.article_id = a.id
		   ORDER BY c.created_at DESC, c.id DESC
		   LIMIT 100
		 ) c ON true
		 LEFT JOIN users u ON u.id = c.author_id
		 WHERE a.slug = $2
		 ORDER BY c.created_at DESC, c.id DESC`,
	},
	opListAll:    {"q6", buildListSQL(sqlCountAll, sqlPageAll)},
	opListTag:    {"q7", buildListSQL(sqlCountByTag, sqlPageByTag)},
	opListAuthor: {"q8", buildListSQL(sqlCountByAuthor, sqlPageByAuthor)},
	opListFav:    {"q9", buildListSQL(sqlCountByFav, sqlPageByFav)},
	opListFeed:   {"q10", buildFeedSQL(sqlCountByFeed, sqlPageByFeed)},

	opFollow: {
		"q11",
		`WITH target AS (
		   SELECT id, username, bio, image FROM users WHERE username = $2
		 ),
		 ins AS (
		   INSERT INTO follows (follower_id, followee_id)
		   SELECT $1, id FROM target
		   ON CONFLICT DO NOTHING
		 )
		 SELECT username, bio, image FROM target`,
	},
	opUnfollow: {
		"q12",
		`WITH target AS (
		   SELECT id, username, bio, image FROM users WHERE username = $2
		 ),
		 del AS (
		   DELETE FROM follows
		   WHERE follower_id = $1 AND followee_id = (SELECT id FROM target)
		 )
		 SELECT username, bio, image FROM target`,
	},
	opFavorite: {
		"q13",
		`WITH a AS (
		   SELECT id, slug, title, description, body, created_at, updated_at, author_id
		   FROM articles WHERE slug = $2
		 ),
		 ins AS (
		   INSERT INTO favorites (user_id, article_id)
		   SELECT $1, id FROM a
		   ON CONFLICT DO NOTHING
		   RETURNING 1
		 )
		 SELECT
		   a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
		   ARRAY(
		     SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id)
		     FROM article_tags at WHERE at.article_id = a.id
		     ORDER BY 1
		   ) AS tags,
		   (SELECT count(*) FROM favorites f WHERE f.article_id = a.id)
		     + (SELECT count(*) FROM ins) AS favorites_count,
		   true AS favorited,
		   u.username, u.bio, u.image,
		   EXISTS (
		     SELECT 1 FROM follows fo
		     WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id
		   ) AS following
		 FROM a
		 JOIN users u ON u.id = a.author_id`,
	},
	opUnfavorite: {
		"q14",
		`WITH a AS (
		   SELECT id, slug, title, description, body, created_at, updated_at, author_id
		   FROM articles WHERE slug = $2
		 ),
		 del AS (
		   DELETE FROM favorites
		   WHERE user_id = $1 AND article_id = (SELECT id FROM a)
		   RETURNING 1
		 )
		 SELECT
		   a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
		   ARRAY(
		     SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id)
		     FROM article_tags at WHERE at.article_id = a.id
		     ORDER BY 1
		   ) AS tags,
		   GREATEST(
		     (SELECT count(*) FROM favorites f WHERE f.article_id = a.id)
		       - (SELECT count(*) FROM del),
		     0::bigint
		   ) AS favorites_count,
		   false AS favorited,
		   u.username, u.bio, u.image,
		   EXISTS (
		     SELECT 1 FROM follows fo
		     WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id
		   ) AS following
		 FROM a
		 JOIN users u ON u.id = a.author_id`,
	},
	opArticleCreate: {
		"q15",
		`WITH n AS (SELECT nextval('articles_id_seq') AS id),
		 a AS (
		   INSERT INTO articles (id, slug, author_id, title, description, body)
		   SELECT n.id,
		          trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id,
		          $1, $2, $3, $4
		   FROM n
		   RETURNING id, slug, title, description, body, created_at, updated_at, author_id
		 ),
		 existing AS MATERIALIZED (
		   SELECT id, name FROM tags WHERE name = ANY($5::text[])
		 ),
		 t AS (
		   INSERT INTO tags (name)
		   SELECT name FROM (SELECT DISTINCT unnest($5::text[]) AS name) names
		   WHERE NOT EXISTS (SELECT 1 FROM existing e WHERE e.name = names.name)
		   ORDER BY name
		   ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name
		   RETURNING id, name
		 ),
		 all_tags AS (
		   SELECT id, name FROM existing
		   UNION ALL
		   SELECT id, name FROM t
		 ),
		 x AS (
		   INSERT INTO article_tags (article_id, tag_id)
		   SELECT a.id, all_tags.id FROM a, all_tags
		 )
		 SELECT
		   a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
		   ARRAY(SELECT name FROM all_tags ORDER BY name) AS tags,
		   0::bigint AS favorites_count,
		   false AS favorited,
		   u.username, u.bio, u.image,
		   false AS following
		 FROM a
		 JOIN users u ON u.id = a.author_id`,
	},
	opArticleUpdate: {
		"q16",
		`WITH cur AS (
		   SELECT id, author_id FROM articles WHERE slug = $1
		 ),
		 a AS (
		   UPDATE articles SET
		     title       = COALESCE($2, title),
		     description = COALESCE($3, description),
		     body        = COALESCE($4, body),
		     slug        = CASE
		       WHEN $2::text IS NULL THEN slug
		       ELSE trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || articles.id
		     END,
		     updated_at  = now()
		   FROM cur
		   WHERE articles.id = cur.id AND cur.author_id = $5
		   RETURNING articles.id, articles.slug, articles.title, articles.description,
		             articles.body, articles.created_at, articles.updated_at, articles.author_id
		 )
		 SELECT
		   cur.author_id,
		   a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
		   CASE WHEN a.id IS NULL THEN NULL ELSE ARRAY(
		     SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id)
		     FROM article_tags at WHERE at.article_id = a.id
		     ORDER BY 1
		   ) END AS tags,
		   CASE WHEN a.id IS NULL THEN NULL
		        ELSE (SELECT count(*) FROM favorites f WHERE f.article_id = a.id)
		   END AS favorites_count,
		   CASE WHEN a.id IS NULL THEN NULL ELSE EXISTS (
		     SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $5
		   ) END AS favorited,
		   u.username, u.bio, u.image,
		   false AS following
		 FROM cur
		 LEFT JOIN a ON true
		 LEFT JOIN users u ON u.id = a.author_id`,
	},
	opArticleDelete: {
		"q17",
		`WITH cur AS (
		   SELECT id, author_id FROM articles WHERE slug = $1
		 ),
		 del AS (
		   DELETE FROM articles USING cur
		   WHERE articles.id = cur.id AND cur.author_id = $2
		 )
		 SELECT author_id FROM cur`,
	},
	opCommentCreate: {
		"q18",
		`WITH ins AS (
		   INSERT INTO comments (article_id, author_id, body)
		   SELECT a.id, $2, $3 FROM articles a WHERE a.slug = $1
		   RETURNING id, body, created_at, updated_at, author_id
		 )
		 SELECT ins.id, ins.body, ins.created_at, ins.updated_at,
		        u.username, u.bio, u.image
		 FROM ins
		 JOIN users u ON u.id = ins.author_id`,
	},
	opCommentDelete: {
		"q19",
		`WITH cur AS (
		   SELECT c.id, c.author_id
		   FROM comments c
		   JOIN articles a ON a.id = c.article_id
		   WHERE c.id = $1 AND a.slug = $2
		 ),
		 del AS (
		   DELETE FROM comments USING cur
		   WHERE comments.id = cur.id AND cur.author_id = $3
		 )
		 SELECT author_id FROM cur`,
	},
	opRegister: {
		"q20",
		`INSERT INTO users (username, email, password_hash)
		 VALUES ($1, $2, $3)
		 ON CONFLICT DO NOTHING
		 RETURNING id, username, email, bio, image`,
	},
	opUserUpdate: {
		"q21",
		`WITH clash AS (
		   SELECT EXISTS (
		     SELECT 1 FROM users
		     WHERE id <> $1 AND (
		       ($2::text IS NOT NULL AND email = $2) OR
		       ($3::text IS NOT NULL AND username = $3)
		     )
		   ) AS taken
		 ),
		 upd AS (
		   UPDATE users SET
		     email         = COALESCE($2, email),
		     username      = COALESCE($3, username),
		     password_hash = COALESCE($4, password_hash),
		     bio           = COALESCE($5, bio),
		     image         = COALESCE($6, image)
		   FROM clash
		   WHERE users.id = $1 AND NOT clash.taken
		   RETURNING users.username, users.email, users.bio, users.image
		 )
		 SELECT clash.taken, upd.username, upd.email, upd.bio, upd.image
		 FROM clash
		 LEFT JOIN upd ON true`,
	},

	opUserByIDBatch: {
		"q22",
		`SELECT u.username, u.email, u.bio, u.image, r.ord
		 FROM unnest($1::int8[]) WITH ORDINALITY AS r(p1, ord)
		 JOIN users u ON u.id = r.p1`,
	},
	opUserByEmailBatch: {
		"q23",
		`SELECT u.id, u.username, u.email, u.bio, u.image, u.password_hash, r.ord
		 FROM unnest($1::text[]) WITH ORDINALITY AS r(p1, ord)
		 JOIN users u ON u.email = r.p1`,
	},
	opProfileBatch: {
		"q24",
		`SELECT u.username, u.bio, u.image,
		        CASE WHEN r.p1 = 0 THEN false
		             ELSE EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.p1 AND fo.followee_id = u.id)
		        END AS following,
		        r.ord
		 FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY AS r(p1, p2, ord)
		 CROSS JOIN LATERAL (SELECT r.p2 AS uname LIMIT 1) k
		 CROSS JOIN LATERAL (
		   SELECT u.id, u.username, u.bio, u.image
		   FROM users u WHERE u.username = k.uname LIMIT 1
		 ) u`,
	},
	opArticleBatch: {
		"q25",
		`WITH ` + sqlTagMapCTE + `
		 SELECT a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
		        a.tags, a.favorites_count,
		        CASE WHEN r.p1 = 0 THEN false
		             ELSE EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = r.p1)
		        END AS favorited,
		        a.username, a.bio, a.image,
		        CASE WHEN r.p1 = 0 THEN false
		             ELSE EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.p1 AND fo.followee_id = a.author_id)
		        END AS following,
		        r.ord
		 FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY AS r(p1, p2, ord)
		 CROSS JOIN LATERAL (SELECT r.p2 AS slug LIMIT 1) k
		 CROSS JOIN LATERAL (
		   SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, a.author_id,
		          ARRAY(
		            SELECT (SELECT names FROM tmap)[at.tag_id]
		            FROM article_tags at
		            WHERE at.article_id = a.id
		            ORDER BY 1
		          ) AS tags,
		          (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
		          u.username, u.bio, u.image
		   FROM articles a
		   JOIN users u ON u.id = a.author_id
		   WHERE a.slug = k.slug
		   LIMIT 1
		 ) a`,
	},
	opCommentsBatch: {
		"q26",
		`SELECT c.id, c.body, c.created_at, c.updated_at, c.username, c.bio, c.image,
		        CASE WHEN c.id IS NULL OR r.p1 = 0 THEN false
		             ELSE EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.p1 AND fo.followee_id = c.author_id)
		        END AS following,
		        r.ord
		 FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY AS r(p1, p2, ord)
		 CROSS JOIN LATERAL (SELECT r.p2 AS slug LIMIT 1) k
		 CROSS JOIN LATERAL (
		   SELECT a.id
		   FROM articles a WHERE a.slug = k.slug LIMIT 1
		 ) a
		 LEFT JOIN LATERAL (
		   SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id,
		          u.username, u.bio, u.image
		   FROM comments c
		   JOIN users u ON u.id = c.author_id
		   WHERE c.article_id = a.id
		   ORDER BY c.created_at DESC, c.id DESC
		   LIMIT 100
		 ) c ON true`,
	},
	opListAllBatch: {
		"q27",
		`WITH ` + sqlTagMapCTE + `
		 SELECT t.n,
		        q.slug, q.title, q.description, q.created_at, q.updated_at,
		        q.tags, q.favorites_count,
		        CASE WHEN q.id IS NULL THEN NULL
		             WHEN r.p1 = 0 THEN false
		             ELSE q.id = ANY(uf.favs)
		        END AS favorited,
		        q.username, q.bio, q.image,
		        CASE WHEN q.id IS NULL THEN NULL
		             WHEN r.p1 = 0 THEN false
		             ELSE q.author_id = ANY(uf.fols)
		        END AS following,
		        r.ord
		 FROM unnest($1::int8[], $2::int8[], $3::int8[]) WITH ORDINALITY AS r(p1, p2, p3, ord)
		 CROSS JOIN (
		   SELECT CASE WHEN EXISTS (SELECT 1 FROM articles ORDER BY id OFFSET 999 LIMIT 1)
		          THEN 1000::bigint
		          ELSE (SELECT count(*) FROM articles)
		   END AS n
		 ) t
		 CROSS JOIN LATERAL (SELECT r.p1 AS uid LIMIT 1) ku
		 CROSS JOIN LATERAL (
		   SELECT
		     CASE WHEN ku.uid = 0 THEN '{}'::int8[] ELSE ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = ku.uid) END AS favs,
		     CASE WHEN ku.uid = 0 THEN '{}'::int8[] ELSE ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = ku.uid) END AS fols
		   LIMIT 1
		 ) uf
		 CROSS JOIN LATERAL (SELECT r.p2 AS lim, r.p3 AS off LIMIT 1) k
		 LEFT JOIN LATERAL (
		   SELECT a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at,
		          ARRAY(
		            SELECT (SELECT names FROM tmap)[at.tag_id]
		            FROM article_tags at
		            WHERE at.article_id = a.id
		            ORDER BY 1
		          ) AS tags,
		          (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
		          u.username, u.bio, u.image
		   FROM (
		     SELECT id, author_id, slug, title, description, created_at, updated_at FROM (
		       SELECT a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at
		       FROM articles a ORDER BY a.id DESC LIMIT 100 OFFSET k.off
		     ) bounded ORDER BY id DESC LIMIT k.lim
		   ) a
		   JOIN users u ON u.id = a.author_id
		   ORDER BY a.id DESC
		 ) q ON true`,
	},
	opListTagBatch: {
		"q28",
		`WITH ` + sqlTagMapCTE + `
		 SELECT COALESCE(tc.n, 0::bigint),
		        q.slug, q.title, q.description, q.created_at, q.updated_at,
		        q.tags, q.favorites_count,
		        CASE WHEN q.id IS NULL THEN NULL
		             WHEN r.p1 = 0 THEN false
		             ELSE q.id = ANY(uf.favs)
		        END AS favorited,
		        q.username, q.bio, q.image,
		        CASE WHEN q.id IS NULL THEN NULL
		             WHEN r.p1 = 0 THEN false
		             ELSE q.author_id = ANY(uf.fols)
		        END AS following,
		        r.ord
		 FROM unnest($1::int8[], $2::int8[], $3::int8[], $4::text[]) WITH ORDINALITY AS r(p1, p2, p3, p4, ord)
		 CROSS JOIN LATERAL (SELECT r.p4 AS tag LIMIT 1) kt
		 LEFT JOIN LATERAL (
		   SELECT t.id AS tid,
		          CASE WHEN EXISTS (
		                 SELECT 1 FROM article_tags at
		                 WHERE at.tag_id = t.id
		                 OFFSET 999 LIMIT 1
		               ) THEN 1000::bigint
		               ELSE (
		                 SELECT count(*) FROM article_tags at
		                 WHERE at.tag_id = t.id
		               )
		          END AS n
		   FROM tags t
		   WHERE t.name = kt.tag
		   LIMIT 1
		 ) tc ON true
		 CROSS JOIN LATERAL (SELECT CASE WHEN COALESCE(tc.n, 0) = 0 THEN 0::bigint ELSE r.p1 END AS uid LIMIT 1) ku
		 CROSS JOIN LATERAL (
		   SELECT
		     CASE WHEN ku.uid = 0 THEN '{}'::int8[] ELSE ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = ku.uid) END AS favs,
		     CASE WHEN ku.uid = 0 THEN '{}'::int8[] ELSE ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = ku.uid) END AS fols
		   LIMIT 1
		 ) uf
		 CROSS JOIN LATERAL (SELECT tc.tid, r.p2 AS lim, r.p3 AS off LIMIT 1) kp
		 LEFT JOIN LATERAL (
		   SELECT am.*
		   FROM (
		     SELECT id FROM (
		       SELECT at.article_id AS id
		       FROM article_tags at
		       WHERE at.tag_id = kp.tid
		       ORDER BY at.article_id DESC
		       LIMIT 100 OFFSET kp.off
		     ) page ORDER BY id DESC LIMIT kp.lim
		   ) p
		   CROSS JOIN LATERAL (SELECT p.id AS aid LIMIT 1) ka
		   CROSS JOIN LATERAL (
		     SELECT a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at,
		            ARRAY(
		              SELECT (SELECT names FROM tmap)[at.tag_id]
		              FROM article_tags at
		              WHERE at.article_id = a.id
		              ORDER BY 1
		            ) AS tags,
		            (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
		            u.username, u.bio, u.image
		     FROM articles a
		     JOIN users u ON u.id = a.author_id
		     WHERE a.id = ka.aid
		     LIMIT 1
		   ) am
		   ORDER BY p.id DESC
		 ) q ON COALESCE(tc.n, 0) > 0`,
	},
	opListAuthorBatch: {
		"q29",
		`WITH ` + sqlTagMapCTE + `
		 SELECT COALESCE(ac.n, 0::bigint),
		        q.slug, q.title, q.description, q.created_at, q.updated_at,
		        q.tags, q.favorites_count,
		        CASE WHEN q.id IS NULL THEN NULL
		             WHEN r.p1 = 0 THEN false
		             ELSE EXISTS (SELECT 1 FROM favorites f WHERE f.user_id = r.p1 AND f.article_id = q.id)
		        END AS favorited,
		        ac.username, ac.bio, ac.image,
		        CASE WHEN q.id IS NULL THEN NULL
		             ELSE uf.is_following
		        END AS following,
		        r.ord
		 FROM unnest($1::int8[], $2::int8[], $3::int8[], $4::text[]) WITH ORDINALITY AS r(p1, p2, p3, p4, ord)
		 CROSS JOIN LATERAL (SELECT r.p4 AS uname LIMIT 1) ka
		 LEFT JOIN LATERAL (
		   SELECT u.id AS uid, u.username, u.bio, u.image,
		          (SELECT count(*) FROM (
		            SELECT 1 FROM articles a WHERE a.author_id = u.id LIMIT 1000
		          ) s) AS n
		   FROM users u
		   WHERE u.username = ka.uname
		   LIMIT 1
		 ) ac ON true
		 CROSS JOIN LATERAL (SELECT CASE WHEN COALESCE(ac.n, 0) = 0 THEN 0::bigint ELSE r.p1 END AS uid, ac.uid AS auid LIMIT 1) ku
		 CROSS JOIN LATERAL (
		   SELECT
		     CASE WHEN ku.uid = 0 THEN false ELSE EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ku.uid AND fo.followee_id = ku.auid) END AS is_following
		   LIMIT 1
		 ) uf
		 CROSS JOIN LATERAL (SELECT ac.uid, r.p2 AS lim, r.p3 AS off LIMIT 1) kp
		 LEFT JOIN LATERAL (
		   SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
		          ARRAY(
		            SELECT (SELECT names FROM tmap)[at.tag_id]
		            FROM article_tags at
		            WHERE at.article_id = a.id
		            ORDER BY 1
		          ) AS tags,
		          (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count
		   FROM (
		     SELECT id, slug, title, description, created_at, updated_at FROM (
		       SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at FROM articles a
		       WHERE a.author_id = kp.uid
		       ORDER BY a.id DESC
		       LIMIT 100 OFFSET kp.off
		     ) page ORDER BY id DESC LIMIT kp.lim
		   ) a
		   ORDER BY a.id DESC
		 ) q ON COALESCE(ac.n, 0) > 0`,
	},
	opListFavBatch: {
		"q30",
		`WITH ` + sqlTagMapCTE + `
		 SELECT COALESCE(fc.n, 0::bigint),
		        q.slug, q.title, q.description, q.created_at, q.updated_at,
		        q.tags, q.favorites_count,
		        CASE WHEN q.id IS NULL THEN NULL
		             WHEN r.p1 = 0 THEN false
		             WHEN r.p1 = fc.fav_uid THEN true
		             ELSE q.id = ANY(uf.favs)
		        END AS favorited,
		        q.username, q.bio, q.image,
		        CASE WHEN q.id IS NULL THEN NULL
		             WHEN r.p1 = 0 THEN false
		             ELSE q.author_id = ANY(uf.fols)
		        END AS following,
		        r.ord
		 FROM unnest($1::int8[], $2::int8[], $3::int8[], $4::text[]) WITH ORDINALITY AS r(p1, p2, p3, p4, ord)
		 CROSS JOIN LATERAL (SELECT r.p4 AS uname LIMIT 1) kf
		 LEFT JOIN LATERAL (
		   SELECT u.id AS fav_uid,
		          (SELECT count(*) FROM (
		            SELECT 1 FROM favorites f WHERE f.user_id = u.id LIMIT 1000
		          ) s) AS n
		   FROM users u
		   WHERE u.username = kf.uname
		   LIMIT 1
		 ) fc ON true
		 CROSS JOIN LATERAL (SELECT CASE WHEN COALESCE(fc.n, 0) = 0 THEN 0::bigint ELSE r.p1 END AS uid, fc.fav_uid LIMIT 1) ku
		 CROSS JOIN LATERAL (
		   SELECT
		     CASE WHEN ku.uid = 0 OR ku.uid = ku.fav_uid THEN '{}'::int8[] ELSE ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = ku.uid) END AS favs,
		     CASE WHEN ku.uid = 0 THEN '{}'::int8[] ELSE ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = ku.uid) END AS fols
		   LIMIT 1
		 ) uf
		 CROSS JOIN LATERAL (SELECT fc.fav_uid, r.p2 AS lim, r.p3 AS off LIMIT 1) kp
		 LEFT JOIN LATERAL (
		   SELECT am.*
		   FROM (
		     SELECT id FROM (
		       SELECT f.article_id AS id FROM favorites f
		       WHERE f.user_id = kp.fav_uid
		       ORDER BY f.article_id DESC
		       LIMIT 100 OFFSET kp.off
		     ) page ORDER BY id DESC LIMIT kp.lim
		   ) p
		   CROSS JOIN LATERAL (SELECT p.id AS aid LIMIT 1) ka
		   CROSS JOIN LATERAL (
		     SELECT a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at,
		            ARRAY(
		              SELECT (SELECT names FROM tmap)[at.tag_id]
		              FROM article_tags at
		              WHERE at.article_id = a.id
		              ORDER BY 1
		            ) AS tags,
		            (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
		            u.username, u.bio, u.image
		     FROM articles a
		     JOIN users u ON u.id = a.author_id
		     WHERE a.id = ka.aid
		     LIMIT 1
		   ) am
		   ORDER BY p.id DESC
		 ) q ON COALESCE(fc.n, 0) > 0`,
	},
	opListFeedBatch: {
		"q31",
		`WITH ` + sqlTagMapCTE + `,
		 rf AS MATERIALIZED (
		   SELECT r.ord, r.p1, r.p2, r.p3,
		          ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.p1) AS fols,
		          ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = r.p1) AS favs
		   FROM unnest($1::int8[], $2::int8[], $3::int8[]) WITH ORDINALITY AS r(p1, p2, p3, ord)
		 ),
		 big_rows AS MATERIALIZED (
		   SELECT d.fid,
		          ARRAY(
		            SELECT a.id FROM articles a
		            WHERE a.author_id = d.fid
		            ORDER BY a.id DESC
		            LIMIT 50
		          ) AS ids
		   FROM (
		     SELECT fo.fid
		     FROM rf, unnest(rf.fols) AS fo(fid)
		     GROUP BY fo.fid
		     HAVING count(*) >= 2
		     ORDER BY count(*) DESC
		     LIMIT 24
		   ) d
		   WHERE EXISTS (
		     SELECT 1 FROM articles a
		     WHERE a.author_id = d.fid
		     ORDER BY a.id DESC
		     OFFSET 999 LIMIT 1
		   )
		 ),
		 big AS MATERIALIZED (
		   SELECT COALESCE(array_agg(fid), '{}'::int8[]) AS fids
		   FROM big_rows
		 )
		 SELECT c.n,
		        am.slug, am.title, am.description, am.created_at, am.updated_at,
		        am.tags, am.favorites_count,
		        CASE WHEN am.id IS NULL THEN NULL
		             ELSE am.id = ANY(rf.favs)
		        END AS favorited,
		        u.username, u.bio, u.image,
		        CASE WHEN am.id IS NULL THEN NULL ELSE true END AS following,
		        rf.ord
		 FROM rf
		 CROSS JOIN big
		 CROSS JOIN LATERAL (
		   SELECT CASE
		     WHEN rf.fols && big.fids THEN 1000::int8
		     ELSE (
		       SELECT count(*) FROM (
		         SELECT 1 FROM articles a
		         WHERE a.author_id = ANY(rf.fols)
		         LIMIT 1000
		       ) s
		     )
		   END AS n,
		   CASE
		     WHEN rf.p2 + LEAST(rf.p3, 9000000000000000000) <= 50 AND (rf.fols && big.fids) THEN
		       COALESCE((SELECT max(br.ids[rf.p2 + rf.p3]) FROM big_rows br WHERE br.fid = ANY(rf.fols)), 0)
		     ELSE 0::int8
		   END AS floor_id
		   LIMIT 1
		 ) c
		 LEFT JOIN LATERAL (
		   SELECT fa.id
		   FROM unnest(rf.fols) AS fo(followee_id)
		   CROSS JOIN LATERAL (
		     SELECT a.id
		     FROM articles a
		     WHERE a.author_id = fo.followee_id
		       AND a.id >= c.floor_id
		     ORDER BY a.id DESC
		     LIMIT (rf.p2 + LEAST(rf.p3, 9000000000000000000))
		   ) fa
		   ORDER BY fa.id DESC
		   LIMIT LEAST(rf.p2, 100) OFFSET rf.p3
		 ) p ON true
		 LEFT JOIN LATERAL (SELECT p.id AS aid LIMIT 1) ka ON p.id IS NOT NULL
		 LEFT JOIN LATERAL (
		   SELECT a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at,
		          ARRAY(
		            SELECT (SELECT names FROM tmap)[at.tag_id]
		            FROM article_tags at
		            WHERE at.article_id = a.id
		            ORDER BY 1
		          ) AS tags,
		          (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count
		   FROM articles a
		   WHERE a.id = ka.aid
		   LIMIT 1
		 ) am ON p.id IS NOT NULL
		 LEFT JOIN LATERAL (SELECT am.author_id AS uid LIMIT 1) kau ON am.id IS NOT NULL
		 LEFT JOIN LATERAL (
		   SELECT u.username, u.bio, u.image
		   FROM users u
		   WHERE u.id = kau.uid
		   LIMIT 1
		 ) u ON am.id IS NOT NULL`,
	},

	opFollowBatch: {
		"q32",
		`WITH req AS MATERIALIZED (
		   SELECT r.p1, r.p2, r.ord
		   FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY AS r(p1, p2, ord)
		 ),
		 target AS MATERIALIZED (
		   SELECT u.id, u.username, u.bio, u.image
		   FROM (SELECT DISTINCT p2 FROM req) d
		   JOIN users u ON u.username = d.p2
		 ),
		 ins AS (
		   INSERT INTO follows (follower_id, followee_id)
		   SELECT DISTINCT r.p1, t.id
		   FROM req r
		   JOIN target t ON t.username = r.p2
		   ON CONFLICT DO NOTHING
		 )
		 SELECT t.username, t.bio, t.image, r.ord
		 FROM req r
		 JOIN target t ON t.username = r.p2`,
	},
	opUnfollowBatch: {
		"q33",
		`WITH req AS MATERIALIZED (
		   SELECT r.p1, r.p2, r.ord
		   FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY AS r(p1, p2, ord)
		 ),
		 target AS MATERIALIZED (
		   SELECT u.id, u.username, u.bio, u.image
		   FROM (SELECT DISTINCT p2 FROM req) d
		   JOIN users u ON u.username = d.p2
		 ),
		 del AS (
		   DELETE FROM follows fo
		   USING req r, target t
		   WHERE r.p2 = t.username
		     AND fo.follower_id = r.p1
		     AND fo.followee_id = t.id
		 )
		 SELECT t.username, t.bio, t.image, r.ord
		 FROM req r
		 JOIN target t ON t.username = r.p2`,
	},
	opFavoriteBatch: {
		"q34",
		`WITH ` + sqlTagMapCTE + `,
		 req AS MATERIALIZED (
		   SELECT r.p1, r.p2, r.ord
		   FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY AS r(p1, p2, ord)
		 ),
		 arts AS MATERIALIZED (
		   SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, a.author_id,
		          ARRAY(
		            SELECT (SELECT names FROM tmap)[at.tag_id]
		            FROM article_tags at WHERE at.article_id = a.id
		            ORDER BY 1
		          ) AS tags,
		          (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS base_favs,
		          u.username, u.bio, u.image
		   FROM (SELECT DISTINCT p2 FROM req) s
		   JOIN articles a ON a.slug = s.p2
		   JOIN users u ON u.id = a.author_id
		 ),
		 ins AS MATERIALIZED (
		   INSERT INTO favorites (user_id, article_id)
		   SELECT DISTINCT r.p1, a.id
		   FROM req r
		   JOIN arts a ON a.slug = r.p2
		   ON CONFLICT DO NOTHING
		   RETURNING article_id
		 ),
		 delta AS MATERIALIZED (
		   SELECT article_id, count(*) AS added
		   FROM ins
		   GROUP BY article_id
		 )
		 SELECT
		   a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
		   a.tags,
		   a.base_favs + COALESCE(d.added, 0) AS favorites_count,
		   true AS favorited,
		   a.username, a.bio, a.image,
		   EXISTS (
		     SELECT 1 FROM follows fo
		     WHERE fo.follower_id = r.p1 AND fo.followee_id = a.author_id
		   ) AS following,
		   r.ord
		 FROM req r
		 JOIN arts a ON a.slug = r.p2
		 LEFT JOIN delta d ON d.article_id = a.id`,
	},
	opUnfavoriteBatch: {
		"q35",
		`WITH ` + sqlTagMapCTE + `,
		 req AS MATERIALIZED (
		   SELECT r.p1, r.p2, r.ord
		   FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY AS r(p1, p2, ord)
		 ),
		 arts AS MATERIALIZED (
		   SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, a.author_id,
		          ARRAY(
		            SELECT (SELECT names FROM tmap)[at.tag_id]
		            FROM article_tags at WHERE at.article_id = a.id
		            ORDER BY 1
		          ) AS tags,
		          (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS base_favs,
		          u.username, u.bio, u.image
		   FROM (SELECT DISTINCT p2 FROM req) s
		   JOIN articles a ON a.slug = s.p2
		   JOIN users u ON u.id = a.author_id
		 ),
		 del AS MATERIALIZED (
		   DELETE FROM favorites f
		   USING req r, arts a
		   WHERE r.p2 = a.slug
		     AND f.user_id = r.p1
		     AND f.article_id = a.id
		   RETURNING f.article_id
		 ),
		 delta AS MATERIALIZED (
		   SELECT article_id, count(*) AS removed
		   FROM del
		   GROUP BY article_id
		 )
		 SELECT
		   a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
		   a.tags,
		   GREATEST(a.base_favs - COALESCE(d.removed, 0), 0::bigint) AS favorites_count,
		   false AS favorited,
		   a.username, a.bio, a.image,
		   EXISTS (
		     SELECT 1 FROM follows fo
		     WHERE fo.follower_id = r.p1 AND fo.followee_id = a.author_id
		   ) AS following,
		   r.ord
		 FROM req r
		 JOIN arts a ON a.slug = r.p2
		 LEFT JOIN delta d ON d.article_id = a.id`,
	},
	opCommentCreateBatch: {
		"q36",
		`WITH req AS MATERIALIZED (
		   SELECT r.p2, r.p3, r.ord,
		          a.id AS article_id,
		          nextval('comments_id_seq') AS comment_id
		   FROM unnest($1::text[], $2::int8[], $3::text[]) WITH ORDINALITY AS r(p1, p2, p3, ord)
		   CROSS JOIN LATERAL (SELECT r.p1 AS slug LIMIT 1) k
		   CROSS JOIN LATERAL (SELECT a.id FROM articles a WHERE a.slug = k.slug LIMIT 1) a
		 ),
		 ins AS MATERIALIZED (
		   INSERT INTO comments (id, article_id, author_id, body)
		   SELECT comment_id, article_id, p2, p3
		   FROM req
		   RETURNING id, body, created_at, updated_at, author_id
		 )
		 SELECT ins.id, ins.body, ins.created_at, ins.updated_at,
		        u.username, u.bio, u.image,
		        r.ord
		 FROM ins
		 JOIN req r ON r.comment_id = ins.id
		 JOIN users u ON u.id = ins.author_id`,
	},
}
