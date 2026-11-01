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
    | ViewerKeyText = 5 // (viewer bigint, key text, text): new comments

/// A kind of batched read: its statement, parameter layout and limits.
type Kind(id: int, name: string, stmt: Stmt, layout: Layout) =
    member _.Id = id
    member _.Name = name
    member _.Stmt = stmt
    member _.Layout = layout
    member val MaxBatch = 64 with get, set
    member val MaxInflight = 6 with get, set
    /// one execution answers every request in the batch (the same for every viewer: GET /api/tags, as #48 and #7)
    member val Broadcast = false with get, set
    /// lists: the same rows from one enrichment per distinct article of the batch (#7), for batches whose pages
    /// overlap; null = none
    member val Shared: Stmt = null with get, set
    /// lists: each distinct article of the batch once, then one row per request with its page ids and flags
    /// (#82's packed results; Db.Packer builds the responses); null = none
    member val Packed: Stmt = null with get, set
    /// the smallest batch that uses Packed (its CTEs cost more than they save on tiny batches)
    member val PackedMin = 4 with get, set
    /// writes: this statement runs first, in the same transaction as Stmt (which reads the responses back); the
    /// batch goes to a write connection
    member val Pre: Stmt = null with get, set
    member val Write = false with get, set

let kinds = List<Kind>()

let private addKind name stmt layout =
    let k = Kind(kinds.Count, name, stmt, layout)
    kinds.Add k
    k

let Collation =
    "SELECT datlocprovider::text, datcollate, coalesce(datlocale, '') FROM pg_database WHERE datname = current_database()"

let private feedProof = Environment.GetEnvironmentVariable "FEED_PROOF" <> "0"
let private feedProofN =
    match Environment.GetEnvironmentVariable "FEED_PROOF_N" with
    | null | "" -> 8
    | s -> int s

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
    | Layout.ViewerKeyText -> "unnest($1::int4[], $2::int8[], $3::text[], $4::text[]) AS r(i, v, k, b)"
    | _ -> "unnest($1::int4[], $2::int8[], $3::int4[], $4::int8[], $5::text[]) AS r(i, v, l, o, k)"

let private oids (l: Layout) : uint32[] =
    match l with
    | Layout.None -> [| Oid.Int4Array |]
    | Layout.Viewer -> [| Oid.Int4Array; Oid.Int8Array |]
    | Layout.ViewerKey -> [| Oid.Int4Array; Oid.Int8Array; Oid.TextArray |]
    | Layout.List -> [| Oid.Int4Array; Oid.Int8Array; Oid.Int4Array; Oid.Int8Array |]
    | Layout.ViewerKeyText -> [| Oid.Int4Array; Oid.Int8Array; Oid.TextArray; Oid.TextArray |]
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

/// The shared form of a batched list (#7's shared enrichment): requests -> capped counts -> page ids, then each
/// distinct article of the batch is enriched once (tags, favorite count, author); viewer flags stay per request.
/// Only requests already queued when the statement starts share it; nothing outlives the statement (rule 5).
/// A page subquery under a constant LIMIT 100 (limit is 1-100): a generic plan otherwise guesses that LIMIT $n keeps
/// a tenth of the table and joins the batch's pages to articles and users with sequential scans (#7's bounded pages).
let private bounded (page: string) = "SELECT * FROM (" + page + ") pg0 LIMIT 100"

let private sharedList (count: string) (pageIds: string) (l: Layout) (feed: bool) =
    Stmt.Define(
        "WITH r AS MATERIALIZED (SELECT * FROM " + unnest l + "), "
        + "c AS MATERIALIZED (SELECT r.*, (" + bindParams count l + ") AS n FROM r), "
        + "p AS MATERIALIZED (SELECT r.i, r.v, r.n, pg.id FROM c r LEFT JOIN LATERAL (" + bindParams (bounded pageIds) l + ") pg ON true), "
        + "e AS MATERIALIZED (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id, "
        + "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id" + tagOrder () + ") AS tags, "
        + "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fc, u.username, u.bio, u.image "
        + "FROM (SELECT DISTINCT id FROM p WHERE id IS NOT NULL) d JOIN articles a ON a.id = d.id JOIN users u ON u.id = a.author_id) "
        + "SELECT p.i, p.n, e.id, e.slug, e.title, e.description, e.created_at, e.updated_at, e.tags, e.fc, "
        + "(SELECT true FROM favorites f WHERE f.user_id = p.v AND f.article_id = e.id) IS NOT NULL, "
        + "e.username, e.bio, e.image, "
        + (if feed then "e.id IS NOT NULL " // the viewer follows every feed author
           else "(SELECT true FROM follows fo WHERE fo.follower_id = p.v AND fo.followee_id = e.author_id) IS NOT NULL ")
        + "FROM p LEFT JOIN e ON e.id = p.id ORDER BY p.i, e.id DESC",
        oids l
    )

/// Packed lists (from #82, rust-tokio-nickita-khylkouski, MIT; on #7's shared lists). Columns:
/// 0 i (-1 for an article row), 1 count, 2 id, 3 slug, 4 title, 5 description, 6 created_at, 7 updated_at, 8 tags,
/// 9 favorites count, 10 username, 11 bio, 12 image, 13 author id, 14 page ids (newest first), 15 the viewer's
/// favorited ids among them, 16 the viewer's followees among their authors. Article rows come first (UNION ALL,
/// no parallel plans). Every distinct article is enriched once per statement; flags stay per viewer.
let private enrichSet () =
    "tg AS MATERIALIZED (SELECT at.article_id, array_agg(t.name" + (if Json.appSortsTags then "" else " ORDER BY t.name")
    + ") AS tags FROM article_tags at JOIN tags t ON t.id = at.tag_id WHERE at.article_id = ANY (ARRAY(SELECT id FROM d)) GROUP BY 1), "
    + "fc AS MATERIALIZED (SELECT f.article_id, count(*) AS n FROM favorites f WHERE f.article_id = ANY (ARRAY(SELECT id FROM d)) GROUP BY 1), "
    + "e AS MATERIALIZED (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id, "
    + "COALESCE(tg.tags, '{}') AS tags, COALESCE(fc.n, 0) AS fc, u.username, u.bio, u.image "
    + "FROM d JOIN articles a ON a.id = d.id JOIN users u ON u.id = a.author_id "
    + "LEFT JOIN tg ON tg.article_id = a.id LEFT JOIN fc ON fc.article_id = a.id)"

let private packedHead =
    " SELECT -1, NULL::int8, e.id, e.slug, e.title, e.description, e.created_at, e.updated_at, e.tags, e.fc, "
    + "e.username, e.bio, e.image, e.author_id, NULL::int8[], NULL::int8[], NULL::int8[] FROM e UNION ALL "
    + "SELECT q.i, c.n, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, "

/// global list: one count, pages per distinct (limit, offset), each viewer's flags read once for the batch's id window
let private packedAll () =
    Stmt.Define(
        "WITH q AS MATERIALIZED (SELECT * FROM " + unnest Layout.List + "), "
        + "c AS MATERIALIZED (SELECT count(*) AS n FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s), "
        + "p AS MATERIALIZED (SELECT r.l, r.o, x.id FROM (SELECT DISTINCT l, o FROM q) r "
        + "CROSS JOIN LATERAL (" + bounded "SELECT a.id FROM articles a ORDER BY a.id DESC LIMIT r.l OFFSET r.o" + ") x), "
        + "d AS MATERIALIZED (SELECT DISTINCT id FROM p), "
        + enrichSet ()
        + ", b AS MATERIALIZED (SELECT min(id) AS lo, max(id) AS hi, array_agg(DISTINCT author_id) AS au FROM e), "
        + "pa AS MATERIALIZED (SELECT l, o, array_agg(id ORDER BY id DESC) AS ids FROM p GROUP BY l, o), "
        + "vf AS MATERIALIZED (SELECT f.user_id, array_agg(f.article_id) AS ids FROM favorites f "
        + "WHERE f.user_id = ANY (ARRAY(SELECT DISTINCT v FROM q WHERE v <> 0)) "
        + "AND f.article_id BETWEEN (SELECT lo FROM b) AND (SELECT hi FROM b) GROUP BY 1), "
        + "vo AS MATERIALIZED (SELECT fo.follower_id, array_agg(fo.followee_id) AS ids FROM follows fo "
        + "WHERE fo.follower_id = ANY (ARRAY(SELECT DISTINCT v FROM q WHERE v <> 0)) AND fo.followee_id = ANY ((SELECT au FROM b)::int8[]) GROUP BY 1)"
        + packedHead
        + "COALESCE(pa.ids, '{}'), COALESCE(vf.ids, '{}'), COALESCE(vo.ids, '{}') FROM q CROSS JOIN c "
        + "LEFT JOIN pa ON pa.l = q.l AND pa.o = q.o LEFT JOIN vf ON vf.user_id = q.v LEFT JOIN vo ON vo.follower_id = q.v",
        oids Layout.List
    )

/// filtered lists: a count per distinct key, a page per distinct (limit, offset, key), flags by one = ANY (page)
/// read per request
let private packedKey (count: string) (pageIds: string) =
    let l = Layout.ListKey
    Stmt.Define(
        "WITH q AS MATERIALIZED (SELECT * FROM " + unnest l + "), "
        + "c AS MATERIALIZED (SELECT r.k, (" + bindParams count l + ") AS n FROM (SELECT DISTINCT k FROM q) r), "
        + "p AS MATERIALIZED (SELECT r.l, r.o, r.k, x.id FROM (SELECT DISTINCT l, o, k FROM q) r "
        + "CROSS JOIN LATERAL (" + bindParams (bounded pageIds) l + ") x), "
        + "d AS MATERIALIZED (SELECT DISTINCT id FROM p), "
        + enrichSet ()
        + ", pa AS MATERIALIZED (SELECT p.l, p.o, p.k, array_agg(p.id ORDER BY p.id DESC) AS ids, array_agg(DISTINCT e.author_id) AS au "
        + "FROM p JOIN e ON e.id = p.id GROUP BY p.l, p.o, p.k)"
        + packedHead
        + "COALESCE(pa.ids, '{}'), "
        + "CASE WHEN q.v = 0 OR pa.ids IS NULL THEN '{}'::int8[] ELSE ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = q.v AND f.article_id = ANY (pa.ids)) END, "
        + "CASE WHEN q.v = 0 OR pa.ids IS NULL THEN '{}'::int8[] ELSE ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = q.v AND fo.followee_id = ANY (pa.au)) END "
        + "FROM q JOIN c ON c.k = q.k LEFT JOIN pa ON pa.l = q.l AND pa.o = q.o AND pa.k = q.k",
        oids l
    )

/// feed: each request's followees read once for its count and page; every page article's author is followed
let private packedFeed () =
    Stmt.Define(
        "WITH q AS MATERIALIZED (SELECT r.*, ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v) AS fl FROM "
        + unnest Layout.List + "), "
        + (if feedProof then
               // count proof shared by the batch (#100): the followees most viewers share are probed once for a
               // 1000th article; a viewer who follows one has the capped count 1000 without walking its own
               "h AS MATERIALIZED (SELECT ARRAY(SELECT t.a FROM (SELECT f.a FROM q, unnest(q.fl) AS f(a) GROUP BY f.a "
               + "HAVING count(*) >= 2 ORDER BY count(*) DESC LIMIT " + string feedProofN + ") t "
               + "WHERE EXISTS (SELECT 1 FROM articles a3 WHERE a3.author_id = t.a OFFSET 999 LIMIT 1)) AS ha), "
           else "")
        + "c AS MATERIALIZED (SELECT q.i, CASE "
        + (if feedProof then "WHEN q.fl && (SELECT ha FROM h) THEN 1000::int8 " else "")
        + "WHEN EXISTS (SELECT 1 FROM articles a3 WHERE a3.author_id = ANY (q.fl) "
        + "ORDER BY a3.author_id, a3.id DESC OFFSET 999 LIMIT 1) THEN 1000::int8 "
        + "ELSE (SELECT count(*) FROM articles a3 WHERE a3.author_id = ANY (q.fl)) END AS n FROM q), "
        + "p AS MATERIALIZED (SELECT q.i, x.id FROM q CROSS JOIN LATERAL ("
        + bounded (
            "SELECT y.id FROM unnest(q.fl) AS f(a) "
            + "CROSS JOIN LATERAL (SELECT a3.id FROM articles a3 WHERE a3.author_id = f.a ORDER BY a3.id DESC LIMIT (q.l + q.o)) y "
            + "ORDER BY y.id DESC LIMIT q.l OFFSET q.o")
        + ") x), "
        + "d AS MATERIALIZED (SELECT DISTINCT id FROM p), "
        + enrichSet ()
        + ", pa AS MATERIALIZED (SELECT p.i, array_agg(p.id ORDER BY p.id DESC) AS ids, "
        + "array_agg(p.id) FILTER (WHERE EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = p.id AND f.user_id = q.v)) AS favs, "
        + "array_agg(DISTINCT e.author_id) AS fols FROM p JOIN q ON q.i = p.i JOIN e ON e.id = p.id GROUP BY p.i)"
        + packedHead
        + "COALESCE(pa.ids, '{}'), COALESCE(pa.favs, '{}'), COALESCE(pa.fols, '{}') FROM q JOIN c ON c.i = q.i LEFT JOIN pa ON pa.i = q.i",
        oids Layout.List
    )

/// Article and comments by slug when at least half of a batch repeats a slug (#82): each distinct slug's article (or
/// comment list) is read once; the viewer flags stay per request. Same rows as the per-request forms.
let private sharedArticle () =
    Stmt.Define(
        "WITH q AS MATERIALIZED (SELECT * FROM " + unnest Layout.ViewerKey + "), "
        + "e AS MATERIALIZED (SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, a.author_id, "
        + "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id" + tagOrder () + ") AS tags, "
        + "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fc, u.username, u.bio, u.image "
        + "FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = ANY (ARRAY(SELECT DISTINCT k FROM q))) "
        + "SELECT q.i, e.id, e.slug, e.title, e.description, e.body, e.created_at, e.updated_at, e.tags, e.fc, "
        + "(SELECT true FROM favorites f WHERE f.user_id = q.v AND f.article_id = e.id) IS NOT NULL, e.username, e.bio, e.image, "
        + "(SELECT true FROM follows fo WHERE fo.follower_id = q.v AND fo.followee_id = e.author_id) IS NOT NULL "
        + "FROM q JOIN e ON e.slug = q.k",
        oids Layout.ViewerKey
    )

let private sharedComments () =
    Stmt.Define(
        "WITH q AS MATERIALIZED (SELECT * FROM " + unnest Layout.ViewerKey + "), "
        + "e AS MATERIALIZED (SELECT a.slug, a.id AS aid, c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image "
        + "FROM articles a LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c "
        + "WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true "
        + "LEFT JOIN users u ON u.id = c.author_id WHERE a.slug = ANY (ARRAY(SELECT DISTINCT k FROM q))), "
        + "fl AS MATERIALIZED (SELECT q.i, ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = q.v) AS ids FROM q) "
        + "SELECT q.i, e.aid, e.id, e.body, e.created_at, e.updated_at, e.username, e.bio, e.image, e.author_id = ANY (fl.ids) "
        + "FROM q JOIN fl ON fl.i = q.i JOIN e ON e.slug = q.k ORDER BY q.i, e.created_at DESC, e.id DESC",
        oids Layout.ViewerKey
    )

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

/// the feed page: the newest (limit + offset) of each followee, merged
[<Literal>]
let private FeedPage =
    "SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::bigint + $3::bigint)) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3"

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

let mutable FavoriteW: Kind = Unchecked.defaultof<_>
let mutable UnfavoriteW: Kind = Unchecked.defaultof<_>
let mutable FollowW: Kind = Unchecked.defaultof<_>
let mutable UnfollowW: Kind = Unchecked.defaultof<_>
let mutable CommentW: Kind = Unchecked.defaultof<_>
/// favorites and follows go through the write kinds (WRITE_BATCH, default on)
let mutable WriteBatch = false
/// new comments go through CommentW (COMMENT_BATCH, default on with WRITE_BATCH)
let mutable CommentBatch = false

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
        if Environment.GetEnvironmentVariable "TAGS_BROADCAST" = "0" then
            addKind "tags" (Stmt.Define("SELECT r.i, ARRAY(SELECT t.name FROM tags t WHERE r.i >= 0 ORDER BY t.name) FROM " + unnest Layout.None, oids Layout.None)) Layout.None
        else
            // one execution for all the tag requests queued when the statement starts; nothing is kept after it
            let k = addKind "tags" (Stmt.Define("SELECT 0, ARRAY(SELECT t.name FROM tags t ORDER BY t.name)")) Layout.None
            k.Broadcast <- true
            k
    Article <- batched "article" (fullSelect () + " WHERE a.slug = $2") Layout.ViewerKey
    Comments <- batched "comments" CommentsSql Layout.ViewerKey
    Profile <- batched "profile" ProfileSql Layout.ViewerKey
    User <- batched "user" UserById Layout.Viewer
    // Group commit for favorites and follows (rule 6 allows it: each response waits for its batch's commit). The
    // batch's inserts or deletes are one statement, then the batched article or profile read gives the responses,
    // in one transaction. Rows are written in key order, so two concurrent batches lock in the same order.
    if Environment.GetEnvironmentVariable "WRITE_BATCH" <> "0" then
        let r = " FROM " + unnest Layout.ViewerKey
        let writeKind name (pre: string) (read: Kind) =
            let k = addKind name read.Stmt Layout.ViewerKey
            k.Pre <- Stmt.Define(pre, oids Layout.ViewerKey)
            k.Write <- true
            k
        FavoriteW <-
            writeKind "favorite" ("INSERT INTO favorites (user_id, article_id) SELECT r.v, a.id" + r
                                  + " JOIN articles a ON a.slug = r.k ORDER BY 1, 2 ON CONFLICT DO NOTHING") Article
        UnfavoriteW <-
            writeKind "unfavorite" ("DELETE FROM favorites f USING (SELECT r.v, a.id" + r
                                    + " JOIN articles a ON a.slug = r.k) x WHERE f.user_id = x.v AND f.article_id = x.id") Article
        FollowW <-
            writeKind "follow" ("INSERT INTO follows (follower_id, followee_id) SELECT r.v, u.id" + r
                                + " JOIN users u ON u.username = r.k ORDER BY 1, 2 ON CONFLICT DO NOTHING") Profile
        UnfollowW <-
            writeKind "unfollow" ("DELETE FROM follows fo USING (SELECT r.v, u.id" + r
                                  + " JOIN users u ON u.username = r.k) x WHERE fo.follower_id = x.v AND fo.followee_id = x.id") Profile
        // new comments: RETURNING cannot name the request, so each new row is matched back to its request by
        // (author, article, body) and its rank among identical ones (identical requests get distinct comments)
        if Environment.GetEnvironmentVariable "COMMENT_BATCH" <> "0" then
            CommentW <-
                addKind
                    "comment"
                    (Stmt.Define(
                        "WITH r AS MATERIALIZED (SELECT r.i, r.v, r.b, a.id AS aid FROM " + unnest Layout.ViewerKeyText
                        + " JOIN articles a ON a.slug = r.k), "
                        + "c AS (INSERT INTO comments (article_id, author_id, body) SELECT aid, v, b FROM r ORDER BY i "
                        + "RETURNING id, article_id, author_id, body, created_at, updated_at) "
                        + "SELECT r.i, c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image "
                        + "FROM (SELECT r.*, row_number() OVER (PARTITION BY r.v, r.aid, r.b ORDER BY r.i) AS n FROM r) r "
                        + "JOIN (SELECT c.*, row_number() OVER (PARTITION BY c.author_id, c.article_id, c.body ORDER BY c.id) AS n FROM c) c "
                        + "ON c.author_id = r.v AND c.article_id = r.aid AND c.body = r.b AND c.n = r.n "
                        + "JOIN users u ON u.id = r.v",
                        oids Layout.ViewerKeyText
                    ))
                    Layout.ViewerKeyText
            CommentW.Write <- true
            CommentBatch <- true
        WriteBatch <- true
    let at = articleTail ()
    let shared = Environment.GetEnvironmentVariable "LIST_SHARED" = "1"
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
    if shared then
        ListAll.Shared <- sharedList CountAll "SELECT a.id FROM articles a ORDER BY a.id DESC LIMIT $2 OFFSET $3" Layout.List false
        ListAuthor.Shared <-
            sharedList CountAuthor "SELECT a.id FROM articles a WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a.id DESC LIMIT $2 OFFSET $3" Layout.ListKey false
        ListTag.Shared <-
            sharedList CountTag "SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3" Layout.ListKey false
        ListFavorited.Shared <-
            sharedList CountFavorited "SELECT f.article_id AS id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3" Layout.ListKey false
    ListFeed <-
        batchedList
            "feed"
            (listOf FeedPage (feedTail ()))
            CountFeed
            Layout.List

    if shared && Environment.GetEnvironmentVariable "FEED_SHARED" <> "0" then
        ListFeed.Shared <- sharedList CountFeed FeedPage Layout.List true

    if Environment.GetEnvironmentVariable "SLUG_SHARED" = "1" then
        Article.Shared <- sharedArticle ()
        Comments.Shared <- sharedComments ()
    if Environment.GetEnvironmentVariable "LIST_PACKED" <> "0" then
        ListAll.Packed <- packedAll ()
        ListAuthor.Packed <-
            packedKey CountAuthor "SELECT a.id FROM articles a WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a.id DESC LIMIT $2 OFFSET $3"
        ListTag.Packed <-
            packedKey CountTag "SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3"
        ListFavorited.Packed <-
            packedKey CountFavorited "SELECT f.article_id AS id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3"
        if Environment.GetEnvironmentVariable "FEED_PACKED" <> "0" then ListFeed.Packed <- packedFeed ()

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
