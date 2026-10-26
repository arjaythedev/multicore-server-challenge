/// The Postgres side: ONE thread owns every Postgres connection in its own io_uring ring, and the batch queues
/// shared by all I/O loops (one queue per kind for the whole box: a bigger drain shares more work, #79, #82, #22).
///
/// Batching (#22's policy, no timer): read requests wait in their kind's queue until a read connection has room
/// (fewer than Depth statements in Postgres); then the kind whose oldest request has waited longest sends what it
/// has queued (up to MaxBatch) as ONE statement. At low load every batch has one request; under load requests stay
/// queued until a backend is free, so batches grow. A kind holds at most MaxInflight connections.
/// Writes go to their own connections (a read never waits behind a commit), to the one with the fewest in flight.
module Db

open System
open System.Collections.Generic
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

/// One batched statement: the requests of one kind, their parameters as arrays.
[<Sealed; AllowNullLiteral>]
type BatchQuery(k: Sql.Kind, release: BatchQuery -> unit) =
    inherit PgQuery()
    let items = Array.zeroCreate<Ctx> k.MaxBatch
    let finished = Array.zeroCreate<Ctx> k.MaxBatch
    member val N = 0 with get, set
    member _.Items = items
    member _.Kind = k
    override b.Write(w) =
        let n = b.N
        w.Bind k.Stmt
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
        if l = Sql.Layout.ViewerKey || l = Sql.Layout.ListKey then
            w.BeginArray Oid.Text
            for i in 0 .. n - 1 do w.Text items.[i].Key
            w.EndArray n
        w.EndBind()
        w.Sync()
    override b.Row(_, row) =
        let i = row.Int4 0
        if uint32 i < uint32 b.N then Handlers.batchRow items.[i] row
    override b.Done(err) =
        let n = b.N
        Array.Copy(items, finished, n)
        Array.Clear(items, 0, n)
        b.N <- 0
        release b // the kind's next batch may go out before these responses are written
        for i in 0 .. n - 1 do
            let c = finished.[i]
            finished.[i] <- null
            try Handlers.batchDone c err
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
      Depth: int }

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
    let mutable seq = 0L
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
    let mutable stLast = Environment.TickCount64

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
    member private _.Pump() =
        needPump <- false
        let mutable go = true
        while go do
            let mutable best = -1
            let mutable oldest = Int64.MaxValue
            for k in 0 .. kinds.Length - 1 do
                let p = pending.[k]
                if p.Count > 0 && inflight.[k] < kinds.[k].MaxInflight then
                    let t = p.Peek().Queued
                    if t < oldest then
                        oldest <- t
                        best <- k
            if best < 0 then go <- false
            else
                let mutable conn: PgConn = null
                for c in reads do
                    if not c.Broken && c.Inflight < o.Depth && (isNull conn || c.Inflight < conn.Inflight) then conn <- c
                if isNull conn then go <- false
                else
                    let kind = kinds.[best]
                    let b = if free.[best].Count > 0 then free.[best].Pop() else BatchQuery(kind, releaseBatch)
                    let p = pending.[best]
                    let n = min p.Count kind.MaxBatch
                    for i in 0 .. n - 1 do b.Items.[i] <- p.Dequeue()
                    b.N <- n
                    inflight.[best] <- inflight.[best] + 1
                    if stats then
                        stBatches <- stBatches + 1L
                        stItems <- stItems + int64 n
                    conn.Submit b |> ignore

    member private this.Drain() =
        let mutable m = Unchecked.defaultof<Msg>
        while inbox.TryTake(&m) do
            match m.Op with
            | 0 ->
                m.C.Queued <- seq
                seq <- seq + 1L
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
            while true do
                ring.Enter(1u, 0L) |> ignore
                cqes.Clear()
                ring.Reap(cqes, Int32.MaxValue) |> ignore
                for i in 0 .. cqes.Count - 1 do
                    try this.Handle cqes.[i] with e -> eprintfn "%O" e
                (try this.Drain() with e -> eprintfn "%O" e)
                if needPump then (try this.Pump() with e -> eprintfn "%O" e)
                this.Flush()
                if stats && Environment.TickCount64 - stLast > 5000L then
                    stLast <- Environment.TickCount64
                    let q = pending |> Array.sumBy (fun p -> p.Count)
                    eprintfn "pg batches=%d items=%d avg=%.1f queued=%d inflight=%s" stBatches stItems
                        (if stBatches > 0L then float stItems / float stBatches else 0.0) q
                        (String.Join(",", conns |> Seq.map (fun c -> string c.Inflight)))
                    stBatches <- 0L
                    stItems <- 0L

    override _.Enqueue(c, kind) = inbox.Post(Msg(0, kind.Id, c, null))
    override _.Read(q) = inbox.Post(Msg(1, 0, null, q))
    override _.Write(q) = inbox.Post(Msg(2, 0, null, q))
    override _.Post(c) = inbox.Post(Msg(3, 0, c, null))
