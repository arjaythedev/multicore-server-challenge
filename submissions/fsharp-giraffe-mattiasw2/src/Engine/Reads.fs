module Engine.Reads

// Read batching, the read-side twin of Commit. Every hot read is a value (`Read`) and queues
// here. A reader lane takes everything that queued while its previous batch was in flight, up
// to a cap, and answers the whole batch in two round trips inside ONE read-only snapshot:
//
//   plan     F#: the batch's distinct needs. Forty requests for page 1 of the global feed are
//            one page; forty viewers of one article are one row.
//   phase A  whatever a key leads to, each row read once: the tags table; each distinct list
//            page with its articles' columns and a capped count per list key; each feed
//            viewer's count and the newest article ids of its followees; the article of each
//            slug; each comment thread; each username's user.
//   plan     F#: the feed pages (cut from those ids), every article shown, every
//            author to name, and each viewer's (viewer, article) and (viewer, user) pairs.
//   phase B  what only ids can ask for, once per BATCH: the feed articles' columns, the tags
//            and favorite counts of every article shown, every author once, and the viewers'
//            flags as one index range per viewer.
//   assemble pure: each request's answer from those maps. Requests that show the same article
//            share one Card object.
//
// The SQL only looks rows up by keys F# has already made distinct, so there is no dedup, join
// or grouping work left for Postgres. A lane lets the oldest request wait up to the gather window
// for batch-mates; near saturation the queue already holds a full batch, nobody waits, and each
// request costs less.
//
// Not a cache: every request is answered from a snapshot taken after it arrived, and nothing
// outlives its batch (README rule 5).

open System
open System.Collections.Generic
open System.Data
open System.Threading
open System.Threading.Channels
open System.Threading.Tasks
open Npgsql
open NpgsqlTypes

// ------------------------------------------------------------ requests ---------

/// One hot read, as data.
type Read =
    | ReadTags
    | ReadPage of viewer: ViewerId * filter: ArticleFilter * paging: Paging
    | ReadFeed of viewer: ViewerId * paging: Paging
    | ReadArticle of viewer: ViewerId * slug: string
    | ReadComments of viewer: ViewerId * slug: string
    | ReadProfile of viewer: ViewerId * username: string

type Answer =
    | TagNames of string list
    | Listed of ArticlePage
    | Found of Article option
    | Thread of Comment list option
    | Person of Profile option

// ----------------------------------------------------------------- SQL ---------

let private texts (name: string) (values: string[]) : NpgsqlParameter =
    NpgsqlParameter<string[]>(name, NpgsqlDbType.Array ||| NpgsqlDbType.Text, TypedValue = values)

let private longs (name: string) (values: int64[]) : NpgsqlParameter =
    NpgsqlParameter<int64[]>(name, NpgsqlDbType.Array ||| NpgsqlDbType.Bigint, TypedValue = values)

let private ints (name: string) (values: int[]) : NpgsqlParameter =
    NpgsqlParameter<int[]>(name, NpgsqlDbType.Array ||| NpgsqlDbType.Integer, TypedValue = values)

/// Both the tag list and the cards' tag names: the tags table (200 rows) in name order, which is
/// the spec's `ORDER BY t.name` in the database's collation (not .NET's).
let private tagsSql = "SELECT t.id, t.name FROM tags t ORDER BY t.name"

/// An article's columns as a card needs them, without the body. The statement that finds an
/// article returns them, so its row is read once.
let private cardColumns = "a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at"

let private noCard = "NULL::int8, NULL::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz"

/// One kind of list. Its statement resolves each distinct key once (`k.kid`), counts each key
/// (capped) and returns each distinct page's articles, newest first (id DESC).
type private Listing =
    { /// The key's id, from the key text `r.key`.
      Resolve: string
      /// The rows to count for `k.kid`; the caller caps them at 1000.
      Counted: string
      /// The cards (`cardColumns`) of the page `p.lim`, `p.off` of `k.kid`.
      Page: string }

// The global count walks the primary key from the OLDEST end: those pages are all-visible, so
// it is an index-only scan that never touches the heap. count(min(total, 1000)) either way.
let private everything =
    { Resolve = "0::int8"
      Counted = "SELECT 1 FROM articles a ORDER BY a.id"
      Page = $"SELECT {cardColumns} FROM articles a ORDER BY a.id DESC LIMIT p.lim OFFSET p.off" }

/// A page of ids `y.id`, then each article's row: one probe each. (LIMIT 1 keeps the planner,
/// which cannot see how few ids there are, from turning the probes into a join of whole tables.)
let private cardsOf (ids: string) =
    $"SELECT a.* FROM ({ids}) y CROSS JOIN LATERAL (SELECT {cardColumns} FROM articles a WHERE a.id = y.id LIMIT 1) a"

let private byTag =
    { Resolve = "(SELECT t.id FROM tags t WHERE t.name = r.key)"
      Counted = "SELECT 1 FROM article_tags at WHERE at.tag_id = k.kid"
      Page =
        cardsOf
            "SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = k.kid
              ORDER BY at.article_id DESC LIMIT p.lim OFFSET p.off" }

let private userOfKey = "(SELECT u.id FROM users u WHERE u.username = r.key)"

let private byAuthor =
    { Resolve = userOfKey
      Counted = "SELECT 1 FROM articles a WHERE a.author_id = k.kid"
      Page = $"SELECT {cardColumns} FROM articles a WHERE a.author_id = k.kid ORDER BY a.id DESC LIMIT p.lim OFFSET p.off" }

let private favoritedBy =
    { Resolve = userOfKey
      Counted = "SELECT 1 FROM favorites f WHERE f.user_id = k.kid"
      Page =
        cardsOf
            "SELECT f.article_id AS id FROM favorites f WHERE f.user_id = k.kid
              ORDER BY f.article_id DESC LIMIT p.lim OFFSET p.off" }

/// Indexed by `listingOf`.
let private listings = [| everything; byTag; byAuthor; favoritedBy |]

let private listingOf (filter: ArticleFilter) : struct (int * string) =
    match filter with
    | Everything -> 0, ""
    | ByTag tag -> 1, tag
    | ByAuthor name -> 2, name
    | FavoritedBy name -> 3, name

/// Phase A, per listing. Count rows: the key's position, no card, the total. Page rows: the
/// page's position, a card, no total.
let private listSql (l: Listing) =
    $"WITH k AS MATERIALIZED (
            SELECT r.i, {l.Resolve} AS kid FROM unnest(@keys::text[]) WITH ORDINALITY AS r(key, i))
      SELECT k.i, {noCard}, (SELECT count(*) FROM ({l.Counted} LIMIT 1000) s) AS total FROM k
      UNION ALL
      SELECT p.i, x.*, NULL::int8
        FROM unnest(@pkeys::int8[], @lims::int8[], @offs::int8[]) WITH ORDINALITY AS p(k, lim, off, i)
        JOIN k ON k.i = p.k
       CROSS JOIN LATERAL ({l.Page}) x"

let private listSqls = listings |> Array.map listSql

/// Phase A, the feeds of the batch's distinct viewers (@viewers, each with the deepest
/// limit + offset it asks for). Rows of kind 0: the viewer's position and its capped count.
/// Rows of kind 1: the viewer's position and one of its newest `depth` (article, author); F#
/// cuts each page from them.
///
/// A hub is a followee that several of the batch's viewers share (the 32 most shared).
///
/// The candidates. A hub's floor is the id of its `depth`-th newest article: a viewer who follows
/// it has at least `depth` articles from that id up, so its pages lie there, and ONE index scan
/// (every followee, from the floor up) finds them. A viewer without a hub that has a floor takes
/// the newest `depth` of each followee, a scan per followee.
///
/// The count. A viewer who follows an author with 1000 or more articles has a feed of 1000 or
/// more. The batch proves that once for each hub that three or more viewers share (the proof
/// walks 1000 index entries, as much as counting for one viewer), and its viewers get 1000
/// without a count. The rest are counted.
let private feedSql =
    "WITH fv AS MATERIALIZED (
          SELECT r.i, r.depth, ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v) AS fids
            FROM unnest(@viewers::int8[], @depths::int8[]) WITH ORDINALITY AS r(v, depth, i)),
        hub AS MATERIALIZED (
          SELECT h.f,
                 (SELECT a.id FROM articles a WHERE a.author_id = h.f ORDER BY a.id DESC OFFSET h.depth - 1 LIMIT 1) AS floor,
                 CASE WHEN h.n >= 3 THEN EXISTS (SELECT 1 FROM articles a WHERE a.author_id = h.f OFFSET 999) ELSE false END AS big
            FROM (SELECT x.f, max(fv.depth) AS depth, count(*) AS n
                    FROM fv CROSS JOIN LATERAL unnest(fv.fids) AS x(f)
                   GROUP BY x.f HAVING count(*) >= 2 ORDER BY count(*) DESC LIMIT 32) h),
        heavy AS MATERIALIZED (SELECT coalesce(array_agg(hub.f) FILTER (WHERE hub.big), '{}') AS ids FROM hub),
        fl AS MATERIALIZED (
          SELECT fv.i, fv.depth, fv.fids, (SELECT max(hub.floor) FROM hub WHERE hub.f = ANY (fv.fids)) AS floor FROM fv)
     SELECT 0, fl.i, NULL::int8, NULL::int8,
            CASE WHEN fl.fids && (SELECT h.ids FROM heavy h) THEN 1000::int8
                 ELSE (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = ANY (fl.fids) LIMIT 1000) s)
            END
       FROM fl
     UNION ALL
     SELECT 1, fl.i, a.id, a.author_id, NULL::int8
       FROM fl CROSS JOIN LATERAL (
              SELECT a.id, a.author_id FROM articles a WHERE a.author_id = ANY (fl.fids) AND a.id >= fl.floor
               ORDER BY a.id DESC LIMIT fl.depth) a
      WHERE fl.floor IS NOT NULL
     UNION ALL
     SELECT 1, fl.i, a.id, a.author_id, NULL::int8
       FROM fl CROSS JOIN LATERAL (
              SELECT n.id, f.id AS author_id FROM unnest(fl.fids) AS f(id)
               CROSS JOIN LATERAL (SELECT a.id FROM articles a WHERE a.author_id = f.id ORDER BY a.id DESC LIMIT fl.depth) n
               ORDER BY n.id DESC LIMIT fl.depth) a
      WHERE fl.floor IS NULL"

/// Phase A: the article of each distinct slug an article page shows, with its body.
let private slugsSql = $"SELECT {cardColumns}, a.body FROM articles a WHERE a.slug = ANY (@slugs)"

/// Phase A: the newest 100 comments of each distinct slug a comments page shows (F# puts them in
/// order). An article without comments is one row without a comment; no row means no article.
let private threadsSql =
    "SELECT r.i, c.id, c.body, c.created_at, c.updated_at, c.author_id
       FROM unnest(@threads::text[]) WITH ORDINALITY AS r(slug, i)
      CROSS JOIN LATERAL (SELECT a.id FROM articles a WHERE a.slug = r.slug LIMIT 1) a
       LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id
                            FROM comments c WHERE c.article_id = a.id
                           ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true"

let private userColumns = "u.id, u.username, u.bio, u.image"

/// Phase A: the profiles' users.
let private usernamesSql = $"SELECT {userColumns} FROM users u WHERE u.username = ANY (@usernames)"

// Phase B: flat statements over ids F# has made distinct, put together in F#.
//   metaSql       the feed articles' columns (phase A returned only their ids);
//   cardTagsSql   the cards' (article, tag id) pairs, one index scan for all of them;
//   favoritesSql  the cards' favorite counts, one index scan (an article without any has no row);
//   authorsSql    each distinct author of a card or a comment, once.
// F# names each card's tags and orders them by their position in the tags table. On the seed,
// 1,000 cards took 9.9 ms as one statement with the tag names and counts inside, 4.2 ms flat.

let private metaSql = $"SELECT {cardColumns} FROM articles a WHERE a.id = ANY (@ids)"

let private cardTagsSql = "SELECT at.article_id, at.tag_id FROM article_tags at WHERE at.article_id = ANY (@ids)"

let private favoritesSql =
    "SELECT f.article_id, count(*) FROM favorites f WHERE f.article_id = ANY (@ids) GROUP BY f.article_id"

let private authorsSql = $"SELECT {userColumns} FROM users u WHERE u.id = ANY (@ids)"

/// Phase B: the viewers' flags that are set. F# has grouped the pairs: viewer i's articles are
/// @fa[@fs[i] : @fe[i]] and the users it might follow are @oa[@os[i] : @oe[i]], so each viewer
/// is one index range scan with = ANY, and nothing is sorted or aggregated here.
/// Rows: following?, viewer, article or user.
let private flagsSql =
    "SELECT false, p.v, f.article_id
       FROM unnest(@fv::int8[], @fs::int4[], @fe::int4[]) AS p(v, s, e)
      CROSS JOIN LATERAL (SELECT f.article_id FROM favorites f
                           WHERE f.user_id = p.v AND f.article_id = ANY ((@fa::int8[])[p.s:p.e])) f
     UNION ALL
     SELECT true, q.v, fo.followee_id
       FROM unnest(@ov::int8[], @os::int4[], @oe::int4[]) AS q(v, s, e)
      CROSS JOIN LATERAL (SELECT fo.followee_id FROM follows fo
                           WHERE fo.follower_id = q.v AND fo.followee_id = ANY ((@oa::int8[])[q.s:q.e])) fo"

// ---------------------------------------------------------------- plan ---------

/// Distinct keys in first-seen order, each with its position. `capacity`: about how many keys
/// to expect (a table that grows by doubling throws away as much as it ends up holding).
[<Sealed>]
type private Distinct<'k when 'k: equality>(capacity: int) =
    let index = Dictionary<'k, int>(capacity)
    let items = ResizeArray<'k>(capacity)

    new() = Distinct<'k>(0)

    member _.Add(key: 'k) : int =
        match index.TryGetValue key with
        | true, i -> i
        | _ ->
            let i = items.Count
            index[key] <- i
            items.Add key
            i

    member _.Count = items.Count
    member _.Items = items
    member _.IndexOf(key: 'k) = index[key]

    /// -1 for a key that was never added.
    member _.Find(key: 'k) : int =
        match index.TryGetValue key with
        | true, i -> i
        | _ -> -1

/// Saturating, so a huge offset cannot overflow the feed's LIMIT.
let private depthOf (p: Paging) =
    if p.Offset > Int64.MaxValue - p.Limit then Int64.MaxValue else p.Limit + p.Offset

/// What phase A must find.
[<NoEquality; NoComparison>]
type private PlanA =
    { Tags: bool
      /// Per listing: its distinct keys, and its distinct pages (key position, limit, offset).
      Keys: Distinct<string>[]
      Pages: Distinct<struct (int * int64 * int64)>[]
      /// The feeds' distinct viewers, each with its deepest limit + offset.
      FeedViewers: Distinct<int64>
      FeedDepths: ResizeArray<int64>
      Slugs: Distinct<string>
      Threads: Distinct<string>
      Usernames: Distinct<string> }

let private pageOf (a: PlanA) (filter: ArticleFilter) (paging: Paging) : struct (int * int * int) =
    let struct (l, key) = listingOf filter
    let k = a.Keys[l].Add key
    struct (l, k, a.Pages[l].Add(struct (k, paging.Limit, paging.Offset)))

let private planA (reads: Read[]) : PlanA =
    let plan =
        { // The tags table: for a tag list, and to name the tags of any card.
          Tags =
            reads
            |> Array.exists (function
                | ReadComments _
                | ReadProfile _ -> false
                | _ -> true)
          Keys = Array.init listings.Length (fun _ -> Distinct())
          Pages = Array.init listings.Length (fun _ -> Distinct())
          FeedViewers = Distinct()
          FeedDepths = ResizeArray()
          Slugs = Distinct()
          Threads = Distinct()
          Usernames = Distinct() }
    for read in reads do
        match read with
        | ReadTags -> ()
        | ReadPage(_, filter, paging) -> pageOf plan filter paging |> ignore
        | ReadFeed(viewer, paging) ->
            let i = plan.FeedViewers.Add viewer
            let depth = depthOf paging
            if i = plan.FeedDepths.Count then plan.FeedDepths.Add depth
            elif depth > plan.FeedDepths[i] then plan.FeedDepths[i] <- depth
        | ReadArticle(_, slug) -> plan.Slugs.Add slug |> ignore
        | ReadComments(_, slug) -> plan.Threads.Add slug |> ignore
        | ReadProfile(_, username) -> plan.Usernames.Add username |> ignore
    plan

/// An article's row.
[<NoEquality; NoComparison>]
type private Row =
    { Id: int64
      AuthorId: int64
      Slug: string
      Title: string
      Description: string
      CreatedAt: DateTime
      UpdatedAt: DateTime
      /// Only where an article page asked for it.
      Body: string option }

/// A comment's row.
[<NoEquality; NoComparison>]
type private Remark =
    { Id: int64
      Body: string
      CreatedAt: DateTime
      UpdatedAt: DateTime
      AuthorId: int64 }

/// What the two phases found. Phase A fills everything down to Newest; phase B adds the feed
/// articles' rows and fills the rest.
[<NoEquality; NoComparison>]
type private Found =
    { /// The tags table in name order, and tag id -> its position there.
      TagNames: ResizeArray<string>
      TagRanks: Dictionary<int, int>
      /// Per listing: each key's capped count, each page's article ids.
      Totals: int64[][]
      PageIds: ResizeArray<int64>[][]
      Rows: Dictionary<int64, Row>
      SlugIds: Dictionary<string, int64>
      /// Per thread slug: its newest comments, or null where there is no such article.
      Threads: ResizeArray<Remark>[]
      /// Per username.
      Users: Author voption[]
      /// Per feed viewer: its capped count, and the newest `depth` articles of its followees as
      /// (article, author).
      FeedTotals: int64[]
      Feeds: ResizeArray<struct (int64 * int64)>[]
      /// Article id -> its tags' positions.
      CardTags: Dictionary<int64, ResizeArray<int>>
      mutable FavoritesCounts: Dictionary<int64, int64>
      Authors: Dictionary<int64, Author>
      Favorited: HashSet<struct (int64 * int64)>
      Following: HashSet<struct (int64 * int64)> }

/// What phase B must fetch.
[<NoEquality; NoComparison>]
type private PlanB =
    { /// Per request: a feed request's page as (article, author), newest first; null otherwise.
      FeedPages: struct (int64 * int64)[][]
      /// Feed articles whose row phase A did not happen to return.
      Meta: Distinct<int64>
      /// Every article shown, and every author of an article or a comment shown.
      Cards: Distinct<int64>
      Authors: Distinct<int64>
      /// (viewer, article shown to it) and (viewer, user it may follow), with repeats.
      Favorites: ResizeArray<struct (int64 * int64)>
      Follows: ResizeArray<struct (int64 * int64)> }

let private newestPairFirst (struct (x: int64, _: int64)) (struct (y: int64, _: int64)) = compare y x

/// A feed page: the newest `limit` after `offset` of the viewer's candidates (sorted, newest
/// first).
let private feedPage (candidates: ResizeArray<struct (int64 * int64)>) (paging: Paging) : struct (int64 * int64)[] =
    let skip = if paging.Offset > int64 candidates.Count then candidates.Count else int paging.Offset
    let take = if paging.Limit > int64 (candidates.Count - skip) then candidates.Count - skip else int paging.Limit
    candidates.GetRange(skip, take).ToArray()

/// (No user has id 0, so an anonymous viewer's flags are all false and need no pairs.)
let private planB (reads: Read[]) (a: PlanA) (found: Found) : PlanB =
    let plan =
        { FeedPages = Array.zeroCreate reads.Length
          Meta = Distinct()
          // Nearly every row phase A returned is shown, and each has an author.
          Cards = Distinct found.Rows.Count
          Authors = Distinct found.Rows.Count
          Favorites = ResizeArray found.Rows.Count
          Follows = ResizeArray found.Rows.Count }
    /// An article phase A returned, shown to `viewer`.
    let card (viewer: ViewerId) (id: int64) =
        match found.Rows.TryGetValue id with
        | true, row ->
            plan.Cards.Add id |> ignore
            plan.Authors.Add row.AuthorId |> ignore
            if viewer <> 0L then
                plan.Favorites.Add(struct (viewer, id))
                plan.Follows.Add(struct (viewer, row.AuthorId))
        | _ -> ()
    for i in 0 .. reads.Length - 1 do
        match reads[i] with
        | ReadTags -> ()
        | ReadPage(viewer, filter, paging) ->
            let struct (l, _, page) = pageOf a filter paging
            for id in found.PageIds[l][page] do
                card viewer id
        | ReadFeed(viewer, paging) ->
            let page = feedPage found.Feeds[a.FeedViewers.IndexOf viewer] paging
            plan.FeedPages[i] <- page
            // The viewer follows every author on its feed: no (viewer, author) pair to look up.
            for struct (id, author) in page do
                plan.Cards.Add id |> ignore
                plan.Authors.Add author |> ignore
                if not (found.Rows.ContainsKey id) then plan.Meta.Add id |> ignore
                plan.Favorites.Add(struct (viewer, id))
        | ReadArticle(viewer, slug) ->
            match found.SlugIds.TryGetValue slug with
            | true, id -> card viewer id
            | _ -> ()
        | ReadComments(viewer, slug) ->
            let thread = found.Threads[a.Threads.IndexOf slug]
            if not (isNull thread) then
                for c in thread do
                    plan.Authors.Add c.AuthorId |> ignore
                    if viewer <> 0L then plan.Follows.Add(struct (viewer, c.AuthorId))
        | ReadProfile(viewer, username) ->
            match found.Users[a.Usernames.IndexOf username] with
            | ValueSome u when viewer <> 0L -> plan.Follows.Add(struct (viewer, u.Id))
            | _ -> ()
    plan

let private byOwner (struct (v: int64, x: int64)) (struct (w: int64, y: int64)) =
    if v <> w then compare v w else compare x y

/// Pairs (owner, item) as the flags statement takes them: the distinct owners, and each owner's
/// distinct items as the slice [start : end] (1-based, inclusive) of one flat array.
let private slices (pairs: ResizeArray<struct (int64 * int64)>) : struct (int64[] * int[] * int[] * int64[]) =
    pairs.Sort(Comparison byOwner)
    let owners = ResizeArray<int64>()
    let starts = ResizeArray<int>()
    let ends = ResizeArray<int>()
    let items = ResizeArray<int64>(pairs.Count)
    for i in 0 .. pairs.Count - 1 do
        let struct (owner, item) = pairs[i]
        if i = 0 then
            owners.Add owner
            starts.Add 1
            items.Add item
        else
            let struct (lastOwner, lastItem) = pairs[i - 1]
            if owner <> lastOwner then
                ends.Add items.Count
                owners.Add owner
                starts.Add(items.Count + 1)
                items.Add item
            elif item <> lastItem then
                items.Add item
    if pairs.Count > 0 then ends.Add items.Count
    struct (owners.ToArray(), starts.ToArray(), ends.ToArray(), items.ToArray())

// ------------------------------------------------------------ assemble ---------

let private newestFirst (x: Remark) (y: Remark) =
    // DateTime.Compare, not `compare`: F#'s generic comparison boxes structs.
    match DateTime.Compare(y.CreatedAt, x.CreatedAt) with
    | 0 -> compare y.Id x.Id
    | c -> c

/// Pure: every request's answer from what the two phases found.
let private assemble (reads: Read[]) (a: PlanA) (b: PlanB) (found: Found) : Answer[] =
    let following (viewer: ViewerId) (user: int64) =
        viewer <> 0L && found.Following.Contains(struct (viewer, user))
    // One list for every tag request of the batch (a list is 200 nodes).
    let tagNames = lazy (List.ofSeq found.TagNames)
    let cards = Dictionary<int64, Card> b.Cards.Count
    /// An article's card, built once for the batch. Its tags come out in the database's name
    /// order: their positions in the tags table, sorted.
    let card (id: int64) : Card voption =
        match cards.TryGetValue id with
        | true, c -> ValueSome c
        | _ ->
            match found.Rows.TryGetValue id with
            | true, row ->
                match found.Authors.TryGetValue row.AuthorId with
                | true, author ->
                    let c =
                        { Id = id
                          Slug = row.Slug
                          Title = row.Title
                          Description = row.Description
                          Body = row.Body
                          TagList =
                            match found.CardTags.TryGetValue id with
                            | true, ranks ->
                                ranks.Sort()
                                Array.init ranks.Count (fun i -> found.TagNames[ranks[i]])
                            | _ -> Array.empty
                          CreatedAt = row.CreatedAt
                          UpdatedAt = row.UpdatedAt
                          FavoritesCount =
                            match found.FavoritesCounts.TryGetValue id with
                            | true, n -> n
                            | _ -> 0L
                          Author = author }
                    cards[id] <- c
                    ValueSome c
                | _ -> ValueNone
            | _ -> ValueNone
    let article (viewer: ViewerId) (c: Card) : Article =
        { Card = c
          Favorited = viewer <> 0L && found.Favorited.Contains(struct (viewer, c.Id))
          Following = following viewer c.Author.Id }
    Array.init reads.Length (fun i ->
        match reads[i] with
        | ReadTags -> TagNames tagNames.Value
        | ReadPage(viewer, filter, paging) ->
            let struct (l, key, page) = pageOf a filter paging
            Listed
                { Articles =
                    [ for id in found.PageIds[l][page] do
                          match card id with
                          | ValueSome c -> article viewer c
                          | ValueNone -> () ]
                  Count = found.Totals[l][key] }
        | ReadFeed(viewer, _) ->
            Listed
                { Articles =
                    [ for struct (id, _) in b.FeedPages[i] do
                          match card id with
                          | ValueSome c ->
                              { Card = c
                                Favorited = found.Favorited.Contains(struct (viewer, id))
                                Following = true }
                          | ValueNone -> () ]
                  Count = found.FeedTotals[a.FeedViewers.IndexOf viewer] }
        | ReadArticle(viewer, slug) ->
            match found.SlugIds.TryGetValue slug with
            | true, id ->
                match card id with
                | ValueSome c -> Found(Some(article viewer c))
                | ValueNone -> Found None
            | _ -> Found None
        | ReadComments(viewer, slug) ->
            let thread = found.Threads[a.Threads.IndexOf slug]
            if isNull thread then
                Thread None
            else
                Thread(
                    Some
                        [ for c in thread do
                              match found.Authors.TryGetValue c.AuthorId with
                              | true, author ->
                                  { Card =
                                      { Id = c.Id
                                        CreatedAt = c.CreatedAt
                                        UpdatedAt = c.UpdatedAt
                                        Body = c.Body
                                        Author = author }
                                    Following = following viewer c.AuthorId }
                              | _ -> () ]
                )
        | ReadProfile(viewer, username) ->
            match found.Users[a.Usernames.IndexOf username] with
            | ValueSome u ->
                Person(
                    Some
                        { Username = u.Username
                          Bio = u.Bio
                          Image = u.Image
                          Following = following viewer u.Id }
                )
            | ValueNone -> Person None)

// ------------------------------------------------------------- execute ---------

let inline private textOrNone (r: NpgsqlDataReader) (i: int) =
    if r.IsDBNull i then None else Some(r.GetString i)

let private command (sql: string) (parameters: NpgsqlParameter list) =
    let c = NpgsqlBatchCommand sql
    for p in parameters do
        c.Parameters.Add p |> ignore
    c

/// A statement and the code that reads its one result set.
type private Step = NpgsqlBatchCommand * (NpgsqlDataReader -> Task)

let private readRows (each: NpgsqlDataReader -> unit) (r: NpgsqlDataReader) : Task =
    task {
        while! r.ReadAsync() do
            each r
    }

/// One round trip: `prefix`, the steps, `suffix` (BEGIN, COMMIT: statements that return no
/// result set).
let private roundTrip (conn: NpgsqlConnection) (prefix: string list) (steps: Step list) (suffix: string option) : Task =
    task {
        use batch = new NpgsqlBatch(conn)
        for sql in prefix do
            batch.BatchCommands.Add(NpgsqlBatchCommand sql)
        for c, _ in steps do
            batch.BatchCommands.Add c
        suffix |> Option.iter (fun sql -> batch.BatchCommands.Add(NpgsqlBatchCommand sql))
        use! reader = batch.ExecuteReaderAsync()
        let mutable first = true
        for _, read in steps do
            if not first then
                let! more = reader.NextResultAsync()
                if not more then invalidOp "Reads: a statement produced no result set"
            first <- false
            do! read reader
        do! reader.CloseAsync()
    }

/// The card columns of the row the reader is on, from column `at`.
let private rowAt (r: NpgsqlDataReader) (at: int) (body: string option) : Row =
    { Id = r.GetInt64 at
      AuthorId = r.GetInt64(at + 1)
      Slug = r.GetString(at + 2)
      Title = r.GetString(at + 3)
      Description = r.GetString(at + 4)
      CreatedAt = r.GetDateTime(at + 5)
      UpdatedAt = r.GetDateTime(at + 6)
      Body = body }

let private userAt (r: NpgsqlDataReader) : Author =
    { Id = r.GetInt64 0
      Username = r.GetString 1
      Bio = textOrNone r 2
      Image = textOrNone r 3 }

let private stepsA (a: PlanA) (found: Found) : Step list =
    [ if a.Tags then
          command tagsSql [],
          readRows (fun r ->
              found.TagRanks[r.GetInt32 0] <- found.TagNames.Count
              found.TagNames.Add(r.GetString 1))
      for l in 0 .. listings.Length - 1 do
          if a.Pages[l].Count > 0 then
              let pages = a.Pages[l].Items
              command
                  listSqls[l]
                  [ texts "@keys" (a.Keys[l].Items.ToArray())
                    longs "@pkeys" [| for struct (k, _, _) in pages -> int64 k + 1L |]
                    longs "@lims" [| for struct (_, lim, _) in pages -> lim |]
                    longs "@offs" [| for struct (_, _, off) in pages -> off |] ],
              readRows (fun r ->
                  let i = int (r.GetInt64 0) - 1
                  if r.IsDBNull 1 then
                      found.Totals[l][i] <- r.GetInt64 8
                  else
                      let id = r.GetInt64 1
                      let page = found.PageIds[l][i]
                      page.Add id
                      if not (found.Rows.ContainsKey id) then found.Rows[id] <- rowAt r 1 None)
      if a.FeedViewers.Count > 0 then
          command feedSql [ longs "@viewers" (a.FeedViewers.Items.ToArray()); longs "@depths" (a.FeedDepths.ToArray()) ],
          readRows (fun r ->
              let i = int (r.GetInt64 1) - 1
              if r.GetInt32 0 = 0 then
                  found.FeedTotals[i] <- r.GetInt64 4
              else
                  let candidates = found.Feeds[i]
                  candidates.Add(struct (r.GetInt64 2, r.GetInt64 3)))
      if a.Slugs.Count > 0 then
          command slugsSql [ texts "@slugs" (a.Slugs.Items.ToArray()) ],
          // After the lists, so that an article a list also shows keeps the row with the body.
          readRows (fun r ->
              let row = rowAt r 0 (Some(r.GetString 7))
              found.Rows[row.Id] <- row
              found.SlugIds[row.Slug] <- row.Id)
      if a.Threads.Count > 0 then
          command threadsSql [ texts "@threads" (a.Threads.Items.ToArray()) ],
          readRows (fun r ->
              let i = int (r.GetInt64 0) - 1
              if isNull found.Threads[i] then found.Threads[i] <- ResizeArray()
              if not (r.IsDBNull 1) then
                  let thread = found.Threads[i]
                  thread.Add
                      { Id = r.GetInt64 1
                        Body = r.GetString 2
                        CreatedAt = r.GetDateTime 3
                        UpdatedAt = r.GetDateTime 4
                        AuthorId = r.GetInt64 5 })
      if a.Usernames.Count > 0 then
          command usernamesSql [ texts "@usernames" (a.Usernames.Items.ToArray()) ],
          readRows (fun r ->
              let u = userAt r
              let i = a.Usernames.Find u.Username
              if i >= 0 then found.Users[i] <- ValueSome u) ]

/// The count lanes: favorite counts for all the read lanes at once. A favorite count walks the
/// article's index entries (and the heap of pages writes have touched), so it costs by the row,
/// and the popular articles are on the pages of batch after batch. Each count lane runs one
/// statement at a time over the union of the articles of every batch waiting when it starts,
/// each counted once. A run is bound after the batches it answers asked, in its own snapshot,
/// and keeps nothing once they have their counts: a batch of batches, not a cache. (The idea is
/// nish-std-amritk's.)
[<Sealed>]
type [<AllowNullLiteral>] Counts(ds: NpgsqlDataSource, lanes: int) =
    let queue =
        Channel.CreateUnbounded<struct (int64[] * TaskCompletionSource<Dictionary<int64, int64>>)>()
    let totals = [| 0L; 0L; 0L |] // runs, ids asked for, ids counted

    let drain (into: ResizeArray<struct (int64[] * TaskCompletionSource<Dictionary<int64, int64>>)>) =
        let mutable w = Unchecked.defaultof<struct (int64[] * TaskCompletionSource<Dictionary<int64, int64>>)>
        while queue.Reader.TryRead(&w) do
            into.Add w

    let run (conn: NpgsqlConnection) (ids: int64[]) : Task<Dictionary<int64, int64>> =
        task {
            let found = Dictionary<int64, int64>(ids.Length)
            use c = new NpgsqlCommand(favoritesSql.Replace("@ids", "$1"), conn)
            c.Parameters.Add(NpgsqlParameter<int64[]>(NpgsqlDbType = (NpgsqlDbType.Array ||| NpgsqlDbType.Bigint), TypedValue = ids))
            |> ignore
            use! r = c.ExecuteReaderAsync()
            while! r.ReadAsync() do
                found[r.GetInt64 0] <- r.GetInt64 1
            return found
        }

    let lane () : Task =
        task {
            let mutable conn: NpgsqlConnection = null
            let waiting = ResizeArray()
            let union = HashSet<int64>()
            while! queue.Reader.WaitToReadAsync() do
                drain waiting
                if waiting.Count > 0 then
                    try
                        if isNull conn || conn.State <> ConnectionState.Open then
                            if not (isNull conn) then conn.Dispose()
                            conn <- null
                            let! c = ds.OpenConnectionAsync()
                            conn <- c
                        let mutable asked = 0
                        for struct (ids, _) in waiting do
                            asked <- asked + ids.Length
                            for id in ids do
                                union.Add id |> ignore
                        let ids = Array.zeroCreate union.Count
                        union.CopyTo ids
                        let! found = run conn ids
                        Interlocked.Increment(&totals[0]) |> ignore
                        Interlocked.Add(&totals[1], int64 asked) |> ignore
                        Interlocked.Add(&totals[2], int64 ids.Length) |> ignore
                        for struct (_, reply) in waiting do
                            reply.TrySetResult found |> ignore
                    with e ->
                        for struct (_, reply) in waiting do
                            reply.TrySetException e |> ignore
                    waiting.Clear()
                    union.Clear()
        }

    do
        for _ in 1..lanes do
            Task.Run<unit>(fun () -> task { do! lane () }) |> ignore

    /// The favorite counts of `ids` (an article without any has no entry). The dictionary is
    /// shared with the other batches of its run: read it, never write it.
    member _.Of(ids: int64[]) : Task<Dictionary<int64, int64>> =
        let reply = TaskCompletionSource<Dictionary<int64, int64>>(TaskCreationOptions.RunContinuationsAsynchronously)
        if queue.Writer.TryWrite(struct (ids, reply)) then reply.Task
        else Task.FromException<Dictionary<int64, int64>>(InvalidOperationException "Counts: closed")

    /// Runs, ids asked for and ids counted, since the last call.
    member _.Take() : struct (int64 * int64 * int64) =
        struct (Interlocked.Exchange(&totals[0], 0L), Interlocked.Exchange(&totals[1], 0L), Interlocked.Exchange(&totals[2], 0L))

let private stepsB (b: PlanB) (found: Found) (countHere: bool) : Step list =
    [ if b.Meta.Count > 0 then
          command metaSql [ longs "@ids" (b.Meta.Items.ToArray()) ],
          readRows (fun r ->
              let row = rowAt r 0 None
              found.Rows[row.Id] <- row)
      if b.Cards.Count > 0 then
          let ids = b.Cards.Items.ToArray()
          command cardTagsSql [ longs "@ids" ids ],
          readRows (fun r ->
              let article = r.GetInt64 0
              let ranks =
                  match found.CardTags.TryGetValue article with
                  | true, ranks -> ranks
                  | _ ->
                      let ranks = ResizeArray 4
                      found.CardTags[article] <- ranks
                      ranks
              match found.TagRanks.TryGetValue(r.GetInt32 1) with
              | true, rank -> ranks.Add rank
              | _ -> ())
          if countHere then
              command favoritesSql [ longs "@ids" ids ],
              readRows (fun r -> found.FavoritesCounts[r.GetInt64 0] <- r.GetInt64 1)
      if b.Authors.Count > 0 then
          command authorsSql [ longs "@ids" (b.Authors.Items.ToArray()) ],
          readRows (fun r ->
              let u = userAt r
              found.Authors[u.Id] <- u)
      if b.Favorites.Count > 0 || b.Follows.Count > 0 then
          let struct (fv, fs, fe, fa) = slices b.Favorites
          let struct (ov, os, oe, oa) = slices b.Follows
          command
              flagsSql
              [ longs "@fv" fv
                ints "@fs" fs
                ints "@fe" fe
                longs "@fa" fa
                longs "@ov" ov
                ints "@os" os
                ints "@oe" oe
                longs "@oa" oa ],
          readRows (fun r ->
              let pair = struct (r.GetInt64 1, r.GetInt64 2)
              (if r.GetBoolean 0 then found.Following else found.Favorited).Add pair |> ignore) ]

let private beginRead = "BEGIN ISOLATION LEVEL REPEATABLE READ, READ ONLY"

/// One batch, two round trips in one REPEATABLE READ snapshot: both phases see the same
/// database, so an article phase A found is still there in phase B. Read-only, so committing
/// costs nothing, and it takes one snapshot instead of one per statement.
///
/// `times`, if not null, records phase A, the plan between, phase B and the assembly; `laps`,
/// if not null, gets the Stopwatch timestamp at the end of each (0 where the batch had no such
/// step).
let answerWith (conn: NpgsqlConnection) (counts: Counts) (times: Db.Millis[]) (laps: int64[]) (reads: Read[]) : Task<Answer[]> =
    task {
        let at = ref (Diagnostics.Stopwatch.GetTimestamp())
        let lap (i: int) =
            let now = Diagnostics.Stopwatch.GetTimestamp()
            if not (isNull times) then times[i].Record(Diagnostics.Stopwatch.GetElapsedTime(at.Value, now))
            if not (isNull laps) then laps[i] <- now
            at.Value <- now
        let a = planA reads
        let found =
            { TagNames = ResizeArray()
              TagRanks = Dictionary()
              Totals = Array.init listings.Length (fun l -> Array.zeroCreate a.Keys[l].Count)
              PageIds = Array.init listings.Length (fun l -> Array.init a.Pages[l].Count (fun _ -> ResizeArray()))
              Rows = Dictionary()
              SlugIds = Dictionary()
              Threads = Array.zeroCreate a.Threads.Count
              Users = Array.create a.Usernames.Count ValueNone
              FeedTotals = Array.zeroCreate a.FeedViewers.Count
              Feeds = Array.init a.FeedViewers.Count (fun _ -> ResizeArray())
              CardTags = Dictionary()
              FavoritesCounts = Dictionary()
              Authors = Dictionary()
              Favorited = HashSet()
              Following = HashSet() }
        // Only tags or anonymous profiles: phase A is everything, and needs no snapshot of its own.
        let twoPhases =
            reads
            |> Array.exists (function
                | ReadTags -> false
                | ReadProfile(viewer, _) -> viewer <> 0L
                | _ -> true)
        let mutable b = Unchecked.defaultof<PlanB>
        if twoPhases then
            do! roundTrip conn [ beginRead ] (stepsA a found) None
            lap 0
            for pages in found.PageIds do
                for ids in pages do
                    ids.Sort(fun x y -> compare y x)
            for t in found.Threads do
                if not (isNull t) then t.Sort(Comparison newestFirst)
            for candidates in found.Feeds do
                candidates.Sort(Comparison newestPairFirst)
            b <- planB reads a found
            found.CardTags.EnsureCapacity b.Cards.Count |> ignore
            let shared = not (isNull counts) && b.Cards.Count > 0
            // The count lanes work beside phase B, not after it.
            let counting = if shared then counts.Of(b.Cards.Items.ToArray()) else null
            if not shared then found.FavoritesCounts.EnsureCapacity b.Cards.Count |> ignore
            found.Authors.EnsureCapacity b.Authors.Count |> ignore
            lap 1
            do! roundTrip conn [] (stepsB b found (not shared)) (Some "COMMIT")
            if shared then
                let! counted = counting
                found.FavoritesCounts <- counted
            lap 2
        else
            do! roundTrip conn [] (stepsA a found) None
            lap 0
            b <- planB reads a found
        let answers = assemble reads a b found
        lap 3
        return answers
    }

/// One batch on one connection. Public for the batch property test (Tests/BatchTests.fs): a
/// request's answer never depends on its batch-mates.
let answer (conn: NpgsqlConnection) (reads: Read[]) : Task<Answer[]> = answerWith conn null null null reads

// --------------------------------------------------------------- lanes ---------

[<Sealed>]
type private Pending(read: Read) =
    let reply = TaskCompletionSource<Answer>(TaskCreationOptions.RunContinuationsAsynchronously)
    let arrived = Diagnostics.Stopwatch.GetTimestamp()
    let trace = if Db.Millis.Enabled then Db.Trace.Current.Value else null
    member _.Read = read
    member _.Arrived = arrived
    member _.Trace = trace
    member _.Task = reply.Task
    member _.Answer(a: Answer) = reply.TrySetResult a |> ignore
    member _.Fail(e: exn) = reply.TrySetException e |> ignore

let private unexpected (a: Answer) : 'a = invalidOp $"Reads: unexpected answer {a}"

/// The hot reads' side of the process: `lanes` dedicated connections (not multiplexed: a batch
/// holds a snapshot across two round trips), each answering one batch at a time. The lane whose
/// turn it is to gather lets the first request it takes wait up to `gather` for batch-mates (less
/// if `maxBatch` of them arrive sooner): bigger batches share more, and the wait is inside the
/// latency budget.
[<Sealed>]
type Gather(connectionString: string, lanes: int, countLanes: int, maxBatch: int, gather: TimeSpan, shareMin: int, logCapacity: int) =
    let queue =
        // Never SingleReader, even with one lane: a single-reader channel cannot report its length
        // (Depth), which the diagnostics read.
        Channel.CreateUnbounded<Pending>(UnboundedChannelOptions(SingleReader = false, SingleWriter = false))
    let ds = NpgsqlDataSource.Create connectionString
    let shared = if countLanes > 0 then Counts(ds, countLanes) else null
    let counts = [| 0L; 0L |] // batches, requests
    let queued = Db.Millis() // per request: arrived -> taken into a batch
    let executed = Db.Millis() // per batch: taken -> answered
    let answered = Db.Millis() // per request: arrived -> answered
    let phases = Array.init 4 (fun _ -> Db.Millis()) // per batch: phase A, plan B, phase B, assemble
    let busy = [| 0L |] // lanes running a batch
    // The batch log (logCapacity > 0, BATCH_LOG): per batch its lane, size, and the Stopwatch
    // timestamps of taken, phase A, plan, phase B and answered (0: no such step).
    let logged: int64[] = Array.zeroCreate (logCapacity * 7)
    let logNext = [| -1 |]
    let unixAt0 = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() * 1000L
    let ticksAt0 = Diagnostics.Stopwatch.GetTimestamp()
    let worst = [| 0L |] // TimeSpan ticks: the longest arrived -> answered since Worst() last ran
    /// How often a gathering lane takes what has been queued since it last looked.
    let tick = TimeSpan.FromMilliseconds 2.0
    /// One lane gathers at a time, so a batch forms while the other lanes wait their turn.
    let gate = new SemaphoreSlim(1, 1)

    let rec noteWorst (ticks: int64) =
        let seen = Volatile.Read(&worst[0])
        if ticks > seen && Interlocked.CompareExchange(&worst[0], ticks, seen) <> seen then
            noteWorst ticks

    /// How many requests the gathering lane takes: its fair share of what waits, so that a burst
    /// arriving while lanes are idle is spread over them and runs on several backends at once,
    /// instead of one batch running on one backend while the others wait. The share is what waits
    /// (taken + queued) over the idle lanes, this one included, at least `shareMin` and at most
    /// `maxBatch`. With every other lane busy (full speed) it is everything up to `maxBatch`, as
    /// big as a batch gets, since that shares the most work. shareMin = 0 turns it off.
    let share (taken: int) =
        if shareMin <= 0 then
            maxBatch
        else
            let idle = max 1 (lanes - int (Volatile.Read &busy[0]))
            let waiting = taken + queue.Reader.Count
            min maxBatch (max shareMin ((waiting + idle - 1) / idle))

    let take (into: ResizeArray<Pending>) =
        let limit = share into.Count
        let mutable p = Unchecked.defaultof<Pending>
        while into.Count < limit && queue.Reader.TryRead(&p) do
            into.Add p

    let rollback (conn: NpgsqlConnection) : Task =
        task {
            if conn.State = ConnectionState.Open then
                try
                    use c = new NpgsqlCommand("ROLLBACK", conn)
                    let! _ = c.ExecuteNonQueryAsync()
                    ()
                with _ ->
                    ()
        }

    let rec serve (conn: NpgsqlConnection) (laps: int64[]) (batch: Pending[]) : Task =
        task {
            let mutable failure = None
            try
                let! answers = answerWith conn shared phases laps (batch |> Array.map _.Read)
                for i in 0 .. batch.Length - 1 do
                    batch[i].Answer answers[i]
            with e ->
                failure <- Some e
            match failure with
            | None -> ()
            | Some e ->
                do! rollback conn
                match e with
                | :? PostgresException when batch.Length > 1 && conn.State = ConnectionState.Open ->
                    // One request's statement failed and took the batch with it: each request
                    // runs again alone and meets its own fate.
                    for p in batch do
                        do! serve conn null [| p |]
                | e ->
                    for p in batch do
                        p.Fail e
        }

    let lane (index: int) : Task =
        task {
            let mutable conn: NpgsqlConnection = null
            let pending = ResizeArray<Pending>(maxBatch)
            while! queue.Reader.WaitToReadAsync() do
                // Gather: take requests until the oldest has waited `gather`, or a full batch
                // is in hand, whichever comes first. Never TryPeek the queue: a peek stops the
                // ConcurrentQueue under the channel from clearing the slots it dequeues and
                // from reusing its segments, so each dead segment keeps every answer it ever
                // carried alive through gen0 GCs (~400 MB promoted per gen0 at 140k users).
                do! gate.WaitAsync()
                try
                    take pending
                    // (Ticks, not TimeSpan's `>`: F#'s generic comparison boxes structs.)
                    let mutable waiting = gather.Ticks > 0L && pending.Count > 0
                    while waiting && pending.Count < share pending.Count do
                        let left = gather - Diagnostics.Stopwatch.GetElapsedTime pending[0].Arrived
                        if left.Ticks > 0L then
                            do! Task.Delay(if left.Ticks < tick.Ticks then left else tick)
                            take pending
                        else
                            waiting <- false
                finally
                    gate.Release() |> ignore
                if pending.Count > 0 then
                    let batch = pending.ToArray()
                    pending.Clear()
                    let taken = Diagnostics.Stopwatch.GetTimestamp()
                    let laps: int64[] = if logCapacity > 0 then Array.zeroCreate 4 else null
                    Interlocked.Increment(&busy[0]) |> ignore
                    if Db.Millis.Enabled then
                        for p in batch do
                            queued.Record(Diagnostics.Stopwatch.GetElapsedTime(p.Arrived, taken))
                            if not (isNull p.Trace) then p.Trace.ReadQueued <- taken - p.Arrived
                    try
                        if isNull conn || conn.State <> ConnectionState.Open then
                            if not (isNull conn) then conn.Dispose()
                            conn <- null
                            let! c = ds.OpenConnectionAsync()
                            conn <- c
                        do! serve conn laps batch
                    with e ->
                        for p in batch do
                            p.Fail e
                    let finished = Diagnostics.Stopwatch.GetTimestamp()
                    if logCapacity > 0 then
                        let i = Interlocked.Increment &logNext[0]
                        if i < logCapacity then
                            let at = i * 7
                            logged[at] <- int64 index
                            logged[at + 1] <- int64 batch.Length
                            logged[at + 2] <- taken
                            for k in 0..3 do
                                logged[at + 3 + k] <- laps[k]
                    Interlocked.Decrement(&busy[0]) |> ignore
                    if Db.Millis.Enabled then
                        executed.Record(Diagnostics.Stopwatch.GetElapsedTime(taken, finished))
                        for p in batch do
                            answered.Record(Diagnostics.Stopwatch.GetElapsedTime(p.Arrived, finished))
                            if not (isNull p.Trace) then p.Trace.ReadExecuted <- finished - taken
                    // The queue is FIFO, so the batch's first request waited longest.
                    noteWorst (Diagnostics.Stopwatch.GetElapsedTime(batch[0].Arrived, finished)).Ticks
                    Interlocked.Increment(&counts[0]) |> ignore
                    Interlocked.Add(&counts[1], int64 batch.Length) |> ignore
        }

    do
        for i in 0 .. lanes - 1 do
            Task.Run<unit>(fun () -> task { do! lane i }) |> ignore

    /// Queues one read; the task completes when its batch has been answered.
    member _.Run(read: Read) : Task<Answer> =
        let p = Pending read
        if queue.Writer.TryWrite p then p.Task else Task.FromException<Answer>(InvalidOperationException "Reads: closed")

    member this.Tags() : Task<string list> =
        task {
            match! this.Run ReadTags with
            | TagNames names -> return names
            | a -> return unexpected a
        }

    member this.Page(viewer: ViewerId, filter: ArticleFilter, paging: Paging) : Task<ArticlePage> =
        task {
            match! this.Run(ReadPage(viewer, filter, paging)) with
            | Listed page -> return page
            | a -> return unexpected a
        }

    member this.Feed(viewer: ViewerId, paging: Paging) : Task<ArticlePage> =
        task {
            match! this.Run(ReadFeed(viewer, paging)) with
            | Listed page -> return page
            | a -> return unexpected a
        }

    member this.Article(viewer: ViewerId, slug: string) : Task<Article option> =
        task {
            match! this.Run(ReadArticle(viewer, slug)) with
            | Found article -> return article
            | a -> return unexpected a
        }

    member this.Comments(viewer: ViewerId, slug: string) : Task<Comment list option> =
        task {
            match! this.Run(ReadComments(viewer, slug)) with
            | Thread comments -> return comments
            | a -> return unexpected a
        }

    member this.Profile(viewer: ViewerId, username: string) : Task<Profile option> =
        task {
            match! this.Run(ReadProfile(viewer, username)) with
            | Person profile -> return profile
            | a -> return unexpected a
        }

    /// (batches, requests) so far.
    member _.Counts = Volatile.Read(&counts[0]), Volatile.Read(&counts[1])

    /// p50/p95/p99 of: a request's wait for its batch, a batch's execution, a request's whole
    /// time in Reads.
    member _.Timings = queued.Summary(), executed.Summary(), answered.Summary()

    /// p50/p95/p99 per batch of: phase A, the plan between the phases, phase B,
    /// the assembly. (A batch of tags and anonymous profiles has phase A and assembly only.)
    member _.PhaseTimings = phases[0].Summary(), phases[1].Summary(), phases[2].Summary(), phases[3].Summary()

    /// Requests queued and not yet taken into a batch.
    member _.Depth = queue.Reader.Count

    /// The count lanes' runs, ids asked for and ids counted since the last call (zeros without count lanes).
    member _.Counted() : struct (int64 * int64 * int64) =
        if isNull shared then struct (0L, 0L, 0L) else shared.Take()

    /// Lanes running a batch right now.
    member _.Busy = Volatile.Read(&busy[0])

    /// Writes the batch log as CSV (unix microseconds; 0 where a batch had no such step) and
    /// returns how many batches it held.
    member _.WriteLog(path: string) =
        let n = min logCapacity (Volatile.Read &logNext[0] + 1)
        let us (ticks: int64) =
            if ticks = 0L then 0L else unixAt0 + (ticks - ticksAt0) * 1_000_000L / Diagnostics.Stopwatch.Frequency
        use w = new IO.StreamWriter(path)
        w.WriteLine "lane,size,taken_us,phase_a_us,plan_us,phase_b_us,answered_us"
        for i in 0 .. n - 1 do
            let at = i * 7
            w.WriteLine
                $"{logged[at]},{logged[at + 1]},{us logged[at + 2]},{us logged[at + 3]},{us logged[at + 4]},{us logged[at + 5]},{us logged[at + 6]}"
        n

    /// The longest arrived -> answered since the last call, and resets it.
    member _.Worst() = TimeSpan(Interlocked.Exchange(&worst[0], 0L))
