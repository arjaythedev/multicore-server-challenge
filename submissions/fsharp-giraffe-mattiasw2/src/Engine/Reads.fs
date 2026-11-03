module Engine.Reads

// Read batching, the read-side twin of Commit. Every hot read is a value (`Read`) and queues
// here. A reader lane takes everything that queued while its previous batch was in flight, up
// to a cap, and answers the whole batch in two round trips inside ONE read-only snapshot:
//
//   plan     F#: the batch's distinct needs. Forty requests for page 1 of the global feed are
//            one page; an article page and its comments are one slug lookup.
//   phase A  ids: the tag list, one capped count per distinct list key, the ids of each
//            distinct page, slug -> article id, username -> user, and each distinct comment
//            thread (so phase B knows who wrote the comments).
//   phase B  everything shown, once per BATCH, across every kind of request: each distinct
//            article's card (columns, tags, favorite count, author) whether a list or an
//            article page shows it, and the viewers' flags as two sets: (viewer, article)
//            favorited and (viewer, user) following.
//   assemble pure: each request's answer from those maps. Requests that show the same article
//            share one Card object (and Web encodes its JSON once).
//
// The SQL only looks rows up by keys F# has already made distinct (unnest the arrays, one
// LATERAL index probe per key), so there is no dedup work left for Postgres. A lane lets the
// oldest request wait up to the gather window for batch-mates; near saturation the queue already
// holds a full batch, nobody waits, and each request costs less.
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

let private bools (name: string) (values: bool[]) : NpgsqlParameter =
    NpgsqlParameter<bool[]>(name, NpgsqlDbType.Array ||| NpgsqlDbType.Boolean, TypedValue = values)

/// A list's capped counts, one row (r.i, NULL, total) per distinct count key in @ckeys, and its
/// page of ids over the distinct request `r` (r.key, r.lim, r.off, r.depth). Every page is newest
/// first (id DESC).
type private Listing = { Counts: string; Page: string }

/// Counts: `rows` (over the key r.key, LIMIT 1000) counted for each key.
let private capped (rows: string) =
    $"SELECT r.i, NULL::int8 AS id, (SELECT count(*) FROM ({rows}) s) AS total
        FROM unnest(@ckeys::text[]) WITH ORDINALITY AS r(key, i)"

// The global count walks the primary key from the OLDEST end: those pages are all-visible, so
// it is an index-only scan that never touches the heap. count(min(total, 1000)) either way.
let private everything =
    { Counts = capped "SELECT 1 FROM articles a ORDER BY a.id LIMIT 1000"
      Page = "SELECT a.id FROM articles a ORDER BY a.id DESC LIMIT r.lim OFFSET r.off" }

let private byTag =
    { Counts = capped "SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.key) LIMIT 1000"
      Page =
        "SELECT at.article_id AS id FROM article_tags at
          WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.key)
          ORDER BY at.article_id DESC LIMIT r.lim OFFSET r.off" }

let private byAuthor =
    { Counts = capped "SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = r.key) LIMIT 1000"
      Page =
        "SELECT a.id FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = r.key)
          ORDER BY a.id DESC LIMIT r.lim OFFSET r.off" }

let private favoritedBy =
    { Counts = capped "SELECT 1 FROM favorites f WHERE f.user_id = (SELECT u.id FROM users u WHERE u.username = r.key) LIMIT 1000"
      Page =
        "SELECT f.article_id AS id FROM favorites f WHERE f.user_id = (SELECT u.id FROM users u WHERE u.username = r.key)
          ORDER BY f.article_id DESC LIMIT r.lim OFFSET r.off" }

// The feed's key is the viewer. Each followee contributes at most depth = limit + offset of its
// newest articles.
let private feed =
    { Counts =
        // A viewer who follows an author with 1000 or more articles has a feed of 1000 or more.
        // The batch proves that once for each of the 8 followees its viewers share most (heavy),
        // and those viewers get 1000 without a count. The rest are counted as before.
        "WITH fv AS MATERIALIZED (
              SELECT r.i, ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.key::int8) AS fids
                FROM unnest(@ckeys::text[]) WITH ORDINALITY AS r(key, i)),
            shared AS MATERIALIZED (
              SELECT x.id FROM fv CROSS JOIN LATERAL unnest(fv.fids) AS x(id)
               GROUP BY x.id HAVING count(*) >= 2 ORDER BY count(*) DESC LIMIT 8),
            heavy AS MATERIALIZED (
              SELECT coalesce(array_agg(s.id), '{}') AS ids FROM shared s
               WHERE EXISTS (SELECT 1 FROM articles a WHERE a.author_id = s.id OFFSET 999))
          SELECT fv.i, NULL::int8 AS id,
                 CASE WHEN fv.fids && (SELECT h.ids FROM heavy h) THEN 1000::int8
                      ELSE (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = ANY (fv.fids) LIMIT 1000) s)
                 END AS total
            FROM fv"
      Page =
        "SELECT x.id FROM follows fo CROSS JOIN LATERAL
                (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT r.depth) x
          WHERE fo.follower_id = r.key::int8 ORDER BY x.id DESC LIMIT r.lim OFFSET r.off" }

/// Indexed by `listingOf`.
let private listings = [| everything; byTag; byAuthor; favoritedBy; feed |]

/// A list request's listing and key.
let private listingOf (read: Read) : struct (int * string) =
    match read with
    | ReadPage(_, Everything, _) -> 0, ""
    | ReadPage(_, ByTag tag, _) -> 1, tag
    | ReadPage(_, ByAuthor name, _) -> 2, name
    | ReadPage(_, FavoritedBy name, _) -> 3, name
    | ReadFeed(viewer, _) -> 4, string viewer
    | _ -> invalidArg "read" "not a list"

/// Phase A, per listing: count rows (i = the count key's position, total set) and page rows (i =
/// the page's position, id set).
let private listSql (l: Listing) =
    $"{l.Counts}
      UNION ALL
      SELECT r.i, x.id, NULL::int8
        FROM unnest(@pkeys::text[], @lims::int8[], @offs::int8[], @depths::int8[]) WITH ORDINALITY AS r(key, lim, off, depth, i)
       CROSS JOIN LATERAL ({l.Page}) x"

let private listSqls = listings |> Array.map listSql

let private tagsSql = "SELECT name FROM tags ORDER BY name"

// Every lookup by a key is CROSS JOIN LATERAL (... LIMIT 1): one index probe per key. With a
// plain join the planner, which cannot see how few keys there are, may hash-join whole tables;
// the LIMIT 1 (the keys are unique, so it changes nothing) keeps it from flattening the LATERAL
// back into that join.

let private slugsSql =
    "SELECT r.i, x.id FROM unnest(@slugs::text[]) WITH ORDINALITY AS r(slug, i)
      CROSS JOIN LATERAL (SELECT a.id FROM articles a WHERE a.slug = r.slug LIMIT 1) x"

let private usersSql =
    "SELECT r.i, x.id, x.username, x.bio, x.image FROM unnest(@usernames::text[]) WITH ORDINALITY AS r(username, i)
      CROSS JOIN LATERAL (SELECT u.id, u.username, u.bio, u.image FROM users u WHERE u.username = r.username LIMIT 1) x"

/// Phase B: each distinct article's card; the body only where an article page shows it.
/// Each tag name is one tags_pkey probe: as a JOIN the planner hash-joins the whole tags table
/// once per card, which was over half of this statement's time.
let private cardsSql =
    "SELECT x.* FROM unnest(@ids::int8[], @bodies::bool[]) AS r(id, body)
      CROSS JOIN LATERAL (
            SELECT a.id, CASE WHEN r.body THEN a.body END AS body, a.slug, a.title, a.description, a.created_at, a.updated_at,
                   ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at
                          WHERE at.article_id = a.id ORDER BY 1) AS tag_list,
                   (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
                   a.author_id, u.username, u.bio, u.image
              FROM articles a JOIN users u ON u.id = a.author_id
             WHERE a.id = r.id LIMIT 1) x"

/// Phase A: the newest 100 comments of each distinct slug a comments page shows (F# puts them in
/// order), so phase B already knows who wrote them. An article without comments has no rows.
let private threadsSql =
    "SELECT a.id, c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image
       FROM unnest(@threads::text[]) AS r(slug)
      CROSS JOIN LATERAL (SELECT a.id FROM articles a WHERE a.slug = r.slug LIMIT 1) a
      CROSS JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id
                            FROM comments c WHERE c.article_id = a.id
                           ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c
      CROSS JOIN LATERAL (SELECT u.username, u.bio, u.image FROM users u WHERE u.id = c.author_id LIMIT 1) u"

/// Phase B: the viewers' flags that are set. Favorited for the (viewer, article) pairs shown;
/// following for the authors of those articles (each article's author looked up once, not once
/// per viewer) and for the (viewer, user) pairs F# already knows: profiles and comment authors.
/// Each viewer's pairs are one index range scan with = ANY, not one probe per pair.
/// Rows: following?, viewer, article or user.
let private flagsSql =
    "WITH p AS MATERIALIZED (SELECT q.v, q.a FROM unnest(@av::int8[], @aa::int8[]) AS q(v, a)),
          au AS MATERIALIZED (
            SELECT d.a, x.author_id FROM (SELECT DISTINCT p.a FROM p) d
             CROSS JOIN LATERAL (SELECT ar.author_id FROM articles ar WHERE ar.id = d.a LIMIT 1) x),
          fav AS (SELECT p.v, array_agg(p.a) AS ids FROM p GROUP BY p.v),
          fol AS (SELECT s.v, array_agg(DISTINCT s.u) AS ids
                    FROM (SELECT p.v, au.author_id AS u FROM p JOIN au ON au.a = p.a
                          UNION ALL
                          SELECT q.v, q.u FROM unnest(@uv::int8[], @uu::int8[]) AS q(v, u)) s
                   GROUP BY s.v)
     SELECT false, fav.v, f.article_id FROM fav
      CROSS JOIN LATERAL (SELECT f.article_id FROM favorites f WHERE f.user_id = fav.v AND f.article_id = ANY (fav.ids)) f
     UNION ALL
     SELECT true, fol.v, fo.followee_id FROM fol
      CROSS JOIN LATERAL (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = fol.v AND fo.followee_id = ANY (fol.ids)) fo"

// ---------------------------------------------------------------- plan ---------

/// Distinct keys in first-seen order, each with its position.
[<Sealed>]
type private Distinct<'k when 'k: equality>() =
    let index = Dictionary<'k, int>()
    let items = ResizeArray<'k>()

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

/// Saturating, so a huge offset cannot overflow the feed's LIMIT.
let private depthOf (p: Paging) =
    if p.Offset > Int64.MaxValue - p.Limit then Int64.MaxValue else p.Limit + p.Offset

/// What phase A must find.
[<NoEquality; NoComparison>]
type private PlanA =
    { Tags: bool
      Counts: Distinct<string>[]
      Pages: Distinct<struct (string * int64 * int64 * int64)>[]
      Slugs: Distinct<string>
      Threads: Distinct<string>
      Usernames: Distinct<string> }

let private pageKey (read: Read) (paging: Paging) =
    let struct (l, key) = listingOf read
    struct (l, key, struct (key, paging.Limit, paging.Offset, depthOf paging))

let private planA (reads: Read[]) : PlanA =
    let plan =
        { Tags =
            reads
            |> Array.exists (function
                | ReadTags -> true
                | _ -> false)
          Counts = Array.init listings.Length (fun _ -> Distinct())
          Pages = Array.init listings.Length (fun _ -> Distinct())
          Slugs = Distinct()
          Threads = Distinct()
          Usernames = Distinct() }
    for read in reads do
        match read with
        | ReadTags -> ()
        | ReadPage(_, _, paging)
        | ReadFeed(_, paging) ->
            let struct (l, key, page) = pageKey read paging
            plan.Counts[l].Add key |> ignore
            plan.Pages[l].Add page |> ignore
        | ReadArticle(_, slug) -> plan.Slugs.Add slug |> ignore
        | ReadComments(_, slug) ->
            plan.Slugs.Add slug |> ignore
            plan.Threads.Add slug |> ignore
        | ReadProfile(_, username) -> plan.Usernames.Add username |> ignore
    plan

/// What phase A found.
[<NoEquality; NoComparison>]
type private FoundA =
    { mutable TagNames: string list
      Totals: int64[][]
      PageIds: ResizeArray<int64>[][]
      SlugIds: int64 voption[]
      /// Article id -> its newest comments (newest first once phase A is sorted).
      Threads: Dictionary<int64, ResizeArray<CommentCard>>
      Users: Author voption[] }

/// What phase B must fetch.
[<NoEquality; NoComparison>]
type private PlanB =
    { Cards: Distinct<int64>
      Bodies: ResizeArray<bool>
      ArticlePairs: Distinct<struct (int64 * int64)>
      UserPairs: Distinct<struct (int64 * int64)> }

/// (No user has id 0, so an anonymous viewer's flags are all false and need no pairs.)
let private planB (reads: Read[]) (a: PlanA) (found: FoundA) : PlanB =
    let plan =
        { Cards = Distinct()
          Bodies = ResizeArray()
          ArticlePairs = Distinct()
          UserPairs = Distinct() }
    let card (viewer: ViewerId) (id: int64) (body: bool) =
        let i = plan.Cards.Add id
        if i = plan.Bodies.Count then plan.Bodies.Add body
        elif body then plan.Bodies[i] <- true
        if viewer <> 0L then plan.ArticlePairs.Add(struct (viewer, id)) |> ignore
    for read in reads do
        match read with
        | ReadTags -> ()
        | ReadPage(viewer, _, paging)
        | ReadFeed(viewer, paging) ->
            let struct (l, _, page) = pageKey read paging
            for id in found.PageIds[l][a.Pages[l].IndexOf page] do
                card viewer id false
        | ReadArticle(viewer, slug) ->
            match found.SlugIds[a.Slugs.IndexOf slug] with
            | ValueSome id -> card viewer id true
            | ValueNone -> ()
        | ReadComments(viewer, slug) ->
            match found.SlugIds[a.Slugs.IndexOf slug] with
            | ValueSome id when viewer <> 0L ->
                match found.Threads.TryGetValue id with
                | true, thread ->
                    for c in thread do
                        plan.UserPairs.Add(struct (viewer, c.Author.Id)) |> ignore
                | _ -> ()
            | _ -> ()
        | ReadProfile(viewer, username) ->
            match found.Users[a.Usernames.IndexOf username] with
            | ValueSome u when viewer <> 0L -> plan.UserPairs.Add(struct (viewer, u.Id)) |> ignore
            | _ -> ()
    plan

/// What phase B found.
[<NoEquality; NoComparison>]
type private FoundB =
    { Cards: Dictionary<int64, Card>
      Favorited: HashSet<struct (int64 * int64)>
      Following: HashSet<struct (int64 * int64)> }

// ------------------------------------------------------------ assemble ---------

let private newestFirst (x: CommentCard) (y: CommentCard) =
    // DateTime.Compare, not `compare`: F#'s generic comparison boxes structs.
    match DateTime.Compare(y.CreatedAt, x.CreatedAt) with
    | 0 -> compare y.Id x.Id
    | c -> c

/// Pure: every request's answer from what the two phases found.
let private assemble (reads: Read[]) (a: PlanA) (foundA: FoundA) (foundB: FoundB) : Answer[] =
    let following (viewer: ViewerId) (user: int64) =
        viewer <> 0L && foundB.Following.Contains(struct (viewer, user))
    let article (viewer: ViewerId) (card: Card) : Article =
        { Card = card
          Favorited = viewer <> 0L && foundB.Favorited.Contains(struct (viewer, card.Id))
          Following = following viewer card.Author.Id }
    let card (id: int64) =
        match foundB.Cards.TryGetValue id with
        | true, c -> ValueSome c
        | _ -> ValueNone
    reads
    |> Array.map (fun read ->
        match read with
        | ReadTags -> TagNames foundA.TagNames
        | ReadPage(viewer, _, paging)
        | ReadFeed(viewer, paging) ->
            let struct (l, key, page) = pageKey read paging
            Listed
                { Articles =
                    [ for id in foundA.PageIds[l][a.Pages[l].IndexOf page] do
                          match card id with
                          | ValueSome c -> article viewer c
                          | ValueNone -> () ]
                  Count = foundA.Totals[l][a.Counts[l].IndexOf key] }
        | ReadArticle(viewer, slug) ->
            match foundA.SlugIds[a.Slugs.IndexOf slug] |> ValueOption.bind card with
            | ValueSome c -> Found(Some(article viewer c))
            | ValueNone -> Found None
        | ReadComments(viewer, slug) ->
            match foundA.SlugIds[a.Slugs.IndexOf slug] with
            | ValueNone -> Thread None
            | ValueSome id ->
                let cards =
                    match foundA.Threads.TryGetValue id with
                    | true, t -> List.ofSeq t
                    | _ -> []
                Thread(Some [ for c in cards -> { Card = c; Following = following viewer c.Author.Id } ])
        | ReadProfile(viewer, username) ->
            match foundA.Users[a.Usernames.IndexOf username] with
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

/// One round trip: `prefix`, the steps, `suffix` (BEGIN / COMMIT, which return no result set).
let private roundTrip (conn: NpgsqlConnection) (prefix: string option) (steps: Step list) (suffix: string option) : Task =
    task {
        use batch = new NpgsqlBatch(conn)
        prefix |> Option.iter (fun sql -> batch.BatchCommands.Add(NpgsqlBatchCommand sql))
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

let private stepsA (a: PlanA) (found: FoundA) : Step list =
    [ if a.Tags then
          command tagsSql [], readRows (fun r -> found.TagNames <- r.GetString 0 :: found.TagNames)
      for l in 0 .. listings.Length - 1 do
          if a.Pages[l].Count > 0 then
              let pages = a.Pages[l].Items
              command
                  listSqls[l]
                  [ texts "@ckeys" (a.Counts[l].Items.ToArray())
                    texts "@pkeys" [| for struct (k, _, _, _) in pages -> k |]
                    longs "@lims" [| for struct (_, lim, _, _) in pages -> lim |]
                    longs "@offs" [| for struct (_, _, off, _) in pages -> off |]
                    longs "@depths" [| for struct (_, _, _, depth) in pages -> depth |] ],
              readRows (fun r ->
                  let i = int (r.GetInt64 0) - 1
                  if r.IsDBNull 1 then
                      found.Totals[l][i] <- r.GetInt64 2
                  else
                      let ids = found.PageIds[l][i]
                      ids.Add(r.GetInt64 1))
      if a.Slugs.Count > 0 then
          command slugsSql [ texts "@slugs" (a.Slugs.Items.ToArray()) ],
          readRows (fun r -> found.SlugIds[int (r.GetInt64 0) - 1] <- ValueSome(r.GetInt64 1))
      if a.Threads.Count > 0 then
          command threadsSql [ texts "@threads" (a.Threads.Items.ToArray()) ],
          readRows (fun r ->
              let article = r.GetInt64 0
              let thread =
                  match found.Threads.TryGetValue article with
                  | true, t -> t
                  | _ ->
                      let t = ResizeArray()
                      found.Threads[article] <- t
                      t
              thread.Add
                  { Id = r.GetInt64 1
                    Body = r.GetString 2
                    CreatedAt = r.GetDateTime 3
                    UpdatedAt = r.GetDateTime 4
                    Author =
                      { Id = r.GetInt64 5
                        Username = r.GetString 6
                        Bio = textOrNone r 7
                        Image = textOrNone r 8 } })
      if a.Usernames.Count > 0 then
          command usersSql [ texts "@usernames" (a.Usernames.Items.ToArray()) ],
          readRows (fun r ->
              found.Users[int (r.GetInt64 0) - 1] <-
                  ValueSome
                      { Id = r.GetInt64 1
                        Username = r.GetString 2
                        Bio = textOrNone r 3
                        Image = textOrNone r 4 }) ]

let private stepsB (b: PlanB) (found: FoundB) : Step list =
    let firsts (pairs: Distinct<struct (int64 * int64)>) = [| for struct (x, _) in pairs.Items -> x |]
    let seconds (pairs: Distinct<struct (int64 * int64)>) = [| for struct (_, y) in pairs.Items -> y |]
    [ if b.Cards.Count > 0 then
          command cardsSql [ longs "@ids" (b.Cards.Items.ToArray()); bools "@bodies" (b.Bodies.ToArray()) ],
          readRows (fun r ->
              let id = r.GetInt64 0
              found.Cards[id] <-
                  { Id = id
                    Body = textOrNone r 1
                    Slug = r.GetString 2
                    Title = r.GetString 3
                    Description = r.GetString 4
                    CreatedAt = r.GetDateTime 5
                    UpdatedAt = r.GetDateTime 6
                    TagList = r.GetFieldValue<string[]> 7
                    FavoritesCount = r.GetInt64 8
                    Author =
                      { Id = r.GetInt64 9
                        Username = r.GetString 10
                        Bio = textOrNone r 11
                        Image = textOrNone r 12 } })
      if b.ArticlePairs.Count > 0 || b.UserPairs.Count > 0 then
          command
              flagsSql
              [ longs "@av" (firsts b.ArticlePairs)
                longs "@aa" (seconds b.ArticlePairs)
                longs "@uv" (firsts b.UserPairs)
                longs "@uu" (seconds b.UserPairs) ],
          readRows (fun r ->
              let pair = struct (r.GetInt64 1, r.GetInt64 2)
              (if r.GetBoolean 0 then found.Following else found.Favorited).Add pair |> ignore) ]

/// One batch, two round trips in one REPEATABLE READ snapshot: both phases see the same
/// database, so an article phase A found is still there in phase B. Read-only, so committing
/// costs nothing, and it takes one snapshot instead of one per statement. Public for the batch
/// property test (Tests/BatchTests.fs): a request's answer never depends on its batch-mates.
let answer (conn: NpgsqlConnection) (reads: Read[]) : Task<Answer[]> =
    task {
        let a = planA reads
        let foundA =
            { TagNames = []
              Totals = Array.init listings.Length (fun l -> Array.zeroCreate a.Counts[l].Count)
              PageIds = Array.init listings.Length (fun l -> Array.init a.Pages[l].Count (fun _ -> ResizeArray()))
              SlugIds = Array.create a.Slugs.Count ValueNone
              Threads = Dictionary()
              Users = Array.create a.Usernames.Count ValueNone }
        let foundB =
            { Cards = Dictionary()
              Favorited = HashSet()
              Following = HashSet() }
        // Only tags or anonymous profiles: phase A is everything, and needs no snapshot of its own.
        let twoPhases =
            reads
            |> Array.exists (function
                | ReadTags -> false
                | ReadProfile(viewer, _) -> viewer <> 0L
                | _ -> true)
        if twoPhases then
            do! roundTrip conn (Some "BEGIN ISOLATION LEVEL REPEATABLE READ, READ ONLY") (stepsA a foundA) None
            for pages in foundA.PageIds do
                for ids in pages do
                    ids.Sort(fun x y -> compare y x)
            for t in foundA.Threads.Values do
                t.Sort(Comparison newestFirst)
            let b = planB reads a foundA
            do! roundTrip conn None (stepsB b foundB) (Some "COMMIT")
        else
            do! roundTrip conn None (stepsA a foundA) None
        foundA.TagNames <- List.rev foundA.TagNames
        return assemble reads a foundA foundB
    }

// --------------------------------------------------------------- lanes ---------

[<Sealed>]
type private Pending(read: Read) =
    let reply = TaskCompletionSource<Answer>(TaskCreationOptions.RunContinuationsAsynchronously)
    let arrived = Diagnostics.Stopwatch.GetTimestamp()
    member _.Read = read
    member _.Arrived = arrived
    member _.Task = reply.Task
    member _.Answer(a: Answer) = reply.TrySetResult a |> ignore
    member _.Fail(e: exn) = reply.TrySetException e |> ignore

let private unexpected (a: Answer) : 'a = invalidOp $"Reads: unexpected answer {a}"

/// Durations in 1 ms buckets (the last bucket holds everything from 2 s up), for the shutdown
/// line: cheap enough to record every request.
[<Sealed>]
type private Millis() =
    let buckets: int64[] = Array.zeroCreate 2001

    member _.Record(elapsed: TimeSpan) =
        let ms = int elapsed.TotalMilliseconds
        Interlocked.Increment(&buckets[if ms < 0 then 0 elif ms > 2000 then 2000 else ms]) |> ignore

    /// "p50/p95/p99 ms", or "-" before anything was recorded.
    member _.Summary() =
        let counts = Array.copy buckets
        let total = Array.sum counts
        if total = 0L then
            "-"
        else
            let at (q: float) =
                let target = int64 (Math.Ceiling(q * float total))
                let mutable seen = 0L
                let mutable i = 0
                while seen + counts[i] < target do
                    seen <- seen + counts[i]
                    i <- i + 1
                i
            $"{at 0.5}/{at 0.95}/{at 0.99} ms"

/// The hot reads' side of the process: `lanes` dedicated connections (not multiplexed: a batch
/// holds a snapshot across two round trips), each answering one batch at a time. The lane whose
/// turn it is to gather lets the first request it takes wait up to `gather` for batch-mates (less
/// if `maxBatch` of them arrive sooner): bigger batches share more, and the wait is inside the
/// latency budget.
[<Sealed>]
type Gather(connectionString: string, lanes: int, maxBatch: int, gather: TimeSpan) =
    let queue =
        Channel.CreateUnbounded<Pending>(UnboundedChannelOptions(SingleReader = (lanes = 1), SingleWriter = false))
    let ds = NpgsqlDataSource.Create connectionString
    let counts = [| 0L; 0L |] // batches, requests
    let queued = Millis() // per request: arrived -> taken into a batch
    let executed = Millis() // per batch: taken -> answered
    let answered = Millis() // per request: arrived -> answered
    let busy = [| 0L |] // lanes running a batch
    let worst = [| 0L |] // TimeSpan ticks: the longest arrived -> answered since Worst() last ran
    /// How often a gathering lane takes what has been queued since it last looked.
    let tick = TimeSpan.FromMilliseconds 2.0
    /// One lane gathers at a time, so a batch forms while the other lanes wait their turn.
    let gate = new SemaphoreSlim(1, 1)

    let rec noteWorst (ticks: int64) =
        let seen = Volatile.Read(&worst[0])
        if ticks > seen && Interlocked.CompareExchange(&worst[0], ticks, seen) <> seen then
            noteWorst ticks

    let take (into: ResizeArray<Pending>) =
        let mutable p = Unchecked.defaultof<Pending>
        while into.Count < maxBatch && queue.Reader.TryRead(&p) do
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

    let rec serve (conn: NpgsqlConnection) (batch: Pending[]) : Task =
        task {
            let mutable failure = None
            try
                let! answers = answer conn (batch |> Array.map _.Read)
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
                        do! serve conn [| p |]
                | e ->
                    for p in batch do
                        p.Fail e
        }

    let lane () : Task =
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
                    while waiting && pending.Count < maxBatch do
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
                    Interlocked.Increment(&busy[0]) |> ignore
                    for p in batch do
                        queued.Record(Diagnostics.Stopwatch.GetElapsedTime(p.Arrived, taken))
                    try
                        if isNull conn || conn.State <> ConnectionState.Open then
                            if not (isNull conn) then conn.Dispose()
                            conn <- null
                            let! c = ds.OpenConnectionAsync()
                            conn <- c
                        do! serve conn batch
                    with e ->
                        for p in batch do
                            p.Fail e
                    let finished = Diagnostics.Stopwatch.GetTimestamp()
                    Interlocked.Decrement(&busy[0]) |> ignore
                    executed.Record(Diagnostics.Stopwatch.GetElapsedTime(taken, finished))
                    for p in batch do
                        answered.Record(Diagnostics.Stopwatch.GetElapsedTime(p.Arrived, finished))
                    // The queue is FIFO, so the batch's first request waited longest.
                    noteWorst (Diagnostics.Stopwatch.GetElapsedTime(batch[0].Arrived, finished)).Ticks
                    Interlocked.Increment(&counts[0]) |> ignore
                    Interlocked.Add(&counts[1], int64 batch.Length) |> ignore
        }

    do
        for _ in 1..lanes do
            Task.Run<unit>(fun () -> task { do! lane () }) |> ignore

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

    /// Requests queued and not yet taken into a batch.
    member _.Depth = queue.Reader.Count

    /// Lanes running a batch right now.
    member _.Busy = Volatile.Read(&busy[0])

    /// The longest arrived -> answered since the last call, and resets it.
    member _.Worst() = TimeSpan(Interlocked.Exchange(&worst[0], 0L))
