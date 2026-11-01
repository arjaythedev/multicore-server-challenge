module Web.Program

// Giraffe on Kestrel (the sss8 pattern): a thin route table over Engine. Configured only by the
// runtime contract's environment variables (SPEC.md), plus optional tuning knobs.

open System
open System.Net
open System.Threading.Tasks
open Microsoft.AspNetCore.Builder
open Microsoft.AspNetCore.Hosting
open Microsoft.AspNetCore.Http
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
        ctx.Response.StatusCode <- status
        ctx.Response.ContentType <- "application/json"
        ctx.Response.ContentLength <- int64 body.Length
        ctx.Response.Body.WriteAsync(body).AsTask()

[<EntryPoint>]
let main args =
    let cores = Environment.ProcessorCount
    let databaseUrl = required "DATABASE_URL"
    let secret = required "JWT_SECRET"
    let host = setting "HOST" "127.0.0.1"
    let port = int (setting "PORT" "3000")
    // Multiplexed: these connections carry every request; Postgres does best with a few
    // busy backends per core, not many idle ones. Rule: 95 or fewer in total.
    let poolSize = min 95 (int (setting "DB_POOL_SIZE" (string (cores * 3))))
    let bcryptLanes = int (setting "BCRYPT_THREADS" (string (max 1 (cores / 2))))

    Engine.Passwords.start bcryptLanes
    let ds = Engine.Db.dataSource (Engine.Db.connectionString databaseUrl poolSize)
    let env: Handlers.Env = { Db = ds; Jwt = Jwt.Signer secret }

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
        | true, ip -> o.Listen(ip, port)
        | _ when host = "localhost" -> o.ListenLocalhost port
        | _ -> o.ListenAnyIP port)
    |> ignore
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
    (Engine.Tags.all ds).GetAwaiter().GetResult() |> ignore
    eprintfn "conduit (F#, Giraffe on Kestrel) on %s:%d, %d db connections (multiplexed), %d bcrypt lanes" host port poolSize bcryptLanes
    app.Run()
    0
