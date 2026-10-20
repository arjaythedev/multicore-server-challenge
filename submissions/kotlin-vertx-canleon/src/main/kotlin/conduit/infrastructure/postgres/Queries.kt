package conduit.infrastructure.postgres

// SQL for the Postgres repositories, with `?` placeholders (numbered $1, $2, ... when executed, see PostgresClient.kt).
// The parameters of each statement are listed above it in binding order. Based on SPEC.md's reference SQL, with two
// plan fixes measured with EXPLAIN ANALYZE on the full seed (same results, same indexes, less work):
// - tag names are looked up per tag through tags_pkey instead of hash-joining all 200 tags for every article row;
// - every paged list picks its page of ids first (index-only), so the per-row subqueries run only for the rows
//   returned, not for the rows OFFSET skips (page 5: 4.1 ms -> 0.3 ms).

/** An article's tag names, sorted: 2-3 primary-key lookups. */
private const val TAG_LIST =
    "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1)"

/** Parameters: viewer id, viewer id. */
private const val ARTICLE_LIST_SELECT = """
SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       $TAG_LIST AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = ?) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ? AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
"""

/**
 * Like ARTICLE_LIST_SELECT, for the feed: every feed article is by an author the viewer follows (the same snapshot
 * selected it through follows), so `following` is true without checking. Parameters: viewer id.
 */
private const val FEED_SELECT = """
SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       $TAG_LIST AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = ?) AS favorited,
       u.username, u.bio, u.image,
       true AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
"""

/** Parameters: viewer id, viewer id. */
private const val ARTICLE_FULL_SELECT = """
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
       $TAG_LIST AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = ?) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ? AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
"""

/** SPEC's SLUGIFY of one parameter. */
private const val SLUGIFY = "trim(both '-' from lower(regexp_replace(?, '[^A-Za-z0-9]+', '-', 'g')))"

// ---- users ----

/** username, email, password hash */
internal const val USER_INSERT = """
INSERT INTO users (username, email, password_hash) VALUES (?, ?, ?)
RETURNING id, username, email, bio, image"""

/** email */
internal const val USER_BY_EMAIL = "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = ?"

/** id */
internal const val USER_BY_ID = "SELECT id, username, email, bio, image FROM users WHERE id = ?"

/** email, username, password hash, bio, image (null: unchanged), id */
internal const val USER_UPDATE = """
UPDATE users SET email = COALESCE(?, email), username = COALESCE(?, username),
                 password_hash = COALESCE(?, password_hash), bio = COALESCE(?, bio), image = COALESCE(?, image)
 WHERE id = ?
RETURNING id, username, email, bio, image"""

// ---- profiles ----

/** viewer id, username */
internal const val PROFILE = """
SELECT u.id, u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ? AND fo.followee_id = u.id) AS following
  FROM users u WHERE u.username = ?"""

/**
 * username, follower id. Finds the user and follows them in one statement (idempotent); no row: no such user.
 * The profile comes from the lookup, so the snapshot rule (see FAVORITE_BY_SLUG) doesn't matter here.
 */
internal const val FOLLOW_BY_USERNAME = """
WITH target AS (SELECT id, username, bio, image FROM users WHERE username = ?),
     added AS (INSERT INTO follows (follower_id, followee_id) SELECT ?, id FROM target ON CONFLICT DO NOTHING)
SELECT username, bio, image, true AS following FROM target"""

/** username, follower id. Finds the user and unfollows them in one statement; no row: no such user. */
internal const val UNFOLLOW_BY_USERNAME = """
WITH target AS (SELECT id, username, bio, image FROM users WHERE username = ?),
     removed AS (DELETE FROM follows WHERE follower_id = ? AND followee_id IN (SELECT id FROM target))
SELECT username, bio, image, false AS following FROM target"""

// ---- article lists: one page and the count capped at 1,000 ----
// The page and its count are parts, combined into one statement below (one round trip instead of two).
// Every page of ids is bounded twice: "OFFSET ? LIMIT 100" inside, then "LIMIT ?" (the real limit, 1-100) outside.
// Same rows as "LIMIT ? OFFSET ?", but a generic plan (prepared statement) then knows the page has at most 100 rows,
// instead of assuming a parameter LIMIT returns 10% of the table.

/** viewer id, viewer id, offset, limit */
private const val LIST_ALL = ARTICLE_LIST_SELECT +
    "WHERE a.id IN (SELECT b.id FROM (SELECT p.id FROM articles p ORDER BY p.id DESC OFFSET ? LIMIT 100) b " +
    "ORDER BY b.id DESC LIMIT ?) ORDER BY a.id DESC"

private const val COUNT_ALL = "SELECT count(*) AS articles_count FROM (SELECT 1 FROM articles a LIMIT 1000) s"

/** viewer id, viewer id, tag name, offset, limit */
private const val LIST_BY_TAG = ARTICLE_LIST_SELECT +
    "WHERE a.id IN (SELECT b.article_id FROM (SELECT at.article_id FROM article_tags at " +
    "WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = ?) ORDER BY at.article_id DESC OFFSET ? LIMIT 100) b " +
    "ORDER BY b.article_id DESC LIMIT ?) ORDER BY a.id DESC"

/** tag name */
private const val COUNT_BY_TAG =
    "SELECT count(*) AS articles_count FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = ?) LIMIT 1000) s"

/** viewer id, viewer id, author username, offset, limit */
private const val LIST_BY_AUTHOR = ARTICLE_LIST_SELECT +
    "WHERE a.id IN (SELECT b.id FROM (SELECT p.id FROM articles p " +
    "WHERE p.author_id = (SELECT au.id FROM users au WHERE au.username = ?) ORDER BY p.id DESC OFFSET ? LIMIT 100) b " +
    "ORDER BY b.id DESC LIMIT ?) ORDER BY a.id DESC"

/** author username */
private const val COUNT_BY_AUTHOR =
    "SELECT count(*) AS articles_count FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = ?) LIMIT 1000) s"

/** viewer id, viewer id, username of the user who favorited, offset, limit */
private const val LIST_FAVORITED_BY = ARTICLE_LIST_SELECT +
    "WHERE a.id IN (SELECT b.article_id FROM (SELECT f.article_id FROM favorites f " +
    "WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = ?) ORDER BY f.article_id DESC OFFSET ? LIMIT 100) b " +
    "ORDER BY b.article_id DESC LIMIT ?) ORDER BY a.id DESC"

/** username of the user who favorited */
private const val COUNT_FAVORITED_BY =
    "SELECT count(*) AS articles_count FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = ?) LIMIT 1000) s"

/** user id, limit, offset (per followed author; added as bigint so a huge offset can't overflow), user id, offset, limit */
private const val FEED = FEED_SELECT +
    "WHERE a.id IN (SELECT b.id FROM (SELECT x.id FROM follows fo CROSS JOIN LATERAL " +
    "(SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT (?::bigint + ?::bigint)) x " +
    "WHERE fo.follower_id = ? ORDER BY x.id DESC OFFSET ? LIMIT 100) b ORDER BY b.id DESC LIMIT ?) ORDER BY a.id DESC"

/** user id */
private const val COUNT_FEED = "SELECT count(*) AS articles_count FROM (SELECT 1 FROM articles a WHERE a.author_id IN " +
    "(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = ?) LIMIT 1000) s"

/**
 * The count (one row) with the page left-joined onto it: one row per article, each carrying articles_count. An empty
 * page (offset past the end) still gives one row, with a NULL id, so the count is never lost.
 * Parameters: the count's, then the page's.
 */
private const val PAGE_WITH_COUNT_START = "SELECT total.articles_count, page.* FROM ("
private const val PAGE_WITH_COUNT_MIDDLE = ") total LEFT JOIN ("
private const val PAGE_WITH_COUNT_END = ") page ON true ORDER BY page.id DESC"

/** viewer id, viewer id, offset, limit */
internal const val PAGE_ALL = PAGE_WITH_COUNT_START + COUNT_ALL + PAGE_WITH_COUNT_MIDDLE + LIST_ALL + PAGE_WITH_COUNT_END

/** tag name; viewer id, viewer id, tag name, offset, limit */
internal const val PAGE_BY_TAG = PAGE_WITH_COUNT_START + COUNT_BY_TAG + PAGE_WITH_COUNT_MIDDLE + LIST_BY_TAG + PAGE_WITH_COUNT_END

/** author username; viewer id, viewer id, author username, offset, limit */
internal const val PAGE_BY_AUTHOR = PAGE_WITH_COUNT_START + COUNT_BY_AUTHOR + PAGE_WITH_COUNT_MIDDLE + LIST_BY_AUTHOR + PAGE_WITH_COUNT_END

/** username; viewer id, viewer id, username, offset, limit */
internal const val PAGE_FAVORITED_BY =
    PAGE_WITH_COUNT_START + COUNT_FAVORITED_BY + PAGE_WITH_COUNT_MIDDLE + LIST_FAVORITED_BY + PAGE_WITH_COUNT_END

/** user id; user id, limit, offset, user id, offset, limit */
internal const val PAGE_FEED = PAGE_WITH_COUNT_START + COUNT_FEED + PAGE_WITH_COUNT_MIDDLE + FEED + PAGE_WITH_COUNT_END

// ---- single articles ----

/** viewer id, viewer id, slug */
internal const val ARTICLE_BY_SLUG = ARTICLE_FULL_SELECT + "WHERE a.slug = ?"

/** viewer id, viewer id, article id */
internal const val ARTICLE_BY_ID = ARTICLE_FULL_SELECT + "WHERE a.id = ?"

/** tag names (text[]). Runs before ARTICLE_INSERT, so the tags exist when the article links them. */
internal const val TAGS_INSERT = "INSERT INTO tags (name) SELECT DISTINCT unnest(?::text[]) ON CONFLICT (name) DO NOTHING"

/**
 * title (for the slug), author id, title, description, body, tag names (text[]).
 * Inserts the article and links its tags in one statement, so both happen or neither does.
 */
internal const val ARTICLE_INSERT = """
WITH created AS (
  INSERT INTO articles (id, slug, author_id, title, description, body)
  SELECT n.id, $SLUGIFY || '-' || n.id, ?, ?, ?, ?
    FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
  RETURNING id),
     linked AS (
  INSERT INTO article_tags (article_id, tag_id)
  SELECT created.id, t.id FROM created, tags t WHERE t.name = ANY(?::text[]))
SELECT id FROM created"""

/** slug */
internal const val ARTICLE_OWNER = "SELECT id, author_id FROM articles WHERE slug = ?"

/** title, description, body (null: unchanged), title, title (for the slug), article id */
internal const val ARTICLE_UPDATE = """
UPDATE articles SET title = COALESCE(?, title), description = COALESCE(?, description), body = COALESCE(?, body),
       slug = CASE WHEN ?::text IS NULL THEN slug ELSE $SLUGIFY || '-' || id END,
       updated_at = now()
 WHERE id = ?"""

/** article id */
internal const val ARTICLE_DELETE = "DELETE FROM articles WHERE id = ?"

/**
 * slug, user id, user id. Finds the article, favorites it (idempotent) and returns it as the user now sees it, in one
 * statement; no row: no such article.
 * Snapshot rule: every part of one statement sees the data as it was before the statement, so the count doesn't see
 * the row the CTE just inserted; adding the inserted rows (0 or 1) gives the count after the change.
 */
internal const val FAVORITE_BY_SLUG = """
WITH target AS (SELECT id FROM articles WHERE slug = ?),
     added AS (INSERT INTO favorites (user_id, article_id) SELECT ?, id FROM target ON CONFLICT DO NOTHING RETURNING 1)
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
       $TAG_LIST AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) + (SELECT count(*) FROM added) AS favorites_count,
       true AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ? AND fo.followee_id = a.author_id) AS following
  FROM target JOIN articles a ON a.id = target.id JOIN users u ON u.id = a.author_id"""

/** slug, user id, user id. Like FAVORITE_BY_SLUG, but removes the favorite: the count subtracts the deleted rows. */
internal const val UNFAVORITE_BY_SLUG = """
WITH target AS (SELECT id FROM articles WHERE slug = ?),
     removed AS (DELETE FROM favorites WHERE user_id = ? AND article_id IN (SELECT id FROM target) RETURNING 1)
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
       $TAG_LIST AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) - (SELECT count(*) FROM removed) AS favorites_count,
       false AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ? AND fo.followee_id = a.author_id) AS following
  FROM target JOIN articles a ON a.id = target.id JOIN users u ON u.id = a.author_id"""

// ---- comments ----

/**
 * article slug, viewer id. The article looked up by slug, with its newest 100 comments left-joined: no row means no
 * such article (404); one row with a NULL comment id means an article without comments.
 */
internal const val COMMENTS_BY_ARTICLE_SLUG = """
SELECT target.id AS article_id, comment.*
  FROM (SELECT id FROM articles WHERE slug = ?) target
  LEFT JOIN LATERAL (
       SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
              EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ? AND fo.followee_id = c.author_id) AS following
         FROM comments c JOIN users u ON u.id = c.author_id
        WHERE c.article_id = target.id
        ORDER BY c.created_at DESC, c.id DESC
        LIMIT 100) comment ON true
 ORDER BY comment.created_at DESC, comment.id DESC"""

/**
 * article slug, author id, body. Finds the article and adds the comment in one statement; no row: no such article.
 * SPEC: a new comment has author.following = false.
 */
internal const val COMMENT_INSERT_BY_SLUG = """
WITH target AS (SELECT id FROM articles WHERE slug = ?),
     c AS (INSERT INTO comments (article_id, author_id, body) SELECT id, ?, ? FROM target
           RETURNING id, body, created_at, updated_at, author_id)
SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, false AS following
  FROM c JOIN users u ON u.id = c.author_id"""

/** comment id, article slug */
internal const val COMMENT_OWNER = """
SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
 WHERE c.id = ? AND a.slug = ?"""

/** comment id */
internal const val COMMENT_DELETE = "DELETE FROM comments WHERE id = ?"

// ---- tags ----

internal const val TAGS = "SELECT name FROM tags ORDER BY name"
