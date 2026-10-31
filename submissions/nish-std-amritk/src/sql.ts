// The statements the server prepares on every connection, by name. They are
// the reference SQL of the multicore server challenge's SPEC.md "SQL",
// https://github.com/arjaythedev/multicore-server-challenge/blob/c301225/SPEC.md,
// with two changes that keep its answers: an endpoint whose reference runs a
// lookup and then a write runs them as one statement (a data-modifying
// `WITH`) or as statements of one pipelined group, and every article select
// returns its columns in the one order `ARTICLE_COLUMNS` names, so one writer
// serves them all. Each group is one implicit transaction, committed at its
// Sync, and a response is sent only after its group's ReadyForQuery.
//
// The read plans' statements (`registerPlanStatements`, `planArticleBatch`,
// `planCommentBatch`) answer the same reads for many requests at once, over
// arrays of their distinct keys: the same rows, split into what finds a
// page (its ids) and what describes an article (its columns, once a plan).
// The statements above still answer a read sent alone.
//
// Copyright (c) 2026 arjaythedev and the challenge contributors. MIT License;
// see LICENSE.md beside this file.
import { PG_BATCH_TEXT, PgBatchConfig, PgPool } from "nish/net/postgres"

/** The article columns, in order: what `ARTICLE_LIST` and `ARTICLE_FULL` select. */
export const COL_SLUG: i32 = 0
export const COL_TITLE: i32 = 1
export const COL_DESCRIPTION: i32 = 2
export const COL_TAGS: i32 = 3
export const COL_CREATED: i32 = 4
export const COL_UPDATED: i32 = 5
export const COL_FAVORITED: i32 = 6
export const COL_FAVORITES: i32 = 7
export const COL_USERNAME: i32 = 8
export const COL_BIO: i32 = 9
export const COL_IMAGE: i32 = 10
export const COL_FOLLOWING: i32 = 11
/** `ARTICLE_FULL` only. */
export const COL_BODY: i32 = 12

/**
 * SPEC.md's ARTICLE_LIST_SELECT, without `a.id` and in `COL_` order, in three
 * parts around the two places the viewer's id goes. A tag's name is a
 * primary-key lookup per tag (an article has one to four): joined to `tags`
 * instead, the generic plan hash-joins a scan of all 200 tags for every
 * article of the page.
 */
const LIST_FAVORITED: string =
  "SELECT a.slug, a.title, a.description, " +
  "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list, " +
  "a.created_at, a.updated_at, " +
  "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = "
const LIST_FOLLOWING: string =
  ") AS favorited, " +
  "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, " +
  "u.username, u.bio, u.image, " +
  "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = "
const LIST_END: string = " AND fo.followee_id = a.author_id) AS following"
/** ARTICLE_LIST_SELECT with `$1` the viewer. */
const ARTICLE_LIST: string = LIST_FAVORITED + "$1" + LIST_FOLLOWING + "$1" + LIST_END
/** SPEC.md's ARTICLE_FULL_SELECT: the list's columns and `a.body` last. */
const ARTICLE_FULL: string = ARTICLE_LIST + ", a.body"
const ARTICLE_FROM: string = " FROM articles a JOIN users u ON u.id = a.author_id"
const SLUGIFY_2: string = "trim(both '-' from lower(regexp_replace($2::text, '[^A-Za-z0-9]+', '-', 'g')))"
// A scalar subquery, so the volatile currval is read once and the primary key
// is probed with it, rather than tested against every row.
const LAST_ARTICLE: string = "(SELECT currval(pg_get_serial_sequence('articles', 'id')))"
const FOLLOWING_1: string = "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = "

/**
 * The FROM of a list page: the articles `where` keeps, newest first, cut to
 * `$2` from `$3` before any column is computed. Computing the metadata after
 * the page is cut is an idea from the challenge's rust-tokio-Scooter1337
 * submission; the SQL is written here.
 */
const pageFrom = (where: string): string =>
  " FROM (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM articles a2 WHERE " +
  where +
  " ORDER BY a2.id DESC LIMIT $2 OFFSET $3) a JOIN users u ON u.id = a.author_id ORDER BY a.id DESC"

/** Registers every statement on `pool`; false when the pool refused one. */
export const registerStatements = (pool: PgPool): boolean => {
  const none: i32[] = []
  let ok: boolean = true
  // Article lists: the page, then the capped count, of each filter.
  // The page is cut in a subquery before the select list runs: with LIMIT and
  // OFFSET over the whole select, every per-row subquery also ran for each
  // row the OFFSET skips.
  ok = pool.register("list_all", ARTICLE_LIST + pageFrom("TRUE"), none) && ok
  ok = pool.register("count_all", "SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s", none) && ok
  ok =
    pool.register(
      "list_tag",
      ARTICLE_LIST +
        ARTICLE_FROM +
        " WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC",
      none
    ) && ok
  ok =
    pool.register(
      "count_tag",
      "SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s",
      none
    ) && ok
  ok =
    pool.register(
      "list_author",
      ARTICLE_LIST + pageFrom("a2.author_id = (SELECT au.id FROM users au WHERE au.username = $4)"),
      none
    ) && ok
  ok =
    pool.register(
      "count_author",
      "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s",
      none
    ) && ok
  ok =
    pool.register(
      "list_favorited",
      ARTICLE_LIST +
        ARTICLE_FROM +
        " WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC",
      none
    ) && ok
  ok =
    pool.register(
      "count_favorited",
      "SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s",
      none
    ) && ok
  ok =
    pool.register(
      "list_feed",
      ARTICLE_LIST +
        ARTICLE_FROM +
        " WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC",
      none
    ) && ok
  ok =
    pool.register(
      "count_feed",
      "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s",
      none
    ) && ok
  // One article, by slug or by id.
  ok = pool.register("article_slug", ARTICLE_FULL + ARTICLE_FROM + " WHERE a.slug = $2", none) && ok
  ok = pool.register("article_id", ARTICLE_FULL + ARTICLE_FROM + " WHERE a.id = $2", none) && ok
  ok =
    pool.register("article_last", ARTICLE_FULL + ARTICLE_FROM + " WHERE a.id = " + LAST_ARTICLE, none) && ok
  // Every tag in one row, as one array: one DataRow to frame and send, not 200.
  ok = pool.register("tags", "SELECT ARRAY(SELECT name FROM tags ORDER BY name)", none) && ok
  // Users.
  ok = pool.register("user_id", "SELECT id, username, email, bio, image FROM users WHERE id = $1", none) && ok
  ok =
    pool.register(
      "login",
      "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1",
      none
    ) && ok
  ok =
    pool.register(
      "signup",
      "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image",
      none
    ) && ok
  ok =
    pool.register(
      "user_update",
      "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), " +
        "password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) " +
        "WHERE id = $1 RETURNING id, username, email, bio, image",
      none
    ) && ok
  // Profiles and follows: the lookup and the write in one statement.
  ok =
    pool.register(
      "profile",
      "SELECT u.username, u.bio, u.image, " +
        FOLLOWING_1 +
        "u.id) AS following FROM users u WHERE u.username = $2",
      none
    ) && ok
  ok =
    pool.register(
      "follow",
      "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2), " +
        "i AS (INSERT INTO follows (follower_id, followee_id) SELECT $1::bigint, u.id FROM u ON CONFLICT DO NOTHING) " +
        "SELECT username, bio, image FROM u",
      none
    ) && ok
  ok =
    pool.register(
      "unfollow",
      "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2), " +
        "d AS (DELETE FROM follows fo USING u WHERE fo.follower_id = $1 AND fo.followee_id = u.id) " +
        "SELECT username, bio, image FROM u",
      none
    ) && ok
  // Writing articles. A create is one group: the article, its tags, then the article as written.
  ok =
    pool.register(
      "article_create",
      "INSERT INTO articles (id, slug, author_id, title, description, body) SELECT n.id, " +
        SLUGIFY_2 +
        " || '-' || n.id, $1::bigint, $2::text, $3::text, $4::text FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n RETURNING id",
      none
    ) && ok
  ok =
    pool.register(
      "tags_create",
      "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING",
      none
    ) && ok
  ok =
    pool.register(
      "article_tags_create",
      "INSERT INTO article_tags (article_id, tag_id) SELECT " +
        LAST_ARTICLE +
        ", t.id FROM tags t WHERE t.name = ANY($1::text[])",
      none
    ) && ok
  ok = pool.register("article_owner", "SELECT id, author_id FROM articles WHERE slug = $1", none) && ok
  ok =
    pool.register(
      "article_update",
      "UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body), " +
        "slug = CASE WHEN $2::text IS NULL THEN slug ELSE " +
        SLUGIFY_2 +
        " || '-' || id END, updated_at = now() WHERE id = $1",
      none
    ) && ok
  ok =
    pool.register(
      "article_delete",
      "WITH a0 AS (SELECT id, author_id FROM articles WHERE slug = $1), " +
        "d AS (DELETE FROM articles a USING a0 WHERE a.id = a0.id AND a0.author_id = $2) SELECT author_id FROM a0",
      none
    ) && ok
  // Favorites: the write; the article as it is after it is then read by a
  // read plan, like an article page. A folded write's request runs `noop`,
  // so that every request of a write batch has a statement of its own.
  ok = pool.register("noop", "SELECT 1", none) && ok
  ok =
    pool.register(
      "favorite",
      "INSERT INTO favorites (user_id, article_id) SELECT $1::bigint, a.id FROM articles a WHERE a.slug = $2 ON CONFLICT DO NOTHING",
      none
    ) && ok
  ok =
    pool.register(
      "unfavorite",
      "DELETE FROM favorites f USING articles a WHERE f.user_id = $1 AND f.article_id = a.id AND a.slug = $2",
      none
    ) && ok
  // A write batch's favorites and unfavorites, each kind one statement over
  // the batch's (viewer, slug) pairs; each request then reads its article in a plan.
  ok =
    pool.register(
      "favorite_many",
      "INSERT INTO favorites (user_id, article_id) SELECT q.v, a.id FROM unnest($1::int8[], $2::text[]) q(v, slug) " +
        "JOIN articles a ON a.slug = q.slug ON CONFLICT DO NOTHING",
      none
    ) && ok
  ok =
    pool.register(
      "unfavorite_many",
      "DELETE FROM favorites f USING unnest($1::int8[], $2::text[]) q(v, slug), articles a " +
        "WHERE a.slug = q.slug AND f.user_id = q.v AND f.article_id = a.id",
      none
    ) && ok
  // Comments: the article and its newest comments in one statement, one row
  // with the comment columns NULL when it has none, and no row when the
  // article does not exist.
  ok =
    pool.register(
      "comments",
      "SELECT a.id, c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, " +
        FOLLOWING_1 +
        "c.author_id) FROM articles a LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id " +
        "FROM comments c WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true " +
        "LEFT JOIN users u ON u.id = c.author_id WHERE a.slug = $2 ORDER BY c.created_at DESC, c.id DESC",
      none
    ) && ok
  ok =
    pool.register(
      "comment_create",
      "WITH a0 AS (SELECT id FROM articles WHERE slug = $1), " +
        "c AS (INSERT INTO comments (article_id, author_id, body) SELECT a0.id, $2::bigint, $3::text FROM a0 RETURNING id, body, created_at, updated_at, author_id) " +
        "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image FROM c JOIN users u ON u.id = c.author_id",
      none
    ) && ok
  ok =
    pool.register(
      "comment_delete",
      "WITH c0 AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $1 AND a.slug = $2), " +
        "d AS (DELETE FROM comments c USING c0 WHERE c.id = c0.id AND c0.author_id = $3) SELECT author_id FROM c0",
      none
    ) && ok
  return ok
}

// ---- Read plans (plan.ts) ---------------------------------------------------------

/**
 * A plan's list page, from `q.lim` and `q.off` and the ids `pageIds` selects
 * (with `author` beside each `id`): its article ids and their authors, newest
 * first, as two arrays.
 */
const planPage = (pageIds: string): string =>
  "CROSS JOIN LATERAL (SELECT array_agg(p.id ORDER BY p.id DESC) AS ids, array_agg(p.author ORDER BY p.id DESC) AS authors FROM (" +
  pageIds +
  ") p) x"

/**
 * A plan's statement for one kind of list: a row (-k, count) for each count
 * key `k` of `$1`, and a row (k, NULL, ids, authors) for each page key `k`
 * of the parallel arrays `$2` (the key), `$3` (limits) and `$4` (offsets).
 * `keyJoin` finds the key's row (`t` or `u`, NULL when there is none),
 * `count` the capped count over it, and `pageIds` the page.
 */
const planList = (keyType: string, keyJoin: string, count: string, pageIds: string): string =>
  "SELECT -q.k, (SELECT count(*) FROM (" +
  count +
  " LIMIT 1000) s), NULL::int8[], NULL::int8[] FROM unnest($1::" +
  keyType +
  "[]) WITH ORDINALITY q(key, k) " +
  keyJoin +
  " UNION ALL SELECT q.k, NULL::int8, x.ids, x.authors FROM unnest($2::" +
  keyType +
  "[], $3::int8[], $4::int8[]) WITH ORDINALITY q(key, lim, off, k) " +
  keyJoin +
  " " +
  planPage(pageIds)

/** Registers the plans' statements on `pool`; false when the pool refused one. */
export const registerPlanStatements = (pool: PgPool): boolean => {
  const none: i32[] = []
  let ok: boolean = true
  // The global count walks the primary key from the oldest end, whose pages
  // are all visible, so it stays an index-only scan while new articles keep
  // the newest pages busy: an idea from the challenge's
  // rust-epoll-WorriedArrow submission. It is min(articles, 1000), as
  // SPEC.md's count is.
  ok =
    pool.register(
      "plan_global",
      "SELECT 0::int8, (SELECT count(*) FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s), NULL::int8[], NULL::int8[] " +
        "UNION ALL SELECT q.k, NULL::int8, x.ids, x.authors FROM unnest($1::int8[], $2::int8[]) WITH ORDINALITY q(lim, off, k) " +
        planPage(
          "SELECT a.id, a.author_id AS author FROM articles a ORDER BY a.id DESC LIMIT q.lim OFFSET q.off"
        ),
      none
    ) && ok
  ok =
    pool.register(
      "plan_tag",
      planList(
        "text",
        "LEFT JOIN tags t ON t.name = q.key",
        "SELECT 1 FROM article_tags at WHERE at.tag_id = t.id",
        "SELECT a.id, a.author_id AS author FROM (SELECT at.article_id FROM article_tags at WHERE at.tag_id = t.id " +
          "ORDER BY at.article_id DESC LIMIT q.lim OFFSET q.off) i JOIN articles a ON a.id = i.article_id"
      ),
      none
    ) && ok
  ok =
    pool.register(
      "plan_author",
      planList(
        "text",
        "LEFT JOIN users u ON u.username = q.key",
        "SELECT 1 FROM articles a WHERE a.author_id = u.id",
        "SELECT a.id, a.author_id AS author FROM articles a WHERE a.author_id = u.id ORDER BY a.id DESC LIMIT q.lim OFFSET q.off"
      ),
      none
    ) && ok
  ok =
    pool.register(
      "plan_favorited",
      planList(
        "text",
        "LEFT JOIN users u ON u.username = q.key",
        "SELECT 1 FROM favorites f WHERE f.user_id = u.id",
        "SELECT a.id, a.author_id AS author FROM (SELECT f.article_id FROM favorites f WHERE f.user_id = u.id " +
          "ORDER BY f.article_id DESC LIMIT q.lim OFFSET q.off) i JOIN articles a ON a.id = i.article_id"
      ),
      none
    ) && ok
  // A feed's page reads at most limit + offset of each followee's newest ids
  // from articles_author_idx, as SPEC.md's does, and the followee is the author.
  // Followees several viewers of the plan share are looked at once (`hubs`).
  // The depth-th newest article of one is a floor for those viewers' pages,
  // which can hold nothing older, so every other followee's walk stops there;
  // and one with 1,000 articles proves its followers' count without a count.
  // An idea from the challenge's rust-epoll-WorriedArrow and
  // rust-epoll-theCatWisel submissions; the SQL follows the latter's.
  ok =
    pool.register(
      "plan_feed",
      "WITH w AS MATERIALIZED (SELECT q.key, q.lim, q.off, q.k FROM unnest($2::int8[], $3::int8[], $4::int8[]) WITH ORDINALITY q(key, lim, off, k)), " +
        "u AS MATERIALIZED (SELECT r.key, max(r.depth) AS depth, ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.key) AS fids " +
        "FROM (SELECT c.key, 1::int8 AS depth FROM unnest($1::int8[]) c(key) UNION ALL SELECT w.key, w.lim + w.off FROM w) r GROUP BY r.key), " +
        "hubs AS MATERIALIZED (SELECT h.fid, (SELECT a.id FROM articles a WHERE a.author_id = h.fid ORDER BY a.id DESC LIMIT 1 OFFSET h.depth - 1) AS floor_id " +
        "FROM (SELECT f.fid, max(u.depth) AS depth FROM u, unnest(u.fids) f(fid) GROUP BY f.fid HAVING count(*) >= 2 ORDER BY count(*) DESC, f.fid LIMIT 32) h), " +
        "capped AS MATERIALIZED (SELECT ARRAY(SELECT n.fid FROM (SELECT h.fid FROM hubs h WHERE h.floor_id IS NOT NULL ORDER BY h.floor_id DESC LIMIT 16) n " +
        "WHERE EXISTS (SELECT 1 FROM articles a WHERE a.author_id = n.fid ORDER BY a.id DESC LIMIT 1 OFFSET 999)) AS fids) " +
        "SELECT -c.k, CASE WHEN cardinality(u.fids) = 0 THEN 0::int8 WHEN u.fids && capped.fids THEN 1000::int8 " +
        "ELSE (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = ANY(u.fids) LIMIT 1000) s) END, NULL::int8[], NULL::int8[] " +
        "FROM unnest($1::int8[]) WITH ORDINALITY c(key, k) JOIN u ON u.key = c.key CROSS JOIN capped " +
        "UNION ALL SELECT w.k, NULL::int8, x.ids, x.authors FROM w JOIN u ON u.key = w.key " +
        "CROSS JOIN LATERAL (SELECT COALESCE(max(h.floor_id), 0::int8) AS floor_id FROM hubs h WHERE h.fid = ANY(u.fids)) fl " +
        planPage(
          "SELECT y.id, fid AS author FROM unnest(u.fids) fid CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 " +
            "WHERE a2.author_id = fid AND a2.id >= fl.floor_id ORDER BY a2.id DESC LIMIT (w.lim + w.off)) y ORDER BY y.id DESC LIMIT w.lim OFFSET w.off"
        ),
      none
    ) && ok
  // Every tag by name, once a plan: the tag list's answer, and the names, in
  // order, of the tags of every article the plan writes.
  ok = pool.register("plan_tags", "SELECT id, name FROM tags ORDER BY name", none) && ok
  // The articles every list, feed and article page of the plan returned, each
  // once: ARTICLE_LIST_SELECT's columns but the viewer's two flags, with tag
  // ids for the tag names, and the body of those an article page shows. Its
  // rows come in binary (`bindStartBinary`): the id, the count, the two times
  // and the tag ids (an `int4[]`, read by `PgBinaryArray`) are sent as they
  // are stored instead of formatted as text.
  ok =
    pool.register(
      "plan_meta",
      "SELECT a.id, a.slug, a.title, a.description, " +
        "ARRAY(SELECT at.tag_id FROM article_tags at WHERE at.article_id = a.id), " +
        "a.created_at, a.updated_at, u.username, u.bio, u.image, " +
        "CASE WHEN q.with_body THEN a.body END " +
        "FROM unnest($1::int8[], $2::bool[]) q(id, with_body) JOIN articles a ON a.id = q.id JOIN users u ON u.id = a.author_id",
      none
    ) && ok
  // Each article's favorite count, for a worker's count lane (plan.ts
  // `CountRun`): the costliest column of `plan_meta`, a walk of the article's
  // index entries and, for the pages writes have touched, its heap.
  ok =
    pool.register(
      "plan_counts",
      "SELECT q.id, (SELECT count(*) FROM favorites f WHERE f.article_id = q.id) FROM unnest($1::int8[]) q(id)",
      none
    ) && ok
  // The flags: (0, viewer, article) for each favorite asked about that
  // exists, (1, viewer, user) for each follow; each viewer's in one range
  // scan of the primary key over its ids. Each viewer's ids come as one
  // `int8[]` literal, grouped by the plan: regrouping (viewer, id) pairs
  // here took half the statement's time.
  ok =
    pool.register(
      "plan_flags",
      "SELECT 0::int8, g.v, f.article_id FROM unnest($1::int8[], $2::text[]) g(v, ids) " +
        "CROSS JOIN LATERAL (SELECT f.article_id FROM favorites f WHERE f.user_id = g.v AND f.article_id = ANY(g.ids::int8[])) f " +
        "UNION ALL SELECT 1::int8, g.v, fo.followee_id FROM unnest($1::int8[], $3::text[]) g(v, ids) " +
        "CROSS JOIN LATERAL (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = g.v AND fo.followee_id = ANY(g.ids::int8[])) fo",
      none
    ) && ok
  return ok
}

/** A plan's batcher of articles by slug: each distinct slug's id and author, no row when there is none. */
export const planArticleBatch = (maxRequests: i32): PgBatchConfig =>
  planBatch("plan_article", "SELECT a.id, a.author_id FROM articles a WHERE a.slug = q.key", "", maxRequests)

/** A plan's batcher of profiles by username: the user's id and profile, no row when there is none. */
export const planProfileBatch = (maxRequests: i32): PgBatchConfig =>
  planBatch("plan_profile", "SELECT u.id, u.username, u.bio, u.image FROM users u WHERE u.username = q.key", "", maxRequests)

/**
 * A plan's batcher of comments by slug: the article's newest comments, with
 * their authors' ids and profiles, one row with the comment columns NULL when
 * it has none, and no row when the article does not exist.
 */
export const planCommentBatch = (maxRequests: i32): PgBatchConfig =>
  planBatch(
    "plan_comments",
    "SELECT a.id AS article_id, c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image " +
      "FROM articles a LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id " +
      "FROM comments c WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true " +
      "LEFT JOIN users u ON u.id = c.author_id WHERE a.slug = q.key",
    "t.created_at DESC, t.id DESC",
    maxRequests
  )

const planBatch = (name: string, select: string, orderBy: string, maxRequests: i32): PgBatchConfig => {
  const c = new PgBatchConfig()
  c.name = name
  c.select = select
  c.orderBy = orderBy
  c.keyType = PG_BATCH_TEXT
  // Binary rows: the ids and times are read as they are stored.
  c.binary = true
  c.maxRequests = maxRequests
  // A plan's keys are at most PLAN_KEY_BYTES, each escaped at worst to twice its length.
  c.maxBytes = 65536
  c.queueSize = maxRequests
  c.queueBytes = 65536
  // One execution a plan; a second run would be a plan's failed take, made again empty.
  c.runs = 2
  return c
}
