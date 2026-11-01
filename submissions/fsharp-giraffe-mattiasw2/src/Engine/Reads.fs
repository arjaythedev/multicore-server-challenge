module Engine.Reads

// Read batching, the read-side twin of Commit. Every hot read is a value (`Read`) and queues
// here. A reader lane takes everything that queued while its previous batch was in flight, up
// to a cap, and answers the whole batch in two round trips inside ONE read-only snapshot:
//
//   plan     F#: the batch's distinct needs. Forty requests for page 1 of the global feed are
//            one page; an article page and its comments are one slug lookup.
//   phase A  ids: the tag list, one capped count per distinct list key, the ids of each
//            distinct page, slug -> article id, username -> user.
//   phase B  everything shown, once per BATCH, across every kind of request: each distinct
//            article's card (columns, tags, favorite count, author) whether a list or an
//            article page shows it, each distinct comment thread, and the viewers' flags as two
//            sets: (viewer, article) favorited and (viewer, user) following.
//   assemble pure: each request's answer from those maps. Requests that show the same article
//            share one Card object (and Web encodes its JSON once).
//
// The SQL only looks rows up by keys F# has already made distinct (unnest the arrays, one
// LATERAL index probe per key), so there is no dedup work left for Postgres. No timer: with no
// load a batch is one request; near saturation the batches grow and each request costs less.
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

/// A list's capped count and its page of ids, over the distinct request `r` (r.key, and for the
/// page r.lim, r.off, r.depth). Every page is newest first (id DESC).
type private Listing = { Count: string; Page: string }

// The global count walks the primary key from the OLDEST end: those pages are all-visible, so
// it is an index-only scan that never touches the heap. count(min(total, 1000)) either way.
let private everything =
    { Count = "SELECT 1 FROM articles a ORDER BY a.id LIMIT 1000"
      Page = "SELECT a.id FROM articles a ORDER BY a.id DESC LIMIT r.lim OFFSET r.off" }

let private byTag =
    { Count = "SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.key) LIMIT 1000"
      Page =
        "SELECT at.article_id AS id FROM article_tags at
          WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.key)
          ORDER BY at.article_id DESC LIMIT r.lim OFFSET r.off" }

let private byAuthor =
    { Count = "SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = r.key) LIMIT 1000"
      Page =
        "SELECT a.id FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = r.key)
          ORDER BY a.id DESC LIMIT r.lim OFFSET r.off" }

let private favoritedBy =
    { Count = "SELECT 1 FROM favorites f WHERE f.user_id = (SELECT u.id FROM users u WHERE u.username = r.key) LIMIT 1000"
      Page =
        "SELECT f.article_id AS id FROM favorites f WHERE f.user_id = (SELECT u.id FROM users u WHERE u.username = r.key)
          ORDER BY f.article_id DESC LIMIT r.lim OFFSET r.off" }

// The feed's key is the viewer. Each followee contributes at most depth = limit + offset of its
// newest articles.
let private feed =
    { Count =
        "SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.key::int8)
          LIMIT 1000"
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
    $"SELECT r.i, NULL::int8 AS id, (SELECT count(*) FROM ({l.Count}) s) AS total
        FROM unnest(@ckeys::text[]) WITH ORDINALITY AS r(key, i)
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
let private cardsSql =
    "SELECT x.* FROM unnest(@ids::int8[], @bodies::bool[]) AS r(id, body)
      CROSS JOIN LATERAL (
            SELECT a.id, CASE WHEN r.body THEN a.body END AS body, a.slug, a.title, a.description, a.created_at, a.updated_at,
                   ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
                          WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
                   (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
                   a.author_id, u.username, u.bio, u.image
              FROM articles a JOIN users u ON u.id = a.author_id
             WHERE a.id = r.id LIMIT 1) x"

/// Phase B: each distinct article's newest 100 comments (F# puts them in order).
let private threadsSql =
    "SELECT c.article_id, c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image
       FROM unnest(@articles::int8[]) AS r(article_id)
      CROSS JOIN LATERAL (SELECT c.article_id, c.id, c.body, c.created_at, c.updated_at, c.author_id
                            FROM comments c WHERE c.article_id = r.article_id
                           ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c
      CROSS JOIN LATERAL (SELECT u.username, u.bio, u.image FROM users u WHERE u.id = c.author_id LIMIT 1) u"

/// Phase B: the (viewer, article) pairs shown, and only those where a flag is set: does the
/// viewer favorite the article, and follow its author?
let private articleFlagsSql =
    "SELECT * FROM (
        SELECT r.v, r.a, x.author_id,
               EXISTS (SELECT 1 FROM favorites f WHERE f.user_id = r.v AND f.article_id = r.a) AS favorited,
               EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = x.author_id) AS following
          FROM unnest(@av::int8[], @aa::int8[]) AS r(v, a)
         CROSS JOIN LATERAL (SELECT a.author_id FROM articles a WHERE a.id = r.a LIMIT 1) x) s
      WHERE favorited OR following"

/// Phase B: (viewer, user) follows among the authors of the comment threads shown, and the
/// profiles shown.
let private followsSql =
    "SELECT r.v, x.author_id AS u FROM unnest(@cv::int8[], @ca::int8[]) AS r(v, a)
      CROSS JOIN LATERAL (SELECT DISTINCT t.author_id FROM (SELECT c.author_id FROM comments c WHERE c.article_id = r.a
                                                            ORDER BY c.created_at DESC, c.id DESC LIMIT 100) t) x
      WHERE EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = x.author_id)
     UNION ALL
     SELECT r.v, r.u FROM unnest(@uv::int8[], @uu::int8[]) AS r(v, u)
      WHERE EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = r.u)"

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
          Usernames = Distinct() }
    for read in reads do
        match read with
        | ReadTags -> ()
        | ReadPage(_, _, paging)
        | ReadFeed(_, paging) ->
            let struct (l, key, page) = pageKey read paging
            plan.Counts[l].Add key |> ignore
            plan.Pages[l].Add page |> ignore
        | ReadArticle(_, slug)
        | ReadComments(_, slug) -> plan.Slugs.Add slug |> ignore
        | ReadProfile(_, username) -> plan.Usernames.Add username |> ignore
    plan

/// What phase A found.
[<NoEquality; NoComparison>]
type private FoundA =
    { mutable TagNames: string list
      Totals: int64[][]
      PageIds: ResizeArray<int64>[][]
      SlugIds: int64 voption[]
      Users: Author voption[] }

/// What phase B must fetch.
[<NoEquality; NoComparison>]
type private PlanB =
    { Cards: Distinct<int64>
      Bodies: ResizeArray<bool>
      Threads: Distinct<int64>
      ArticlePairs: Distinct<struct (int64 * int64)>
      CommentPairs: Distinct<struct (int64 * int64)>
      UserPairs: Distinct<struct (int64 * int64)> }

/// (No user has id 0, so an anonymous viewer's flags are all false and need no pairs.)
let private planB (reads: Read[]) (a: PlanA) (found: FoundA) : PlanB =
    let plan =
        { Cards = Distinct()
          Bodies = ResizeArray()
          Threads = Distinct()
          ArticlePairs = Distinct()
          CommentPairs = Distinct()
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
            | ValueSome id ->
                plan.Threads.Add id |> ignore
                if viewer <> 0L then plan.CommentPairs.Add(struct (viewer, id)) |> ignore
            | ValueNone -> ()
        | ReadProfile(viewer, username) ->
            match found.Users[a.Usernames.IndexOf username] with
            | ValueSome u when viewer <> 0L -> plan.UserPairs.Add(struct (viewer, u.Id)) |> ignore
            | _ -> ()
    plan

/// What phase B found.
[<NoEquality; NoComparison>]
type private FoundB =
    { Cards: Dictionary<int64, Card>
      Threads: Dictionary<int64, ResizeArray<CommentCard>>
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
                    match foundB.Threads.TryGetValue id with
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
      if b.Threads.Count > 0 then
          command threadsSql [ longs "@articles" (b.Threads.Items.ToArray()) ],
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
      if b.ArticlePairs.Count > 0 then
          command articleFlagsSql [ longs "@av" (firsts b.ArticlePairs); longs "@aa" (seconds b.ArticlePairs) ],
          readRows (fun r ->
              let viewer = r.GetInt64 0
              if r.GetBoolean 3 then found.Favorited.Add(struct (viewer, r.GetInt64 1)) |> ignore
              if r.GetBoolean 4 then found.Following.Add(struct (viewer, r.GetInt64 2)) |> ignore)
      if b.CommentPairs.Count > 0 || b.UserPairs.Count > 0 then
          command
              followsSql
              [ longs "@cv" (firsts b.CommentPairs)
                longs "@ca" (seconds b.CommentPairs)
                longs "@uv" (firsts b.UserPairs)
                longs "@uu" (seconds b.UserPairs) ],
          readRows (fun r -> found.Following.Add(struct (r.GetInt64 0, r.GetInt64 1)) |> ignore) ]

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
              Users = Array.create a.Usernames.Count ValueNone }
        let foundB =
            { Cards = Dictionary()
              Threads = Dictionary()
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
            let b = planB reads a foundA
            do! roundTrip conn None (stepsB b foundB) (Some "COMMIT")
            for t in foundB.Threads.Values do
                t.Sort(Comparison newestFirst)
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

/// The hot reads' side of the process: `lanes` dedicated connections (not multiplexed: a batch
/// holds a snapshot across two round trips), each answering one batch at a time. A lane that
/// wakes for a request first lets it wait up to `gather` for batch-mates (less if `maxBatch` of
/// them are already queued): bigger batches share more, and the wait is inside the latency budget.
[<Sealed>]
type Gather(connectionString: string, lanes: int, maxBatch: int, gather: TimeSpan) =
    let queue =
        Channel.CreateUnbounded<Pending>(UnboundedChannelOptions(SingleReader = (lanes = 1), SingleWriter = false))
    let ds = NpgsqlDataSource.Create connectionString
    let counts = [| 0L; 0L |] // batches, requests
    /// How often a gathering lane looks whether a full batch is already queued.
    let tick = TimeSpan.FromMilliseconds 2.0

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
                // Gather: until the oldest request has waited `gather`, or a full batch is
                // queued, whichever comes first.
                // (Ticks, not TimeSpan's `>`: F#'s generic comparison boxes structs.)
                let mutable waiting = gather.Ticks > 0L
                while waiting do
                    match queue.Reader.TryPeek() with
                    | true, oldest when queue.Reader.Count < maxBatch ->
                        let left = gather - Diagnostics.Stopwatch.GetElapsedTime oldest.Arrived
                        if left.Ticks > 0L then
                            do! Task.Delay(if left.Ticks < tick.Ticks then left else tick)
                        else
                            waiting <- false
                    | _ -> waiting <- false
                take pending
                if pending.Count > 0 then
                    let batch = pending.ToArray()
                    pending.Clear()
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
