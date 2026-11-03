module Web.Program

// Giraffe on Kestrel (the sss8 pattern): a thin route table over Engine. Configured only by the
// runtime contract's environment variables (SPEC.md), plus optional tuning knobs.

open System
open System.Net
open System.Threading.Tasks
open Microsoft.AspNetCore.Builder
open Microsoft.AspNetCore.Hosting
open Microsoft.AspNetCore.Http
open Microsoft.AspNetCore.Server.Kestrel.Core
open Microsoft.Extensions.DependencyInjection
open Microsoft.Extensions.Logging
open Giraffe
open Giraffe.EndpointRouting

let endpoints (env: Handlers.Env) : Endpoint list =
    [ GET
          [ route "/api/tags" (Handlers.tags env)
            route "/api/user" (Handlers.currentUser env)
            routef "/api/profiles/%s" (Handlers.profile env)
            route "/api/articles" (Handlers.listArticles env)
            route "/api/articles/feed" (Handlers.feed env)
            routef "/api/articles/%s" (Handlers.article env)
            routef "/api/articles/%s/comments" (Handlers.comments env) ]
      POST
          [ route "/api/users" (Handlers.register env)
            route "/api/users/login" (Handlers.login env)
            routef "/api/profiles/%s/follow" (Handlers.follow env true)
            route "/api/articles" (Handlers.createArticle env)
            routef "/api/articles/%s/favorite" (Handlers.favorite env true)
            routef "/api/articles/%s/comments" (Handlers.addComment env) ]
      PUT
          [ route "/api/user" (Handlers.updateUser env)
            routef "/api/articles/%s" (Handlers.updateArticle env) ]
      DELETE
          [ routef "/api/profiles/%s/follow" (Handlers.follow env false)
            routef "/api/articles/%s" (Handlers.deleteArticle env)
            routef "/api/articles/%s/favorite" (Handlers.favorite env false)
            routef "/api/articles/%s/comments/%s" (Handlers.deleteComment env) ] ]

let private setting (name: string) (fallback: string) =
    match Environment.GetEnvironmentVariable name with
    | null
    | "" -> fallback
    | v -> v

let private required (name: string) =
    match Environment.GetEnvironmentVariable name with
    | null
    | "" -> failwith $"{name} is not set"
    | v -> v

/// A JSON body (`{"errors": ...}`) on whatever the handlers did not answer.
let private writeError (ctx: HttpContext) (status: int) (message: string) : Task =
    if ctx.Response.HasStarted then
        Task.CompletedTask
    else
        let body = Wire.error message
        task {
            try
                ctx.Response.StatusCode <- status
                ctx.Response.ContentType <- "application/json"
                ctx.Response.ContentLength <- int64 body.Length
                do! ctx.Response.Body.WriteAsync(body.Memory)
            finally
                body.Release()
        }

[<EntryPoint>]
let main args =
    let cores = Environment.ProcessorCount
    let databaseUrl = required "DATABASE_URL"
    let secret = required "JWT_SECRET"
    let host = setting "HOST" "127.0.0.1"
    let port = int (setting "PORT" "3000")
    // Group commit: WRITE_LANES connections of their own, each committing one group of up to
    // WRITE_GROUP writes at a time.
    let writeLanes = max 1 (int (setting "WRITE_LANES" "2"))
    let writeGroup = max 1 (int (setting "WRITE_GROUP" "128"))
    // Read batching: READ_LANES connections of their own, each running one batch of up to
    // READ_BATCH requests at a time. One busy backend per core.
    let readLanes = max 1 (int (setting "READ_LANES" (string cores)))
    let readBatch = max 1 (int (setting "READ_BATCH" "512"))
    let readGather = TimeSpan.FromMilliseconds(float (setting "READ_GATHER_MS" "25"))
    // Multiplexed: the cold reads (sign-in lookups, the read after a write). Rule: 95 or fewer
    // connections in total, lanes included.
    let poolSize = min (95 - writeLanes - readLanes) (int (setting "DB_POOL_SIZE" (string (max 2 (cores / 2)))))
    // Two threads, each computing up to four hashes in lockstep (~50 a second), cover a login
    // rate far above this workload's; fewer threads also fill the lockstep batches.
    let bcryptLanes = max 1 (int (setting "BCRYPT_THREADS" "2"))
    // Each bcrypt thread computes up to BCRYPT_WIDTH hashes in lockstep, letting the first wait
    // up to BCRYPT_GATHER_MS for batch-mates.
    let bcryptWidth = max 1 (int (setting "BCRYPT_WIDTH" "4"))
    // Logins are ~0.1% of the requests, so waiting for batch-mates barely touches p95 or p99.
    let bcryptGather = TimeSpan.FromMilliseconds(float (setting "BCRYPT_GATHER_MS" "150"))
    // Diagnostics: a line on stderr every STATS_SECONDS (fractions allowed); 0, the default, is off.
    let statsEvery = TimeSpan.FromSeconds(float (setting "STATS_SECONDS" "0"))
    let connections = Stats.Connections()
    let listening (listen: ListenOptions) =
        if statsEvery.Ticks > 0L then
            connections.Count listen

    Engine.Passwords.start bcryptLanes bcryptWidth bcryptGather
    let ds = Engine.Db.dataSource (Engine.Db.connectionString databaseUrl poolSize true)
    let writes =
        Engine.Commit.Writer(Engine.Db.connectionString databaseUrl writeLanes false, writeLanes, writeGroup)
    let reads = Engine.Reads.Gather(Engine.Db.connectionString databaseUrl readLanes false, readLanes, readBatch, readGather)
    let env: Handlers.Env =
        { Db = ds
          Reads = reads
          Writes = writes
          Jwt = Jwt.Signer secret }

    let builder = WebApplication.CreateSlimBuilder(args)
    builder.Logging.ClearProviders() |> ignore
    builder.WebHost.ConfigureKestrel(fun o ->
        o.AddServerHeader <- false
        // Outlive Nginx's 60 s upstream keep-alive (SPEC) and a browser's idle gap.
        o.Limits.KeepAliveTimeout <- TimeSpan.FromSeconds 120.0
        o.Limits.MaxConcurrentConnections <- Nullable()
        o.Limits.MaxConcurrentUpgradedConnections <- Nullable()
        o.Limits.MinRequestBodyDataRate <- null
        match IPAddress.TryParse host with
        | true, ip -> o.Listen(ip, port, listening)
        | _ when host = "localhost" -> o.ListenLocalhost(port, listening)
        | _ -> o.ListenAnyIP(port, listening))
    |> ignore
    // Kestrel's listen backlog is 512 unless set. Users arrive thousands a second, so a GC pause
    // of a few hundred ms fills 512, and the kernel drops the rest: each dropped connection costs
    // its user a 1-3 s TCP retry. The box allows 65535 (somaxconn); the kernel caps it to that.
    builder.WebHost.UseSockets(fun o -> o.Backlog <- 65535) |> ignore
    builder.Services.AddRouting().AddGiraffe() |> ignore

    let app = builder.Build()
    app.Use(
        Func<HttpContext, RequestDelegate, Task>(fun ctx next ->
            task {
                try
                    do! next.Invoke ctx
                with e ->
                    eprintfn "%s %s: %s" ctx.Request.Method ctx.Request.Path.Value (e.ToString())
                    do! writeError ctx 500 "internal error"
            })
    )
    |> ignore
    app.UseRouting().UseGiraffe(endpoints env) |> ignore
    app.Run(RequestDelegate(fun ctx -> writeError ctx 404 "not found"))

    // Touch the database before taking traffic: a bad DATABASE_URL fails here, loudly.
    (Engine.Tags.all reads).GetAwaiter().GetResult() |> ignore
    eprintfn
        "conduit (F#, Giraffe on Kestrel) on %s:%d, %d read lanes (batches of <= %d) + %d write lanes (groups of <= %d) + %d multiplexed db connections, %d bcrypt lanes"
        host port readLanes readBatch writeLanes writeGroup poolSize bcryptLanes
    if statsEvery.Ticks > 0L then
        Stats.start statsEvery connections reads readLanes writes
    app.Lifetime.ApplicationStopping.Register(fun () ->
        let hashes, verifies = Engine.Passwords.counts ()
        eprintfn "bcrypt: %d hashes (sign-ups, password changes), %d verifies (logins)" hashes verifies
        let lockstepBatches, inBatches = Engine.Passwords.lockstep ()
        eprintfn "bcrypt lockstep: %d hashes in %d batches" inBatches lockstepBatches
        let groups, written = writes.Counts
        eprintfn "group commit: %d writes in %d groups" written groups
        let batches, requests = reads.Counts
        eprintfn "read batching: %d requests in %d batches" requests batches
        let queued, executed, answered = reads.Timings
        eprintfn "read timings (p50/p95/p99): queued %s, batch executed %s, answered %s" queued executed answered)
    |> ignore
    app.Run()
    0
