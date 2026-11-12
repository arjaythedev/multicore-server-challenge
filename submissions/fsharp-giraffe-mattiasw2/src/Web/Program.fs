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

// Routes with path parameters are ASP.NET route templates, not Giraffe's `routef`: `routef` parses its
// "%s" format through FSharp.Core's printf machinery (reflection, MakeGenericMethod), which Native AOT
// cannot compile. Each helper reads the parameter names from the template itself, so a template and
// the values its handler reads cannot drift apart.

/// The names of a route template's `{name}` segments, in order.
let private parameters (template: string) : string array =
    template.Split '/'
    |> Array.filter (fun s -> s.StartsWith '{' && s.EndsWith '}')
    |> Array.map (fun s -> s.Substring(1, s.Length - 2))

let private expect (count: int) (template: string) : string array =
    match parameters template with
    | names when names.Length = count -> names
    | names -> invalidArg (nameof template) $"{template}: {names.Length} parameters, expected {count}"

/// `route1 "/api/articles/{slug}" handler`: the handler gets the decoded `{slug}`.
let private route1 (template: string) (handler: string -> HttpHandler) : Endpoint =
    let names = expect 1 template
    route template (fun next ctx -> handler (string ctx.Request.RouteValues[names[0]]) next ctx)

/// `route2 "/api/articles/{slug}/comments/{id}" handler`: the handler gets both values, in template order.
let private route2 (template: string) (handler: string * string -> HttpHandler) : Endpoint =
    let names = expect 2 template
    route template (fun next ctx ->
        let values = ctx.Request.RouteValues
        handler (string values[names[0]], string values[names[1]]) next ctx)

let endpoints (env: Handlers.Env) : Endpoint list =
    [ GET
          [ route "/api/tags" (Handlers.tags env)
            route "/api/user" (Handlers.currentUser env)
            route1 "/api/profiles/{username}" (Handlers.profile env)
            route "/api/articles" (Handlers.listArticles env)
            route "/api/articles/feed" (Handlers.feed env)
            route1 "/api/articles/{slug}" (Handlers.article env)
            route1 "/api/articles/{slug}/comments" (Handlers.comments env) ]
      POST
          [ route "/api/users" (Handlers.register env)
            route "/api/users/login" (Handlers.login env)
            route1 "/api/profiles/{username}/follow" (Handlers.follow env true)
            route "/api/articles" (Handlers.createArticle env)
            route1 "/api/articles/{slug}/favorite" (Handlers.favorite env true)
            route1 "/api/articles/{slug}/comments" (Handlers.addComment env) ]
      PUT
          [ route "/api/user" (Handlers.updateUser env)
            route1 "/api/articles/{slug}" (Handlers.updateArticle env) ]
      DELETE
          [ route1 "/api/profiles/{username}/follow" (Handlers.follow env false)
            route1 "/api/articles/{slug}" (Handlers.deleteArticle env)
            route1 "/api/articles/{slug}/favorite" (Handlers.favorite env false)
            route2 "/api/articles/{slug}/comments/{id}" (Handlers.deleteComment env) ] ]

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
    // Every capacity default follows the cores this process may run on (ProcessorCount honours
    // the CPU affinity, so `taskset` sizes it like a smaller box). Only per-batch caps and
    // latency budgets are fixed: lanes x cap still scales with the cores.
    let cores = Environment.ProcessorCount
    // A quarter of the cores, rounded: 2 on 6 or 8, 1 on 4, 4 on 16.
    let quarter = max 1 ((cores + 2) / 4)
    let databaseUrl = required "DATABASE_URL"
    let secret = required "JWT_SECRET"
    let host = setting "HOST" "127.0.0.1"
    let port = int (setting "PORT" "3000")
    // Group commit: WRITE_LANES connections of their own, each committing one group of up to
    // WRITE_GROUP writes at a time.
    let writeLanes = max 1 (int (setting "WRITE_LANES" (string quarter)))
    let writeGroup = max 1 (int (setting "WRITE_GROUP" "128"))
    // A group smaller than WRITE_GROUP_MIN waits for company until its oldest write has waited
    // WRITE_GATHER_MS (0: never waits, as before).
    let writeGroupMin = max 1 (int (setting "WRITE_GROUP_MIN" "8"))
    let writeGather = TimeSpan.FromMilliseconds(float (setting "WRITE_GATHER_MS" "2"))
    // Read batching: READ_LANES connections of their own, each running one batch of up to
    // READ_BATCH requests at a time. One busy backend per core.
    let readLanes = max 1 (int (setting "READ_LANES" (string cores)))
    let readBatch = max 1 (int (setting "READ_BATCH" "2048"))
    let readGather = TimeSpan.FromMilliseconds(float (setting "READ_GATHER_MS" "25"))
    // A gathering lane takes its fair share of what waits (what waits over the idle lanes), at
    // least READ_SHARE_MIN (64; 0: take everything up to READ_BATCH, as before).
    let readShareMin = max 0 (int (setting "READ_SHARE_MIN" "64"))
    // Count lanes: connections that count favorites for all the read lanes' batches at once
    // (1; 0: each batch counts its own, in its phase B).
    let countLanes = max 0 (int (setting "READ_COUNT_LANES" "1"))
    // A fine timeline for diagnostics (off unless BATCH_LOG is set): a batch log and a sample of
    // CPU, GC and queues every BATCH_LOG_MS (25), written at shutdown to BATCH_LOG.batches.csv and
    // BATCH_LOG.samples.csv. BATCH_LOG_PG_CGROUP: Postgres's cgroup cpu.stat, for its CPU.
    let batchLog = setting "BATCH_LOG" ""
    // Multiplexed: the cold reads (sign-in lookups, the read after a write). Rule: 95 or fewer
    // connections in total, lanes included.
    let poolSize = min (95 - writeLanes - readLanes - countLanes) (int (setting "DB_POOL_SIZE" (string (max 2 (cores / 2)))))
    // A quarter of the cores, each computing several hashes in lockstep (five on a recent x86-64
    // core, ~120 a second per idle thread), covers the login rate the reads leave room for; fewer
    // threads also fill the lockstep batches.
    let bcryptLanes = max 1 (int (setting "BCRYPT_THREADS" (string quarter)))
    // Each bcrypt thread computes up to BCRYPT_WIDTH hashes in lockstep (1 to 6; 0, the default:
    // the width this CPU hashes fastest at) with the kernel BCRYPT_KERNEL (c, ah, bextr or shrx;
    // by default the fastest, timed at startup), letting the first wait up to BCRYPT_GATHER_MS
    // for batch-mates.
    let bcryptWidth = max 0 (int (setting "BCRYPT_WIDTH" "0"))
    let bcryptKernel = setting "BCRYPT_KERNEL" ""
    // Logins are ~0.1% of the requests, so waiting for batch-mates barely touches p95 or p99.
    let bcryptGather = TimeSpan.FromMilliseconds(float (setting "BCRYPT_GATHER_MS" "150"))
    // Diagnostics: a line on stderr every STATS_SECONDS (fractions allowed); 0, the default, is off.
    let statsEvery = TimeSpan.FromSeconds(float (setting "STATS_SECONDS" "0"))
    // The read and write timings (the shutdown lines) only while a diagnostic is on.
    Engine.Db.Millis.Enabled <- statsEvery.Ticks > 0L || batchLog <> ""
    let connections = Stats.Connections()
    let listening (listen: ListenOptions) =
        if statsEvery.Ticks > 0L then
            connections.Count listen

    Engine.Passwords.start bcryptLanes bcryptKernel bcryptWidth bcryptGather
    let bcryptKernel, bcryptWidth, bcryptMs = Engine.Passwords.kernel ()
    // Each kind of connection names itself, so Postgres's own views (pg_stat_activity) and
    // probes on its backends can tell the read lanes, the write lanes and the pool apart.
    let named (role: string) (connectionString: string) = $"{connectionString};Application Name=conduit-{role}"
    let ds = Engine.Db.dataSource (named "pool" (Engine.Db.connectionString databaseUrl poolSize true))
    let writes =
        Engine.Commit.Writer(
            named "write" (Engine.Db.connectionString databaseUrl writeLanes false),
            writeLanes,
            writeGroup,
            writeGroupMin,
            writeGather
        )
    let reads =
        Engine.Reads.Gather(
            named "read" (Engine.Db.connectionString databaseUrl (readLanes + countLanes) false),
            readLanes,
            countLanes,
            readBatch,
            readGather,
            readShareMin,
            (if batchLog = "" then 0 else 400_000)
        )
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
    // Server time per endpoint, only while the stats line is on; with PHASES_FILE too, where each
    // request's time went (Stats.Phases), appended to that file at every stats line.
    let perEndpoint = if statsEvery.Ticks > 0L then Some(Stats.Endpoints()) else None
    let phasesFile = setting "PHASES_FILE" ""
    let phases = if statsEvery.Ticks > 0L && phasesFile <> "" then Some(Stats.Phases()) else None
    app.Use(
        Func<HttpContext, RequestDelegate, Task>(fun ctx next ->
            task {
                let started = Diagnostics.Stopwatch.GetTimestamp()
                let trace =
                    match phases with
                    | Some _ ->
                        let t = Engine.Db.Trace()
                        Engine.Db.Trace.Current.Value <- t
                        t
                    | None -> null
                try
                    do! next.Invoke ctx
                with e ->
                    Stats.eprint $"{ctx.Request.Method} {ctx.Request.Path.Value}: {e}"
                    do! writeError ctx 500 "internal error"
                if perEndpoint.IsSome || phases.IsSome then
                    let finished = Diagnostics.Stopwatch.GetTimestamp()
                    let name =
                        Stats.Endpoints.Name(ctx.Request.Method, ctx.Request.Path.Value, ctx.Request.Query.ContainsKey)
                    perEndpoint |> Option.iter (fun t -> t.Record(name, Diagnostics.Stopwatch.GetElapsedTime(started, finished)))
                    phases |> Option.iter (fun p -> p.Record(name, finished - started, trace))
            })
    )
    |> ignore
    app.UseRouting().UseGiraffe(endpoints env) |> ignore
    app.Run(RequestDelegate(fun ctx -> writeError ctx 404 "not found"))

    // Touch the database before taking traffic: a bad DATABASE_URL fails here, loudly.
    (Engine.Tags.all reads).GetAwaiter().GetResult() |> ignore
    let serverGC = if Runtime.GCSettings.IsServerGC then "true" else "false"
    Stats.eprint (
        $"conduit (F#, Giraffe on Kestrel) on {host}:{port}, {cores} cores:"
        + $" {readLanes} read lanes (batches of <= {readBatch}, gather {int readGather.TotalMilliseconds} ms,"
        + $" fair share from {readShareMin})"
        + $" + {writeLanes} write lanes (groups of <= {writeGroup}, waiting {int writeGather.TotalMilliseconds} ms for {writeGroupMin})"
        + $" + {poolSize} multiplexed db connections, {bcryptLanes} bcrypt threads ({bcryptWidth} wide, kernel {bcryptKernel}, {bcryptMs:F1} ms a hash), server GC {serverGC}"
    )
    let sampler =
        if batchLog = "" then
            None
        else
            let every = TimeSpan.FromMilliseconds(float (setting "BATCH_LOG_MS" "25"))
            let s = Stats.Sampler(every, reads, writes, setting "BATCH_LOG_PG_CGROUP" "", 200_000)
            s.Start()
            Some(s, new Stats.GcLog(100_000))
    if statsEvery.Ticks > 0L then
        Stats.start statsEvery connections reads readLanes writes writeLanes (phases |> Option.map (fun p -> p, phasesFile))
    app.Lifetime.ApplicationStopping.Register(fun () ->
        let hashes, verifies = Engine.Passwords.counts ()
        Stats.eprint $"bcrypt: {hashes} hashes (sign-ups, password changes), {verifies} verifies (logins)"
        let lockstepBatches, inBatches = Engine.Passwords.lockstep ()
        Stats.eprint $"bcrypt lockstep: {inBatches} hashes in {lockstepBatches} batches"
        let groups, written = writes.Counts
        Stats.eprint $"group commit: {written} writes in {groups} groups"
        let refused, failedAlone = writes.Refusals
        Stats.eprint $"group commit refusals: {refused} groups rerun write by write, {failedAlone} writes failed alone"
        let batches, requests = reads.Counts
        Stats.eprint $"read batching: {requests} requests in {batches} batches"
        let queued, executed, answered = reads.Timings
        Stats.eprint $"read timings (p50/p95/p99): queued {queued}, batch executed {executed}, answered {answered}"
        let a, plan, b, assembled = reads.PhaseTimings
        Stats.eprint $"read batch phases (p50/p95/p99): A {a}, plan {plan}, B {b}, assemble {assembled}"
        let queued, executed, answered = writes.Timings
        Stats.eprint $"write timings (p50/p95/p99): queued {queued}, group executed {executed}, answered {answered}"
        match perEndpoint with
        | Some t ->
            Stats.eprint "server time per endpoint (count, p50/p95/p99):"
            for line in t.Lines() do
                Stats.eprint line
        | None -> ()
        phases |> Option.iter (fun p -> p.Snapshot(phasesFile, DateTimeOffset.UtcNow.ToUnixTimeSeconds()))
        sampler
        |> Option.iter (fun (s, gc) ->
            let batches = reads.WriteLog(batchLog + ".batches.csv")
            let samples = s.Write(batchLog + ".samples.csv")
            let collections, lines = gc.Write(batchLog + ".gc.csv")
            Stats.eprint $"batch log: {batches} batches, {samples} samples, {collections} GC pauses written to {batchLog}.*.csv"
            let pauses = GC.GetTotalPauseDuration().TotalMilliseconds
            Stats.eprint $"GC pauses by generation (runtime total {pauses:F0} ms):"
            for line in lines do
                Stats.eprint line))
    |> ignore
    app.Run()
    0
