module Engine.Reads

// Read batching, the read-side twin of Commit. Every hot read queues here. A reader lane takes
// everything that queued while its previous batch was in flight, up to a cap, groups it by kind,
// and sends ONE NpgsqlBatch with ONE statement per kind: that statement answers every request of
// its kind at once (array parameters in, each row tagged with `k`, the request it belongs to).
// Inside a statement the viewer-independent work (an article's columns, tags and favorite count,
// a comment thread, a page of ids, a list's count) is done once per distinct key, and only the
// viewer's own flags (favorited, following) are per request. No timer: with no load a batch is
// one request; under load the batches grow by themselves and each request costs Postgres less.
//
// Not a cache: every request is answered by a statement that started after it arrived, and
// nothing outlives its batch (README rule 5).

open System.Collections.Generic
open System.Data
open System.Threading
open System.Threading.Channels
open System.Threading.Tasks
open Npgsql
open NpgsqlTypes
open Npgsql.FSharp

/// A text[] parameter: one element per request, in batch order.
let texts (name: string) (values: string[]) : NpgsqlParameter =
    NpgsqlParameter<string[]>(name, NpgsqlDbType.Array ||| NpgsqlDbType.Text, TypedValue = values)

/// An int8[] parameter: one element per request, in batch order.
let int64s (name: string) (values: int64[]) : NpgsqlParameter =
    NpgsqlParameter<int64[]>(name, NpgsqlDbType.Array ||| NpgsqlDbType.Bigint, TypedValue = values)

type internal IRead =
    abstract Kind: IKind
    abstract Fail: exn -> unit

and internal IKind =
    /// The one statement for these requests (all of this kind, in arrival order).
    abstract Command: IRead[] -> NpgsqlBatchCommand
    /// Reads the statement's result set and answers each request.
    abstract Answer: NpgsqlDataReader * IRead[] -> Task

[<Sealed>]
type internal Pending<'q, 'r>(kind: IKind, arg: 'q) =
    let reply = TaskCompletionSource<'r>(TaskCreationOptions.RunContinuationsAsynchronously)
    member _.Arg = arg
    member _.Task = reply.Task
    member _.Answer(result: 'r) = reply.TrySetResult result |> ignore

    interface IRead with
        member _.Kind = kind
        member _.Fail e = reply.TrySetException e |> ignore

/// One kind of read, with two statements that return the same columns:
/// - `batched` answers several requests at once. It takes them through `parameters` (arrays,
///   request i at index i) and tags every row with `k` = i + 1, in the order that request needs
///   its rows.
/// - `single` answers one request (`parameter`), untagged. A kind with ONE request in a batch
///   uses it: the batched statement's sharing machinery (unnest, materialized CTEs, DISTINCT,
///   the joins back to the requests) only pays for itself when there is something to share.
/// `answer` turns one request's rows into its result. A `shared` kind's `single` statement does
/// not depend on the request: it runs once and every request of the batch gets all its rows.
[<Sealed>]
type Kind<'q, 'row, 'r>
    (
        batched: string,
        parameters: 'q[] -> NpgsqlParameter list,
        single: string,
        parameter: 'q -> NpgsqlParameter list,
        row: RowReader -> 'row,
        answer: 'q -> 'row list -> 'r,
        shared: bool
    ) =

    let finish (p: Pending<'q, 'r>) (rows: 'row list) =
        try
            p.Answer(answer p.Arg rows)
        with e ->
            (p :> IRead).Fail e

    let untagged (reads: IRead[]) = shared || reads.Length = 1

    new(batched, parameters, single, parameter, row, answer) =
        Kind(batched, parameters, single, parameter, row, answer, false)

    interface IKind with
        member _.Command reads =
            let pending = reads |> Array.map (fun r -> r :?> Pending<'q, 'r>)
            if shared then
                NpgsqlBatchCommand single
            elif untagged reads then
                let command = NpgsqlBatchCommand single
                for p in parameter pending[0].Arg do
                    command.Parameters.Add p |> ignore
                command
            else
                let command = NpgsqlBatchCommand batched
                for p in parameters (pending |> Array.map _.Arg) do
                    command.Parameters.Add p |> ignore
                command

        member _.Answer(reader, reads) =
            task {
                let read = RowReader reader
                if untagged reads then
                    let rows = ResizeArray()
                    while! reader.ReadAsync() do
                        rows.Add(row read)
                    let rows = List.ofSeq rows
                    for r in reads do
                        finish (r :?> Pending<'q, 'r>) rows
                else
                    let k = reader.GetOrdinal "k"
                    let buckets = Array.init reads.Length (fun _ -> ResizeArray<'row>())
                    while! reader.ReadAsync() do
                        buckets[int (reader.GetInt64 k) - 1].Add(row read)
                    for i in 0 .. reads.Length - 1 do
                        finish (reads[i] :?> Pending<'q, 'r>) (List.ofSeq buckets[i])
            }

/// A kind whose one result is everyone's: one statement, no parameters, no `k`.
let shared (sql: string) (row: RowReader -> 'row) (answer: 'row list -> 'r) : Kind<unit, 'row, 'r> =
    Kind<unit, 'row, 'r>(sql, (fun _ -> []), sql, (fun _ -> []), row, (fun () rows -> answer rows), true)

/// A text parameter for a single statement.
let text (name: string) (value: string) : NpgsqlParameter =
    NpgsqlParameter<string>(name, NpgsqlDbType.Text, TypedValue = value)

/// An int8 parameter for a single statement.
let long (name: string) (value: int64) : NpgsqlParameter = NpgsqlParameter<int64>(name, value)

/// One batch: one statement per kind, one round trip.
let private execute (conn: NpgsqlConnection) (statements: (IKind * IRead[]) list) : Task =
    task {
        use batch = new NpgsqlBatch(conn)
        for kind, reads in statements do
            batch.BatchCommands.Add(kind.Command reads)
        use! reader = batch.ExecuteReaderAsync()
        let mutable first = true
        for kind, reads in statements do
            if not first then
                let! more = reader.NextResultAsync()
                if not more then invalidOp "Reads: a statement produced no result set"
            first <- false
            do! kind.Answer(reader, reads)
    }

/// The hot reads' side of the process: `lanes` dedicated connections (not multiplexed: a batch
/// needs a connection of its own), each running one batch at a time.
[<Sealed>]
type Gather(connectionString: string, lanes: int, maxBatch: int) =
    let queue =
        Channel.CreateUnbounded<IRead>(UnboundedChannelOptions(SingleReader = (lanes = 1), SingleWriter = false))
    let ds = NpgsqlDataSource.Create connectionString
    let counts = [| 0L; 0L; 0L |] // batches, statements, requests

    let take (into: ResizeArray<IRead>) =
        let mutable r = Unchecked.defaultof<IRead>
        while into.Count < maxBatch && queue.Reader.TryRead(&r) do
            into.Add r

    /// The batch's requests grouped by kind, kinds in order of first arrival.
    let byKind (reads: ResizeArray<IRead>) : (IKind * IRead[]) list =
        let groups = Dictionary<IKind, ResizeArray<IRead>>(HashIdentity.Reference)
        let order = ResizeArray<IKind>()
        for r in reads do
            match groups.TryGetValue r.Kind with
            | true, g -> g.Add r
            | _ ->
                groups[r.Kind] <- ResizeArray [ r ]
                order.Add r.Kind
        [ for kind in order -> kind, groups[kind].ToArray() ]

    let run (conn: NpgsqlConnection) (statements: (IKind * IRead[]) list) : Task =
        task {
            try
                do! execute conn statements
            with
            | :? PostgresException when statements.Length > 1 && conn.State = ConnectionState.Open ->
                // One statement failed and took the batch's later ones with it: each kind runs
                // again alone (those already answered ignore a second answer).
                for statement in statements do
                    try
                        do! execute conn [ statement ]
                    with e ->
                        for r in snd statement do
                            r.Fail e
            | e ->
                for _, reads in statements do
                    for r in reads do
                        r.Fail e
        }

    let lane () : Task =
        task {
            let mutable conn: NpgsqlConnection = null
            let batch = ResizeArray<IRead>(maxBatch)
            while! queue.Reader.WaitToReadAsync() do
                take batch
                if batch.Count > 0 then
                    let statements = byKind batch
                    let requests = batch.Count
                    batch.Clear()
                    try
                        if isNull conn || conn.State <> ConnectionState.Open then
                            if not (isNull conn) then conn.Dispose()
                            conn <- null
                            let! c = ds.OpenConnectionAsync()
                            conn <- c
                        do! run conn statements
                    with e ->
                        for _, reads in statements do
                            for r in reads do
                                r.Fail e
                    Interlocked.Increment(&counts[0]) |> ignore
                    Interlocked.Add(&counts[1], int64 statements.Length) |> ignore
                    Interlocked.Add(&counts[2], int64 requests) |> ignore
        }

    do
        for _ in 1..lanes do
            Task.Run<unit>(fun () -> task { do! lane () }) |> ignore

    /// Queues one read of `kind`; the task completes when its batch has been read.
    member _.Run(kind: Kind<'q, 'row, 'r>, arg: 'q) : Task<'r> =
        let p = Pending<'q, 'r>(kind, arg)
        if queue.Writer.TryWrite p then
            p.Task
        else
            Task.FromException<'r>(System.InvalidOperationException "Reads: closed")

    /// (batches, statements, requests) so far.
    member _.Counts = Volatile.Read(&counts[0]), Volatile.Read(&counts[1]), Volatile.Read(&counts[2])
