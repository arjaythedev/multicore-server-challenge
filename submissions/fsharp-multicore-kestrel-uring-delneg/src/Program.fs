module Program

open System
open System.Net
open System.Threading
open System.Threading.Tasks
open Microsoft.AspNetCore.Builder
open Microsoft.AspNetCore.Connections
open Microsoft.AspNetCore.Hosting
open Microsoft.AspNetCore.Hosting.Server
open Microsoft.Extensions.DependencyInjection

let env name fallback =
    match Environment.GetEnvironmentVariable name with
    | null
    | "" -> fallback
    | v -> v

let envNum name (fallback: int) = int (env name (string fallback))

/// Kestrel needs an IHttpApplication to start; the io_uring loops answer every request themselves, so Kestrel's
/// HTTP layer never runs.
type private Unused() =
    interface IHttpApplication<obj> with
        member _.CreateContext(_) = null
        member _.ProcessRequestAsync(_) = Task.CompletedTask
        member _.DisposeContext(_, _) = ()

let private codePoint (c: string) =
    c = "C" || c = "POSIX" || c.StartsWith("C.", StringComparison.OrdinalIgnoreCase)

[<EntryPoint>]
let main _ =
    let url = env "DATABASE_URL" "postgres://conduit:conduit@127.0.0.1:5432/conduit"
    // Session settings only (rule 3). Generic plans: custom planning costs as much as running these statements.
    // No JIT, no parallel workers for short OLTP queries. No Memoize: in a batched statement it could hand one
    // request a row another request's lookup fetched (#22).
    let options =
        env "DB_OPTIONS" "-c plan_cache_mode=force_generic_plan -c jit=off -c max_parallel_workers_per_gather=0 -c enable_memoize=off"
    // The collation decides whether tag lists are sorted by Postgres or by us (#22, #59), and so the SQL text.
    let col = Pg.queryOnce url "" Sql.Collation
    Json.appSortsTags <-
        match col.[0] with
        | "c" -> codePoint col.[1] // libc
        | "b" -> codePoint col.[2] // builtin C / C.UTF-8
        | _ -> false // ICU: Postgres sorts
    Sql.define ()
    // experiments: write the batched statements out (for replays) and stop
    match Environment.GetEnvironmentVariable "MC_DUMP_SQL" with
    | null
    | "" -> ()
    | path ->
        let sb = Text.StringBuilder()
        for k in Sql.kinds do
            sb.Append("-- ").Append(k.Name).Append('\n').Append(k.Stmt.Sql).Append("\n\n") |> ignore
            if not (isNull k.Shared) then
                sb.Append("-- ").Append(k.Name).Append(" shared\n").Append(k.Shared.Sql).Append("\n\n") |> ignore
            if not (isNull k.Packed) then
                sb.Append("-- ").Append(k.Name).Append(" packed\n").Append(k.Packed.Sql).Append("\n\n") |> ignore
        IO.File.WriteAllText(path, sb.ToString())
        exit 0
    let batch = envNum "BATCH_MAX" 64
    let inflight = envNum "BATCH_INFLIGHT" 6
    // packed lists pay off from these batch sizes (replay: global list from 4, the others from 8-16)
    let packedMin = envNum "PACKED_MIN" 8
    for k in Sql.kinds do
        k.MaxBatch <- batch
        k.MaxInflight <- inflight
        k.PackedMin <- packedMin
        match Environment.GetEnvironmentVariable("BATCH_" + k.Name.ToUpperInvariant()) with
        | null
        | "" -> ()
        | s ->
            let p = s.Split ':'
            k.MaxBatch <- int p.[0]
            if p.Length > 1 then k.MaxInflight <- int p.[1]
    Sql.ListAll.PackedMin <- envNum "LIST_PACKED_MIN" 4
    Jwt.init (env "JWT_SECRET" "multicore-server-challenge")
    Bcrypt.selfTest ()
    Bcrypt.init (envNum "BCRYPT_THREADS" 2) (envNum "BCRYPT_WAIT_MS" 150) (envNum "BCRYPT_IDLE_WAIT_MS" 150) (envNum "BCRYPT_HELP_AT" 4) (envNum "BCRYPT_LANES" 5)
    Ctx.HttpDate.keep ()
    let reads = envNum "DB_CONNS" 6
    let writes = envNum "DB_WRITE_CONNS" 8
    Ctx.Backend.Current <-
        Db.PgThread(
            { Url = url
              PgOptions = options
              Reads = reads
              Writes = writes
              Depth = envNum "DISPATCH_DEPTH" 1
              WaitUs = envNum "BATCH_WAIT_US" 20000 }
        )
    Http.loopCount <- envNum "LOOPS" 2

    let builder = WebApplication.CreateEmptyBuilder(WebApplicationOptions())
    builder.WebHost.UseKestrelCore() |> ignore
    builder.Services.AddSingleton<IConnectionListenerFactory, Http.UringTransportFactory>() |> ignore
    let host = env "HOST" "127.0.0.1"
    let port = envNum "PORT" 3000
    builder.WebHost.ConfigureKestrel(fun o ->
        o.AddServerHeader <- false
        o.Listen(IPAddress.Parse host, port))
    |> ignore
    let app = builder.Build()
    let server = app.Services.GetRequiredService<IServer>()
    server.StartAsync(Unused(), CancellationToken.None).GetAwaiter().GetResult()
    eprintfn "conduit on %s:%d: %d io_uring loops, postgres %d read + %d write connections, batches %d:%d, tags sorted by %s"
        host port Http.loopCount reads writes batch inflight (if Json.appSortsTags then "app" else "postgres")
    Thread.Sleep Timeout.Infinite
    0
