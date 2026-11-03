module Engine.Commit

// Group commit (README rule 6 allows it: each response waits for its own commit). Every write
// queues here instead of committing alone. A writer lane takes everything that queued while its
// previous group was in flight, up to a cap, and sends it as ONE NpgsqlBatch: one round trip, and
// one implicit transaction that ends at the batch's Sync, so the whole group shares one commit
// and one WAL flush. Nobody is answered before that commit. With no load a group is one write,
// which is exactly the old one-commit-per-write; under load the groups grow by themselves.
//
// Nothing slow ever enters a group: a write arrives with its SQL and parameters complete (a
// password is bcrypt-hashed BEFORE it is queued, on the bcrypt lanes), so a lane only ever
// waits on Postgres, and one slow request can never hold up everyone else's commit.

open System
open System.Data
open System.Threading
open System.Threading.Channels
open System.Threading.Tasks
open Npgsql
open NpgsqlTypes
open Npgsql.FSharp

/// One SQL statement and its parameters, spelled as for Npgsql.FSharp.
type Statement = string * (string * SqlValue) list

/// A write waiting for its group. Its statements run in order and yield exactly ONE result set
/// between them: Npgsql skips statements that have none, so the last statement returns the rows
/// (a SELECT, or RETURNING) and the ones before it must not.
type private IWrite =
    abstract Statements: Statement list
    /// Stopwatch timestamp of its arrival in the queue.
    abstract Arrived: int64
    /// The request's trace, or null (Db.Trace).
    abstract Trace: Db.Trace
    /// Reads this write's result set; the reader is positioned on it.
    abstract Read: NpgsqlDataReader -> Task
    /// The group committed: hand the rows to the caller.
    abstract Committed: unit -> unit
    abstract Failed: exn -> unit

[<Sealed>]
type private Pending<'r>(statements: Statement list, read: RowReader -> 'r) =
    let reply = TaskCompletionSource<'r list>(TaskCreationOptions.RunContinuationsAsynchronously)
    let mutable rows: 'r list = []
    let arrived = Diagnostics.Stopwatch.GetTimestamp()
    let trace = Db.Trace.Current.Value
    member _.Task = reply.Task

    interface IWrite with
        member _.Statements = statements
        member _.Arrived = arrived
        member _.Trace = trace

        member _.Read reader =
            task {
                let row = RowReader reader
                let acc = ResizeArray()
                while! reader.ReadAsync() do
                    acc.Add(read row)
                rows <- List.ofSeq acc
            }

        member _.Committed() = reply.TrySetResult rows |> ignore
        member _.Failed e = reply.TrySetException e |> ignore

/// The SqlValue cases the Engine's writes use.
let private parameter (name: string, value: SqlValue) : NpgsqlParameter =
    match value with
    | SqlValue.Null -> NpgsqlParameter(name, DBNull.Value)
    | SqlValue.Long v -> NpgsqlParameter<int64>(name, v)
    | SqlValue.String v -> NpgsqlParameter<string>(name, NpgsqlDbType.Text, TypedValue = v)
    | SqlValue.StringArray v -> NpgsqlParameter<string[]>(name, NpgsqlDbType.Array ||| NpgsqlDbType.Text, TypedValue = v)
    | other -> invalidArg name $"Commit: no mapping for {other}"

/// One group, one batch, one transaction. Returns only after the commit.
let private execute (conn: NpgsqlConnection) (group: IWrite list) : Task =
    task {
        use batch = new NpgsqlBatch(conn)
        for w in group do
            for sql, parameters in w.Statements do
                let command = NpgsqlBatchCommand sql
                for p in parameters do
                    command.Parameters.Add(parameter p) |> ignore
                batch.BatchCommands.Add command
        use! reader = batch.ExecuteReaderAsync()
        let mutable first = true
        for w in group do
            if not first then
                let! more = reader.NextResultAsync()
                if not more then invalidOp "Commit: a write produced no result set"
            first <- false
            do! w.Read reader
        // Closing reads on to ReadyForQuery, which comes after the Sync's COMMIT: only now is
        // the group durable, and only now does anyone hear back.
        do! reader.CloseAsync()
    }

/// The process's write side: `lanes` dedicated connections (not multiplexed: a batch's implicit
/// transaction needs a connection of its own), each committing one group at a time.
[<Sealed>]
type Writer(connectionString: string, lanes: int, maxGroup: int, minGroup: int, gather: TimeSpan) =
    let queue =
        // Never SingleReader, even with one lane: a single-reader channel cannot report its length
        // (Depth), which the diagnostics read.
        Channel.CreateUnbounded<IWrite>(UnboundedChannelOptions(SingleReader = false, SingleWriter = false))
    let ds = NpgsqlDataSource.Create connectionString
    let counts = [| 0L; 0L; 0L; 0L; 0L |] // groups, writes, groups refused and rerun alone, writes failed alone, Stopwatch ticks executing
    let queued = Db.Millis() // per write: arrived -> taken into a group
    let executed = Db.Millis() // per group: taken -> committed (or failed)
    let answered = Db.Millis() // per write: arrived -> committed (or failed)

    let take (into: ResizeArray<IWrite>) =
        let mutable w = Unchecked.defaultof<IWrite>
        while into.Count < maxGroup && queue.Reader.TryRead(&w) do
            into.Add w

    let alone (conn: NpgsqlConnection) (w: IWrite) : Task =
        task {
            try
                do! execute conn [ w ]
                w.Committed()
            with e ->
                Interlocked.Increment(&counts[3]) |> ignore
                w.Failed e
        }

    let commit (conn: NpgsqlConnection) (group: IWrite list) : Task =
        task {
            try
                do! execute conn group
                for w in group do
                    w.Committed()
            with
            | :? PostgresException when group.Length > 1 && conn.State = ConnectionState.Open ->
                // The server refused one statement (a UNIQUE name, a deadlock) and rolled the
                // whole group back, so none of it happened: each write runs again in its own
                // transaction and meets its own fate.
                Interlocked.Increment(&counts[2]) |> ignore
                for w in group do
                    do! alone conn w
            | e ->
                // A lone write the server refused, or not the server's verdict (a broken
                // connection): whether the group committed is unknown, so it is not retried;
                // its writes fail.
                if e :? PostgresException then Interlocked.Increment(&counts[3]) |> ignore
                for w in group do
                    w.Failed e
        }

    let lane () : Task =
        task {
            let mutable conn: NpgsqlConnection = null
            let group = ResizeArray<IWrite>(maxGroup)
            while! queue.Reader.WaitToReadAsync() do
                take group
                // A small group waits for company: until it holds `minGroup` writes or its oldest
                // has waited `gather`, whichever comes first. Without it, a lane that wakes for the
                // first write while the other lane commits takes that write nearly alone, and the
                // lanes split the stream into groups of 2-6, a commit and a WAL flush each.
                // (Ticks, not TimeSpan's `>`: F#'s generic comparison boxes structs.)
                let mutable waiting = gather.Ticks > 0L && group.Count > 0
                while waiting && group.Count < minGroup do
                    let left = gather - Diagnostics.Stopwatch.GetElapsedTime group[0].Arrived
                    if left.Ticks > 0L then
                        do! Task.Delay left
                        take group
                    else
                        waiting <- false
                if group.Count > 0 then
                    let writes = List.ofSeq group
                    group.Clear()
                    let taken = Diagnostics.Stopwatch.GetTimestamp()
                    for w in writes do
                        queued.Record(Diagnostics.Stopwatch.GetElapsedTime(w.Arrived, taken))
                        if not (isNull w.Trace) then w.Trace.WriteQueued <- taken - w.Arrived
                    try
                        if isNull conn || conn.State <> ConnectionState.Open then
                            if not (isNull conn) then conn.Dispose()
                            conn <- null
                            let! c = ds.OpenConnectionAsync()
                            conn <- c
                        do! commit conn writes
                    with e ->
                        for w in writes do
                            w.Failed e
                    let finished = Diagnostics.Stopwatch.GetTimestamp()
                    executed.Record(Diagnostics.Stopwatch.GetElapsedTime(taken, finished))
                    Interlocked.Add(&counts[4], finished - taken) |> ignore
                    for w in writes do
                        answered.Record(Diagnostics.Stopwatch.GetElapsedTime(w.Arrived, finished))
                        if not (isNull w.Trace) then w.Trace.WriteExecuted <- finished - taken
                    Interlocked.Increment(&counts[0]) |> ignore
                    Interlocked.Add(&counts[1], int64 writes.Length) |> ignore
        }

    do
        for _ in 1..lanes do
            Task.Run<unit>(fun () -> task { do! lane () }) |> ignore

    /// Queues one write; the task completes after its group commits, with the rows of its
    /// result set (see IWrite for the one-result-set rule).
    member _.Run(statements: Statement list, read: RowReader -> 'r) : Task<'r list> =
        let p = Pending<'r>(statements, read)
        if queue.Writer.TryWrite p then p.Task else Task.FromException<'r list>(InvalidOperationException "Commit: closed")

    /// (groups, writes) so far. A group that the server refused and that ran again write by
    /// write still counts once.
    member _.Counts = Volatile.Read(&counts[0]), Volatile.Read(&counts[1])

    /// Stopwatch ticks the lanes have spent executing groups, all lanes together: its growth over
    /// a span, divided by the span and the lane count, is how busy the write lanes were.
    member _.BusyTicks = Volatile.Read(&counts[4])

    /// (groups the server refused and that ran again write by write, writes that then failed alone).
    member _.Refusals = Volatile.Read(&counts[2]), Volatile.Read(&counts[3])

    /// p50/p95/p99 of: a write's wait for its group, a group's execution (one round trip and its
    /// commit), a write's whole time in Commit.
    member _.Timings = queued.Summary(), executed.Summary(), answered.Summary()

    /// Writes queued and not yet taken into a group.
    member _.Depth = queue.Reader.Count
