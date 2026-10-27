/// The Postgres side: ONE thread owns every Postgres connection in its own io_uring ring, and the batch queues
/// shared by all I/O loops (one queue per kind for the whole box: a bigger drain shares more work, #79, #82, #22).
///
/// Batching (#22's policy plus a clock, #79): read requests wait in their kind's queue until the oldest has waited
/// WaitUs (20 ms by default) or MaxBatch are queued, and a read connection has room (fewer than Depth statements in
/// Postgres); then the kind whose oldest request has waited longest sends what it has queued (up to MaxBatch) as
/// ONE statement. A kind holds at most MaxInflight connections. Without the clock, batches at a moderate load
/// average ~2 requests and Postgres pays its per-statement cost for each; with 20 ms the box spent ~38% less CPU
/// per request, for ~30 ms more p95 (experiments/worklog.md). Under full load batches fill before the clock.
/// Writes go to their own connections (a read never waits behind a commit), to the one with the fewest in flight.
module Db

open System
open System.Buffers
open System.Buffers.Binary
open System.Buffers.Text
open System.Collections.Generic
open System.Text.Encodings.Web
open System.Text.Json
open System.Threading
open Pg
open Ring
open Ctx

// user_data: op (3 bits) | connection (rest)
[<Literal>]
let private OpEvent = 4UL
[<Literal>]
let private OpIgnore = 5UL
[<Literal>]
let private OpRecv = 6UL
[<Literal>]
let private OpSend = 7UL

[<Struct>]
type private Art =
    { Id: int64
      Author: int64
      Start: int
      Fav: int // the "false" after "favorited":
      Fol: int // the "false" after "following":
      End: int }

[<Struct>]
type private Head =
    { I: int
      Count: int64
      Ids: int
      NIds: int
      Favs: int
      NFavs: int
      Fols: int
      NFols: int }

/// Packed list results (Sql: #82's form): each distinct article's JSON is written once per batch with both flags
/// false, then every request's response is assembled from those pieces and its own page ids and flag arrays.
/// Nothing outlives the batch.
[<Sealed>]
type Packer() =
    let buf = ArrayBufferWriter<byte>(64 * 1024)
    let w = new Utf8JsonWriter(buf, JsonWriterOptions(Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping, SkipValidation = true))
    let arts = List<Art>()
    let index = Dictionary<int64, int>()
    let heads = List<Head>()
    let longs = List<int64>()
    static let open' = "{\"articles\":["B
    static let close' = "],\"articlesCount\":"B
    static let tru = "true"B
    static let fals = "false"B

    /// appends an int8[] (binary) to longs; returns how many
    let readLongs (b: ReadOnlySpan<byte>) =
        if b.Length < 20 || BinaryPrimitives.ReadInt32BigEndian b <> 1 then 0
        else
            let count = BinaryPrimitives.ReadInt32BigEndian(b.Slice 12)
            let mutable pos = 20
            let mutable added = 0
            for _ in 1..count do
                let len = BinaryPrimitives.ReadInt32BigEndian(b.Slice pos)
                pos <- pos + 4
                if len = 8 then
                    longs.Add(BinaryPrimitives.ReadInt64BigEndian(b.Slice pos))
                    added <- added + 1
                if len > 0 then pos <- pos + len
            added

    let contains (start: int) (n: int) (v: int64) =
        let mutable found = false
        let mutable k = start
        while not found && k < start + n do
            if longs.[k] = v then found <- true
            k <- k + 1
        found

    static let put (o: IBufferWriter<byte>) (src: ReadOnlySpan<byte>) =
        let s = o.GetSpan src.Length
        src.CopyTo s
        o.Advance src.Length

    member _.Clear() =
        buf.ResetWrittenCount()
        arts.Clear()
        index.Clear()
        heads.Clear()
        longs.Clear()

    member _.Row(r: PgRow) =
        let i = r.Int4 0
        if i < 0 then
            let id = r.Int8 2
            w.Reset()
            let start = buf.WrittenCount
            w.WriteStartObject()
            Json.text w Json.N.slug r 3
            Json.text w Json.N.title r 4
            Json.text w Json.N.description r 5
            Json.time w Json.N.createdAt (r.Micros 6)
            Json.time w Json.N.updatedAt (r.Micros 7)
            Json.tagList w r 8
            w.WriteNumber(Json.N.favoritesCount, r.Int8 9)
            w.WriteBoolean(Json.N.favorited, false)
            w.Flush()
            let fav = buf.WrittenCount - 5
            w.WritePropertyName Json.N.author
            w.WriteStartObject()
            Json.text w Json.N.username r 10
            Json.nullableText w Json.N.bio r 11
            Json.nullableText w Json.N.image r 12
            w.WriteBoolean(Json.N.following, false)
            w.Flush()
            let fol = buf.WrittenCount - 5
            w.WriteEndObject()
            w.WriteEndObject()
            w.Flush()
            index.[id] <- arts.Count
            arts.Add { Id = id; Author = r.Int8 13; Start = start; Fav = fav; Fol = fol; End = buf.WrittenCount }
        else
            let ids = longs.Count
            let nIds = readLongs (r.Bytes 14)
            let favs = longs.Count
            let nFavs = readLongs (r.Bytes 15)
            let fols = longs.Count
            let nFols = readLongs (r.Bytes 16)
            heads.Add { I = i; Count = r.Int8 1; Ids = ids; NIds = nIds; Favs = favs; NFavs = nFavs; Fols = fols; NFols = nFols }

    member _.Heads = heads.Count
    member _.HeadIndex(k: int) = heads.[k].I

    /// writes the k-th request's response body into c; false when an article is missing (then nothing is usable)
    member _.Write(k: int, c: Ctx) =
        let h = heads.[k]
        let o = c.Out :> IBufferWriter<byte>
        put o (ReadOnlySpan open')
        let src = buf.WrittenSpan
        let mutable ok = true
        for j in 0 .. h.NIds - 1 do
            let id = longs.[h.Ids + j]
            let mutable ai = 0
            if index.TryGetValue(id, &ai) then
                let a = arts.[ai]
                if j > 0 then put o (ReadOnlySpan ","B)
                put o (src.Slice(a.Start, a.Fav - a.Start))
                put o (ReadOnlySpan(if contains h.Favs h.NFavs id then tru else fals))
                put o (src.Slice(a.Fav + 5, a.Fol - a.Fav - 5))
                put o (ReadOnlySpan(if contains h.Fols h.NFols a.Author then tru else fals))
                put o (src.Slice(a.Fol + 5, a.End - a.Fol - 5))
            else ok <- false
        put o (ReadOnlySpan close')
        let s = o.GetSpan 24
        let mutable n = 0
        Utf8Formatter.TryFormat(h.Count, s, &n) |> ignore
        s.[n] <- '}'B
        o.Advance(n + 1)
        ok

/// One batched statement: the requests of one kind, their parameters as arrays.
[<Sealed; AllowNullLiteral>]
type BatchQuery(k: Sql.Kind, release: BatchQuery -> unit) =
    inherit PgQuery()
    let items = Array.zeroCreate<Ctx> k.MaxBatch
    let finished = Array.zeroCreate<Ctx> k.MaxBatch
    let packed = Array.zeroCreate<bool> k.MaxBatch
    let mutable packer: Packer = Unchecked.defaultof<_>
    let mutable packing = false
    member val N = 0 with get, set
    member _.Items = items
    member _.Kind = k
    /// at most half of the batch's pages are distinct (#7's rule): the shared form pays off
    member private b.Overlapping() =
        let n = b.N
        if n < 2 then false
        else
            let mutable unique = 0
            for i in 0 .. n - 1 do
                let a = items.[i]
                let mutable seen = false
                let mutable j = 0
                while not seen && j < i do
                    let x = items.[j]
                    if x.Limit = a.Limit && x.Offset = a.Offset && x.Key.SequenceEqual a.Key then seen <- true
                    j <- j + 1
                if not seen then unique <- unique + 1
            unique <= n / 2
    override b.Write(w) =
        packing <- not (isNull k.Packed) && b.N >= k.PackedMin
        if packing then
            if isNull (box packer) then packer <- Packer()
            packer.Clear()
        if not (isNull k.Pre) then
            w.Bind k.Pre
            b.Params w
            w.EndBind()
        w.Bind(
            if packing then k.Packed
            elif not (isNull k.Shared) && b.Overlapping() then k.Shared
            else k.Stmt
        )
        if not k.Broadcast then b.Params w
        w.EndBind()
        w.Sync()
    member private b.Params(w: PgWriter) =
        let n = b.N
        w.BeginArray Oid.Int4
        for i in 0 .. n - 1 do w.Int4 i
        w.EndArray n
        let l = k.Layout
        if l <> Sql.Layout.None then
            w.BeginArray Oid.Int8
            for i in 0 .. n - 1 do w.Int8 items.[i].Viewer
            w.EndArray n
        if l = Sql.Layout.List || l = Sql.Layout.ListKey then
            w.BeginArray Oid.Int4
            for i in 0 .. n - 1 do w.Int4 items.[i].Limit
            w.EndArray n
            w.BeginArray Oid.Int8
            for i in 0 .. n - 1 do w.Int8 items.[i].Offset
            w.EndArray n
        if l = Sql.Layout.ViewerKey || l = Sql.Layout.ListKey || l = Sql.Layout.ViewerKeyText then
            w.BeginArray Oid.Text
            for i in 0 .. n - 1 do w.Text items.[i].Key
            w.EndArray n
        if l = Sql.Layout.ViewerKeyText then
            w.BeginArray Oid.Text
            for i in 0 .. n - 1 do w.Text items.[i].S1
            w.EndArray n
    override b.Row(_, row) =
        if packing then packer.Row row
        elif k.Broadcast then Handlers.tagsRows items b.N row // the only broadcast kind
        else
            let i = row.Int4 0
            if uint32 i < uint32 b.N then Handlers.batchRow items.[i] row
    override b.Done(err) =
        let n = b.N
        if packing && isNull err then
            try
                for h in 0 .. packer.Heads - 1 do
                    let i = packer.HeadIndex h
                    if uint32 i < uint32 n && not packed.[i] then
                        let c = items.[i]
                        packed.[i] <- true
                        if not (packer.Write(h, c)) then
                            eprintfn "packed %O: an article is missing" c.Route
                            c.Error(500, "internal error")
            with e ->
                eprintfn "packed: %O" e
                for i in 0 .. n - 1 do
                    packed.[i] <- true
                    items.[i].Error(500, "internal error")
        Array.Copy(items, finished, n)
        Array.Clear(items, 0, n)
        b.N <- 0
        release b // the kind's next batch may go out before these responses are written
        for i in 0 .. n - 1 do
            let c = finished.[i]
            finished.[i] <- null
            try
                if packed.[i] then
                    packed.[i] <- false
                    c.Finish()
                elif packing && isNull err then
                    eprintfn "packed %O: no row for the request" c.Route
                    c.Error(500, "internal error")
                    c.Finish()
                else Handlers.batchDone c err
            with e ->
                eprintfn "%O" e
                c.Error(500, "internal error")
                c.Finish()

/// What the I/O loops and bcrypt threads post to the Postgres thread.
[<Struct>]
type private Msg =
    val Op: int // 0 enqueue (kind), 1 read query, 2 write query, 3 after bcrypt
    val Kind: int
    val C: Ctx
    val Q: PgQuery
    new(op, kind, c, q) = { Op = op; Kind = kind; C = c; Q = q }

type Options =
    { Url: string
      PgOptions: string
      Reads: int
      Writes: int
      Depth: int
      /// a kind's batch waits until its oldest request has waited this long (or the batch is full); 0 = no clock
      WaitUs: int }

[<Sealed>]
type PgThread(o: Options) as this =
    inherit Backend()
    /// created on the Postgres thread (SINGLE_ISSUER)
    let mutable ring: Ring = null
    let inbox = Mailbox<Msg>()
    let conns = List<PgConn>()
    let reads = List<PgConn>()
    let writes = List<PgConn>()
    let kinds = Sql.kinds.ToArray()
    let pending = kinds |> Array.map (fun _ -> Queue<Ctx>())
    let inflight = Array.zeroCreate<int> kinds.Length
    let free = kinds |> Array.map (fun _ -> Stack<BatchQuery>())
    let cqes = List<Cqe>(4096)
    let waitTicks = int64 o.WaitUs * Diagnostics.Stopwatch.Frequency / 1_000_000L
    let mutable needPump = false
    let mutable thread: Thread = null
    let ready = new ManualResetEventSlim(false)
    let mutable initError: exn = null
    let freed = fun (c: PgConn) -> if not c.IsWrite then needPump <- true
    let releaseBatch = fun (b: BatchQuery) ->
        let k = b.Kind.Id
        inflight.[k] <- inflight.[k] - 1
        free.[k].Push b
        needPump <- true
    let stats = not (isNull (Environment.GetEnvironmentVariable "MC_STATS"))
    let mutable stBatches = 0L
    let mutable stItems = 0L
    let stKB = Array.zeroCreate<int64> 64
    let stKI = Array.zeroCreate<int64> 64
    let mutable stLast = Environment.TickCount64
    // the planner (default on, PLANNER=0 off): these kinds' requests go out together, as one MegaQuery (Planner.fs, #47)
    let mega =
        kinds |> Array.map (fun k ->
            Planner.enabled
            && (k.Id = Sql.Article.Id || k.Id = Sql.Comments.Id || k.Id = Sql.Profile.Id || k.Id = Sql.ListAll.Id
                || k.Id = Sql.ListTag.Id || k.Id = Sql.ListAuthor.Id || k.Id = Sql.ListFavorited.Id || k.Id = Sql.ListFeed.Id))
    let megaMax =
        match Environment.GetEnvironmentVariable "PLANNER_MAX" with
        | null | "" -> 2048
        | s -> int s
    let megaFree = Stack<Planner.MegaQuery>()
    let mutable megaInflight = 0
    let mutable stMega = 0L
    let mutable stMegaItems = 0L
    let releaseMega = fun (b: Planner.MegaQuery) ->
        megaInflight <- megaInflight - 1
        megaFree.Push b
        needPump <- true

    do
        for i in 0 .. o.Reads + o.Writes - 1 do
            let isWrite = i >= o.Reads
            let s = Pg.connect o.Url o.PgOptions true
            let c = PgConn(s, i, isWrite)
            conns.Add c
            (if isWrite then writes else reads).Add c
        thread <- Thread((fun () -> this.Run()), 1024 * 1024, IsBackground = true, Name = "postgres")
        thread.Start()
        ready.Wait()
        if not (isNull initError) then raise initError

    member private _.ArmRecv(c: PgConn) =
        let mutable addr = 0n
        let mutable len = 0
        c.RecvTarget(&addr, &len)
        ring.RecvInto(c.Fd, addr, len, OpRecv ||| (uint64 c.Index <<< 3))

    member private _.ArmEvent() = ring.Read(inbox.Fd, inbox.Sink, 8, OpEvent)

    member private _.Least(list: List<PgConn>) =
        let mutable best: PgConn = null
        for c in list do
            if not c.Broken && (isNull best || c.Inflight < best.Inflight) then best <- c
        best

    member private this.Submit(list: List<PgConn>, q: PgQuery) =
        let c = this.Least list
        if isNull c then q.Done(PgError("08006", "no postgres connection"))
        else c.Submit q |> ignore

    /// fill free read connections, the kind whose oldest request waited longest first
    /// Returns the ticks until the next batch window closes (0 = none waiting).
    member private this.Batch(k: int, conn: PgConn) =
        let kind = kinds.[k]
        let b = if free.[k].Count > 0 then free.[k].Pop() else BatchQuery(kind, releaseBatch)
        let p = pending.[k]
        let n = min p.Count kind.MaxBatch
        for i in 0 .. n - 1 do b.Items.[i] <- p.Dequeue()
        b.N <- n
        inflight.[k] <- inflight.[k] + 1
        if stats then
            stBatches <- stBatches + 1L
            stItems <- stItems + int64 n
            stKB.[k] <- stKB.[k] + 1L
            stKI.[k] <- stKI.[k] + int64 n
        if isNull conn then b.Done(PgError("08006", "no postgres connection")) else conn.Submit b |> ignore

    member private this.Mega(conn: PgConn) =
        let b = if megaFree.Count > 0 then megaFree.Pop() else Planner.MegaQuery(megaMax, releaseMega)
        let mutable n = 0
        // oldest kinds first, until the batch is full
        let mutable more = true
        while more && n < megaMax do
            let mutable kb = -1
            let mutable tb = Int64.MaxValue
            for k in 0 .. kinds.Length - 1 do
                if mega.[k] && pending.[k].Count > 0 && pending.[k].Peek().Queued < tb then
                    tb <- pending.[k].Peek().Queued
                    kb <- k
            if kb < 0 then more <- false
            else
                let p = pending.[kb]
                while n < megaMax && p.Count > 0 do
                    b.Items.[n] <- p.Dequeue()
                    n <- n + 1
        b.N <- n
        b.Conn <- conn
        megaInflight <- megaInflight + 1
        if stats then
            stMega <- stMega + 1L
            stMegaItems <- stMegaItems + int64 n
        b.Plan()
        conn.Submit b |> ignore

    member private this.Pump() : int64 =
        needPump <- false
        let now = if waitTicks > 0L then Diagnostics.Stopwatch.GetTimestamp() else 0L
        let mutable next = Int64.MaxValue
        // write kinds: to the write connection with the fewest in flight, by the same clock
        for k in 0 .. kinds.Length - 1 do
            if kinds.[k].Write then
                let p = pending.[k]
                let mutable more = true
                while more && p.Count > 0 && inflight.[k] < kinds.[k].MaxInflight do
                    let t = p.Peek().Queued
                    if waitTicks > 0L && p.Count < kinds.[k].MaxBatch && now - t < waitTicks then
                        next <- min next (t + waitTicks - now)
                        more <- false
                    else this.Batch(k, this.Least writes)
        let mutable go = true
        while go do
            let mutable best = -1
            let mutable oldest = Int64.MaxValue
            if Planner.enabled && megaInflight < reads.Count then
                let mutable total = 0
                let mutable t0 = Int64.MaxValue
                for k in 0 .. kinds.Length - 1 do
                    if mega.[k] && pending.[k].Count > 0 then
                        total <- total + pending.[k].Count
                        t0 <- min t0 (pending.[k].Peek().Queued)
                if total > 0 then
                    if waitTicks > 0L && total < megaMax && now - t0 < waitTicks then next <- min next (t0 + waitTicks - now)
                    else
                        oldest <- t0
                        best <- kinds.Length // the planner batch
            for k in 0 .. kinds.Length - 1 do
                let p = pending.[k]
                if p.Count > 0 && inflight.[k] < kinds.[k].MaxInflight && not kinds.[k].Write && not mega.[k] then
                    let t = p.Peek().Queued
                    if waitTicks > 0L && p.Count < kinds.[k].MaxBatch && now - t < waitTicks then
                        next <- min next (t + waitTicks - now)
                    elif t < oldest then
                        oldest <- t
                        best <- k
            if best < 0 then go <- false
            else
                let mutable conn: PgConn = null
                for c in reads do
                    if not c.Broken && c.Inflight < o.Depth && (isNull conn || c.Inflight < conn.Inflight) then conn <- c
                if isNull conn then go <- false
                elif best = kinds.Length then this.Mega conn
                else this.Batch(best, conn)
        if next = Int64.MaxValue then 0L else max 1L next

    member private this.Drain() =
        let mutable m = Unchecked.defaultof<Msg>
        while inbox.TryTake(&m) do
            match m.Op with
            | 0 ->
                m.C.Queued <- Diagnostics.Stopwatch.GetTimestamp()
                pending.[m.Kind].Enqueue m.C
                needPump <- true
            | 1 -> this.Submit(reads, m.Q)
            | 2 -> this.Submit(writes, m.Q)
            | _ ->
                try Handlers.afterBcrypt m.C
                with e ->
                    eprintfn "%O" e
                    m.C.Error(500, "internal error")
                    m.C.Finish()

    member private this.Flush() =
        for c in conns do
            if not c.Broken && not c.SendInFlight && c.HasPending then
                let mutable addr = 0n
                let mutable len = 0
                c.TakeSend(&addr, &len)
                if len > 0 then ring.Send(c.Fd, false, addr, len, MSG_NOSIGNAL, OpSend ||| (uint64 c.Index <<< 3))

    member private this.Handle(e: Cqe) =
        let op = e.U &&& 7UL
        if op = OpEvent then
            inbox.Rearmed()
            this.ArmEvent()
        elif op = OpRecv || op = OpSend then
            let c = conns.[int (e.U >>> 3)]
            if not c.Broken then
                if op = OpRecv then
                    if e.Res > 0 then
                        c.Received(e.Res, freed)
                        if not c.Broken then this.ArmRecv c
                    else c.Fail(if e.Res = 0 then "closed by server" else sprintf "recv errno %d" -e.Res)
                else
                    let mutable addr = 0n
                    let mutable len = 0
                    if e.Res = -EAGAIN || e.Res = -EINTR then
                        c.Sent(0, &addr, &len) |> ignore
                        if len > 0 then ring.Send(c.Fd, false, addr, len, MSG_NOSIGNAL, e.U)
                    elif not (c.Sent(e.Res, &addr, &len)) then c.Fail(sprintf "send errno %d" -e.Res)
                    elif len > 0 then ring.Send(c.Fd, false, addr, len, MSG_NOSIGNAL, e.U)

    member private this.Run() =
        try
            try
                ring <- Ring(1024u, 8192u)
                for c in conns do this.ArmRecv c
                this.ArmEvent()
                ring.Submit() |> ignore
            with e -> initError <- e
        finally
            ready.Set()
        if isNull initError then
            let mutable waitNs = 0L
            while true do
                ring.Enter(1u, waitNs) |> ignore
                cqes.Clear()
                ring.Reap(cqes, Int32.MaxValue) |> ignore
                for i in 0 .. cqes.Count - 1 do
                    try this.Handle cqes.[i] with e -> eprintfn "%O" e
                (try this.Drain() with e -> eprintfn "%O" e)
                if needPump || waitTicks > 0L then
                    let t = (try this.Pump() with e -> eprintfn "%O" e; 0L)
                    waitNs <- if t > 0L then max 20_000L (t * 1_000_000_000L / Diagnostics.Stopwatch.Frequency) else 0L
                this.Flush()
                if stats && Environment.TickCount64 - stLast > 5000L then
                    stLast <- Environment.TickCount64
                    let q = pending |> Array.sumBy (fun p -> p.Count)
                    eprintfn "pg batches=%d items=%d avg=%.1f queued=%d inflight=%s" stBatches stItems
                        (if stBatches > 0L then float stItems / float stBatches else 0.0) q
                        (String.Join(",", conns |> Seq.map (fun c -> string c.Inflight)))
                    eprintfn "pg kinds %s" (String.Join(" ", kinds |> Seq.filter (fun k -> stKB.[k.Id] > 0L) |> Seq.map (fun k -> sprintf "%s=%d/%.1f" k.Name stKB.[k.Id] (float stKI.[k.Id] / float stKB.[k.Id]))))
                    if Planner.enabled then
                        eprintfn "pg planner batches=%d avg=%.1f" stMega (if stMega > 0L then float stMegaItems / float stMega else 0.0)
                        stMega <- 0L
                        stMegaItems <- 0L
                    Array.Clear stKB
                    Array.Clear stKI
                    stBatches <- 0L
                    stItems <- 0L

    override _.Enqueue(c, kind) = inbox.Post(Msg(0, kind.Id, c, null))
    override _.Read(q) = inbox.Post(Msg(1, 0, null, q))
    override _.Write(q) = inbox.Post(Msg(2, 0, null, q))
    override _.Post(c) = inbox.Post(Msg(3, 0, c, null))
