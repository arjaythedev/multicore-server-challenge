/// The Postgres side. Requests wait in a lane (one for reads, one for writes, shared by every I/O thread); a
/// lane's connection threads each take everything queued once the oldest request has waited the lane's clock
/// (or the batch is full) and answer it with ONE pipelined round trip: a few batched statements and a Sync.
/// Rendering happens on the connection thread, then the replies go back to the I/O threads.
module Store

open System
open System.Collections.Generic
open System.Diagnostics
open System.Text
open System.Threading
open Pg
open Json

// ---------------- jobs ----------------

[<AllowNullLiteral>]
type Job(dest: Io.Dest) =
    member _.Dest = dest
    member val T = 0L with get, set

type RKind =
    | Tags = 0
    | User = 1
    | Login = 2
    | Profile = 3
    | Article = 4
    | Comments = 5
    | List = 6

/// List kinds, as the read statement numbers them
[<Literal>]
let ListGlobal = 0
[<Literal>]
let ListTag = 1
[<Literal>]
let ListAuthor = 2
[<Literal>]
let ListFavorited = 3
[<Literal>]
let ListFeed = 4

[<AllowNullLiteral>]
type RJob(kind: RKind, dest: Io.Dest) =
    inherit Job(dest)
    member _.Kind = kind
    member val Viewer = 0L with get, set
    member val Key: string = null with get, set // slug, username, email, tag or author name
    member val ListKind = 0 with get, set
    member val Limit = 20 with get, set
    member val Offset = 0L with get, set
    member val Token: string = null with get, set
    member val Password: byte[] = null with get, set

type WKind =
    | FavAdd = 0
    | FavDel = 1
    | FollowAdd = 2
    | FollowDel = 3
    | CommentAdd = 4
    | CommentDel = 5
    | Signup = 6
    | UpdateUser = 7
    | ArticleCreate = 8
    | ArticleUpdate = 9
    | ArticleDelete = 10

[<AllowNullLiteral>]
type WJob(kind: WKind, dest: Io.Dest) =
    inherit Job(dest)
    member _.Kind = kind
    member val Viewer = 0L with get, set
    member val Key: string = null with get, set // slug or username
    member val Text: string = null with get, set // comment body
    member val CommentId = 0L with get, set
    member val Token: string = null with get, set
    member val Email: string = null with get, set
    member val Username: string = null with get, set
    member val Hash: string = null with get, set
    member val Bio: string = null with get, set
    member val Image: string = null with get, set
    member val Title: string = null with get, set
    member val Description: string = null with get, set
    member val Body: string = null with get, set
    member val TagList: string[] = null with get, set

// ---------------- lanes ----------------

let private ticksPerUs = float Stopwatch.Frequency / 1e6

/// A queue shared by every I/O thread, drained by its connection threads in batches.
///
/// One idle thread at a time is the leader: it sleeps (usleep, which doesn't spin) until the oldest queued
/// job has waited the clock, then takes up to a batch and hands leadership on. The other idle threads block in an
/// untimed wait. A timed Monitor.Wait spins before it blocks, which cost more CPU than the batches themselves.
[<Sealed>]
type Lane<'T when 'T :> Job>(clockUs: int, maxBatch: int) =
    let q = Queue<'T>()
    let gate = obj ()
    let clock = int64 (float clockUs * ticksPerUs)
    let mutable leader = false
    member _.Count = q.Count

    member _.Push(j: 'T) =
        j.T <- Stopwatch.GetTimestamp()
        lock gate (fun () ->
            q.Enqueue j
            if (q.Count = 1 && not leader) || q.Count = maxBatch then Monitor.Pulse gate)

    member _.Take(into: List<'T>) =
        let mutable got = false
        while not got do
            let mutable sleepUs = 0
            lock gate (fun () ->
                while q.Count = 0 || (leader && q.Count < maxBatch) do
                    Monitor.Wait gate |> ignore
                if q.Count >= maxBatch then got <- true
                else
                    let left = clock - (Stopwatch.GetTimestamp() - q.Peek().T)
                    if left <= 0L then got <- true
                    else
                        leader <- true
                        sleepUs <- max 1 (int (float left / ticksPerUs))
                if got then
                    while q.Count > 0 && into.Count < maxBatch do
                        into.Add(q.Dequeue())
                    if q.Count > 0 then Monitor.Pulse gate)
            if not got then
                Sys.usleep(uint32 sleepUs) |> ignore
                lock gate (fun () -> leader <- false)

let mutable stats = false

/// experiments (RD_DUMP=path): the read statement's inputs of a few batches, as psql EXECUTE lines for EXPLAIN
let mutable dumpPath: string = null
let mutable private dumpLeft = 40
let mutable private dumpSkip = 0

let private pgArray (xs: seq<string>) =
    let b = StringBuilder("'{")
    let mutable first = true
    for x in xs do
        if not first then b.Append ',' |> ignore
        first <- false
        if isNull x then b.Append "NULL" |> ignore
        else b.Append('"').Append(x.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("'", "''")).Append('"') |> ignore
    b.Append("}'").ToString()

let private dumpRead (cols: string list) =
    lock typeof<RJob> (fun () ->
        dumpSkip <- dumpSkip + 1
        if dumpLeft > 0 && dumpSkip > 4000 && dumpSkip % 25 = 0 then
            dumpLeft <- dumpLeft - 1
            IO.File.AppendAllText(dumpPath, "EXECUTE rd(" + String.Join(", ", cols) + ");\n"))
let private statReads = ref 0L
let private statReadBatches = ref 0L

// ---------------- rendering helpers ----------------

let private reply (j: Job) (bytes: byte[]) = Io.post j.Dest bytes

let private replyBody (j: Job) (code: int) (w: W) = reply j (response code (w.Span(0, w.Length)))

/// writes a text column as a JSON string, or null
let inline private textOrNull (w: W) (c: Conn) (i: int) =
    if c.IsNull i then w.Raw "null"B else w.Str(c.Span i)

let private userJson (w: W) (c: Conn) (email: int) (token: string) (username: int) (bio: int) (image: int) =
    w.Raw """{"user":{"email":"""B
    w.Str(c.Span email)
    w.Raw ""","token":"""B
    w.StrS token
    w.Raw ""","username":"""B
    w.Str(c.Span username)
    w.Raw ""","bio":"""B
    textOrNull w c bio
    w.Raw ""","image":"""B
    textOrNull w c image
    w.Raw "}}"B

/// columns: id, username, email, bio, image (signup, update user, users by id)
let private userReply (j: Job) (w: W) (c: Conn) (token: string) (code: int) =
    w.Reset()
    userJson w c 2 token 1 3 4
    replyBody j code w

/// a full article from the columns of Sql.articleCreated / articleUpdate
let private fullArticle (w: W) (c: Conn) =
    w.Raw """{"article":{"slug":"""B
    w.Str(c.Span 1)
    w.Raw ""","title":"""B
    w.Str(c.Span 2)
    w.Raw ""","description":"""B
    w.Str(c.Span 3)
    w.Raw ""","body":"""B
    w.Str(c.Span 4)
    w.Raw ""","createdAt":"""B
    w.Time(c.Time 5)
    w.Raw ""","updatedAt":"""B
    w.Time(c.Time 6)
    w.Raw ""","tagList":["""B
    // text[] binary: ndim, flags, oid, [size, lbound], elements
    let o = c.Off 7
    let b = c.Buf
    if i32 b o = 1 then
        let n = i32 b (o + 12)
        let mutable p = o + 20
        for k in 0 .. n - 1 do
            let len = i32 b p
            if k > 0 then w.Byte ','B
            w.Str(ReadOnlySpan(b, p + 4, len))
            p <- p + 4 + len
    w.Raw """],"favoritesCount":"""B
    w.Int(c.Int8 8)
    w.Raw ""","favorited":"""B
    w.Bool(c.Bool 9)
    w.Raw ""","author":{"username":"""B
    w.Str(c.Span 10)
    w.Raw ""","bio":"""B
    textOrNull w c 11
    w.Raw ""","image":"""B
    textOrNull w c 12
    w.Raw ""","following":"""B
    w.Bool(c.Bool 13)
    w.Raw "}}}"B

/// int8[] column into a list; returns how many
let private readIds (c: Conn) (i: int) (into: List<int64>) =
    if c.IsNull i then 0
    else
        let b = c.Buf
        let o = c.Off i
        if i32 b o = 0 then 0
        else
            let n = i32 b (o + 12)
            let mutable p = o + 20
            for _ in 1 .. n do
                into.Add(i64 b (p + 4))
                p <- p + 12
            n

let private readIdArray (c: Conn) (i: int) : int64[] =
    let l = List<int64>()
    readIds c i l |> ignore
    l.ToArray()

let inline private has (xs: int64[]) (v: int64) =
    not (isNull xs) && Array.IndexOf(xs, v) >= 0

/// One article of a batch: its JSON prefix pieces in the arena (everything up to the flags)
[<Struct>]
type private Art =
    { Author: int64
      ListOff: int
      ListLen: int
      FullOff: int
      FullLen: int }

// ---------------- reads ----------------

/// Per-connection state for answering read batches; reused from batch to batch.
[<Sealed>]
type private Reader(c: Conn) =
    let arena = W(1 <<< 20)
    let w = W(1 <<< 16)
    let tags = List<RJob>()
    let users = List<RJob>()
    let logins = List<RJob>()
    let profiles = List<RJob>()
    let arts = List<RJob>()
    let cmts = List<RJob>()
    let lists = List<RJob>()
    // read statement inputs
    let groupIndex = Dictionary<struct (int * string * int64 * int64 * int64), int>()
    let gk = List<int>()
    let gkey = List<string>()
    let gv = List<int64>()
    let glim = List<int64>()
    let goff = List<int64>()
    let rq = List<struct (int * int * int)>() // request: group, from, to (1-based, inclusive)
    // read statement outputs
    let groupCount = List<int64>()
    let groupIds = List<int64[]>()
    let artIndex = Dictionary<int64, Art>()
    let pending = List<struct (int64 * int64 * int * int * int * int * int * int * int * int * int * int)>()
    let tagIds = List<int>()
    let favs = Dictionary<int64, int64[]>()
    let follows = Dictionary<int64, int64[]>()
    let direct = Dictionary<int, int64>()
    let tagRank = Dictionary<int, int>()
    let tagName = List<struct (int * int)>() // arena offset, length of the JSON string, by rank
    // comments
    let slugIndex = Dictionary<string, int>()
    let slugs = List<string>()
    let cmtRows = List<struct (int * int64 * int64 * int64 * int * int)>() // slug index, id, author, created, frag off, len
    let cmtAuthors = Dictionary<int64, struct (int * int)>()
    let cmtFollows = Dictionary<int64, int64[]>()
    let found = HashSet<int>()
    let mutable tagsBody: byte[] = null
    let mutable dump = false

    let clear () =
        for l in [ tags; users; logins; profiles; arts; cmts; lists ] do
            l.Clear()
        groupIndex.Clear()
        gk.Clear()
        gkey.Clear()
        gv.Clear()
        glim.Clear()
        goff.Clear()
        rq.Clear()
        groupCount.Clear()
        groupIds.Clear()
        artIndex.Clear()
        pending.Clear()
        tagIds.Clear()
        favs.Clear()
        follows.Clear()
        direct.Clear()
        tagRank.Clear()
        tagName.Clear()
        slugIndex.Clear()
        slugs.Clear()
        cmtRows.Clear()
        cmtAuthors.Clear()
        cmtFollows.Clear()
        found.Clear()
        arena.Reset()
        tagsBody <- null

    /// Reads one statement's replies: BindComplete, rows, CommandComplete. False after an error.
    let statement (onRow: unit -> unit) =
        let mutable ok = true
        let mutable go = true
        while go do
            match c.Next() with
            | 'D'B ->
                c.Row() |> ignore
                onRow ()
            | 'C'B -> go <- false
            | 'E'B ->
                let e = c.Error()
                eprintfn "postgres: %A" e
                ok <- false
                go <- false
            | 'Z'B -> failwith "unexpected ReadyForQuery"
            | _ -> ()
        ok

    let finishSync () =
        while c.Next() <> 'Z'B do
            ()

    let groupFor (j: RJob) =
        let v = if j.ListKind = ListFeed then j.Viewer else 0L
        let key = if j.ListKind = ListGlobal || j.ListKind = ListFeed then "" else j.Key
        let top = j.Offset + int64 j.Limit
        // pages near the top share one fetch per source; deep pages get their own
        let shared = top <= 200L
        let gkeyT = if shared then struct (j.ListKind, key, v, 0L, 0L) else struct (j.ListKind, key, v, j.Offset, int64 j.Limit)
        let gi =
            match groupIndex.TryGetValue gkeyT with
            | true, gi -> gi
            | _ ->
                let gi = gk.Count
                groupIndex.[gkeyT] <- gi
                gk.Add j.ListKind
                gkey.Add(if key = "" then null else key)
                gv.Add v
                glim.Add(if shared then top else int64 j.Limit)
                goff.Add(if shared then 0L else j.Offset)
                gi
        if shared && glim.[gi] < top then glim.[gi] <- top
        if shared then rq.Add(struct (gi + 1, int j.Offset + 1, int top))
        else rq.Add(struct (gi + 1, 1, j.Limit))

    let artRow () =
        // t=2: a id, b author, c favorites, s1 slug, s2 title, s3 description, s4 body, s5..s7 author, ts1, ts2, tg
        let id = c.Int8 1
        let a1 = arena.Length
        arena.Raw """{"slug":"""B
        arena.Str(c.Span 5)
        arena.Raw ""","title":"""B
        arena.Str(c.Span 6)
        arena.Raw ""","description":"""B
        arena.Str(c.Span 7)
        arena.Byte ','B
        let a1Len = arena.Length - a1
        let body = arena.Length
        if not (c.IsNull 8) then
            arena.Raw "\"body\":"B
            arena.Str(c.Span 8)
            arena.Byte ','B
        let bodyLen = arena.Length - body
        let a2 = arena.Length
        arena.Raw "\"createdAt\":"B
        arena.Time(c.Time 12)
        arena.Raw ""","updatedAt":"""B
        arena.Time(c.Time 13)
        arena.Raw ""","favoritesCount":"""B
        arena.Int(c.Int8 3)
        arena.Raw ""","tagList":["""B
        let a2Len = arena.Length - a2
        let a3 = arena.Length
        arena.Raw """],"author":{"username":"""B
        arena.Str(c.Span 9)
        arena.Raw ""","bio":"""B
        textOrNull arena c 10
        arena.Raw ""","image":"""B
        textOrNull arena c 11
        arena.Raw ""","following":"""B
        let a3Len = arena.Length - a3
        let ts = tagIds.Count
        let o = c.Off 14
        let b = c.Buf
        if not (c.IsNull 14) && i32 b o = 1 then
            let n = i32 b (o + 12)
            let mutable p = o + 20
            for _ in 1 .. n do
                tagIds.Add(i32 b (p + 4))
                p <- p + 8
        pending.Add(struct (id, c.Int8 2, a1, a1Len, body, bodyLen, a2, a2Len, a3, a3Len, ts, tagIds.Count - ts))

    let readRow () =
        match c.Int4 0 with
        | 1 ->
            let gi = int (c.Int8 1) - 1
            while groupIds.Count <= gi do
                groupIds.Add null
                groupCount.Add 0L
            groupCount.[gi] <- c.Int8 2
            groupIds.[gi] <- readIdArray c 4
        | 2 -> artRow ()
        | 3 -> favs.[c.Int8 1] <- readIdArray c 4
        | 4 -> follows.[c.Int8 1] <- readIdArray c 4
        | _ -> direct.[int (c.Int8 1) - 1] <- c.Int8 2

    /// after the tags statement: put each article's pieces together, tag names sorted by name
    let assemble () =
        let ranks = List<int>()
        for struct (id, author, a1, a1Len, body, bodyLen, a2, a2Len, a3, a3Len, ts, tn) in pending do
            ranks.Clear()
            for k in ts .. ts + tn - 1 do
                match tagRank.TryGetValue tagIds.[k] with
                | true, r -> ranks.Add r
                | _ -> ()
            ranks.Sort()
            let writeHead (withBody: bool) =
                let start = arena.Length
                arena.Raw(arena.Span(a1, a1Len))
                if withBody then arena.Raw(arena.Span(body, bodyLen))
                arena.Raw(arena.Span(a2, a2Len))
                for k in 0 .. ranks.Count - 1 do
                    if k > 0 then arena.Byte ','B
                    let struct (o, l) = tagName.[ranks.[k]]
                    arena.Raw(arena.Span(o, l))
                arena.Raw(arena.Span(a3, a3Len))
                struct (start, arena.Length - start)
            let struct (lo, ll) = writeHead false
            let struct (fo, fl) = if bodyLen > 0 then writeHead true else struct (lo, ll)
            artIndex.[id] <- { Author = author; ListOff = lo; ListLen = ll; FullOff = fo; FullLen = fl }

    let flagsAndClose (w: W) (a: Art) (id: int64) (viewer: int64) =
        w.Bool(viewer <> 0L && has (match follows.TryGetValue viewer with | true, x -> x | _ -> null) a.Author)
        w.Raw """},"favorited":"""B
        w.Bool(viewer <> 0L && has (match favs.TryGetValue viewer with | true, x -> x | _ -> null) id)
        w.Byte '}'B

    let answerLists () =
        for i in 0 .. lists.Count - 1 do
            let j = lists.[i]
            let struct (gi, from, upto) = rq.[i]
            let ids = if gi - 1 < groupIds.Count then groupIds.[gi - 1] else null
            w.Reset()
            w.Raw """{"articles":["""B
            let mutable first = true
            if not (isNull ids) then
                for k in from - 1 .. (min upto ids.Length) - 1 do
                    match artIndex.TryGetValue ids.[k] with
                    | true, a ->
                        if not first then w.Byte ','B
                        first <- false
                        w.Raw(arena.Span(a.ListOff, a.ListLen))
                        flagsAndClose w a ids.[k] j.Viewer
                    | _ -> ()
            w.Raw """],"articlesCount":"""B
            w.Int(if gi - 1 < groupCount.Count then groupCount.[gi - 1] else 0L)
            w.Byte '}'B
            replyBody j 200 w

    let answerArticles () =
        for i in 0 .. arts.Count - 1 do
            let j = arts.[i]
            match direct.TryGetValue i with
            | true, id ->
                match artIndex.TryGetValue id with
                | true, a ->
                    w.Reset()
                    w.Raw """{"article":"""B
                    w.Raw(arena.Span(a.FullOff, a.FullLen))
                    flagsAndClose w a id j.Viewer
                    w.Byte '}'B
                    replyBody j 200 w
                | _ -> reply j notFound
            | _ -> reply j notFound

    let commentRow () =
        match c.Int4 0 with
        | 1 ->
            let off = arena.Length
            arena.Raw """{"id":"""B
            arena.Int(c.Int8 2)
            arena.Raw ""","createdAt":"""B
            arena.Time(c.Time 7)
            arena.Raw ""","updatedAt":"""B
            arena.Time(c.Time 8)
            arena.Raw ""","body":"""B
            arena.Str(c.Span 4)
            arena.Raw ""","author":"""B
            cmtRows.Add(struct (int (c.Int8 1) - 1, c.Int8 2, c.Int8 3, c.Time 7, off, arena.Length - off))
        | 2 ->
            let off = arena.Length
            arena.Raw """{"username":"""B
            arena.Str(c.Span 4)
            arena.Raw ""","bio":"""B
            textOrNull arena c 5
            arena.Raw ""","image":"""B
            textOrNull arena c 6
            arena.Raw ""","following":"""B
            cmtAuthors.[c.Int8 1] <- struct (off, arena.Length - off)
        | 3 -> cmtFollows.[c.Int8 1] <- readIdArray c 9
        | _ -> found.Add(int (c.Int8 1) - 1) |> ignore

    let answerComments () =
        // threads in order: newest first (created_at, then id, descending)
        let byThread = Dictionary<int, List<struct (int * int64 * int64 * int64 * int * int)>>()
        for r in cmtRows do
            let struct (si, _, _, _, _, _) = r
            match byThread.TryGetValue si with
            | true, l -> l.Add r
            | _ ->
                let l = List()
                l.Add r
                byThread.[si] <- l
        for l in byThread.Values do
            l.Sort(fun (struct (_, id1, _, t1, _, _)) (struct (_, id2, _, t2, _, _)) ->
                let x = compare t2 t1
                if x <> 0 then x else compare id2 id1)
        for j in cmts do
            let si = slugIndex.[j.Key]
            if not (found.Contains si) then reply j notFound
            else
                let fol = if j.Viewer <> 0L then (match cmtFollows.TryGetValue j.Viewer with | true, x -> x | _ -> null) else null
                w.Reset()
                w.Raw """{"comments":["""B
                match byThread.TryGetValue si with
                | true, l ->
                    for k in 0 .. l.Count - 1 do
                        let struct (_, _, author, _, off, len) = l.[k]
                        if k > 0 then w.Byte ','B
                        w.Raw(arena.Span(off, len))
                        let struct (ao, al) = cmtAuthors.[author]
                        w.Raw(arena.Span(ao, al))
                        w.Bool(has fol author)
                        w.Raw "}}"B
                | _ -> ()
                w.Raw "]}"B
                replyBody j 200 w

    let profileReplies = List<struct (int * byte[])>()
    let userRows = Dictionary<int64, struct (byte[] * byte[])>()
    let loginRows = Dictionary<string, struct (int64 * string * byte[] * byte[])>()
    let mutable batchRef: List<RJob> = null
    let mutable hasRead = false
    let mutable hasTags = false

    /// the user object split around its token: {"user":{"email":..,"token": | ,"username":..}}
    let userParts () =
        let lw = W(256)
        lw.Raw """{"user":{"email":"""B
        lw.Str(c.Span 2)
        lw.Raw ""","token":"""B
        let at = lw.Length
        lw.Raw ""","username":"""B
        lw.Str(c.Span 1)
        lw.Raw ""","bio":"""B
        textOrNull lw c 3
        lw.Raw ""","image":"""B
        textOrNull lw c 4
        lw.Raw "}}"B
        struct (lw.Span(0, at).ToArray(), lw.Span(at, lw.Length - at).ToArray())

    let userReplyParts (j: Job) (struct (head: byte[], tail: byte[])) (token: string) =
        let tw = W(512)
        tw.Raw(ReadOnlySpan head)
        tw.StrS token
        tw.Raw(ReadOnlySpan tail)
        replyBody j 200 tw

    /// Writes this batch's statements into the connection's output (no Sync).
    member _.Dump with set (v: bool) = dump <- v

    member _.Prepare(batch: List<RJob>) =
        clear ()
        profileReplies.Clear()
        userRows.Clear()
        loginRows.Clear()
        batchRef <- batch
        for j in batch do
            match j.Kind with
            | RKind.Tags -> tags.Add j
            | RKind.User -> users.Add j
            | RKind.Login -> logins.Add j
            | RKind.Profile -> profiles.Add j
            | RKind.Article -> arts.Add j
            | RKind.Comments -> cmts.Add j
            | _ -> lists.Add j
        let o = c.Out
        hasRead <- arts.Count > 0 || lists.Count > 0
        hasTags <- hasRead || tags.Count > 0
        if hasRead then
            for j in lists do
                groupFor j
            o.Bind("rd", 12)
            o.ArrBegin(OidInt4, gk.Count, false)
            for x in gk do
                o.EInt4 x
            o.ArrEnd()
            o.ArrBegin(OidText, gkey.Count, true)
            for x in gkey do
                o.EText x
            o.ArrEnd()
            for l in [ gv; glim; goff ] do
                o.ArrBegin(OidInt8, l.Count, false)
                for x in l do
                    o.EInt8 x
                o.ArrEnd()
            o.ArrBegin(OidInt4, rq.Count, false)
            for struct (g, _, _) in rq do
                o.EInt4 g
            o.ArrEnd()
            o.ArrBegin(OidInt4, rq.Count, false)
            for struct (_, f, _) in rq do
                o.EInt4 f
            o.ArrEnd()
            o.ArrBegin(OidInt4, rq.Count, false)
            for struct (_, _, t) in rq do
                o.EInt4 t
            o.ArrEnd()
            o.ArrBegin(OidInt8, lists.Count, false)
            for j in lists do
                o.EInt8 j.Viewer
            o.ArrEnd()
            o.ArrBegin(OidText, arts.Count, false)
            for j in arts do
                o.EText j.Key
            o.ArrEnd()
            o.ArrBegin(OidInt8, arts.Count, true)
            for _ in arts do
                o.I32 -1
            o.ArrEnd()
            o.ArrBegin(OidInt8, arts.Count, false)
            for j in arts do
                o.EInt8 j.Viewer
            o.ArrEnd()
            o.EndBind()
            o.Execute()
            if dump then
                let num (xs: seq<'a>) = pgArray (Seq.map string xs)
                dumpRead
                    [ num gk; pgArray gkey; num gv; num glim; num goff
                      num [ for struct (g, _, _) in rq -> g ]; num [ for struct (_, f, _) in rq -> f ]
                      num [ for struct (_, _, t) in rq -> t ]; num [ for j in lists -> j.Viewer ]
                      pgArray [ for j in arts -> j.Key ]; pgArray [ for _ in arts -> null ]; num [ for j in arts -> j.Viewer ] ]
        if cmts.Count > 0 then
            for j in cmts do
                if not (slugIndex.ContainsKey j.Key) then
                    slugIndex.[j.Key] <- slugs.Count
                    slugs.Add j.Key
            o.Bind("cm", 3)
            o.ArrBegin(OidText, slugs.Count, false)
            for s in slugs do
                o.EText s
            o.ArrEnd()
            o.ArrBegin(OidInt4, cmts.Count, false)
            for j in cmts do
                o.EInt4(slugIndex.[j.Key] + 1)
            o.ArrEnd()
            o.ArrBegin(OidInt8, cmts.Count, false)
            for j in cmts do
                o.EInt8 j.Viewer
            o.ArrEnd()
            o.EndBind()
            o.Execute()
        if profiles.Count > 0 then
            o.Bind("pf", 2)
            o.ArrBegin(OidText, profiles.Count, false)
            for j in profiles do
                o.EText j.Key
            o.ArrEnd()
            o.ArrBegin(OidInt8, profiles.Count, false)
            for j in profiles do
                o.EInt8 j.Viewer
            o.ArrEnd()
            o.EndBind()
            o.Execute()
        if users.Count > 0 then
            o.Bind("ui", 1)
            o.ArrBegin(OidInt8, users.Count, false)
            for j in users do
                o.EInt8 j.Viewer
            o.ArrEnd()
            o.EndBind()
            o.Execute()
        if logins.Count > 0 then
            o.Bind("ue", 1)
            o.ArrBegin(OidText, logins.Count, false)
            for j in logins do
                o.EText j.Key
            o.ArrEnd()
            o.EndBind()
            o.Execute()
        if hasTags then
            o.Bind("tg", 0)
            o.EndBind()
            o.Execute()

    /// Reads the replies to what Prepare sent (they come next on the connection). Answers nothing yet.
    member _.Collect() : bool =
        let mutable ok = true
        if hasRead then ok <- statement readRow
        if ok && cmts.Count > 0 then ok <- statement commentRow
        if ok && profiles.Count > 0 then
            ok <-
                statement (fun () ->
                    w.Reset()
                    w.Raw """{"profile":{"username":"""B
                    w.Str(c.Span 2)
                    w.Raw ""","bio":"""B
                    textOrNull w c 3
                    w.Raw ""","image":"""B
                    textOrNull w c 4
                    w.Raw ""","following":"""B
                    w.Bool(c.Bool 5)
                    w.Raw "}}"B
                    profileReplies.Add(struct (int (c.Int8 0) - 1, response 200 (w.Span(0, w.Length)))))
        if ok && users.Count > 0 then
            ok <- statement (fun () -> userRows.[c.Int8 0] <- userParts ())
        if ok && logins.Count > 0 then
            ok <-
                statement (fun () ->
                    let struct (head, tail) = userParts ()
                    loginRows.[c.Text 2] <- struct (c.Int8 0, c.Text 5, head, tail))
        if ok && hasTags then
            let tw = W(8192)
            tw.Raw """{"tags":["""B
            ok <-
                statement (fun () ->
                    let rank = tagName.Count
                    tagRank.[c.Int4 0] <- rank
                    let off = arena.Length
                    arena.Str(c.Span 1)
                    tagName.Add(struct (off, arena.Length - off))
                    if rank > 0 then tw.Byte ','B
                    tw.Str(c.Span 1))
            tw.Raw "]}"B
            tagsBody <- response 200 (tw.Span(0, tw.Length))
        ok

    /// Answers every request of the batch (after its Sync completed).
    member _.Answer(ok: bool) =
        if not ok then
            let err = Json.error 500 "database error"
            for j in batchRef do
                reply j err
        else
            for j in tags do
                reply j tagsBody
            if hasRead then
                assemble ()
                answerLists ()
                answerArticles ()
            if cmts.Count > 0 then answerComments ()
            if profiles.Count > 0 then
                let seen = HashSet<int>()
                for struct (i, b) in profileReplies do
                    seen.Add i |> ignore
                    reply profiles.[i] b
                for i in 0 .. profiles.Count - 1 do
                    if not (seen.Contains i) then reply profiles.[i] notFound
            for j in users do
                match userRows.TryGetValue j.Viewer with
                | true, parts -> userReplyParts j parts j.Token
                | _ -> reply j unauthorized
            for j in logins do
                match loginRows.TryGetValue j.Key with
                | true, struct (id, hash, head, tail) ->
                    Auth.verifyPassword j.Password hash (fun good ->
                        if good then userReplyParts j (struct (head, tail)) (Auth.mint id)
                        else reply j unauthorized)
                | _ -> reply j unauthorized
        if stats then
            Interlocked.Add(statReads, int64 batchRef.Count) |> ignore
            Interlocked.Increment statReadBatches |> ignore

    member r.Finish() =
        while c.Next() <> 'Z'B do
            ()

    member r.Run(batch: List<RJob>) =
        r.Prepare batch
        c.Out.Sync()
        c.Send()
        let ok = r.Collect()
        r.Finish()
        r.Answer ok

// ---------------- writes ----------------

let mutable readLane: Lane<RJob> = Unchecked.defaultof<_>
let mutable writeLane: Lane<WJob> = Unchecked.defaultof<_>

[<Sealed>]
type private Writer(c: Conn) =
    let w = W(1 <<< 16)
    let favJobs = List<WJob>()
    let folJobs = List<WJob>()
    let cmtAdd = List<WJob>()
    let cmtDel = List<WJob>()
    let rare = List<WJob>()
    let seen = HashSet<struct (int * int64)>()
    let deferred = List<WJob>()

    let statement (onRow: unit -> unit) =
        let mutable ok = true
        let mutable go = true
        let mutable err = None
        while go do
            match c.Next() with
            | 'D'B ->
                c.Row() |> ignore
                onRow ()
            | 'C'B -> go <- false
            | 'E'B ->
                err <- Some(c.Error())
                ok <- false
                go <- false
            | _ -> ()
        struct (ok, err)

    let finishSync () =
        while c.Next() <> 'Z'B do
            ()

    let pairs (name: string) (jobs: List<WJob>) =
        let o = c.Out
        o.Bind(name, 2)
        o.ArrBegin(OidInt8, jobs.Count, false)
        for j in jobs do
            o.EInt8 j.Viewer
        o.ArrEnd()
        o.ArrBegin(OidText, jobs.Count, false)
        for j in jobs do
            o.EText j.Key
        o.ArrEnd()
        o.EndBind()
        o.Execute()

    let commentReply () =
        w.Reset()
        w.Raw """{"comment":{"id":"""B
        w.Int(c.Int8 1)
        w.Raw ""","createdAt":"""B
        w.Time(c.Time 3)
        w.Raw ""","updatedAt":"""B
        w.Time(c.Time 4)
        w.Raw ""","body":"""B
        w.Str(c.Span 2)
        w.Raw ""","author":{"username":"""B
        w.Str(c.Span 5)
        w.Raw ""","bio":"""B
        textOrNull w c 6
        w.Raw ""","image":"""B
        textOrNull w c 7
        w.Raw ""","following":false}}}"""B
        response 201 (w.Span(0, w.Length))

    /// Favorites, follows and comments of many users in one implicit transaction (one Sync). Once it has
    /// committed, comments are answered from their RETURNING rows, and favorites and follows go on to the read
    /// lane, which answers them with the article or profile as it is now. False if anything failed (then nothing
    /// was committed).
    let group (favs: List<WJob>) (fols: List<WJob>) (adds: List<WJob>) (dels: List<WJob>) : bool =
        let o = c.Out
        let favAdd = List(favs |> Seq.filter (fun j -> j.Kind = WKind.FavAdd))
        let favDel = List(favs |> Seq.filter (fun j -> j.Kind = WKind.FavDel))
        let folAdd = List(fols |> Seq.filter (fun j -> j.Kind = WKind.FollowAdd))
        let folDel = List(fols |> Seq.filter (fun j -> j.Kind = WKind.FollowDel))
        let mutable nPlain = 0
        for name, l in [ "fa", favAdd; "fd", favDel; "oa", folAdd; "od", folDel ] do
            if l.Count > 0 then
                pairs name l
                nPlain <- nPlain + 1
        if adds.Count > 0 then
            o.Bind("ca", 3)
            o.ArrBegin(OidInt8, adds.Count, false)
            for j in adds do
                o.EInt8 j.Viewer
            o.ArrEnd()
            o.ArrBegin(OidText, adds.Count, false)
            for j in adds do
                o.EText j.Key
            o.ArrEnd()
            o.ArrBegin(OidText, adds.Count, false)
            for j in adds do
                o.EText j.Text
            o.ArrEnd()
            o.EndBind()
            o.Execute()
        if dels.Count > 0 then
            o.Bind("cd", 3)
            o.ArrBegin(OidInt8, dels.Count, false)
            for j in dels do
                o.EInt8 j.Viewer
            o.ArrEnd()
            o.ArrBegin(OidText, dels.Count, false)
            for j in dels do
                o.EText j.Key
            o.ArrEnd()
            o.ArrBegin(OidInt8, dels.Count, false)
            for j in dels do
                o.EInt8 j.CommentId
            o.ArrEnd()
            o.EndBind()
            o.Execute()
        o.Sync()
        c.Send()
        let mutable ok = true
        let check (struct (k, e)) =
            if ok && not k then
                eprintfn "write batch: %A" e
                ok <- false
        for _ in 1 .. nPlain do
            if ok then check (statement ignore)
        let cmtRows = Dictionary<int64, byte[]>()
        let delRows = Dictionary<int, int64>()
        if ok && adds.Count > 0 then check (statement (fun () -> cmtRows.[c.Int8 0] <- commentReply ()))
        if ok && dels.Count > 0 then check (statement (fun () -> delRows.[int (c.Int8 0) - 1] <- c.Int8 1))
        finishSync ()
        if ok then
            // committed: the favorite and follow answers (article, profile) are read by the read lane
            for j in favs do
                readLane.Push(RJob(RKind.Article, j.Dest, Viewer = j.Viewer, Key = j.Key))
            for j in fols do
                readLane.Push(RJob(RKind.Profile, j.Dest, Viewer = j.Viewer, Key = j.Key))
            for j in adds do
                match cmtRows.TryGetValue j.Viewer with
                | true, b -> reply j b
                | _ -> reply j notFound
            for i in 0 .. dels.Count - 1 do
                let j = dels.[i]
                match delRows.TryGetValue i with
                | true, author -> reply j (if author = j.Viewer then noContent else forbidden)
                | _ -> reply j notFound
        ok

    /// one job in its own transaction (Sync): signup, settings, article create/update/delete
    let single (j: WJob) =
        let o = c.Out
        match j.Kind with
        | WKind.Signup ->
            o.Bind("su", 3)
            o.PText j.Username
            o.PText j.Email
            o.PText j.Hash
            o.EndBind()
            o.Execute()
            o.Sync()
            c.Send()
            let mutable id = 0L
            let struct (ok, err) = statement (fun () ->
                id <- c.Int8 0
                userReply j w c (Auth.mint (c.Int8 0)) 201)
            finishSync ()
            if not ok then
                match err with
                | Some(PgError("23505", _)) -> reply j (unprocessable "username or email is taken")
                | e ->
                    eprintfn "signup: %A" e
                    reply j (Json.error 500 "database error")
        | WKind.UpdateUser ->
            o.Bind("uu", 6)
            o.PInt8 j.Viewer
            o.PText j.Email
            o.PText j.Username
            o.PText j.Hash
            o.PText j.Bio
            o.PText j.Image
            o.EndBind()
            o.Execute()
            o.Sync()
            c.Send()
            let mutable any = false
            let struct (ok, err) = statement (fun () ->
                any <- true
                userReply j w c j.Token 200)
            finishSync ()
            if not ok then
                match err with
                | Some(PgError("23505", _)) -> reply j (unprocessable "username or email is taken")
                | e ->
                    eprintfn "update user: %A" e
                    reply j (Json.error 500 "database error")
            elif not any then reply j unauthorized
        | WKind.ArticleCreate ->
            o.Bind("ai", 4)
            o.PInt8 j.Viewer
            o.PText j.Title
            o.PText j.Description
            o.PText j.Body
            o.EndBind()
            o.Execute()
            let tagged = not (isNull j.TagList) && j.TagList.Length > 0
            if tagged then
                for name in [ "ti"; "at" ] do
                    o.Bind(name, 1)
                    o.ArrBegin(OidText, j.TagList.Length, false)
                    for t in j.TagList do
                        o.EText t
                    o.ArrEnd()
                    o.EndBind()
                    o.Execute()
            o.Bind("ac", 1)
            o.PInt8 j.Viewer
            o.EndBind()
            o.Execute()
            o.Sync()
            c.Send()
            let mutable ok = true
            let mutable answered = false
            let step (f: unit -> unit) =
                if ok then
                    let struct (k, e) = statement f
                    if not k then
                        eprintfn "create article: %A" e
                        ok <- false
            step ignore
            if tagged then
                step ignore
                step ignore
            step (fun () ->
                w.Reset()
                fullArticle w c
                answered <- true
                replyBody j 201 w)
            finishSync ()
            if not answered then reply j (Json.error 500 "database error")
        | WKind.ArticleUpdate
        | WKind.ArticleDelete ->
            o.Bind("ao", 1)
            o.PText j.Key
            o.EndBind()
            o.Execute()
            if j.Kind = WKind.ArticleUpdate then
                o.Bind("au", 5)
                o.PInt8 j.Viewer
                o.PText j.Key
                o.PText j.Title
                o.PText j.Description
                o.PText j.Body
                o.EndBind()
            else
                o.Bind("ad", 2)
                o.PInt8 j.Viewer
                o.PText j.Key
                o.EndBind()
            o.Execute()
            o.Sync()
            c.Send()
            let mutable owner = -1L
            let mutable answered = false
            let struct (ok1, e1) = statement (fun () -> owner <- c.Int8 1)
            let struct (ok2, e2) =
                if ok1 then
                    statement (fun () ->
                        if j.Kind = WKind.ArticleUpdate then
                            w.Reset()
                            fullArticle w c
                            answered <- true
                            replyBody j 200 w)
                else struct (false, None)
            finishSync ()
            if not (ok1 && ok2) then
                eprintfn "article change: %A %A" e1 e2
                reply j (Json.error 500 "database error")
            elif owner < 0L then reply j notFound
            elif owner <> j.Viewer then reply j forbidden
            elif j.Kind = WKind.ArticleDelete then reply j noContent
            elif not answered then reply j notFound
        | _ -> ()

    member _.Deferred = deferred

    member _.Run(batch: List<WJob>) =
        favJobs.Clear()
        folJobs.Clear()
        cmtAdd.Clear()
        cmtDel.Clear()
        rare.Clear()
        seen.Clear()
        deferred.Clear()
        for j in batch do
            let cat =
                match j.Kind with
                | WKind.FavAdd
                | WKind.FavDel -> 0
                | WKind.FollowAdd
                | WKind.FollowDel -> 1
                | WKind.CommentAdd -> 2
                | WKind.CommentDel -> 3
                | _ -> -1
            if cat < 0 then rare.Add j
            elif not (seen.Add(struct (cat, j.Viewer))) then deferred.Add j // one per user per kind and batch
            else
                match cat with
                | 0 -> favJobs.Add j
                | 1 -> folJobs.Add j
                | 2 -> cmtAdd.Add j
                | _ -> cmtDel.Add j
        if favJobs.Count + folJobs.Count + cmtAdd.Count + cmtDel.Count > 0 then
            if not (group favJobs folJobs cmtAdd cmtDel) then
                // something in the group failed (say, an article deleted meanwhile): each one alone
                let one = List<WJob>(1)
                let none = List<WJob>()
                let solo (l: List<WJob>) (k: int) =
                    for j in l do
                        one.Clear()
                        one.Add j
                        let ok =
                            match k with
                            | 0 -> group one none none none
                            | 1 -> group none one none none
                            | 2 -> group none none one none
                            | _ -> group none none none one
                        if not ok then reply j (Json.error 500 "database error")
                solo favJobs 0
                solo folJobs 1
                solo cmtAdd 2
                solo cmtDel 3
        for j in rare do
            single j


// ---------------- lanes and their connection threads ----------------


let private connect (url: string) (options: string) =
    let c = new Conn(url, options)
    c.Open()
    for name, sql, oids in Sql.all () do
        c.Prepare(name, sql, oids)
    c

let private failAll (batch: List<'T>) (ex: exn) =
    eprintfn "batch failed: %s" ex.Message
    let err = Json.error 500 "database error"
    for j in batch do
        reply j err

let private readThread (url: string) (options: string) () =
    Sys.schedThread ()
    let mutable c = connect url options
    let mutable r = Reader(c, Dump = not (isNull dumpPath))
    let batch = List<RJob>()
    while true do
        batch.Clear()
        readLane.Take batch
        try
            r.Run batch
        with ex ->
            failAll batch ex
            (c :> IDisposable).Dispose()
            c <- connect url options
            r <- Reader(c, Dump = not (isNull dumpPath))

let private writeThread (url: string) (options: string) () =
    Sys.schedThread ()
    let mutable c = connect url options
    let mutable wr = Writer(c)
    let batch = List<WJob>()
    while true do
        batch.Clear()
        writeLane.Take batch
        try
            wr.Run batch
            for j in wr.Deferred do
                writeLane.Push j
        with ex ->
            failAll batch ex
            (c :> IDisposable).Dispose()
            c <- connect url options
            wr <- Writer(c)

/// Opens the connections (each prepares every statement) and starts their threads.
let start (url: string) (options: string) (reads: int) (writes: int) (readClockUs: int) (readMax: int) (writeClockUs: int) (writeMax: int) =
    readLane <- Lane<RJob>(readClockUs, readMax)
    writeLane <- Lane<WJob>(writeClockUs, writeMax)
    // fail at startup, not on the first request, if a statement doesn't prepare
    (connect url options :> IDisposable).Dispose()
    for i in 1 .. reads do
        Thread(readThread url options, IsBackground = true, Name = sprintf "pg-read-%d" i).Start()
    for i in 1 .. writes do
        Thread(writeThread url options, IsBackground = true, Name = sprintf "pg-write-%d" i).Start()
    if stats then
        Thread((fun () ->
                    while true do
                        Thread.Sleep 5000
                        let n = Interlocked.Exchange(statReads, 0L)
                        let b = Interlocked.Exchange(statReadBatches, 0L)
                        eprintfn "reads %d in %d batches (%.1f per batch), queued now: read %d write %d"
                            n b (if b > 0L then float n / float b else 0.0) readLane.Count writeLane.Count),
               IsBackground = true)
            .Start()
