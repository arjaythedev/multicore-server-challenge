//// The SQL. Same results as SPEC.md's reference SQL, in fewer statements: a list page and its capped count
//// are one statement, slug lookups fold into the statement that needs them, and writes return the response
//// row themselves. `$1` is the viewer wherever a statement has one. Every statement is prepared once per
//// connection at startup under the name `s<index>`.
////
//// Several statements follow the shapes in FooVoo's MIT-licensed elixir-raw submission to the same challenge.

import conduit/pg/proto
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Statement {
  Statement(index: Int, query: String, params: List(Int))
}

/// Batched variants are prepared under `index + batch_offset`.
pub const batch_offset = 100

const slugify = "trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g')))"

// Tag names by primary key per tag (a correlated scalar subquery) instead of a hash join over the tags table.
const tag_list = "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1)"

const tail_head = "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, u.username, u.bio, u.image, "

const following = "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following"

// Column order the handler's article writers read:
// list: id, slug, title, description, created_at, updated_at, tag_list, favorites_count, favorited, username, bio, image, following
// full: the same with body after description.
fn list_cols() -> String {
  "a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, " <> tag_list <> " AS tag_list, " <> tail_head <> following
}

fn full_cols() -> String {
  "a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, " <> tag_list <> " AS tag_list, " <> tail_head <> following
}

// A feed row's author was reached through the viewer's follows row in this same statement snapshot.
fn feed_cols() -> String {
  "a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, " <> tag_list <> " AS tag_list, " <> tail_head <> "true AS following"
}

// The LEFT JOIN LATERAL keeps the count row when the page is empty (then every page column is NULL).
// Page ids are cut with a constant LIMIT 100 (the API's maximum) before the joins and per-row work, so the
// planner's row estimate stays small whether the plan is custom, generic or batched.
fn list_page(count: String, page_where: String, page_tail: String) -> String {
  "WITH c AS (SELECT count(*) AS n FROM (" <> count <> ") s) SELECT c.n, p.* FROM c LEFT JOIN LATERAL (SELECT " <> list_cols() <> " FROM articles a JOIN users u ON u.id = a.author_id " <> page_where <> " " <> page_tail <> ") p ON true ORDER BY p.id DESC"
}

pub const tags = 0

pub const list_all = 1

pub const list_tag = 2

pub const list_author = 3

pub const list_favorited = 4

pub const feed = 5

pub const article_by_slug = 6

pub const comments = 7

pub const profile = 8

pub const follow = 9

pub const unfollow = 10

pub const favorite = 11

pub const unfavorite = 12

pub const comment_create = 13

pub const comment_delete = 14

pub const comment_probe = 15

pub const article_delete = 16

pub const article_probe = 17

pub const article_update = 18

pub const article_create_plain = 19

pub const tags_upsert = 20

pub const article_create_tagged = 21

pub const user_insert = 22

pub const user_by_email = 23

pub const user_by_id = 24

pub const user_update = 25

const int8 = proto.oid_int8

const text = proto.oid_text

const text_array = proto.oid_text_array

pub fn all() -> List(Statement) {
  [
    Statement(tags, "SELECT ARRAY(SELECT name FROM tags ORDER BY name)", []),
    Statement(
      list_all,
      list_page(
        "SELECT 1 FROM articles a LIMIT 1000",
        "WHERE a.id IN (SELECT q.id FROM (SELECT a2.id FROM articles a2 ORDER BY a2.id DESC OFFSET $3 LIMIT 100) q ORDER BY q.id DESC LIMIT $2)",
        "ORDER BY a.id DESC",
      ),
      [int8, int8, int8],
    ),
    Statement(
      list_tag,
      list_page(
        "SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) LIMIT 1000",
        "WHERE a.id IN (SELECT q.article_id FROM (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC OFFSET $3 LIMIT 100) q ORDER BY q.article_id DESC LIMIT $2)",
        "ORDER BY a.id DESC",
      ),
      [int8, int8, int8, text],
    ),
    Statement(
      list_author,
      list_page(
        "SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $4) LIMIT 1000",
        "WHERE a.id IN (SELECT q.id FROM (SELECT a2.id FROM articles a2 WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a2.id DESC OFFSET $3 LIMIT 100) q ORDER BY q.id DESC LIMIT $2)",
        "ORDER BY a.id DESC",
      ),
      [int8, int8, int8, text],
    ),
    Statement(
      list_favorited,
      list_page(
        "SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) LIMIT 1000",
        "WHERE a.id IN (SELECT q.article_id FROM (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC OFFSET $3 LIMIT 100) q ORDER BY q.article_id DESC LIMIT $2)",
        "ORDER BY a.id DESC",
      ),
      [int8, int8, int8, text],
    ),
    // $4 = limit + offset (saturated by the caller). The page ids are materialized first so the per-row work
    // runs for one page only.
    Statement(
      feed,
      "WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s), "
        <> "page_ids AS MATERIALIZED (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT $4) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) "
        <> "SELECT c.n, p.* FROM c LEFT JOIN LATERAL (SELECT " <> feed_cols() <> " FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id IN (SELECT id FROM page_ids) ORDER BY a.id DESC) p ON true ORDER BY p.id DESC",
      [int8, int8, int8, int8],
    ),
    Statement(
      article_by_slug,
      "SELECT " <> full_cols() <> " FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = $2",
      [int8, text],
    ),
    // No row = unknown article; one row with NULL x.id = no comments.
    Statement(
      comments,
      "SELECT a.id, x.id, x.body, x.created_at, x.updated_at, x.username, x.bio, x.image, x.following FROM articles a LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following FROM comments c JOIN users u ON u.id = c.author_id WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) x ON true WHERE a.slug = $2 ORDER BY x.created_at DESC, x.id DESC",
      [int8, text],
    ),
    Statement(
      profile,
      "SELECT u.id, u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following FROM users u WHERE u.username = $2",
      [int8, text],
    ),
    // Data-modifying CTEs run even when unreferenced.
    Statement(
      follow,
      "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, t.id FROM t ON CONFLICT DO NOTHING) SELECT t.username, t.bio, t.image FROM t",
      [int8, text],
    ),
    Statement(
      unfollow,
      "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), w AS (DELETE FROM follows fo USING t WHERE fo.follower_id = $1 AND fo.followee_id = t.id) SELECT t.username, t.bio, t.image FROM t",
      [int8, text],
    ),
    // The count subquery runs on the statement's snapshot, which can't see the CTE's own write, so the written
    // row count is added back (or subtracted).
    Statement(
      favorite,
      "WITH t AS (SELECT id FROM articles WHERE slug = $2), w AS (INSERT INTO favorites (user_id, article_id) SELECT $1, t.id FROM t ON CONFLICT DO NOTHING RETURNING 1) " <> fav_select("+ (SELECT count(*) FROM w), true, "),
      [int8, text],
    ),
    Statement(
      unfavorite,
      "WITH t AS (SELECT id FROM articles WHERE slug = $2), w AS (DELETE FROM favorites f USING t WHERE f.user_id = $1 AND f.article_id = t.id RETURNING 1) " <> fav_select("- (SELECT count(*) FROM w), false, "),
      [int8, text],
    ),
    Statement(
      comment_create,
      "WITH c AS (INSERT INTO comments (article_id, author_id, body) SELECT a.id, $1, $3 FROM articles a WHERE a.slug = $2 RETURNING id, body, created_at, updated_at, author_id) SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image FROM c JOIN users u ON u.id = c.author_id",
      [int8, text, text],
    ),
    // Deletes only the viewer's own comment; the probe tells 404 from 403 after a 0-row delete.
    Statement(
      comment_delete,
      "DELETE FROM comments c USING articles a WHERE c.id = $2 AND a.id = c.article_id AND a.slug = $3 AND c.author_id = $1 RETURNING c.id",
      [int8, int8, text],
    ),
    Statement(
      comment_probe,
      "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $1 AND a.slug = $2",
      [int8, text],
    ),
    Statement(article_delete, "DELETE FROM articles WHERE slug = $2 AND author_id = $1 RETURNING id", [int8, text]),
    Statement(article_probe, "SELECT author_id FROM articles WHERE slug = $1", [text]),
    // The CTE is named `a` so the full column list applies to the updated row.
    Statement(
      article_update,
      "WITH a AS (UPDATE articles SET title = COALESCE($3, title), description = COALESCE($4, description), body = COALESCE($5, body), slug = CASE WHEN $3 IS NULL THEN slug ELSE trim(both '-' from lower(regexp_replace($3, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END, updated_at = now() WHERE slug = $2 AND author_id = $1 RETURNING id, slug, title, description, body, created_at, updated_at, author_id) SELECT " <> full_cols() <> " FROM a JOIN users u ON u.id = a.author_id",
      [int8, text, text, text, text],
    ),
    // Article creation without tags: one statement, the new row read back through RETURNING. A new article has
    // no favorites, so those columns are literals.
    Statement(
      article_create_plain,
      "WITH a AS (" <> insert_article() <> " RETURNING id, slug, title, description, body, created_at, updated_at, author_id) SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, ARRAY[]::text[], " <> new_row_tail() <> " FROM a JOIN users u ON u.id = a.author_id",
      [int8, text, text, text],
    ),
    // With tags: two statements in one Sync group (one implicit transaction, one commit). Missing tags are
    // inserted first, in name order so concurrent creates never deadlock and without burning sequence values
    // for tags that exist; the second statement's snapshot then sees every tag and links them.
    Statement(
      tags_upsert,
      "INSERT INTO tags (name) SELECT x.n FROM (SELECT DISTINCT n FROM unnest($1::text[]) AS n WHERE NOT EXISTS (SELECT 1 FROM tags t WHERE t.name = n) ORDER BY n) x ON CONFLICT (name) DO NOTHING",
      [text_array],
    ),
    Statement(
      article_create_tagged,
      "WITH a AS (" <> insert_article() <> " RETURNING id, slug, title, description, body, created_at, updated_at, author_id), ins AS (INSERT INTO article_tags (article_id, tag_id) SELECT a.id, t.id FROM a, tags t WHERE t.name = ANY($5::text[]) RETURNING tag_id) SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, ARRAY(SELECT t.name FROM tags t WHERE t.name = ANY($5::text[]) ORDER BY t.name), " <> new_row_tail() <> " FROM a JOIN users u ON u.id = a.author_id",
      [int8, text, text, text, text_array],
    ),
    Statement(
      user_insert,
      "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image",
      [text, text, text],
    ),
    Statement(
      user_by_email,
      "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1",
      [text],
    ),
    Statement(user_by_id, "SELECT id, username, email, bio, image FROM users WHERE id = $1", [int8]),
    Statement(
      user_update,
      "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) WHERE id = $1 RETURNING id, username, email, bio, image",
      [int8, text, text, text, text, text],
    ),
  ]
}

fn fav_select(count_adjust: String) -> String {
  "SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, ARRAY(SELECT tg.name FROM article_tags at JOIN tags tg ON tg.id = at.tag_id WHERE at.article_id = a.id ORDER BY tg.name), (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) " <> count_adjust <> "u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) FROM t JOIN articles a ON a.id = t.id JOIN users u ON u.id = a.author_id"
}

fn insert_article() -> String {
  "INSERT INTO articles (id, slug, author_id, title, description, body) SELECT n.id, " <> slugify <> " || '-' || n.id, $1, $2, $3, $4 FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n"
}

fn new_row_tail() -> String {
  "0::bigint, false, u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id)"
}

// ---------------------------------------------------------------- batched reads
//
// Reads of the same kind that are waiting for a connection at the same moment go to Postgres as one statement:
// the per-request query becomes the inner side of a LATERAL join over the unnested parameter arrays of the
// waiting requests, and every row comes back tagged with its request's ordinal. Each request's rows are still
// produced by its own execution of its own query (per outer row), in the statement's snapshot; nothing is shared
// between requests. Subqueries that use no request parameter are tied to the request row (`r.i >= 0`) so they
// run once per request rather than once per statement.

/// The read statements that have a batched variant.
/// Statements that only read; a request made of these is safe to run again on a reopened connection.
pub fn read_only(index: Int) -> Bool {
  case index {
    0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 15 | 17 | 23 | 24 -> True
    _ -> False
  }
}

/// Read connections are split into groups by statement kind, so that the requests waiting on one connection are
/// mostly of one kind and batch together (`conn`). Group 0: tags. 1: an article by slug, a profile, a user.
/// 2: comments. 3: the list pages. 4: the feed and the reads without a batched form.
pub const read_groups = 5

/// How the read connections are shared out among the groups (greedy proportional fill in `pool_init`): the
/// cheap single-row kinds need one connection each and batch best on one, the lists and the feed take the rest.
pub const read_group_weights = [1, 2, 1, 4, 4]

pub fn read_group(index: Int) -> Int {
  case index {
    0 -> 0
    6 | 8 | 24 -> 1
    7 -> 2
    1 | 2 | 3 | 4 -> 3
    _ -> 4
  }
}

pub fn batchable(index: Int) -> Bool {
  case index {
    0 | 1 | 2 | 3 | 4 | 6 | 7 | 8 | 24 -> True
    _ -> False
  }
}

pub fn batched() -> List(Statement) {
  list.filter_map(all(), fn(s) {
    case batchable(s.index) {
      False -> Error(Nil)
      True -> Ok(Statement(s.index + batch_offset, batched_query(s), batched_param_types(s)))
    }
  })
}

fn array_type(oid: Int) -> String {
  case oid {
    20 -> "int8[]"
    _ -> "text[]"
  }
}

fn batched_param_types(s: Statement) -> List(Int) {
  case s.params {
    [] -> [1016]
    params ->
      list.map(params, fn(oid) {
        case oid {
          20 -> 1016
          _ -> 1009
        }
      })
  }
}

fn batched_query(s: Statement) -> String {
  case s.index {
    // SELECT ARRAY(SELECT name FROM tags ORDER BY name), tied to the request row.
    0 -> "SELECT r.i, ARRAY(SELECT name FROM tags WHERE r.i >= 0 ORDER BY name) FROM unnest($1::int8[]) WITH ORDINALITY AS r(p1, i)"
    _ -> {
      let n = list.length(s.params)
      let columns =
        list.index_map(s.params, fn(oid, i) { "$" <> int.to_string(i + 1) <> "::" <> array_type(oid) })
        |> string.join(", ")
      let names = list.index_map(s.params, fn(_, i) { "p" <> int.to_string(i + 1) }) |> string.join(", ")
      let inner = substitute(s.query, n)
      // The global list's count uses no parameter: tie it to the request row.
      let inner = case s.index {
        1 -> string.replace(inner, "SELECT 1 FROM articles a LIMIT 1000", "SELECT 1 FROM articles a WHERE r.i >= 0 LIMIT 1000")
        _ -> inner
      }
      "SELECT r.i, x.* FROM unnest(" <> columns <> ") WITH ORDINALITY AS r(" <> names <> ", i) CROSS JOIN LATERAL (" <> inner <> ") x"
    }
  }
}

// $n -> r.pn, highest first so $1 never touches $10.
fn substitute(query: String, n: Int) -> String {
  case n {
    0 -> query
    _ -> substitute(string.replace(query, "$" <> int.to_string(n), "r.p" <> int.to_string(n)), n - 1)
  }
}

/// A parameter list for the batched variant: one array per parameter position, over the requests in order.
pub fn batch_params(index: Int, requests: List(List(proto.Param))) -> List(proto.Param) {
  case index {
    0 -> [proto.array_literal(list.map(requests, fn(_) { Some(<<"0":utf8>>) }))]
    _ ->
      case requests {
        [first, ..] ->
          list.index_map(first, fn(_, j) {
            proto.array_literal(list.map(requests, fn(params) { nth(params, j) }))
          })
        [] -> []
      }
  }
}

fn nth(params: List(proto.Param), j: Int) -> proto.Param {
  case list.drop(params, j) {
    [p, ..] -> p
    [] -> None
  }
}

/// `Option` re-export so callers of `batch_params` can build parameters without importing option.
pub fn some(p: BitArray) -> Option(BitArray) {
  Some(p)
}
