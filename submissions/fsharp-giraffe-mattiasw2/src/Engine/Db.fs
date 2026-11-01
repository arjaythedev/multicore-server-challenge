module Engine.Db

open System
open Npgsql

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
    // Session setting, not server config: a batch's statement looks costly to the planner (it
    // cannot see how few rows a CTE holds), which crosses jit_above_cost, and compiling then
    // takes ~400 ms of a 1 ms query.
    b.Options <- "-c jit=off"
    b.ConnectionString

let dataSource (connectionString: string) : NpgsqlDataSource = NpgsqlDataSource.Create connectionString

/// SQLSTATE 23505, wherever the driver put it in the exception chain.
let rec isUniqueViolation (e: exn) : bool =
    match e with
    | :? PostgresException as p -> p.SqlState = PostgresErrorCodes.UniqueViolation
    | :? AggregateException as a -> a.InnerExceptions |> Seq.exists isUniqueViolation
    | null -> false
    | e -> isUniqueViolation e.InnerException
