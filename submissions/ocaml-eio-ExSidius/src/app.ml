(* The 19 Conduit endpoints, running the reference SQL from SPEC.md. *)
open Http

exception Fail of int * string

let fail status msg = raise (Fail (status, msg))

(* ---------- SQL ---------- *)

(* Postgres is the bottleneck, so each endpoint makes one round trip where it can: a lookup and the statement that
   depends on it are one statement, and so is a page with its count. Results match the reference SQL in SPEC.md. *)

(* Two plan details matter most. Tag names come from a primary-key probe per tag: a plain join is planned as a hash
   join that scans all of tags for every article. And pages are chosen by id first, from an index alone: with
   LIMIT/OFFSET on the outer query, Postgres computes every subquery for the rows OFFSET then throws away. *)

let article_rest ~favorites_count ~favorited =
  {|ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
                FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list,
       |} ^ favorites_count ^ {| AS favorites_count,
       |} ^ favorited ^ {| AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id|}

let stored_count = "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id)"
let stored_favorited = "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1)"
let tag_fav_follow = article_rest ~favorites_count:stored_count ~favorited:stored_favorited
let list_columns = "SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, "
let full_columns = "SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, "
let list_select = list_columns ^ tag_fav_follow
let full_select = full_columns ^ tag_fav_follow
let s = Pg.stmt

(* One row with total set even for an empty page; then the page's columns are NULL. *)
let with_count ~count list =
  s ("SELECT p.*, c.total FROM (" ^ count ^ ") c(total) LEFT JOIN LATERAL (" ^ list ^ ") p ON true ORDER BY p.id DESC")

let list_total_column = 13

let list_all =
  with_count ~count:"SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s" (list_select ^ " WHERE a.id IN (SELECT id FROM articles ORDER BY id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC")

let list_tag =
  with_count
    ~count:"SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) LIMIT 1000) s"
    (list_select
    ^ " WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC")

let list_author =
  with_count
    ~count:"SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $4) LIMIT 1000) s"
    (list_select
    ^ " WHERE a.id IN (SELECT a2.id FROM articles a2 WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a2.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC")

let list_favorited =
  with_count
    ~count:"SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) LIMIT 1000) s"
    (list_select
    ^ " WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC")

let list_feed =
  with_count
    ~count:"SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s"
    (list_select
    ^ " WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC")

let article_by_slug = s (full_select ^ " WHERE a.slug = $2")
let article_by_id = s (full_select ^ " WHERE a.id = $2")

(* A statement's reads don't see its own writes, so the count is adjusted by what the write actually changed. *)
let favorite_article =
  s ("WITH w AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM articles WHERE slug = $2 ON CONFLICT DO NOTHING RETURNING 1) "
    ^ full_columns
    ^ article_rest ~favorites_count:(stored_count ^ " + (SELECT count(*) FROM w)") ~favorited:"true"
    ^ " WHERE a.slug = $2")

let unfavorite_article =
  s ("WITH w AS (DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM articles WHERE slug = $2) RETURNING 1) "
    ^ full_columns
    ^ article_rest ~favorites_count:(stored_count ^ " - (SELECT count(*) FROM w)") ~favorited:"false"
    ^ " WHERE a.slug = $2")

(* Slugs are computed by the app ($5), which spares Postgres the regular expression. *)
let insert_article =
  s "INSERT INTO articles (id, slug, author_id, title, description, body)\nSELECT n.id, $5::text || '-' || n.id, $1, $2, $3, $4\n  FROM (SELECT nextval('articles_id_seq') AS id) n\nRETURNING id"

let insert_tags = s "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING"
let insert_article_tags = s "INSERT INTO article_tags (article_id, tag_id) SELECT $1, t.id FROM tags t WHERE t.name = ANY($2::text[])"

let update_article =
  s "UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body),\n       slug = CASE WHEN $5::text IS NULL THEN slug ELSE $5::text || '-' || id END,\n       updated_at = now()\n WHERE id = $1"

let delete_article = s "DELETE FROM articles WHERE id = $1"
let article_id_author = s "SELECT id, author_id FROM articles WHERE slug = $1"
let insert_user = s "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)\nRETURNING id, username, email, bio, image"
let user_by_email = s "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1"
let user_by_id = s "SELECT id, username, email, bio, image FROM users WHERE id = $1"

let update_user =
  s "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),\n                 password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)\n WHERE id = $1\nRETURNING id, username, email, bio, image"

let profile_by_username =
  s "SELECT u.id, u.username, u.bio, u.image,\n       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following\n  FROM users u WHERE u.username = $2"

let follow_user =
  s "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),\n     w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM u ON CONFLICT DO NOTHING)\nSELECT username, bio, image FROM u"

let unfollow_user =
  s "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),\n     w AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id IN (SELECT id FROM u))\nSELECT username, bio, image FROM u"

(* No row: no such article. One row with a NULL id: an article without comments. *)
let list_comments =
  s "SELECT c.id, c.body, c.created_at, c.updated_at, c.username, c.bio, c.image, c.following\n  FROM articles a LEFT JOIN LATERAL (\n    SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,\n           EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following\n      FROM comments c JOIN users u ON u.id = c.author_id\n     WHERE c.article_id = a.id\n     ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true\n WHERE a.slug = $2\n ORDER BY c.created_at DESC, c.id DESC"

let insert_comment =
  s "WITH c AS (INSERT INTO comments (article_id, author_id, body) SELECT a.id, $1, $3 FROM articles a WHERE a.slug = $2\n           RETURNING id, body, created_at, updated_at, author_id)\nSELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image\n  FROM c JOIN users u ON u.id = c.author_id"

let comment_author = s "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id\n WHERE c.id = $1 AND a.slug = $2"
let delete_comment = s "DELETE FROM comments WHERE id = $1"
let all_tags = s "SELECT ARRAY(SELECT name FROM tags ORDER BY name)"

(* ---------- batched reads ---------- *)

(* One statement serves every request in a batch. Pages is one row per distinct page: its ordinal, count and ids, from
   $2 limits, $3 offsets and $4 keys (a tag, a username, a viewer or a slug). An article's own data is read once
   however many pages and viewers want it, and each of the viewers in $1 has their favorites and follows walked once,
   as a single list's hashed subplans do. Rows, told apart by kind: 1 a page, 2 an article, 3 a favorite, 4 a follow,
   5 a tag's name. An article's tags come as unsorted ids and each name once: the app sorts them, which is the same
   order under the database's C.UTF-8 collation. *)
let page_input = "unnest($2::int[], $3::bigint[], $4::text[]) WITH ORDINALITY p(lim, off, key, ord)"

let batch_stmt ?(body = false) ?(pre = "") ?(count = "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id)") pages =
  s ("WITH " ^ pre ^ "pages AS MATERIALIZED (" ^ pages
    ^ "),\nids AS MATERIALIZED (SELECT DISTINCT unnest(ids) AS id FROM pages ORDER BY id),\narts AS MATERIALIZED (\n  SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id, "
    ^ (if body then "a.body" else "NULL::text AS body")
    ^ ",\n         ARRAY(SELECT at.tag_id::bigint FROM article_tags at WHERE at.article_id = a.id) AS tag_ids,\n         " ^ count ^ " AS n, u.username, u.bio, u.image\n    FROM ids JOIN articles a ON a.id = ids.id JOIN users u ON u.id = a.author_id)\nSELECT 1 AS kind, ord::bigint AS id, total AS x, ids, NULL AS slug, NULL AS title, NULL AS description,\n       NULL::timestamptz AS created_at, NULL::timestamptz AS updated_at, NULL::bigint[] AS tag_ids, NULL::bigint AS n,\n       NULL AS username, NULL AS bio, NULL AS image, NULL AS body\n  FROM pages\nUNION ALL SELECT 2, id, author_id, NULL, slug, title, description, created_at, updated_at, tag_ids, n, username, bio, image, body FROM arts\nUNION ALL SELECT 3, f.user_id, f.article_id, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL\n  FROM unnest($1::bigint[]) v(id) JOIN favorites f ON f.user_id = v.id WHERE f.article_id IN (SELECT id FROM ids)\nUNION ALL SELECT 4, fo.follower_id, fo.followee_id, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL\n  FROM unnest($1::bigint[]) v(id) JOIN follows fo ON fo.follower_id = v.id WHERE fo.followee_id IN (SELECT author_id FROM arts)\nUNION ALL SELECT 5, t.id, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, t.name, NULL, NULL, NULL\n  FROM tags t WHERE t.id IN (SELECT unnest(tag_ids) FROM arts)")

let global_batch =
  batch_stmt
    ("SELECT p.ord, (SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s) AS total,\n         ARRAY(SELECT id FROM articles ORDER BY id DESC LIMIT p.lim OFFSET p.off) AS ids\n    FROM " ^ page_input)

(* A tag's count is read once however many of its pages are wanted. Proving a 1000th row is cheaper than counting 1000. *)
let tag_batch =
  batch_stmt
    ~pre:("pg AS MATERIALIZED (\n  SELECT p.ord, p.key, ARRAY(SELECT at.article_id FROM article_tags at WHERE at.tag_id = t.id ORDER BY at.article_id DESC LIMIT p.lim OFFSET p.off) AS ids\n    FROM " ^ page_input ^ " CROSS JOIN LATERAL (SELECT (SELECT t.id FROM tags t WHERE t.name = p.key) AS id) t),\nc AS MATERIALIZED (\n  SELECT d.key, COALESCE((SELECT 1000::bigint FROM article_tags at WHERE at.tag_id = t.id OFFSET 999 LIMIT 1),\n                        (SELECT count(*) FROM article_tags at WHERE at.tag_id = t.id)) AS total\n    FROM (SELECT DISTINCT key FROM pg) d CROSS JOIN LATERAL (SELECT (SELECT t.id FROM tags t WHERE t.name = d.key) AS id) t),\n")
    "SELECT pg.ord, c.total, pg.ids FROM pg JOIN c ON c.key = pg.key"

let author_batch =
  batch_stmt
    ("SELECT p.ord, (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = u.id LIMIT 1000) s) AS total,\n         ARRAY(SELECT a2.id FROM articles a2 WHERE a2.author_id = u.id ORDER BY a2.id DESC LIMIT p.lim OFFSET p.off) AS ids\n    FROM " ^ page_input ^ " CROSS JOIN LATERAL (SELECT (SELECT u.id FROM users u WHERE u.username = p.key) AS id) u")

let favorited_batch =
  batch_stmt
    ("SELECT p.ord, (SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = u.id LIMIT 1000) s) AS total,\n         ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = u.id ORDER BY f.article_id DESC LIMIT p.lim OFFSET p.off) AS ids\n    FROM " ^ page_input ^ " CROSS JOIN LATERAL (SELECT (SELECT u.id FROM users u WHERE u.username = p.key) AS id) u")

(* A feed takes two statements. The first walks each followed author once, however many viewers in the batch follow
   them, up to the count cap or the deepest requested page; the app merges each viewer's page from that. Rows: 1 a
   viewer's followed authors, 3 an author's capped count and newest ids. $1 limits, $2 offsets, $3 viewers.
   Each author is read once for both count and ids; OCaml sums the counts for each viewer, capped at 1000. *)
let feed_walk =
  s "WITH p AS MATERIALIZED (SELECT * FROM unnest($1::int[], $2::bigint[], $3::bigint[]) q(lim, off, viewer)),\nd AS MATERIALIZED (\n SELECT g.viewer,g.n,ARRAY(SELECT f.followee_id FROM follows f WHERE f.follower_id=g.viewer) fo\n FROM (SELECT viewer,max(lim+off) n FROM p GROUP BY viewer) g),\nau AS MATERIALIZED (SELECT x.id,max(d.n) n FROM d CROSS JOIN LATERAL unnest(d.fo) x(id) GROUP BY x.id),\na AS MATERIALIZED (SELECT au.id,au.n,ARRAY(SELECT a2.id FROM articles a2 WHERE a2.author_id=au.id ORDER BY a2.id DESC LIMIT greatest(1000,au.n)) ids FROM au)\nSELECT 1 AS kind,d.viewer a,0::bigint b,d.fo ids FROM d\nUNION ALL SELECT 3,a.id,least(1000,cardinality(a.ids))::bigint,a.ids[1:least(a.n,cardinality(a.ids))::int] FROM a"

(* The second fetches the articles those pages need: $1 viewers, $2 ids, with no count of its own. *)
let feed_fetch = batch_stmt "SELECT 1::bigint AS ord, 0::bigint AS total, $2::bigint[] AS ids"

let article_batch =
  batch_stmt ~body:true
    ("SELECT p.ord, 0::bigint AS total, ARRAY(SELECT a.id FROM articles a WHERE a.slug = p.key) AS ids\n    FROM " ^ page_input ^ " WHERE p.lim + p.off >= 0")

let article_pages = "SELECT p.ord, 0::bigint AS total, ARRAY(SELECT a.id FROM articles a WHERE a.slug = p.key) AS ids\n    FROM " ^ page_input ^ " WHERE p.lim + p.off >= 0"

(* $5 users and $6 slugs to favorite, one statement and one commit for all of them; each response waits for it. The
   count is what's stored plus what this statement changed, since a statement doesn't see its own writes. Rows are in
   a consistent order so that two batches can't deadlock on each other. *)
let favorite_input = "i AS MATERIALIZED (SELECT DISTINCT q.user_id, (SELECT a.id FROM articles a WHERE a.slug = q.slug) AS aid FROM unnest($5::bigint[], $6::text[]) q(user_id, slug)),\n"

let favorite_batch =
  batch_stmt ~body:true
    ~pre:(favorite_input ^ "w AS (INSERT INTO favorites (user_id, article_id) SELECT user_id, aid FROM i WHERE aid IS NOT NULL ORDER BY 1, 2 ON CONFLICT DO NOTHING RETURNING article_id),\n")
    ~count:"(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) + (SELECT count(*) FROM w WHERE w.article_id = a.id)"
    article_pages

let unfavorite_batch =
  batch_stmt ~body:true
    ~pre:(favorite_input ^ "w AS (DELETE FROM favorites f USING i WHERE f.user_id = i.user_id AND f.article_id = i.aid RETURNING f.article_id),\n")
    ~count:"(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) - (SELECT count(*) FROM w WHERE w.article_id = a.id)"
    article_pages

(* $1 viewers, $2 usernames. Rows: 1 a user, 2 a follow. *)
let profile_batch =
  s "WITH u AS MATERIALIZED (SELECT u.id, u.username, u.bio, u.image FROM users u WHERE u.username = ANY($2::text[]))\nSELECT 1 AS kind, id AS a, NULL::bigint AS b, username, bio, image FROM u\nUNION ALL SELECT 2, fo.follower_id, fo.followee_id, NULL, NULL, NULL\n  FROM unnest($1::bigint[]) v(id) JOIN follows fo ON fo.follower_id = v.id WHERE fo.followee_id IN (SELECT id FROM u)"

let user_batch = s "SELECT id, username, email, bio, image FROM users WHERE id = ANY($1::bigint[])"

(* $1 followers, $2 usernames. One row per user that exists. *)
let follow_input = "WITH i AS MATERIALIZED (SELECT DISTINCT * FROM unnest($1::bigint[], $2::text[]) q(follower, name)),\nu AS MATERIALIZED (SELECT u.id, u.username, u.bio, u.image FROM users u WHERE u.username = ANY($2::text[])),\n"

let follow_batch =
  s (follow_input ^ "w AS (INSERT INTO follows (follower_id, followee_id) SELECT i.follower, u.id FROM i JOIN u ON u.username = i.name ORDER BY 1, 2 ON CONFLICT DO NOTHING)\nSELECT username, bio, image FROM u")

let unfollow_batch =
  s (follow_input ^ "w AS (DELETE FROM follows fo USING i, u WHERE fo.follower_id = i.follower AND u.username = i.name AND fo.followee_id = u.id)\nSELECT username, bio, image FROM u")

(* $1 authors, $2 slugs, $3 bodies. Ids are taken first to tie each row to its request. One row per comment made. *)
let add_comment_batch =
  s "WITH i AS MATERIALIZED (\n  SELECT q.ord, nextval('comments_id_seq') AS id, q.author, q.body, (SELECT a.id FROM articles a WHERE a.slug = q.slug) AS aid\n    FROM unnest($1::bigint[], $2::text[], $3::text[]) WITH ORDINALITY q(author, slug, body, ord)),\nc AS (INSERT INTO comments (id, article_id, author_id, body) SELECT id, aid, author, body FROM i WHERE aid IS NOT NULL\n      RETURNING id, body, created_at, updated_at, author_id)\nSELECT i.ord, c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image\n  FROM c JOIN i ON i.id = c.id JOIN users u ON u.id = c.author_id"

(* $1 viewers, $2 slugs. Rows: 1 an article that exists, 2 a comment, 3 a comment's author, 4 a follow. *)
let comments_batch =
  s "WITH p AS MATERIALIZED (\n  SELECT q.ord, (SELECT a.id FROM articles a WHERE a.slug = q.slug) AS id FROM unnest($2::text[]) WITH ORDINALITY q(slug, ord) ORDER BY id),\nc AS MATERIALIZED (\n  SELECT p.ord, x.id, x.body, x.created_at, x.updated_at, x.author_id FROM p CROSS JOIN LATERAL (\n    SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c WHERE c.article_id = p.id\n     ORDER BY c.created_at DESC, c.id DESC LIMIT 100) x),\nau AS MATERIALIZED (SELECT DISTINCT author_id AS id FROM c ORDER BY id)\nSELECT 1 AS kind, ord::bigint AS a, NULL::bigint AS b, NULL AS body, NULL::timestamptz AS created_at, NULL::timestamptz AS updated_at, NULL AS username, NULL AS bio, NULL AS image\n  FROM p WHERE id IS NOT NULL\nUNION ALL SELECT 2, ord, id, body, created_at, updated_at, author_id::text, NULL, NULL FROM c\nUNION ALL SELECT 3, u.id, NULL, NULL, NULL, NULL, u.username, u.bio, u.image FROM au JOIN users u ON u.id = au.id\nUNION ALL SELECT 4, fo.follower_id, fo.followee_id, NULL, NULL, NULL, NULL, NULL, NULL\n  FROM unnest($1::bigint[]) v(id) JOIN follows fo ON fo.follower_id = v.id WHERE fo.followee_id IN (SELECT id FROM au)"

(* Byte-identical to trim(both '-' from lower(regexp_replace(x, '[^A-Za-z0-9]+', '-', 'g'))): every byte of a
   multi-byte character is outside the class, so working on bytes gives the same result. *)
let slugify x =
  let b = Buffer.create (String.length x) in
  let pending = ref false in
  String.iter
    (fun c ->
      match c with
      | 'a' .. 'z' | '0' .. '9' | 'A' .. 'Z' ->
          if !pending && Buffer.length b > 0 then Buffer.add_char b '-';
          pending := false;
          Buffer.add_char b (Char.lowercase_ascii c)
      | _ -> pending := true)
    x;
  Buffer.contents b

(* ---------- JSON: types derive their (de)serializers ---------- *)

module Req = struct
  type user_fields = {
    username : string option; [@default None]
    email : string option; [@default None]
    password : string option; [@default None]
    bio : string option; [@default None]
    image : string option; [@default None]
  }
  [@@deriving of_yojson { strict = false }]

  type user = { user : user_fields } [@@deriving of_yojson { strict = false }]

  type article_fields = {
    title : string option; [@default None]
    description : string option; [@default None]
    body : string option; [@default None]
    tagList : string list option; [@default None]
  }
  [@@deriving of_yojson { strict = false }]

  type article = { article : article_fields } [@@deriving of_yojson { strict = false }]
  type comment_fields = { body : string option [@default None] } [@@deriving of_yojson { strict = false }]
  type comment = { comment : comment_fields } [@@deriving of_yojson { strict = false }]
end

module Resp = struct
  type user_fields = {
    email : string;
    token : string;
    username : string;
    bio : string option;
    image : string option;
  }
  [@@deriving to_yojson]

  type user = { user : user_fields } [@@deriving to_yojson]

  type profile_fields = { username : string; bio : string option; image : string option; following : bool }
  [@@deriving to_yojson]

  type profile = { profile : profile_fields } [@@deriving to_yojson]

  type article_fields = {
    slug : string;
    title : string;
    description : string;
    body : string option; [@default None] (* omitted from lists *)
    tagList : string list;
    createdAt : string;
    updatedAt : string;
    favorited : bool;
    favoritesCount : int;
    author : profile_fields;
  }
  [@@deriving to_yojson]

  type article = { article : article_fields } [@@deriving to_yojson]
  type articles = { articles : article_fields list; articlesCount : int } [@@deriving to_yojson]

  type comment_fields = {
    id : int;
    createdAt : string;
    updatedAt : string;
    body : string;
    author : profile_fields;
  }
  [@@deriving to_yojson]

  type comment = { comment : comment_fields } [@@deriving to_yojson]
  type comments = { comments : comment_fields list } [@@deriving to_yojson]
  type tags = { tags : string list } [@@deriving to_yojson]
  type error_fields = { body : string list } [@@deriving to_yojson]
  type error = { errors : error_fields } [@@deriving to_yojson]
end

type page_request = { viewer : int; limit : string; offset : string; key : string }
type page_flags = { favorited : (int * int, unit) Hashtbl.t; following : (int * int, unit) Hashtbl.t }

(* An article's JSON around the viewer's two flags: pre, favorited, mid, following, then "}}". *)
type rendered = { author_id : int; pre : string; mid : string }

(* What every request in a batch shares. An article is rendered once and only the viewer's two flags differ. *)
type shared_page = {
  total : int;
  ids : int array;
  articles : (int, rendered) Hashtbl.t;
  flags : page_flags;
}

type comment_request = { c_viewer : int; c_slug : string }

(* A comment's JSON up to its following flag, with the author's id to look that flag up. *)
type shared_comments = { found : bool; comments : (int * string) list; c_flags : page_flags }

(* username -> id, bio, image; and who among the batch's viewers follows whom. *)
type shared_profiles = { users : (string, int * string option * string option) Hashtbl.t; p_following : (int * int, unit) Hashtbl.t }

type lanes = {
  tags_lane : (unit, Http.response) Batch.t;
  global_lane : (page_request, shared_page) Batch.t;
  feed_lane : (page_request, shared_page) Batch.t;
  tag_lane : (page_request, shared_page) Batch.t;
  author_lane : (page_request, shared_page) Batch.t;
  favorited_lane : (page_request, shared_page) Batch.t;
  article_lane : (page_request, shared_page) Batch.t;
  comments_lane : (comment_request, shared_comments) Batch.t;
  profile_lane : (int * string, shared_profiles) Batch.t;
  user_lane : (int, Pg.row option) Batch.t;
  favorite_lane : (page_request, shared_page) Batch.t;
  unfavorite_lane : (page_request, shared_page) Batch.t;
  add_comment_lane : (int * string * string, Pg.row option) Batch.t;
  follow_lane : (int * string, Pg.row option) Batch.t;
  unfollow_lane : (int * string, Pg.row option) Batch.t;
}

type t = { pool : Pg.pool; secret : string; lanes : lanes option }

let respond status json = { status; body = Yojson.Safe.to_string json }
let error_body msg = Yojson.Safe.to_string (Resp.error_to_yojson { errors = { body = [ msg ] } })

(* Postgres timestamps are microseconds since 2000-01-01 UTC. Prints RFC 3339 with truncated milliseconds. *)
let timestamp r i =
  let ms = Int64.to_int (Pg.timestamp r i) in
  let ms = (if ms >= 0 then ms / 1000 else ((ms + 1) / 1000) - 1) + 946684800000 in
  let secs = ms / 1000 in
  let days = secs / 86400 and sod = secs mod 86400 in
  (* civil_from_days (Howard Hinnant) *)
  let z = days + 719468 in
  let era = z / 146097 in
  let doe = z - (era * 146097) in
  let yoe = (doe - (doe / 1460) + (doe / 36524) - (doe / 146096)) / 365 in
  let doy = doe - ((365 * yoe) + (yoe / 4) - (yoe / 100)) in
  let mp = ((5 * doy) + 2) / 153 in
  let d = doy - (((153 * mp) + 2) / 5) + 1 in
  let m = if mp < 10 then mp + 3 else mp - 9 in
  let y = yoe + (era * 400) + if m <= 2 then 1 else 0 in
  let b = Bytes.of_string "0000-00-00T00:00:00.000Z" in
  let put pos width v =
    let v = ref v in
    for i = pos + width - 1 downto pos do
      Bytes.unsafe_set b i (Char.unsafe_chr (48 + (!v mod 10)));
      v := !v / 10
    done
  in
  put 0 4 y;
  put 5 2 m;
  put 8 2 d;
  put 11 2 (sod / 3600);
  put 14 2 (sod / 60 mod 60);
  put 17 2 (sod mod 60);
  put 20 3 (ms mod 1000);
  Bytes.unsafe_to_string b

(* Columns as in list_select / full_select; the full form has the body at index 4. *)
let article_of_row ~full (r : Pg.row) : Resp.article_fields =
  let o = if full then 1 else 0 in
  {
    slug = Pg.get r 1;
    title = Pg.get r 2;
    description = Pg.get r 3;
    body = (if full then Some (Pg.get r 4) else None);
    tagList = Pg.text_array r (6 + o);
    createdAt = timestamp r (4 + o);
    updatedAt = timestamp r (5 + o);
    favorited = Pg.bool r (8 + o);
    favoritesCount = Pg.int r (7 + o);
    author =
      { username = Pg.get r (9 + o); bio = r.(10 + o); image = r.(11 + o); following = Pg.bool r (12 + o) };
  }

let comment_of_row (r : Pg.row) ~following : Resp.comment_fields =
  {
    id = Pg.int r 0;
    createdAt = timestamp r 2;
    updatedAt = timestamp r 3;
    body = Pg.get r 1;
    author = { username = Pg.get r 4; bio = r.(5); image = r.(6); following };
  }

(* ---------- request helpers ---------- *)

let i n = Some (string_of_int n)
let t v = Some v

let viewer_list_literal ids = "{" ^ String.concat "," (List.map string_of_int ids) ^ "}"

let viewer_literal viewers =
  "{" ^ String.concat "," (Hashtbl.fold (fun v () acc -> string_of_int v :: acc) viewers []) ^ "}"

(* The strings can't hold NUL or anything an array literal would change: a request whose key could, doesn't batch. *)
let batchable key = not (String.contains key '\000')


type viewer = { id : int; token : string option }

let anonymous = { id = 0; token = None }

let authenticate app (req : request) =
  match req.authorization with
  | None -> None
  | Some h ->
      if String.length h > 6 && String.sub h 0 6 = "Token " then begin
        let token = String.sub h 6 (String.length h - 6) in
        match Jwt.verify ~secret:app.secret token with
        | Some id -> Some { id; token = Some token }
        | None -> fail 401 "unauthorized"
      end
      else fail 401 "unauthorized"

let required app req = match authenticate app req with Some v -> v | None -> fail 401 "unauthorized"
let optional app req = match authenticate app req with Some v -> v | None -> anonymous
let current_token v = Option.value v.token ~default:""

let parse_uint v =
  if v <> "" && String.for_all (fun c -> c >= '0' && c <= '9') v then Int64.of_string_opt v else None

let limit_offset params =
  let bad () = fail 422 "limit must be 1-100 and offset >= 0" in
  let limit =
    match List.assoc_opt "limit" params with
    | None -> "20"
    | Some v -> (
        match parse_uint v with
        | Some n when n >= 1L && n <= 100L -> Int64.to_string n
        | _ -> bad ())
  in
  let offset =
    match List.assoc_opt "offset" params with
    | None -> "0"
    | Some v -> ( match parse_uint v with Some n -> Int64.to_string n | None -> bad ())
  in
  (limit, offset)

let parse_body of_yojson (req : request) =
  match of_yojson (Yojson.Safe.from_string req.body) with
  | Ok v -> v
  | Error _ | (exception Yojson.Json_error _) -> fail 422 "invalid body"

let non_empty k = function
  | Some "" -> fail 422 (k ^ " must not be empty")
  | v -> v

let required_field k v = match non_empty k v with Some v -> v | None -> fail 422 (k ^ " is required")

let unique_violation f =
  try f () with Pg.Error { code = "23505"; _ } -> fail 422 "username or email is already taken"

(* ---------- users ---------- *)

let user_response app status (r : Pg.row) token =
  let token = match token with Some v -> v | None -> Jwt.sign ~secret:app.secret (Pg.int r 0) in
  respond status
    (Resp.user_to_yojson
       { user = { email = Pg.get r 2; token; username = Pg.get r 1; bio = r.(3); image = r.(4) } })

let hash_password password =
  match Bcrypt.hash password with Some h -> h | None -> fail 422 "password can't be used"

let register app req =
  let { Req.user = m } = parse_body Req.user_of_yojson req in
  let username = required_field "username" m.username in
  let email = required_field "email" m.email in
  let password = required_field "password" m.password in
  let hash = hash_password password in
  let row =
    unique_violation (fun () ->
        Pg.with_conn app.pool (fun c -> Pg.exec_one c insert_user [| t username; t email; t hash |]))
  in
  user_response app 201 (Option.get row) None

let login app req =
  let { Req.user = m } = parse_body Req.user_of_yojson req in
  let email = required_field "email" m.email in
  let password = required_field "password" m.password in
  let row = Pg.with_conn app.pool (fun c -> Pg.exec_one c user_by_email [| t email |]) in
  match row with
  | Some r when Bcrypt.verify ~password ~hash:(Pg.get r 5) -> user_response app 200 r None
  | _ -> fail 401 "invalid email or password"

let current_user app req =
  let v = required app req in
  let row =
    match app.lanes with
    | Some l -> Batch.submit l.user_lane v.id
    | None -> Pg.with_conn app.pool (fun c -> Pg.exec_one c user_by_id [| i v.id |])
  in
  match row with
  | Some r -> user_response app 200 r (Some (current_token v))
  | None -> fail 401 "unauthorized"

let update_user_h app req =
  let v = required app req in
  let { Req.user = m } = parse_body Req.user_of_yojson req in
  let email = non_empty "email" m.email in
  let username = non_empty "username" m.username in
  let password = non_empty "password" m.password in
  let hash = Option.map hash_password password in
  let row =
    unique_violation (fun () ->
        Pg.with_conn app.pool (fun c ->
            Pg.exec_one c update_user [| i v.id; email; username; hash; m.bio; m.image |]))
  in
  match row with
  | Some r -> user_response app 200 r (Some (current_token v))
  | None -> fail 401 "unauthorized"

(* ---------- profiles ---------- *)

let profile_response profile = respond 200 (Resp.profile_to_yojson { profile })

let get_profile app req username =
  let v = optional app req in
  match app.lanes with
  | Some l when batchable username -> (
      let p = Batch.submit l.profile_lane (v.id, username) in
      match Hashtbl.find_opt p.users username with
      | Some (id, bio, image) ->
          profile_response { username; bio; image; following = Hashtbl.mem p.p_following (v.id, id) }
      | None -> fail 404 "profile not found")
  | _ -> (
      match Pg.with_conn app.pool (fun c -> Pg.exec_one c profile_by_username [| i v.id; t username |]) with
      | Some r ->
          profile_response { username = Pg.get r 1; bio = r.(2); image = r.(3); following = Pg.bool r 4 }
      | None -> fail 404 "profile not found")

let follow app req username ~on =
  let v = required app req in
  let stmt = if on then follow_user else unfollow_user in
  let row =
    match app.lanes with
    | Some l when batchable username ->
        Batch.submit (if on then l.follow_lane else l.unfollow_lane) (v.id, username)
    | _ -> Pg.with_conn app.pool (fun c -> Pg.exec_one c stmt [| i v.id; t username |])
  in
  match row with
  | None -> fail 404 "profile not found"
  | Some r -> profile_response { username = Pg.get r 0; bio = r.(1); image = r.(2); following = on }

(* ---------- articles ---------- *)

let write_list c list params =
  let rows = Pg.exec c list params in
  let articlesCount = match rows with r :: _ -> Pg.int r list_total_column | [] -> 0 in
  let page = List.filter (fun (r : Pg.row) -> r.(0) <> None) rows in
  respond 200 (Resp.articles_to_yojson { articles = List.map (article_of_row ~full:false) page; articlesCount })

let non_empty_param params k =
  match List.assoc_opt k params with Some "" | None -> None | some -> some

let render_article b (r : Pg.row) tags =
  Buffer.clear b;
  Buffer.add_string b {|{"slug":|};
  Json.add_string b (Pg.get r 4);
  Buffer.add_string b {|,"title":|};
  Json.add_string b (Pg.get r 5);
  Buffer.add_string b {|,"description":|};
  Json.add_string b (Pg.get r 6);
  (match r.(14) with
  | Some body ->
      Buffer.add_string b {|,"body":|};
      Json.add_string b body
  | None -> ());
  Buffer.add_string b {|,"tagList":[|};
  List.iteri
    (fun i tag ->
      if i > 0 then Buffer.add_char b ',';
      Json.add_string b tag)
    tags;
  Buffer.add_string b {|],"createdAt":"|};
  Buffer.add_string b (timestamp r 7);
  Buffer.add_string b {|","updatedAt":"|};
  Buffer.add_string b (timestamp r 8);
  Buffer.add_string b {|","favorited":|};
  let pre = Buffer.contents b in
  Buffer.clear b;
  Buffer.add_string b {|,"favoritesCount":|};
  Buffer.add_string b (string_of_int (Pg.int r 10));
  Buffer.add_string b {|,"author":{"username":|};
  Json.add_string b (Pg.get r 11);
  Buffer.add_string b {|,"bio":|};
  Json.add_option b r.(12);
  Buffer.add_string b {|,"image":|};
  Json.add_option b r.(13);
  Buffer.add_string b {|,"following":|};
  { author_id = Pg.int r 2; pre; mid = Buffer.contents b }

(* The ids of a viewer's page, from each followed author's newest ids, each array newest first. *)
let newest_page ~lim ~off authors =
  let n = lim + off in
  let top = Array.make n 0 and len = ref 0 in
  Array.iter
    (fun ids ->
      let continue = ref true and i = ref 0 in
      while !continue && !i < Array.length ids do
        let id = ids.(!i) in
        if !len = n && id <= top.(n - 1) then continue := false
        else begin
          let j = ref (if !len < n then !len else n - 1) in
          while !j > 0 && top.(!j - 1) < id do
            top.(!j) <- top.(!j - 1);
            decr j
          done;
          top.(!j) <- id;
          if !len < n then incr len;
          incr i
        end
      done)
    authors;
  if !len <= off then [||] else Array.sub top off (min lim (!len - off))

let decode_pages rows n =
  let totals = Array.make (n + 1) 0 and ids_of = Array.make (n + 1) [||] in
  let articles = Hashtbl.create 64 and names = Hashtbl.create 64 in
  let flags = { favorited = Hashtbl.create 16; following = Hashtbl.create 16 } in
  let raw = ref [] in
  List.iter
    (fun (r : Pg.row) ->
      match Pg.int4 r 0 with
      | 1 ->
          let page = Pg.int r 1 in
          totals.(page) <- Pg.int r 2;
          ids_of.(page) <- Pg.int_array r 3
      | 2 -> raw := r :: !raw
      | 3 -> Hashtbl.replace flags.favorited (Pg.int r 1, Pg.int r 2) ()
      | 4 -> Hashtbl.replace flags.following (Pg.int r 1, Pg.int r 2) ()
      | _ -> Hashtbl.replace names (Pg.int r 1) (Pg.get r 11))
    rows;
  let b = Buffer.create 2048 in
  List.iter
    (fun (r : Pg.row) ->
      let tags = Array.to_list (Array.map (Hashtbl.find names) (Pg.int_array r 9)) in
      Hashtbl.replace articles (Pg.int r 1) (render_article b r (List.sort String.compare tags)))
    !raw;
  (totals, ids_of, articles, flags)

let run_pages ?(extra = fun _ -> [||]) stmt c (inputs : page_request list) =
  let pages = Hashtbl.create 16 and limits = ref [] and offsets = ref [] and keys = ref [] and n = ref 0 in
  let viewers = Hashtbl.create 16 in
  List.iter
    (fun q ->
      if q.viewer <> 0 then Hashtbl.replace viewers q.viewer ();
      let k = (q.limit, q.offset, q.key) in
      if not (Hashtbl.mem pages k) then begin
        incr n;
        Hashtbl.add pages k !n;
        limits := q.limit :: !limits;
        offsets := q.offset :: !offsets;
        keys := q.key :: !keys
      end)
    inputs;
  let rows =
    Pg.exec c stmt
      (Array.append
         [|
           t (viewer_literal viewers);
           t ("{" ^ String.concat "," (List.rev !limits) ^ "}");
           t ("{" ^ String.concat "," (List.rev !offsets) ^ "}");
           t (Pg.text_array_literal (List.rev !keys));
         |]
         (extra inputs))
  in
  let totals, ids_of, articles, flags = decode_pages rows !n in
  List.map
    (fun q ->
      let page = Hashtbl.find pages (q.limit, q.offset, q.key) in
      { total = totals.(page); ids = ids_of.(page); articles; flags })
    inputs

let run_feed c (inputs : page_request list) =
  let pages = Hashtbl.create 16 and limits = ref [] and offsets = ref [] and viewers = ref [] in
  List.iter
    (fun q ->
      if not (Hashtbl.mem pages (q.limit, q.offset, q.viewer)) then begin
        Hashtbl.add pages (q.limit, q.offset, q.viewer) [||];
        limits := q.limit :: !limits;
        offsets := q.offset :: !offsets;
        viewers := string_of_int q.viewer :: !viewers
      end)
    inputs;
  let rows =
    Pg.exec c feed_walk
      [|
        t ("{" ^ String.concat "," !limits ^ "}");
        t ("{" ^ String.concat "," !offsets ^ "}");
        t ("{" ^ String.concat "," !viewers ^ "}");
      |]
  in
  let counts = Hashtbl.create 64 and follows = Hashtbl.create 16 and tops = Hashtbl.create 64 in
  List.iter
    (fun (r : Pg.row) ->
      match Pg.int4 r 0 with
      | 1 ->
          Hashtbl.replace follows (Pg.int r 1) (Pg.int_array r 3)
      | _ ->
          Hashtbl.replace counts (Pg.int r 1) (Pg.int r 2);
          Hashtbl.replace tops (Pg.int r 1) (Pg.int_array r 3))
    rows;
  let wanted = Hashtbl.create 256 in
  let merged =
    Hashtbl.fold
      (fun (limit, offset, viewer) _ acc ->
        let lim = int_of_string limit and off = int_of_string offset in
        let authors = Hashtbl.find follows viewer in
        let ids = newest_page ~lim ~off (Array.map (Hashtbl.find tops) authors) in
        Array.iter (fun id -> Hashtbl.replace wanted id ()) ids;
        ((limit, offset, viewer), ids) :: acc)
      pages []
  in
  let page_ids = Hashtbl.create 16 in
  List.iter (fun (k, ids) -> Hashtbl.replace page_ids k ids) merged;
  let viewer_set = Hashtbl.create 16 in
  List.iter (fun q -> Hashtbl.replace viewer_set q.viewer ()) inputs;
  let rows =
    Pg.exec c feed_fetch
      [| t (viewer_literal viewer_set); t (viewer_literal wanted) |]
  in
  let _, _, articles, flags = decode_pages rows 1 in
  List.map
    (fun q ->
      (* An article deleted between the two statements just drops out, as it would between the reference's two. *)
      let ids = Hashtbl.find page_ids (q.limit, q.offset, q.viewer) in
      let ids = if Array.for_all (Hashtbl.mem articles) ids then ids else Array.of_list (List.filter (Hashtbl.mem articles) (Array.to_list ids)) in
      { total = Array.fold_left (fun n author -> min 1000 (n + Hashtbl.find counts author))
                  0 (Hashtbl.find follows q.viewer);
        ids; articles; flags })
    inputs

let add_shared_article ?favorited b viewer p id =
  let a = Hashtbl.find p.articles id in
  Buffer.add_string b a.pre;
  Json.add_bool b (match favorited with Some v -> v | None -> Hashtbl.mem p.flags.favorited (viewer, id));
  Buffer.add_string b a.mid;
  Json.add_bool b (Hashtbl.mem p.flags.following (viewer, a.author_id));
  Buffer.add_string b "}}"

let shared_page_response viewer p =
  let b = Buffer.create 8192 in
  Buffer.add_string b {|{"articles":[|};
  Array.iteri
    (fun i id ->
      if i > 0 then Buffer.add_char b ',';
      add_shared_article b viewer p id)
    p.ids;
  Buffer.add_string b {|],"articlesCount":|};
  Buffer.add_string b (string_of_int p.total);
  Buffer.add_char b '}';
  { status = 200; body = Buffer.contents b }

let shared_article_response ?favorited viewer p id =
  let b = Buffer.create 4096 in
  Buffer.add_string b {|{"article":|};
  add_shared_article ?favorited b viewer p id;
  Buffer.add_char b '}';
  { status = 200; body = Buffer.contents b }

let favorite_extra (inputs : page_request list) =
  [|
    t (viewer_list_literal (List.map (fun q -> q.viewer) inputs));
    t (Pg.text_array_literal (List.map (fun q -> q.key) inputs));
  |]

let run_favorites stmt = run_pages ~extra:favorite_extra stmt

let run_profiles c inputs =
  let viewers = Hashtbl.create 16 and names = Hashtbl.create 16 in
  List.iter
    (fun (viewer, name) ->
      if viewer <> 0 then Hashtbl.replace viewers viewer ();
      Hashtbl.replace names name ())
    inputs;
  let rows =
    Pg.exec c profile_batch
      [| t (viewer_literal viewers); t (Pg.text_array_literal (Hashtbl.fold (fun n () acc -> n :: acc) names [])) |]
  in
  let users = Hashtbl.create 16 and p_following = Hashtbl.create 16 in
  List.iter
    (fun (r : Pg.row) ->
      if Pg.int4 r 0 = 1 then Hashtbl.replace users (Pg.get r 3) (Pg.int r 1, r.(4), r.(5))
      else Hashtbl.replace p_following (Pg.int r 1, Pg.int r 2) ())
    rows;
  let shared = { users; p_following } in
  List.map (fun _ -> shared) inputs

let run_users c inputs =
  let rows = Pg.exec c user_batch [| t (viewer_list_literal inputs) |] in
  let by_id = Hashtbl.create 16 in
  List.iter (fun (r : Pg.row) -> Hashtbl.replace by_id (Pg.int r 0) r) rows;
  List.map (Hashtbl.find_opt by_id) inputs

let run_follows stmt c inputs =
  let rows =
    Pg.exec c stmt
      [|
        t (viewer_list_literal (List.map fst inputs));
        t (Pg.text_array_literal (List.map snd inputs));
      |]
  in
  let by_name = Hashtbl.create 16 in
  List.iter (fun (r : Pg.row) -> Hashtbl.replace by_name (Pg.get r 0) r) rows;
  List.map (fun (_, name) -> Hashtbl.find_opt by_name name) inputs

let run_add_comments c inputs =
  let rows =
    Pg.exec c add_comment_batch
      [|
        t (viewer_list_literal (List.map (fun (a, _, _) -> a) inputs));
        t (Pg.text_array_literal (List.map (fun (_, s, _) -> s) inputs));
        t (Pg.text_array_literal (List.map (fun (_, _, b) -> b) inputs));
      |]
  in
  let by_ord = Hashtbl.create 16 in
  List.iter (fun (r : Pg.row) -> Hashtbl.replace by_ord (Pg.int r 0) (Array.sub r 1 7)) rows;
  List.mapi (fun i _ -> Hashtbl.find_opt by_ord (i + 1)) inputs

let run_comments c (inputs : comment_request list) =
  let pages = Hashtbl.create 16 and slugs = ref [] and n = ref 0 and viewers = Hashtbl.create 16 in
  List.iter
    (fun q ->
      if q.c_viewer <> 0 then Hashtbl.replace viewers q.c_viewer ();
      if not (Hashtbl.mem pages q.c_slug) then begin
        incr n;
        Hashtbl.add pages q.c_slug !n;
        slugs := q.c_slug :: !slugs
      end)
    inputs;
  let rows = Pg.exec c comments_batch [| t (viewer_literal viewers); t (Pg.text_array_literal (List.rev !slugs)) |] in
  let found = Array.make (!n + 1) false and raw = Array.make (!n + 1) [] in
  let authors = Hashtbl.create 32 in
  let flags = { favorited = Hashtbl.create 1; following = Hashtbl.create 16 } in
  List.iter
    (fun (r : Pg.row) ->
      match Pg.int4 r 0 with
      | 1 -> found.(Pg.int r 1) <- true
      | 2 -> raw.(Pg.int r 1) <- r :: raw.(Pg.int r 1)
      | 3 -> Hashtbl.replace authors (Pg.int r 1) (Pg.get r 6, r.(7), r.(8))
      | _ -> Hashtbl.replace flags.following (Pg.int r 1, Pg.int r 2) ())
    rows;
  (* Newest first, as the reference orders them. *)
  let newest (a : Pg.row) (b : Pg.row) =
    match Int64.compare (Pg.timestamp b 4) (Pg.timestamp a 4) with 0 -> compare (Pg.int b 2) (Pg.int a 2) | n -> n
  in
  let b = Buffer.create 1024 in
  let comments =
    Array.map
      (fun rs ->
        List.map
          (fun (r : Pg.row) ->
            let author_id = int_of_string (Pg.get r 6) in
            let username, bio, image = Hashtbl.find authors author_id in
            Buffer.clear b;
            Buffer.add_string b {|{"id":|};
            Buffer.add_string b (string_of_int (Pg.int r 2));
            Buffer.add_string b {|,"createdAt":"|};
            Buffer.add_string b (timestamp r 4);
            Buffer.add_string b {|","updatedAt":"|};
            Buffer.add_string b (timestamp r 5);
            Buffer.add_string b {|","body":|};
            Json.add_string b (Pg.get r 3);
            Buffer.add_string b {|,"author":{"username":|};
            Json.add_string b username;
            Buffer.add_string b {|,"bio":|};
            Json.add_option b bio;
            Buffer.add_string b {|,"image":|};
            Json.add_option b image;
            Buffer.add_string b {|,"following":|};
            (author_id, Buffer.contents b))
          (List.sort newest rs))
      raw
  in
  List.map
    (fun q ->
      let page = Hashtbl.find pages q.c_slug in
      { found = found.(page); comments = comments.(page); c_flags = flags })
    inputs

let list_articles app (req : request) =
  let v = optional app req in
  let params = query_params req.query in
  let limit, offset = limit_offset params in
  let base = [| i v.id; t limit; t offset |] in
  let filtered lane list key =
    match app.lanes with
    | Some lanes when batchable key ->
        shared_page_response v.id (Batch.submit (lane lanes) { viewer = v.id; limit; offset; key })
    | _ ->
        let params = if key = "" then base else Array.append base [| t key |] in
        Pg.with_conn app.pool (fun c -> write_list c list params)
  in
  match (non_empty_param params "tag", non_empty_param params "author", non_empty_param params "favorited") with
  | Some tag, _, _ -> filtered (fun l -> l.tag_lane) list_tag tag
  | None, Some author, _ -> filtered (fun l -> l.author_lane) list_author author
  | None, None, Some user -> filtered (fun l -> l.favorited_lane) list_favorited user
  | None, None, None -> filtered (fun l -> l.global_lane) list_all ""

let feed app (req : request) =
  let v = required app req in
  let limit, offset = limit_offset (query_params req.query) in
  match app.lanes with
  (* The app merges a page by holding limit + offset ids, so a far-off page runs alone. *)
  | Some l when String.length offset <= 3 ->
      shared_page_response v.id (Batch.submit l.feed_lane { viewer = v.id; limit; offset; key = string_of_int v.id })
  | _ -> Pg.with_conn app.pool (fun c -> write_list c list_feed [| i v.id; t limit; t offset |])

let full_article c status stmt viewer key =
  match Pg.exec_one c stmt [| i viewer; key |] with
  | Some r -> respond status (Resp.article_to_yojson { article = article_of_row ~full:true r })
  | None -> fail 404 "article not found"

let get_article app req slug =
  let v = optional app req in
  match app.lanes with
  | Some l when batchable slug -> (
      let p = Batch.submit l.article_lane { viewer = v.id; limit = "1"; offset = "0"; key = slug } in
      match p.ids with
      | [| id |] -> shared_article_response v.id p id
      | _ -> fail 404 "article not found")
  | _ -> Pg.with_conn app.pool (fun c -> full_article c 200 article_by_slug v.id (t slug))

let create_article app req =
  let v = required app req in
  let { Req.article = m } = parse_body Req.article_of_yojson req in
  let title = required_field "title" m.title in
  let description = required_field "description" m.description in
  let body = required_field "body" m.body in
  let tags = Option.value m.tagList ~default:[] in
  if List.mem "" tags then fail 422 "tagList must be an array of non-empty strings";
  Pg.with_conn app.pool (fun c ->
      let id =
        Pg.with_tx c (fun () ->
            let r = Option.get (Pg.exec_one c insert_article [| i v.id; t title; t description; t body; t (slugify title) |]) in
            let id = Pg.int r 0 in
            if tags <> [] then begin
              let lit = t (Pg.text_array_literal tags) in
              ignore (Pg.exec c insert_tags [| lit |]);
              ignore (Pg.exec c insert_article_tags [| i id; lit |])
            end;
            id)
      in
      full_article c 201 article_by_id v.id (i id))

let own_article c slug viewer =
  match Pg.exec_one c article_id_author [| t slug |] with
  | None -> fail 404 "article not found"
  | Some r ->
      if Pg.int r 1 <> viewer then fail 403 "not the author";
      Pg.int r 0

let update_article_h app req slug =
  let v = required app req in
  let { Req.article = m } = parse_body Req.article_of_yojson req in
  let title = non_empty "title" m.title in
  let description = non_empty "description" m.description in
  let body = non_empty "body" m.body in
  Pg.with_conn app.pool (fun c ->
      let id = own_article c slug v.id in
      ignore (Pg.exec c update_article [| i id; title; description; body; Option.map slugify title |]);
      full_article c 200 article_by_id v.id (i id))

let no_content = { status = 204; body = "" }

let delete_article_h app req slug =
  let v = required app req in
  Pg.with_conn app.pool (fun c ->
      let id = own_article c slug v.id in
      ignore (Pg.exec c delete_article [| i id |]);
      no_content)

let favorite app req slug ~on =
  let v = required app req in
  let stmt = if on then favorite_article else unfavorite_article in
  match app.lanes with
  | Some l when batchable slug -> (
      let lane = if on then l.favorite_lane else l.unfavorite_lane in
      let p = Batch.submit lane { viewer = v.id; limit = "1"; offset = "0"; key = slug } in
      match p.ids with
      | [| id |] -> shared_article_response ~favorited:on v.id p id
      | _ -> fail 404 "article not found")
  | _ -> Pg.with_conn app.pool (fun c -> full_article c 200 stmt v.id (t slug))

(* ---------- comments ---------- *)

let get_comments app req slug =
  let v = optional app req in
  match app.lanes with
  | Some l when batchable slug ->
      let p = Batch.submit l.comments_lane { c_viewer = v.id; c_slug = slug } in
      if not p.found then fail 404 "article not found";
      let b = Buffer.create 4096 in
      Buffer.add_string b {|{"comments":[|};
      List.iteri
        (fun i (author_id, pre) ->
          if i > 0 then Buffer.add_char b ',';
          Buffer.add_string b pre;
          Json.add_bool b (Hashtbl.mem p.c_flags.following (v.id, author_id));
          Buffer.add_string b "}}")
        p.comments;
      Buffer.add_string b "]}";
      { status = 200; body = Buffer.contents b }
  | _ -> (
  match Pg.with_conn app.pool (fun c -> Pg.exec c list_comments [| i v.id; t slug |]) with
  | [] -> fail 404 "article not found"
  | rows ->
      let rows = List.filter (fun (r : Pg.row) -> r.(0) <> None) rows in
      respond 200
        (Resp.comments_to_yojson
           { comments = List.map (fun r -> comment_of_row r ~following:(Pg.bool r 7)) rows }))

let create_comment app req slug =
  let v = required app req in
  let { Req.comment = m } = parse_body Req.comment_of_yojson req in
  let body = required_field "body" m.body in
  let row =
    match app.lanes with
    | Some l when batchable slug && batchable body -> Batch.submit l.add_comment_lane (v.id, slug, body)
    | _ -> Pg.with_conn app.pool (fun c -> Pg.exec_one c insert_comment [| i v.id; t slug; t body |])
  in
  match row with
  | None -> fail 404 "article not found"
  | Some r -> respond 201 (Resp.comment_to_yojson { comment = comment_of_row r ~following:false })

let delete_comment_h app req slug raw_id =
  let v = required app req in
  match parse_uint raw_id with
  | None -> fail 404 "comment not found"
  | Some id ->
      let id = t (Int64.to_string id) in
      Pg.with_conn app.pool (fun c ->
          match Pg.exec_one c comment_author [| id; t slug |] with
          | None -> fail 404 "comment not found"
          | Some r ->
              if Pg.int r 0 <> v.id then fail 403 "not the author";
              ignore (Pg.exec c delete_comment [| id |]);
              no_content)

let tags_response c =
  match Pg.exec_one c all_tags [||] with
  | Some r -> respond 200 (Resp.tags_to_yojson { tags = Pg.text_array r 0 })
  | None -> failwith "tags: no row"

let tags app =
  match app.lanes with
  | Some l -> Batch.submit l.tags_lane ()
  | None -> Pg.with_conn app.pool tags_response

(* Everyone waiting gets the same response. *)
let run_tags c inputs =
  let r = tags_response c in
  List.map (fun () -> r) inputs

(* ---------- routing ---------- *)

let route app (req : request) =
  let seg = decode ~plus:false in
  match (req.meth, String.split_on_char '/' req.path) with
  | "GET", [ ""; "api"; "tags" ] -> tags app
  | "POST", [ ""; "api"; "users" ] -> register app req
  | "POST", [ ""; "api"; "users"; "login" ] -> login app req
  | "GET", [ ""; "api"; "user" ] -> current_user app req
  | "PUT", [ ""; "api"; "user" ] -> update_user_h app req
  | "GET", [ ""; "api"; "profiles"; u ] -> get_profile app req (seg u)
  | "POST", [ ""; "api"; "profiles"; u; "follow" ] -> follow app req (seg u) ~on:true
  | "DELETE", [ ""; "api"; "profiles"; u; "follow" ] -> follow app req (seg u) ~on:false
  | "GET", [ ""; "api"; "articles" ] -> list_articles app req
  | "POST", [ ""; "api"; "articles" ] -> create_article app req
  | "GET", [ ""; "api"; "articles"; "feed" ] -> feed app req
  | "GET", [ ""; "api"; "articles"; x ] -> get_article app req (seg x)
  | "PUT", [ ""; "api"; "articles"; x ] -> update_article_h app req (seg x)
  | "DELETE", [ ""; "api"; "articles"; x ] -> delete_article_h app req (seg x)
  | "POST", [ ""; "api"; "articles"; x; "favorite" ] -> favorite app req (seg x) ~on:true
  | "DELETE", [ ""; "api"; "articles"; x; "favorite" ] -> favorite app req (seg x) ~on:false
  | "GET", [ ""; "api"; "articles"; x; "comments" ] -> get_comments app req (seg x)
  | "POST", [ ""; "api"; "articles"; x; "comments" ] -> create_comment app req (seg x)
  | "DELETE", [ ""; "api"; "articles"; x; "comments"; id ] -> delete_comment_h app req (seg x) (seg id)
  | _ -> fail 404 "not found"

let handle app req =
  try route app req with
  | Fail (status, msg) -> { status; body = error_body msg }
  | (Eio.Cancel.Cancelled _) as e -> raise e
  | e ->
      Printf.eprintf "error: %s %s: %s\n%!" req.meth req.path (Printexc.to_string e);
      { status = 500; body = error_body "internal error" }
