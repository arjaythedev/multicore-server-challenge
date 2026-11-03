module Engine.Db

open System
open System.Threading
open Npgsql

/// Session settings sent with each login (not server config; PG_OPTIONS replaces them, to compare).
/// A batch's statement looks costly to the planner (it cannot see how few rows a CTE or an
/// unnested array holds), so with the box's defaults it would:
/// - JIT compile it: ~400 ms of a 1 ms query (`jit=off`);
/// - start parallel workers for it, since the box sets max_parallel_workers_per_gather = 4;
/// - re-plan it on most executions: with array parameters each custom plan looks different, so
///   `auto` keeps choosing custom plans (`plan_cache_mode=force_generic_plan`);
/// - memoize the inner side of a LATERAL whose keys are already distinct (`enable_memoize=off`).
/// The last three as in csharp-epoll-aot-gichamba; java-raw-stohirov sends the first three.
let sessionOptions =
    "-c jit=off -c plan_cache_mode=force_generic_plan -c max_parallel_workers_per_gather=0 -c enable_memoize=off"

/// DATABASE_URL (`postgres://user:pass@host:port/db`) as an Npgsql connection string.
///
/// One pool for the process, MULTIPLEXED: a request borrows no physical connection for its
/// lifetime, its statements are queued and written to whichever connection is free, so a few
/// connections carry thousands of concurrent requests without a pool wait. Statements are
/// auto-prepared (server-side plans are cached per connection; rule 5 allows that).
/// `multiplexed` false is for Commit's writer lanes, whose batches each need a connection.
let connectionString (url: string) (poolSize: int) (multiplexed: bool) : string =
    let uri = Uri url
    let user, password =
        match uri.UserInfo.Split(':', 2) with
        | [| u; p |] -> Uri.UnescapeDataString u, Uri.UnescapeDataString p
        | [| u |] -> Uri.UnescapeDataString u, ""
        | _ -> "", ""
    let b = NpgsqlConnectionStringBuilder()
    b.Host <- uri.Host
    b.Port <- (if uri.Port > 0 then uri.Port else 5432)
    b.Username <- user
    if password <> "" then b.Password <- password
    b.Database <- Uri.UnescapeDataString(uri.AbsolutePath.TrimStart '/')
    b.SslMode <- SslMode.Disable
    b.Pooling <- true
    b.MaxPoolSize <- poolSize
    b.MinPoolSize <- 0
    b.Multiplexing <- multiplexed
    // The lanes' own connections: no command timeout, because with one Npgsql arms a timer
    // (a CancellationTokenSource) around every buffer read, and those timers contend on a lock.
    if not multiplexed then b.CommandTimeout <- 0
    b.NoResetOnClose <- true
    b.Enlist <- false
    b.MaxAutoPrepare <- 64
    b.AutoPrepareMinUsages <- 2
    b.ApplicationName <- "conduit-fsharp"
    b.Options <-
        match Environment.GetEnvironmentVariable "PG_OPTIONS" with
        | null -> sessionOptions
        | o -> o
    b.ConnectionString

let dataSource (connectionString: string) : NpgsqlDataSource = NpgsqlDataSource.Create connectionString

/// SQLSTATE 23505, wherever the driver put it in the exception chain.
let rec isUniqueViolation (e: exn) : bool =
    match e with
    | :? PostgresException as p -> p.SqlState = PostgresErrorCodes.UniqueViolation
    | :? AggregateException as a -> a.InnerExceptions |> Seq.exists isUniqueViolation
    | null -> false
    | e -> isUniqueViolation e.InnerException

/// Durations in 1 ms buckets (the last bucket holds everything from 2 s up), for the shutdown
/// lines: cheap enough to record every request.
[<Sealed>]
type Millis() =
    let buckets: int64[] = Array.zeroCreate 2001
    let micros = [| 0L |] // the exact sum, for the mean (phases' means add up; percentiles do not)

    member _.Record(elapsed: TimeSpan) =
        let ms = int elapsed.TotalMilliseconds
        Interlocked.Increment(&buckets[if ms < 0 then 0 elif ms > 2000 then 2000 else ms]) |> ignore
        Interlocked.Add(&micros[0], int64 elapsed.TotalMicroseconds) |> ignore

    member _.Count = Array.sum buckets

    member this.Mean =
        let n = this.Count
        if n = 0L then 0.0 else float (Volatile.Read &micros[0]) / 1000.0 / float n

    /// "p50/p95/p99 ms (mean m)", or "-" before anything was recorded.
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
            $"{at 0.5}/{at 0.95}/{at 0.99} ms (mean %.1f{float (Volatile.Read &micros[0]) / 1000.0 / float total})"

/// One request's time in the lanes, in Stopwatch ticks, filled in by the lanes it used. Only when
/// TRACE_FILE is set: the web layer puts one in `Current` for each request, and a lane's pending
/// entry captures it when queued (AsyncLocal flows into the handler's awaits). Null otherwise.
[<Sealed; AllowNullLiteral>]
type Trace() =
    member val ReadQueued = 0L with get, set
    member val ReadExecuted = 0L with get, set
    member val WriteQueued = 0L with get, set
    member val WriteExecuted = 0L with get, set
    static member val Current = AsyncLocal<Trace>()
