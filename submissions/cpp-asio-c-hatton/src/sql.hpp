// Every statement the server runs, prepared once per connection. The results match SPEC.md's reference SQL;
// where the SQL differs it says why.
#pragma once
#include <string>
#include <vector>

enum StmtId {
  S_TAGS,
  S_REGISTER,
  S_LOGIN,
  S_USER,
  S_UPDATE_USER,
  S_PROFILE,
  S_FOLLOW,
  S_UNFOLLOW,
  S_LIST_ALL,
  S_LIST_ALL_DEEP,
  S_COUNT_ALL,
  S_LIST_TAG,
  S_COUNT_TAG,
  S_LIST_AUTHOR,
  S_LIST_AUTHOR_DEEP,
  S_COUNT_AUTHOR,
  S_LIST_FAV,
  S_COUNT_FAV,
  S_FEED,
  S_COUNT_FEED,
  S_ARTICLE_SLUG,
  S_ARTICLE_ID,
  S_ARTICLE_CURR,
  S_COMMENTS,
  S_CREATE_ARTICLE,
  S_CREATE_TAGS,
  S_CREATE_ARTICLE_TAGS,
  S_ARTICLE_OWNER,
  S_UPDATE_ARTICLE,
  S_DELETE_ARTICLE,
  S_FAVORITE,
  S_UNFAVORITE,
  S_CREATE_COMMENT,
  S_COMMENT_OWNER,
  S_DELETE_COMMENT,
  S_COUNT
};

// Article columns: id, slug, title, description, [body,] created_at, updated_at, tag_list, favorites_count,
// favorited, username, bio, image, following [, extra]. tag_list looks each tag up by primary key (instead of
// a hash join that scans all of tags for every article); the order is the same, by name.
inline std::string article_cols(bool body, const std::string& extra = "") {
  return std::string("SELECT a.id, a.slug, a.title, a.description, ") + (body ? "a.body, " : "") +
         "a.created_at, a.updated_at, "
         "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at "
         "WHERE at.article_id = a.id ORDER BY 1) AS tag_list, "
         "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, "
         "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, "
         "u.username, u.bio, u.image, "
         "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following" +
         extra;
}
inline std::string article_select(bool body) {
  return article_cols(body) + " FROM articles a JOIN users u ON u.id = a.author_id";
}

// Lists pick their page first, in a subquery, and only then join users and compute tags, counts and flags
// for those rows. (With LIMIT/OFFSET directly on the decorated query, Postgres decorates the skipped OFFSET
// rows too: page 5 cost five pages' worth of subqueries.)
static const char* kListCols = "id, slug, title, description, created_at, updated_at, author_id";

#define SLUGIFY(x) "trim(both '-' from lower(regexp_replace(" x ", '[^A-Za-z0-9]+', '-', 'g')))"

inline std::vector<std::string> all_sql() {
  const std::string F = article_select(true);
  std::vector<std::string> s(S_COUNT);
  s[S_TAGS] = "SELECT name FROM tags ORDER BY name";
  s[S_REGISTER] = "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image";
  s[S_LOGIN] = "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1";
  s[S_USER] = "SELECT id, username, email, bio, image FROM users WHERE id = $1";
  s[S_UPDATE_USER] =
      "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), "
      "password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) "
      "WHERE id = $1 RETURNING id, username, email, bio, image";
  s[S_PROFILE] =
      "SELECT u.id, u.username, u.bio, u.image, "
      "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following "
      "FROM users u WHERE u.username = $2";
  // The lookup and the write in one statement (one round trip); no row means 404 and nothing was written.
  s[S_FOLLOW] =
      "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2), "
      "i AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, u.id FROM u ON CONFLICT DO NOTHING) "
      "SELECT username, bio, image FROM u";
  s[S_UNFOLLOW] =
      "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2), "
      "d AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id IN (SELECT id FROM u)) "
      "SELECT username, bio, image FROM u";
  // Each list page also carries its capped count as a last column: an uncorrelated scalar subquery, which
  // Postgres runs once per execution (an InitPlan), so a list costs one statement instead of two. An empty
  // page carries no count; the handler then runs the S_COUNT_* statement on its own.
  auto with_count = [&](const std::string& count) { return article_cols(false, ", (" + count + ") AS total"); };
  const std::string cols = kListCols;
  const std::string join_page = " JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id ORDER BY a.id DESC";
  // min(1000, count): checks for a 1000th row with an index-only scan of the primary key from the oldest
  // (all-visible) pages, counting only when there are fewer.
  s[S_COUNT_ALL] =
      "SELECT CASE WHEN EXISTS (SELECT 1 FROM articles a ORDER BY a.id OFFSET 999) THEN 1000 "
      "ELSE (SELECT count(*) FROM articles) END";
  s[S_COUNT_TAG] =
      "SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = "
      "(SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s";
  s[S_COUNT_AUTHOR] =
      "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = "
      "(SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s";
  s[S_COUNT_FAV] =
      "SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = "
      "(SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s";
  // = ANY(ARRAY(...)): one index scan over all followees instead of a nested loop of rescans.
  s[S_COUNT_FEED] =
      "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = ANY (ARRAY("
      "SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1)) LIMIT 1000) s";
  auto p4 = [](std::string q) {  // the count statements take the filter as $1; inside a list it is $4
    size_t i = q.find("$1");
    return q.replace(i, 2, "$4");
  };
  s[S_LIST_ALL] = with_count(s[S_COUNT_ALL]) + " FROM (SELECT " + cols +
                  " FROM articles ORDER BY id DESC LIMIT $2 OFFSET $3) a JOIN users u ON u.id = a.author_id ORDER BY a.id DESC";
  s[S_LIST_AUTHOR] = with_count(p4(s[S_COUNT_AUTHOR])) + " FROM (SELECT " + cols +
                     " FROM articles WHERE author_id = (SELECT au.id FROM users au WHERE au.username = $4) "
                     "ORDER BY id DESC LIMIT $2 OFFSET $3) a JOIN users u ON u.id = a.author_id ORDER BY a.id DESC";
  // Deep pages (large OFFSET): skip rows in an index-only scan of ids, then fetch the page's rows. A little
  // slower for the first pages, much faster when thousands of rows are skipped.
  s[S_LIST_ALL_DEEP] = with_count(s[S_COUNT_ALL]) +
                       " FROM (SELECT id FROM articles ORDER BY id DESC LIMIT $2 OFFSET $3) p" + join_page;
  s[S_LIST_AUTHOR_DEEP] = with_count(p4(s[S_COUNT_AUTHOR])) +
                          " FROM (SELECT id FROM articles WHERE author_id = (SELECT au.id FROM users au WHERE au.username = $4) "
                          "ORDER BY id DESC LIMIT $2 OFFSET $3) p" + join_page;
  s[S_LIST_TAG] = with_count(p4(s[S_COUNT_TAG])) +
                  " FROM (SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = "
                  "(SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) p" + join_page;
  s[S_LIST_FAV] = with_count(p4(s[S_COUNT_FAV])) +
                  " FROM (SELECT f.article_id AS id FROM favorites f WHERE f.user_id = "
                  "(SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) p" + join_page;
  s[S_FEED] = with_count(s[S_COUNT_FEED]) +
              " FROM (SELECT x.id FROM follows fo CROSS JOIN LATERAL "
              "(SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC "
              "LIMIT ($2::int + $3::int)) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) p" + join_page;
  s[S_ARTICLE_SLUG] = F + " WHERE a.slug = $2";
  s[S_ARTICLE_ID] = F + " WHERE a.id = $2";
  // After S_CREATE_ARTICLE on the same connection: the id it just took from the sequence.
  s[S_ARTICLE_CURR] = F + " WHERE a.id = (SELECT currval(pg_get_serial_sequence('articles', 'id')))";
  // The article lookup and its comments in one statement: no row = 404, one row with a NULL comment id = no comments.
  s[S_COMMENTS] =
      "SELECT a.id, c.id, c.body, c.created_at, c.updated_at, c.username, c.bio, c.image, c.following "
      "FROM articles a LEFT JOIN LATERAL ("
      "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, "
      "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following "
      "FROM comments c JOIN users u ON u.id = c.author_id WHERE c.article_id = a.id "
      "ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true "
      "WHERE a.slug = $2 ORDER BY c.created_at DESC, c.id DESC";
  s[S_CREATE_ARTICLE] =
      "INSERT INTO articles (id, slug, author_id, title, description, body) "
      "SELECT n.id, " SLUGIFY("$2") " || '-' || n.id, $1, $2, $3, $4 "
      "FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n RETURNING id";
  s[S_CREATE_TAGS] = "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING";
  s[S_CREATE_ARTICLE_TAGS] =
      "INSERT INTO article_tags (article_id, tag_id) "
      "SELECT (SELECT currval(pg_get_serial_sequence('articles', 'id'))), t.id FROM tags t WHERE t.name = ANY($1::text[])";
  s[S_ARTICLE_OWNER] = "SELECT id, author_id FROM articles WHERE slug = $1";
  s[S_UPDATE_ARTICLE] =
      "UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body), "
      "slug = CASE WHEN $2::text IS NULL THEN slug ELSE " SLUGIFY("$2") " || '-' || id END, updated_at = now() "
      "WHERE id = $1";
  s[S_DELETE_ARTICLE] = "DELETE FROM articles WHERE id = $1";
  s[S_FAVORITE] =
      "INSERT INTO favorites (user_id, article_id) SELECT $1, a.id FROM articles a WHERE a.slug = $2 ON CONFLICT DO NOTHING";
  s[S_UNFAVORITE] = "DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT a.id FROM articles a WHERE a.slug = $2)";
  s[S_CREATE_COMMENT] =
      "WITH a AS (SELECT id FROM articles WHERE slug = $2), "
      "c AS (INSERT INTO comments (article_id, author_id, body) SELECT a.id, $1, $3 FROM a "
      "RETURNING id, body, created_at, updated_at, author_id) "
      "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image FROM c JOIN users u ON u.id = c.author_id";
  s[S_COMMENT_OWNER] =
      "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $1 AND a.slug = $2";
  s[S_DELETE_COMMENT] = "DELETE FROM comments WHERE id = $1";
  return s;
}
