/// Every statement the server prepares. Reads are written for a whole batch of requests at once: the requests
/// come in as arrays, and each statement returns rows tagged with what they belong to, so the server can answer
/// every request from one execution. Nothing is kept once a batch has been answered.
module Sql

open Pg

let private slugify (x: string) = sprintf "trim(both '-' from lower(regexp_replace(%s, '[^A-Za-z0-9]+', '-', 'g')))" x

/// Article lists and single articles, in one statement.
///
/// Groups ($1..$5): one per distinct page source: global (0), tag (1), author (2), favorited (3), feed (4, keyed by
/// viewer). The server merges every request of a group that starts near the top into one group fetching
/// enough ids for all of them (lim = the largest offset+limit, off = 0); each request then takes its slice
/// ($6..$9). Direct reads ($10..$12) are single articles by slug or id. Output rows, by t:
///   1  group: a = group, b = capped count, arr = the group's ids, newest first
///   2  article, once per distinct article needed: a = id, b = author, c = favorites count, s1..s3 slug, title,
///      description, s4 body (only for direct reads), s5..s7 author name, bio, image, ts1/ts2, tg = tag ids
///   3  viewer: a = viewer, arr = which of the articles they asked for they favorited
///   4  viewer: a = viewer, arr = everyone they follow (about 20; the server checks each author against it)
///   5  direct read: a = its index, b = article id (no row: no such article)
/// hubs: how many shared followees to probe; hubCount/feedBound: whether to use the probes for counts/pages
let readSql (hubs: int) (hubCount: bool) (feedBound: bool) =
    sprintf
        """
WITH g AS MATERIALIZED (
  SELECT g.gi, g.k, g.lim, g.off,
         CASE g.k WHEN 1 THEN (SELECT t.id FROM tags t WHERE t.name = g.key)::int8
                  WHEN 2 THEN (SELECT u.id FROM users u WHERE u.username = g.key)
                  WHEN 3 THEN (SELECT u.id FROM users u WHERE u.username = g.key)
                  WHEN 4 THEN g.v END AS kid
    FROM unnest($1::int4[], $2::text[], $3::int8[], $4::int8[], $5::int8[]) WITH ORDINALITY AS g(k, key, v, lim, off, gi)
), cand AS MATERIALIZED (
  -- the followees that the most feed viewers of this batch share, probed once each below
  SELECT fo.followee_id AS f FROM g JOIN follows fo ON fo.follower_id = g.kid
   WHERE g.k = 4 GROUP BY fo.followee_id HAVING count(*) >= 2 ORDER BY count(*) DESC LIMIT %d
), hub AS MATERIALIZED (
  -- feed counts: a followee with 1,000+ articles proves the capped count, so its followers get 1000 uncounted
  SELECT ARRAY(SELECT c.f FROM cand c
          WHERE %s AND EXISTS (SELECT 1 FROM articles a WHERE a.author_id = c.f ORDER BY a.id DESC OFFSET 999 LIMIT 1)) AS ids
), hb AS MATERIALIZED (
  -- feed pages: if a followee has n articles, the n newest of its followers' feeds are no older than its n-th
  -- newest, so every followee scan for them can stop there. One bound per followee and feed depth n in the batch
  -- (most feeds are page 1, so their bound is the 10th newest, not the deepest page's)
  SELECT c.f, n.n, (SELECT a.id FROM articles a WHERE a.author_id = c.f ORDER BY a.id DESC OFFSET n.n - 1 LIMIT 1) AS b
    FROM cand c, (SELECT DISTINCT g.lim + g.off AS n FROM g WHERE g.k = 4) n WHERE %s
), gb AS MATERIALIZED (
  SELECT g.gi, coalesce((SELECT max(hb.b) FROM hb JOIN follows fo ON fo.followee_id = hb.f AND fo.follower_id = g.kid
                          WHERE hb.n = g.lim + g.off), 0) AS bound
    FROM g WHERE g.k = 4
), ga AS MATERIALIZED (
  SELECT g.gi,
    CASE g.k
      WHEN 0 THEN ARRAY(SELECT a.id FROM articles a ORDER BY a.id DESC LIMIT g.lim OFFSET g.off)
      WHEN 1 THEN ARRAY(SELECT at.article_id FROM article_tags at WHERE at.tag_id = g.kid ORDER BY at.article_id DESC LIMIT g.lim OFFSET g.off)
      WHEN 2 THEN ARRAY(SELECT a.id FROM articles a WHERE a.author_id = g.kid ORDER BY a.id DESC LIMIT g.lim OFFSET g.off)
      WHEN 3 THEN ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = g.kid ORDER BY f.article_id DESC LIMIT g.lim OFFSET g.off)
      -- with a bound, the few articles newer than it come from one index scan over all followees at once;
      -- without one, each followee's newest are fetched separately and merged
      ELSE CASE WHEN gb.bound > 0
        THEN ARRAY(SELECT a2.id FROM articles a2
                    WHERE a2.author_id = ANY(ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = g.kid))
                      AND a2.id >= gb.bound
                    ORDER BY a2.id DESC LIMIT g.lim OFFSET g.off)
        ELSE ARRAY(SELECT x.id FROM follows fo CROSS JOIN LATERAL (
                   SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id
                    ORDER BY a2.id DESC LIMIT g.lim + g.off) x
                 WHERE fo.follower_id = g.kid ORDER BY x.id DESC LIMIT g.lim OFFSET g.off) END
    END AS ids,
    CASE g.k
      WHEN 0 THEN CASE WHEN EXISTS (SELECT 1 FROM articles a OFFSET 999) THEN 1000
                  ELSE (SELECT count(*) FROM articles a) END
      -- a 1,000th row proves the capped count without counting (cheaper than an aggregate over 1,000 rows)
      WHEN 1 THEN CASE WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = g.kid OFFSET 999) THEN 1000
                  ELSE (SELECT count(*) FROM article_tags at WHERE at.tag_id = g.kid) END
      WHEN 2 THEN (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = g.kid LIMIT 1000) s)
      WHEN 3 THEN (SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = g.kid LIMIT 1000) s)
      ELSE CASE WHEN EXISTS (SELECT 1 FROM follows fo, hub WHERE fo.follower_id = g.kid AND fo.followee_id = ANY(hub.ids))
                THEN 1000
                ELSE (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (
                        SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = g.kid) LIMIT 1000) s) END
    END AS cnt
  FROM g LEFT JOIN gb ON gb.gi = g.gi
), r AS MATERIALIZED (
  SELECT r.rv, ga.ids[r.rfrom:r.rto] AS ids
    FROM unnest($6::int4[], $7::int4[], $8::int4[], $9::int8[]) AS r(rg, rfrom, rto, rv) JOIN ga ON ga.gi = r.rg
), d AS MATERIALIZED (
  SELECT d.di, d.dv, COALESCE(d.id, (SELECT a.id FROM articles a WHERE a.slug = d.slug)) AS id
    FROM unnest($10::text[], $11::int8[], $12::int8[]) WITH ORDINALITY AS d(slug, id, dv, di)
), art AS MATERIALIZED (
  SELECT a.id, a.author_id, a.slug, a.title, a.description,
         CASE WHEN a.id = ANY(ARRAY(SELECT d.id FROM d)) THEN a.body END AS body, a.created_at, a.updated_at
    FROM articles a
   WHERE a.id = ANY(ARRAY(SELECT unnest(r.ids) FROM r UNION SELECT d.id FROM d WHERE d.id IS NOT NULL))
), ids AS MATERIALIZED (
  -- the batch's articles in id order: each lookup below is one index scan stepping through the array
  -- (Postgres 18 moves along the leaf pages between nearby keys instead of descending once per article)
  SELECT ARRAY(SELECT art.id FROM art ORDER BY art.id) AS a,
         ARRAY(SELECT DISTINCT art.author_id FROM art ORDER BY 1) AS u
), fc AS MATERIALIZED (
  SELECT f.article_id AS id, count(*) AS n FROM favorites f, ids WHERE f.article_id = ANY(ids.a) GROUP BY f.article_id
), tg AS MATERIALIZED (
  SELECT at.article_id AS id, array_agg(at.tag_id) AS t FROM article_tags at, ids WHERE at.article_id = ANY(ids.a)
   GROUP BY at.article_id
), au AS MATERIALIZED (
  SELECT u.id, u.username, u.bio, u.image FROM users u, ids WHERE u.id = ANY(ids.u)
), vw AS MATERIALIZED (
  -- each signed-in viewer's articles in this batch (duplicates are harmless in ANY)
  SELECT q.v, array_agg(q.id) AS ids
    FROM (SELECT r.rv AS v, unnest(r.ids) AS id FROM r WHERE r.rv <> 0
          UNION ALL SELECT d.dv, d.id FROM d WHERE d.dv <> 0 AND d.id IS NOT NULL) q
   GROUP BY q.v
)
SELECT 1 AS t, ga.gi AS a, ga.cnt AS b, NULL::int8 AS c, ga.ids AS arr, NULL::text AS s1, NULL::text AS s2,
       NULL::text AS s3, NULL::text AS s4, NULL::text AS s5, NULL::text AS s6, NULL::text AS s7,
       NULL::timestamptz AS ts1, NULL::timestamptz AS ts2, NULL::int4[] AS tg
  FROM ga
UNION ALL
SELECT 2, art.id, art.author_id, coalesce(fc.n, 0), NULL,
       art.slug, art.title, art.description, art.body, au.username, au.bio, au.image, art.created_at, art.updated_at,
       coalesce(tg.t, '{}')
  FROM art JOIN au ON au.id = art.author_id LEFT JOIN fc ON fc.id = art.id LEFT JOIN tg ON tg.id = art.id
UNION ALL
SELECT 3, vw.v, NULL, NULL, ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = vw.v AND f.article_id = ANY(vw.ids)),
       NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
  FROM vw
UNION ALL
SELECT 4, vw.v, NULL, NULL, ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = vw.v),
       NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
  FROM vw
UNION ALL
SELECT 5, d.di, d.id, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
  FROM d WHERE d.id IS NOT NULL
"""
        hubs (if hubCount then "true" else "false") (if feedBound then "true" else "false")

let readOids =
    [| OidInt4Arr; OidTextArr; OidInt8Arr; OidInt8Arr; OidInt8Arr; OidInt4Arr; OidInt4Arr; OidInt4Arr; OidInt8Arr
       OidTextArr; OidInt8Arr; OidInt8Arr |]

/// Comment threads for many articles: $1 distinct slugs, $2/$3 each request's slug index and viewer. Rows by t:
///   1 comment: a = slug index, b = id, c = author, s1 = body, ts1/ts2
///   2 author, once per batch: a = id, s1..s3 username, bio, image
///   3 viewer: a = viewer, arr = which authors of the threads they asked for they follow
///   4 article found: a = slug index
let comments =
    """
WITH s AS MATERIALIZED (
  SELECT s.si, (SELECT a.id FROM articles a WHERE a.slug = s.slug) AS aid
    FROM unnest($1::text[]) WITH ORDINALITY AS s(slug, si)
), c AS MATERIALIZED (
  SELECT s.si, c.id, c.author_id, c.body, c.created_at, c.updated_at
    FROM s CROSS JOIN LATERAL (
      SELECT c.id, c.author_id, c.body, c.created_at, c.updated_at FROM comments c
       WHERE c.article_id = s.aid ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c
), vf AS MATERIALIZED (
  SELECT q.v, array_agg(DISTINCT c.author_id) AS au
    FROM (SELECT DISTINCT r.v, r.si FROM unnest($2::int4[], $3::int8[]) AS r(si, v) WHERE r.v <> 0) q
    JOIN c ON c.si = q.si
   GROUP BY q.v
)
SELECT 1 AS t, c.si AS a, c.id AS b, c.author_id AS c, c.body AS s1, NULL::text AS s2, NULL::text AS s3,
       c.created_at AS ts1, c.updated_at AS ts2, NULL::int8[] AS arr
  FROM c
UNION ALL
SELECT 2, u.id, NULL, NULL, u.username, u.bio, u.image, NULL, NULL, NULL
  FROM users u WHERE u.id = ANY(ARRAY(SELECT DISTINCT c.author_id FROM c))
UNION ALL
SELECT 3, vf.v, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
       ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = vf.v AND fo.followee_id = ANY(vf.au))
  FROM vf
UNION ALL
SELECT 4, s.si, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM s WHERE s.aid IS NOT NULL
"""

let commentsOids = [| OidTextArr; OidInt4Arr; OidInt8Arr |]

/// Profiles by username, with the viewer's following flag: one row per request found (i = request index).
let profiles =
    """
SELECT p.i, u.id, u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = p.v AND fo.followee_id = u.id)
  FROM unnest($1::text[], $2::int8[]) WITH ORDINALITY AS p(name, v, i) JOIN users u ON u.username = p.name
"""

let profilesOids = [| OidTextArr; OidInt8Arr |]

let usersById = "SELECT u.id, u.username, u.email, u.bio, u.image FROM users u WHERE u.id = ANY($1::int8[])"
let usersByIdOids = [| OidInt8Arr |]

let usersByEmail =
    "SELECT u.id, u.username, u.email, u.bio, u.image, u.password_hash FROM users u WHERE u.email = ANY($1::text[])"

let usersByEmailOids = [| OidTextArr |]

let tags = "SELECT t.id, t.name FROM tags t ORDER BY t.name"

// ---- writes (batched: one request per user per batch, so rows map back by user id) ----

let favAdd =
    """
INSERT INTO favorites (user_id, article_id)
SELECT x.u, a.id FROM unnest($1::int8[], $2::text[]) AS x(u, slug) JOIN articles a ON a.slug = x.slug
ON CONFLICT DO NOTHING
"""

let favDel =
    """
DELETE FROM favorites f USING unnest($1::int8[], $2::text[]) AS x(u, slug), articles a
 WHERE a.slug = x.slug AND f.user_id = x.u AND f.article_id = a.id
"""

let followAdd =
    """
INSERT INTO follows (follower_id, followee_id)
SELECT x.v, u.id FROM unnest($1::int8[], $2::text[]) AS x(v, name) JOIN users u ON u.username = x.name
ON CONFLICT DO NOTHING
"""

let followDel =
    """
DELETE FROM follows fo USING unnest($1::int8[], $2::text[]) AS x(v, name), users u
 WHERE u.username = x.name AND fo.follower_id = x.v AND fo.followee_id = u.id
"""

let pairOids = [| OidInt8Arr; OidTextArr |]

/// New comments; rows come back by author: author, id, body, times, author's name, bio, image
let commentAdd =
    """
WITH ins AS (
  INSERT INTO comments (article_id, author_id, body)
  SELECT a.id, x.v, x.body FROM unnest($1::int8[], $2::text[], $3::text[]) AS x(v, slug, body) JOIN articles a ON a.slug = x.slug
  RETURNING id, author_id, body, created_at, updated_at
)
SELECT ins.author_id, ins.id, ins.body, ins.created_at, ins.updated_at, u.username, u.bio, u.image
  FROM ins JOIN users u ON u.id = ins.author_id
"""

let commentAddOids = [| OidInt8Arr; OidTextArr; OidTextArr |]

/// Deletes comments their author asked to delete. One row per request whose comment exists on that article:
/// request index, the comment's author (the server answers 403 when it isn't the viewer: nothing was deleted).
let commentDel =
    """
WITH f AS MATERIALIZED (
  SELECT x.i, x.v, c.id, c.author_id
    FROM unnest($1::int8[], $2::text[], $3::int8[]) WITH ORDINALITY AS x(v, slug, cid, i)
    JOIN comments c ON c.id = x.cid JOIN articles a ON a.id = c.article_id
   WHERE a.slug = x.slug
), del AS (
  DELETE FROM comments c USING f WHERE c.id = f.id AND f.author_id = f.v
)
SELECT f.i, f.author_id FROM f
"""

let commentDelOids = [| OidInt8Arr; OidTextArr; OidInt8Arr |]

let signup =
    "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image"

let signupOids = [| OidText; OidText; OidText |]

let updateUser =
    """
UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
                 password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
 WHERE id = $1
RETURNING id, username, email, bio, image
"""

let updateUserOids = [| OidInt8; OidText; OidText; OidText; OidText; OidText |]

let articleInsert =
    sprintf
        """
INSERT INTO articles (id, slug, author_id, title, description, body)
SELECT n.id, %s || '-' || n.id, $1, $2, $3, $4
  FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
RETURNING id
"""
        (slugify "$2")

let articleInsertOids = [| OidInt8; OidText; OidText; OidText |]

let tagsInsert = "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING"

/// the article just inserted on this connection (currval of the articles sequence; as a scalar subquery it is
/// read once, so the primary key can be used)
let articleTagsInsert =
    """
INSERT INTO article_tags (article_id, tag_id)
SELECT currval(pg_get_serial_sequence('articles', 'id')), t.id FROM tags t WHERE t.name = ANY($1::text[])
"""

let textArrOids = [| OidTextArr |]

/// One full article ($1 = viewer): id, slug, title, description, body, created, updated, tag names, favorites
/// count, favorited, author name, bio, image, following.
let private fullColumns (a: string) =
    sprintf
        """%s.id, %s.slug, %s.title, %s.description, %s.body, %s.created_at, %s.updated_at,
       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id WHERE at.article_id = %s.id ORDER BY t.name),
       (SELECT count(*) FROM favorites f WHERE f.article_id = %s.id),
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = %s.id AND f.user_id = $1),
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = %s.author_id)"""
        a a a a a a a a a a a

let articleCreated =
    sprintf "SELECT %s FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = (SELECT currval(pg_get_serial_sequence('articles', 'id')))" (fullColumns "a")

let articleCreatedOids = [| OidInt8 |]

let articleOwner = "SELECT a.id, a.author_id FROM articles a WHERE a.slug = $1"
let articleOwnerOids = [| OidText |]

/// $1 viewer, $2 slug, $3..$5 title, description, body (NULL = unchanged); updates only if the viewer wrote it
let articleUpdate =
    sprintf
        """
WITH up AS (
  UPDATE articles a SET title = COALESCE($3, a.title), description = COALESCE($4, a.description), body = COALESCE($5, a.body),
         slug = CASE WHEN $3::text IS NULL THEN a.slug ELSE %s || '-' || a.id END, updated_at = now()
   WHERE a.slug = $2 AND a.author_id = $1
  RETURNING a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, a.author_id
)
SELECT %s FROM up JOIN users u ON u.id = up.author_id
"""
        (slugify "$3")
        (fullColumns "up")

let articleUpdateOids = [| OidInt8; OidText; OidText; OidText; OidText |]

let articleDelete = "DELETE FROM articles a WHERE a.slug = $2 AND a.author_id = $1"
let articleDeleteOids = [| OidInt8; OidText |]

/// name, sql, parameter types: prepared on every connection at startup
let mutable read = readSql 16 true true

let all () =
    [ "rd", read, readOids
      "cm", comments, commentsOids
      "pf", profiles, profilesOids
      "ui", usersById, usersByIdOids
      "ue", usersByEmail, usersByEmailOids
      "tg", tags, [||]
      "fa", favAdd, pairOids
      "fd", favDel, pairOids
      "oa", followAdd, pairOids
      "od", followDel, pairOids
      "ca", commentAdd, commentAddOids
      "cd", commentDel, commentDelOids
      "su", signup, signupOids
      "uu", updateUser, updateUserOids
      "ai", articleInsert, articleInsertOids
      "ti", tagsInsert, textArrOids
      "at", articleTagsInsert, textArrOids
      "ac", articleCreated, articleCreatedOids
      "ao", articleOwner, articleOwnerOids
      "au", articleUpdate, articleUpdateOids
      "ad", articleDelete, articleDeleteOids ]
