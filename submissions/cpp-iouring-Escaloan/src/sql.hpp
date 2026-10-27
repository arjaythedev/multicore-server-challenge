// Prepared statements. Every statement returns results identical to SPEC.md's reference SQL (checked by the
// differential test in tools/). `$1` is the viewer (int8, 0 = anonymous) wherever favorited/following appear.
//
// Row layouts (binary results):
//   ARTICLE (full):  id, slug, title, description, body, created_at, updated_at, tags text[], favorites_count,
//                    favorited, username, bio, image, following                                      (14)
//   LIST:            n, id, slug, title, description, created_at, updated_at, tags, favorites_count,
//                    favorited, username, bio, image, following; article columns NULL on an empty page (14)
//   COMMENTS:        article_id, c.id, body, created_at, updated_at, username, bio, image, following;
//                    comment columns NULL when the article has none; no row = no article              (9)
//   PROFILE:         username, bio, image, following                                                   (4)
//   USER:            id, username, email, bio, image [, password_hash]                                 (5/6)
#pragma once
#include <cstdint>
#include <string>

namespace sql {

enum Oid : std::uint32_t {
  kBool = 16,
  kInt8 = 20,
  kInt4 = 23,
  kText = 25,
  kInt4Array = 1007,
  kTextArray = 1009,
  kInt8Array = 1016,
  kTimestamptz = 1184,
};

// Statement ids double as prepared-statement names ("s<id>").
enum Stmt : std::uint8_t {
  kTags,
  kUserById,
  kUserByEmail,
  kProfile,
  kArticleBySlug,
  kArticleById,
  kComments,
  kListAll,
  kListTag,
  kListAuthor,
  kListFavorited,
  kFeed,
  kListAllDeep,
  // writes
  kFavorite,
  kUnfavorite,
  kFollow,
  kUnfollow,
  kCommentCreate,
  kCommentDelete,
  kArticleCreate,
  kArticleUpdate,
  kArticleDelete,
  kUserInsert,
  kUserUpdate,
  kStmtCount,
  // Shared-enrichment list forms (sql.cpp): always batched, prepared as "s<id>" with array parameters.
  kListAllShared = kStmtCount,
  kListTagShared,
  kListAuthorShared,
  kListFavoritedShared,
  kFeedShared,
  kStmtTotal
};

struct StmtDef {
  const char* text;
  std::uint8_t nparams;
  std::uint32_t types[6];
};

// Per-article columns over a row source `a` joined to `users u`. Tag names come from primary-key lookups
// (1-4 per article) rather than the hash join over all tags a generic plan picks for a JOIN.
#define CONDUIT_TAGS_COL \
  "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1)"
#define CONDUIT_FULL_COLS                                                                              \
  "a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, " CONDUIT_TAGS_COL ", "  \
  "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id), "                                    \
  "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1), "                 \
  "u.username, u.bio, u.image, "                                                                      \
  "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id)"
// List columns with favorites count and the viewer's favorite from one scan of the article's favorites.
#define CONDUIT_LIST_COLS_FV(FOLLOWING)                                                       \
  "c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, " CONDUIT_TAGS_COL \
  ", fv.fc, fv.fav, u.username, u.bio, u.image, " FOLLOWING
#define CONDUIT_FOLLOWING \
  "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id)"
#define CONDUIT_FV_JOIN                                                                                     \
  " LEFT JOIN users u ON u.id = a.author_id"                                                                \
  " LEFT JOIN LATERAL (SELECT count(*) AS fc, COALESCE(bool_or(f.user_id = $1), false) AS fav FROM favorites f" \
  " WHERE f.article_id = a.id) fv ON true ORDER BY a.id DESC"
#define CONDUIT_PAGE_COLS "a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id"

inline constexpr StmtDef kStmts[kStmtCount] = {
    // kTags: one row, all names sorted.
    {"SELECT ARRAY(SELECT name FROM tags ORDER BY name)", 0, {}},
    // kUserById ($1 id)
    {"SELECT id, username, email, bio, image FROM users WHERE id = $1", 1, {kInt8}},
    // kUserByEmail ($1 email)
    {"SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1", 1, {kText}},
    // kProfile ($1 viewer, $2 username)
    {"SELECT u.username, u.bio, u.image, "
     "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) "
     "FROM users u WHERE u.username = $2",
     2, {kInt8, kText}},
    // kArticleBySlug ($1 viewer, $2 slug)
    {"SELECT " CONDUIT_FULL_COLS " FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = $2", 2,
     {kInt8, kText}},
    // kArticleById ($1 viewer, $2 id)
    {"SELECT " CONDUIT_FULL_COLS " FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = $2", 2,
     {kInt8, kInt8}},
    // kComments ($1 viewer, $2 slug): the viewer's followee set is computed once per execution.
    {"SELECT a.id, c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, "
     "COALESCE(c.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1), false) "
     "FROM articles a "
     "LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c "
     "WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true "
     "LEFT JOIN users u ON u.id = c.author_id "
     "WHERE a.slug = $2 ORDER BY c.created_at DESC, c.id DESC",
     2, {kInt8, kText}},
    // kListAll ($1 viewer, $2 limit, $3 offset). Count walks the PK from the oldest (all-visible) end; the page
    // is cut with a bounded inner LIMIT 100 so the plan never sizes a hash table per call.
    {"WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s) "
     "SELECT " CONDUIT_LIST_COLS_FV(CONDUIT_FOLLOWING) " FROM c LEFT JOIN (SELECT * FROM (SELECT " CONDUIT_PAGE_COLS
     " FROM articles a2 ORDER BY a2.id DESC LIMIT 100 OFFSET $3) b ORDER BY b.id DESC LIMIT $2) a ON true"
     CONDUIT_FV_JOIN,
     3, {kInt8, kInt8, kInt8}},
    // kListTag ($1 viewer, $2 limit, $3 offset, $4 tag)
    {"WITH tg AS (SELECT t.id FROM tags t WHERE t.name = $4), "
     "c AS (SELECT CASE WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT id FROM tg) OFFSET 999 LIMIT 1) "
     "THEN 1000::bigint ELSE (SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT id FROM tg) "
     "LIMIT 1000) s) END AS n) "
     "SELECT " CONDUIT_LIST_COLS_FV(CONDUIT_FOLLOWING) " FROM c LEFT JOIN (SELECT " CONDUIT_PAGE_COLS
     " FROM (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT id FROM tg) "
     "ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) p JOIN articles a2 ON a2.id = p.article_id) a ON true"
     CONDUIT_FV_JOIN,
     4, {kInt8, kInt8, kInt8, kText}},
    // kListAuthor ($1 viewer, $2 limit, $3 offset, $4 username)
    {"WITH au AS (SELECT id FROM users WHERE username = $4), "
     "c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles WHERE author_id = (SELECT id FROM au) LIMIT 1000) s) "
     "SELECT " CONDUIT_LIST_COLS_FV(CONDUIT_FOLLOWING) " FROM c LEFT JOIN (SELECT " CONDUIT_PAGE_COLS
     " FROM articles a2 WHERE a2.author_id = (SELECT id FROM au) ORDER BY a2.id DESC LIMIT $2 OFFSET $3) a ON true"
     CONDUIT_FV_JOIN,
     4, {kInt8, kInt8, kInt8, kText}},
    // kListFavorited ($1 viewer, $2 limit, $3 offset, $4 username)
    {"WITH fu AS (SELECT id FROM users WHERE username = $4), "
     "c AS (SELECT count(*) AS n FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT id FROM fu) LIMIT 1000) s) "
     "SELECT " CONDUIT_LIST_COLS_FV(CONDUIT_FOLLOWING) " FROM c LEFT JOIN (SELECT " CONDUIT_PAGE_COLS
     " FROM (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT id FROM fu) "
     "ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) p JOIN articles a2 ON a2.id = p.article_id) a ON true"
     CONDUIT_FV_JOIN,
     4, {kInt8, kInt8, kInt8, kText}},
    // kFeed ($1 viewer, $2 limit, $3 offset, $4 limit + offset). Every feed author is a followee in the same
    // snapshot, so `following` is the constant true.
    {"WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles a3 WHERE a3.author_id = "
     "ANY(ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1)) LIMIT 1000) s) "
     "SELECT " CONDUIT_LIST_COLS_FV("true") " FROM c LEFT JOIN (SELECT " CONDUIT_PAGE_COLS
     " FROM (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a3.id FROM articles a3 "
     "WHERE a3.author_id = fo.followee_id ORDER BY a3.id DESC LIMIT $4) x WHERE fo.follower_id = $1 "
     "ORDER BY x.id DESC LIMIT $2 OFFSET $3) p JOIN articles a2 ON a2.id = p.id) a ON true" CONDUIT_FV_JOIN,
     4, {kInt8, kInt8, kInt8, kInt8}},
    // kListAllDeep: offsets past cfg::kDeepOffset skip ids with an index-only scan, then fetch the page.
    {"WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s) "
     "SELECT " CONDUIT_LIST_COLS_FV(CONDUIT_FOLLOWING) " FROM c LEFT JOIN (SELECT " CONDUIT_PAGE_COLS
     " FROM (SELECT id FROM articles ORDER BY id DESC LIMIT $2 OFFSET $3) p JOIN articles a2 ON a2.id = p.id) a ON true"
     CONDUIT_FV_JOIN,
     3, {kInt8, kInt8, kInt8}},

    // ---- writes ----
    // kFavorite ($1 viewer, $2 slug): returns the article id (no row = 404). Followed by kArticleBySlug.
    {"WITH t AS (SELECT id FROM articles WHERE slug = $2), "
     "w AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING) "
     "SELECT id FROM t",
     2, {kInt8, kText}},
    // kUnfavorite ($1 viewer, $2 slug)
    {"WITH t AS (SELECT id FROM articles WHERE slug = $2), "
     "w AS (DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM t)) "
     "SELECT id FROM t",
     2, {kInt8, kText}},
    // kFollow ($1 viewer, $2 username) -> username, bio, image
    {"WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), "
     "w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING) "
     "SELECT username, bio, image FROM t",
     2, {kInt8, kText}},
    // kUnfollow ($1 viewer, $2 username)
    {"WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), "
     "w AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM t)) "
     "SELECT username, bio, image FROM t",
     2, {kInt8, kText}},
    // kCommentCreate ($1 slug, $2 viewer, $3 body) -> id, body, created_at, updated_at, username, bio, image
    {"WITH t AS (SELECT id FROM articles WHERE slug = $1), "
     "c AS (INSERT INTO comments (article_id, author_id, body) SELECT id, $2, $3 FROM t "
     "RETURNING id, body, created_at, updated_at, author_id) "
     "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image FROM c JOIN users u ON u.id = c.author_id",
     3, {kText, kInt8, kText}},
    // kCommentDelete ($1 comment id, $2 slug, $3 viewer) -> author_id; deletes only when the viewer is the author
    {"WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id "
     "WHERE c.id = $1 AND a.slug = $2), "
     "w AS (DELETE FROM comments WHERE id = (SELECT id FROM t WHERE author_id = $3)) "
     "SELECT author_id FROM t",
     3, {kInt8, kText, kInt8}},
    // kArticleCreate ($1 viewer, $2 title, $3 description, $4 body, $5 tags text[]) -> ARTICLE layout.
    // One statement, one implicit transaction. Existing tags are read without locking; ON CONFLICT DO UPDATE
    // returns the id of a tag inserted concurrently by another transaction (invisible to `existing`).
    {"WITH n AS (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id), "
     "a AS (INSERT INTO articles (id, slug, author_id, title, description, body) "
     "SELECT n.id, trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id, "
     "$1, $2, $3, $4 FROM n RETURNING id, slug, title, description, body, created_at, updated_at, author_id), "
     "existing AS MATERIALIZED (SELECT id, name FROM tags WHERE name = ANY($5::text[])), "
     "t AS (INSERT INTO tags (name) SELECT name FROM (SELECT DISTINCT unnest($5::text[]) AS name) names "
     "WHERE NOT EXISTS (SELECT 1 FROM existing e WHERE e.name = names.name) ORDER BY name "
     "ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id, name), "
     "all_tags AS (SELECT id, name FROM existing UNION ALL SELECT id, name FROM t), "
     "x AS (INSERT INTO article_tags (article_id, tag_id) SELECT a.id, all_tags.id FROM a, all_tags) "
     "SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, "
     "ARRAY(SELECT name FROM all_tags ORDER BY name), 0::bigint, false, u.username, u.bio, u.image, "
     "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) "
     "FROM a JOIN users u ON u.id = a.author_id",
     5, {kInt8, kText, kText, kText, kTextArray}},
    // kArticleUpdate ($1 slug, $2 title, $3 description, $4 body, $5 viewer); NULL = unchanged.
    // -> id, author_id, rows updated (0 when the viewer is not the author)
    {"WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1), "
     "w AS (UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), "
     "body = COALESCE($4, body), "
     "slug = CASE WHEN $2::text IS NULL THEN slug ELSE trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END, "
     "updated_at = now() WHERE id = (SELECT id FROM t WHERE author_id = $5) RETURNING 1) "
     "SELECT t.id, t.author_id, (SELECT count(*) FROM w) FROM t",
     5, {kText, kText, kText, kText, kInt8}},
    // kArticleDelete ($1 slug, $2 viewer) -> author_id
    {"WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1), "
     "w AS (DELETE FROM articles WHERE id = (SELECT id FROM t WHERE author_id = $2)) "
     "SELECT author_id FROM t",
     2, {kText, kInt8}},
    // kUserInsert ($1 username, $2 email, $3 password_hash) -> USER
    {"INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image",
     3, {kText, kText, kText}},
    // kUserUpdate ($1 id, $2 email, $3 username, $4 password_hash, $5 bio, $6 image); NULL = unchanged
    {"UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), "
     "password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) "
     "WHERE id = $1 RETURNING id, username, email, bio, image",
     6, {kInt8, kText, kText, kText, kText, kText}},
};

// Batched forms (sql.cpp): prepared as "b<id>" for statements where batchable() is true.
bool batchable(int stmt);
// Shared-enrichment forms: the list kind a shared id serves, its text, and the shared id for a list kind (-1: none).
inline int base_kind(int stmt) {
  switch (stmt) {
    case kListAllShared: return kListAll;
    case kListTagShared: return kListTag;
    case kListAuthorShared: return kListAuthor;
    case kListFavoritedShared: return kListFavorited;
    case kFeedShared: return kFeed;
    default: return stmt;
  }
}
std::string shared_text(int stmt);
int shared_for(int list_kind);
std::string batched_text(int stmt);
std::uint32_t array_oid(std::uint32_t elem);

}  // namespace sql
