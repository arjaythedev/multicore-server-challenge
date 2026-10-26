/// All SQL in one place, ported from #22 (csharp-sockets-jh-d, MIT). In the per-request forms $1 is the viewer
/// (0 = anonymous). Article rows: id, slug, title, description, [body], created_at, updated_at, tag_list,
/// favorites_count, favorited, username, bio, image, following (Json.article).
///
/// Reads run batched: the per-request query becomes the inner side of a LATERAL join over the unnested request
/// parameters r(i, v = viewer, l = limit, o = offset, k = key), so it is executed once for each request.
/// Subqueries that use no request parameter are tied to the request row (r.i >= 0) so they run once per request,
/// not once per statement: no request reuses another's results (rule 5).
module Sql

open System
open System.Collections.Generic
open System.Text.RegularExpressions
open Pg

type Layout =
    | None = 0 // tags: index only
    | ViewerKey = 1 // (viewer bigint, key text)
    | Viewer = 2 // (viewer bigint)
    | List = 3 // (viewer bigint, limit int, offset bigint)
    | ListKey = 4 // (viewer bigint, limit int, offset bigint, key text)

/// A kind of batched read: its statement, parameter layout and limits.
type Kind(id: int, name: string, stmt: Stmt, layout: Layout) =
    member _.Id = id
    member _.Name = name
    member _.Stmt = stmt
    member _.Layout = layout
    member val MaxBatch = 64 with get, set
    member val MaxInflight = 6 with get, set

let kinds = List<Kind>()

let private addKind name stmt layout =
    let k = Kind(kinds.Count, name, stmt, layout)
    kinds.Add k
    k

let Collation =
    "SELECT datlocprovider::text, datcollate, coalesce(datlocale, '') FROM pg_database WHERE datname = current_database()"

let private tagOrder () = if Json.appSortsTags then "" else " ORDER BY 1"

[<Literal>]
let private Following =
    "(SELECT true FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) IS NOT NULL"

let private tail (following: string) =
    "a.created_at, a.updated_at, "
    + "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id"
    + tagOrder ()
    + ") AS tag_list, "
    + "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, "
    + "(SELECT true FROM favorites f WHERE f.user_id = $1 AND f.article_id = a.id) IS NOT NULL AS favorited, "
    + "u.username, u.bio, u.image, "
    + following
    + " AS following"

let private articleTail () = tail Following
let private feedTail () = tail "true" // the viewer follows every feed author (same snapshot)

[<Literal>]
let private ListCols = "a.id, a.slug, a.title, a.description, "

let private fullSelect () =
    "SELECT a.id, a.slug, a.title, a.description, a.body, " + articleTail () + " FROM articles a JOIN users u ON u.id = a.author_id"

/// the page is cut in a subquery before anything is joined or computed: OFFSET rows cost an index step only
[<Literal>]
let private PageCols = "SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id FROM articles a"

/// a page of article ids (a subquery producing column "id", newest first) -> article rows
let private listOf (ids: string) (tl: string) =
    "SELECT " + ListCols + tl + " FROM (" + ids + ") p JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id ORDER BY p.id DESC"

let private unnest (l: Layout) =
    match l with
    | Layout.None -> "unnest($1::int4[]) AS r(i)"
    | Layout.Viewer -> "unnest($1::int4[], $2::int8[]) AS r(i, v)"
    | Layout.ViewerKey -> "unnest($1::int4[], $2::int8[], $3::text[]) AS r(i, v, k)"
    | Layout.List -> "unnest($1::int4[], $2::int8[], $3::int4[], $4::int8[]) AS r(i, v, l, o)"
    | _ -> "unnest($1::int4[], $2::int8[], $3::int4[], $4::int8[], $5::text[]) AS r(i, v, l, o, k)"

let private oids (l: Layout) : uint32[] =
    match l with
    | Layout.None -> [| Oid.Int4Array |]
    | Layout.Viewer -> [| Oid.Int4Array; Oid.Int8Array |]
    | Layout.ViewerKey -> [| Oid.Int4Array; Oid.Int8Array; Oid.TextArray |]
    | Layout.List -> [| Oid.Int4Array; Oid.Int8Array; Oid.Int4Array; Oid.Int8Array |]
    | _ -> [| Oid.Int4Array; Oid.Int8Array; Oid.Int4Array; Oid.Int8Array; Oid.TextArray |]

let private paramRef = Regex(@"\$(\d+)")

/// per-request parameters -> request row columns
let private bindParams (sql: string) (l: Layout) =
    paramRef.Replace(
        sql,
        MatchEvaluator(fun m ->
            let n = int m.Groups.[1].Value
            match l with
            | Layout.Viewer -> if n = 1 then "r.v" else raise (ArgumentException sql)
            | Layout.ViewerKey -> (if n = 1 then "r.v" elif n = 2 then "r.k" else raise (ArgumentException sql))
            | _ ->
                match n with
                | 1 -> "r.v"
                | 2 -> "r.l"
                | 3 -> "r.o"
                | 4 -> "r.k"
                | _ -> raise (ArgumentException sql))
    )

let private batched name perRequest l =
    addKind name (Stmt.Define("SELECT r.i, x.* FROM " + unnest l + " CROSS JOIN LATERAL (" + bindParams perRequest l + ") x", oids l)) l

/// lists: (i, count, article columns...), and one row with NULL article columns when the page is empty.
/// OFFSET 0 keeps the count a subquery evaluated once per request.
let private batchedList name page count l =
    addKind
        name
        (Stmt.Define(
            "SELECT r.i, c.n, x.* FROM " + unnest l + " CROSS JOIN LATERAL (SELECT " + bindParams count l + " AS n OFFSET 0) c "
            + "LEFT JOIN LATERAL (" + bindParams page l + ") x ON true",
            oids l
        ))
        l

/// "at least 1000?" is answered by whether a 1000th row exists (OFFSET 999); the exact count only below that
[<Literal>]
let private CountAll =
    "CASE WHEN EXISTS (SELECT 1 FROM articles c WHERE r.i >= 0 ORDER BY c.id OFFSET 999) THEN 1000 "
    + "ELSE (SELECT count(*) FROM articles c WHERE r.i >= 0) END"

[<Literal>]
let private CountTag =
    "(SELECT count(*) FROM (SELECT 1 FROM article_tags c WHERE c.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) LIMIT 1000) s)"

[<Literal>]
let private CountAuthor =
    "(SELECT count(*) FROM (SELECT 1 FROM articles c WHERE c.author_id = (SELECT u.id FROM users u WHERE u.username = $4) LIMIT 1000) s)"

[<Literal>]
let private CountFavorited =
    "(SELECT count(*) FROM (SELECT 1 FROM favorites c WHERE c.user_id = (SELECT u.id FROM users u WHERE u.username = $4) LIMIT 1000) s)"

/// followees as an array: one index scan over articles_author_idx for all of them
[<Literal>]
let private FeedAuthors = "c.author_id = ANY (ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1))"

[<Literal>]
let private CountFeed = "(SELECT count(*) FROM (SELECT 1 FROM articles c WHERE " + FeedAuthors + " LIMIT 1000) s)"

/// $1 viewer, $2 slug. One row with NULL comment columns when the article has no comments; no row = no article.
/// The viewer's followees are read once per request and each comment's author is checked against them.
[<Literal>]
let private CommentsSql =
    """SELECT a.id, c.id AS comment_id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
       c.author_id = ANY (f.ids) AS following
  FROM articles a
  CROSS JOIN LATERAL (SELECT ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) AS ids) f
  LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c
                      WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true
  LEFT JOIN users u ON u.id = c.author_id
 WHERE a.slug = $2
 ORDER BY c.created_at DESC, c.id DESC"""

/// $1 viewer, $2 username
[<Literal>]
let private ProfileSql =
    """SELECT u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following
  FROM users u WHERE u.username = $2"""

[<Literal>]
let private UserById = "SELECT id, username, email, bio, image FROM users WHERE id = $1"

let mutable Tags: Kind = Unchecked.defaultof<_>
let mutable Article: Kind = Unchecked.defaultof<_>
let mutable Comments: Kind = Unchecked.defaultof<_>
let mutable Profile: Kind = Unchecked.defaultof<_>
let mutable User: Kind = Unchecked.defaultof<_>
let mutable ListAll: Kind = Unchecked.defaultof<_>
let mutable ListTag: Kind = Unchecked.defaultof<_>
let mutable ListAuthor: Kind = Unchecked.defaultof<_>
let mutable ListFavorited: Kind = Unchecked.defaultof<_>
let mutable ListFeed: Kind = Unchecked.defaultof<_>

let mutable ArticleBySlug: Stmt = null
let mutable ArticleInsert: Stmt = null
let mutable TagsInsert: Stmt = null
let mutable ArticleTagsInsert: Stmt = null
let mutable ArticleByCurrval: Stmt = null
let mutable ArticleUpdate: Stmt = null
let mutable ArticleAuthorBySlug: Stmt = null
let mutable ArticleDelete: Stmt = null
let mutable FavoriteInsert: Stmt = null
let mutable FavoriteDelete: Stmt = null
let mutable CommentInsert: Stmt = null
let mutable CommentDelete: Stmt = null
let mutable CommentAuthor: Stmt = null
let mutable UserInsert: Stmt = null
let mutable UserByEmail: Stmt = null
let mutable UserUpdate: Stmt = null
let mutable Follow: Stmt = null
let mutable Unfollow: Stmt = null

/// after the collation is known (tag order)
let define () =
    let I8 = Oid.Int8
    let T = Oid.Text
    // the names as a text[] (in name order, from the index); the app writes the JSON
    Tags <-
        addKind "tags" (Stmt.Define("SELECT r.i, ARRAY(SELECT t.name FROM tags t WHERE r.i >= 0 ORDER BY t.name) FROM " + unnest Layout.None, oids Layout.None)) Layout.None
    Article <- batched "article" (fullSelect () + " WHERE a.slug = $2") Layout.ViewerKey
    Comments <- batched "comments" CommentsSql Layout.ViewerKey
    Profile <- batched "profile" ProfileSql Layout.ViewerKey
    User <- batched "user" UserById Layout.Viewer
    let at = articleTail ()
    ListAll <-
        batchedList "list" ("SELECT " + ListCols + at + " FROM (" + PageCols + " ORDER BY a.id DESC LIMIT $2 OFFSET $3) a JOIN users u ON u.id = a.author_id ORDER BY a.id DESC") CountAll Layout.List
    ListAuthor <-
        batchedList
            "author"
            ("SELECT " + ListCols + at + " FROM (" + PageCols
             + " WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a.id DESC LIMIT $2 OFFSET $3) a"
             + " JOIN users u ON u.id = a.author_id ORDER BY a.id DESC")
            CountAuthor
            Layout.ListKey
    ListTag <-
        batchedList
            "tag"
            (listOf "SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3" at)
            CountTag
            Layout.ListKey
    ListFavorited <-
        batchedList
            "favorited"
            (listOf "SELECT f.article_id AS id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3" at)
            CountFavorited
            Layout.ListKey
    ListFeed <-
        batchedList
            "feed"
            (listOf
                "SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::bigint + $3::bigint)) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3"
                (feedTail ()))
            CountFeed
            Layout.List

    ArticleBySlug <- Stmt.Define(fullSelect () + " WHERE a.slug = $2", I8, T)
    // $1 viewer, $2 slug prefix ("<slugified title>-"), $3 title, $4 description, $5 body
    ArticleInsert <-
        Stmt.Define(
            """INSERT INTO articles (id, slug, author_id, title, description, body)
SELECT n.id, $2 || n.id, $1, $3, $4, $5
  FROM (SELECT nextval('articles_id_seq'::regclass) AS id) n""",
            I8, T, T, T, T
        )
    // only tags that don't exist yet (no sequence burn), in name order (no deadlock between concurrent creates)
    TagsInsert <-
        Stmt.Define(
            """INSERT INTO tags (name)
SELECT n FROM (SELECT DISTINCT unnest($1::text[]) AS n) x
 WHERE NOT EXISTS (SELECT 1 FROM tags t WHERE t.name = x.n)
 ORDER BY n
ON CONFLICT (name) DO NOTHING""",
            Oid.TextArray
        )
    ArticleTagsInsert <-
        Stmt.Define(
            """INSERT INTO article_tags (article_id, tag_id)
SELECT (SELECT currval('articles_id_seq'::regclass)), t.id FROM tags t WHERE t.name = ANY($1::text[])""",
            Oid.TextArray
        )
    ArticleByCurrval <- Stmt.Define(fullSelect () + " WHERE a.id = (SELECT currval('articles_id_seq'::regclass))", I8)
    // $1 viewer, $2 slug, $3 title, $4 description, $5 body, $6 new slug prefix (NULL when the title is unchanged)
    ArticleUpdate <-
        Stmt.Define(
            """WITH a AS (
  UPDATE articles SET title = COALESCE($3, title), description = COALESCE($4, description), body = COALESCE($5, body),
         slug = CASE WHEN $6::text IS NULL THEN slug ELSE $6 || id END,
         updated_at = now()
   WHERE slug = $2 AND author_id = $1
  RETURNING id, slug, title, description, body, created_at, updated_at, author_id)
SELECT a.id, a.slug, a.title, a.description, a.body, """
            + at
            + " FROM a JOIN users u ON u.id = a.author_id",
            I8, T, T, T, T, T
        )
    ArticleAuthorBySlug <- Stmt.Define("SELECT author_id FROM articles WHERE slug = $1", T)
    ArticleDelete <- Stmt.Define("DELETE FROM articles WHERE slug = $1 AND author_id = $2", T, I8)
    // the write, then the read-back as its own statement in the same Sync group (one round trip)
    FavoriteInsert <-
        Stmt.Define("INSERT INTO favorites (user_id, article_id) SELECT $1, a.id FROM articles a WHERE a.slug = $2 ON CONFLICT DO NOTHING", I8, T)
    FavoriteDelete <-
        Stmt.Define("DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT a.id FROM articles a WHERE a.slug = $2)", I8, T)
    // $1 viewer, $2 slug, $3 body
    CommentInsert <-
        Stmt.Define(
            """WITH c AS (INSERT INTO comments (article_id, author_id, body)
           SELECT a.id, $1, $3 FROM articles a WHERE a.slug = $2
           RETURNING id, body, created_at, updated_at, author_id)
SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
  FROM c JOIN users u ON u.id = c.author_id""",
            I8, T, T
        )
    // $1 comment id, $2 slug, $3 viewer
    CommentDelete <-
        Stmt.Define("DELETE FROM comments c USING articles a WHERE c.id = $1 AND a.id = c.article_id AND a.slug = $2 AND c.author_id = $3", I8, T, I8)
    CommentAuthor <- Stmt.Define("SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $1 AND a.slug = $2", I8, T)
    UserInsert <- Stmt.Define("INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image", T, T, T)
    UserByEmail <- Stmt.Define("SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1", T)
    UserUpdate <-
        Stmt.Define(
            """UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
                 password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
 WHERE id = $1
RETURNING id, username, email, bio, image""",
            I8, T, T, T, T, T
        )
    Follow <-
        Stmt.Define(
            """WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),
     i AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, u.id FROM u ON CONFLICT DO NOTHING)
SELECT username, bio, image FROM u""",
            I8, T
        )
    Unfollow <-
        Stmt.Define(
            """WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),
     d AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id IN (SELECT id FROM u))
SELECT username, bio, image FROM u""",
            I8, T
        )
