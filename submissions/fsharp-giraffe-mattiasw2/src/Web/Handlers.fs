/// The 19 endpoints as Giraffe handlers: authenticate, decode, call Engine, encode. No SQL here
/// and no JSON shapes here (Engine and Wire own those).
module Web.Handlers

open System
open System.Text.Json
open System.Threading.Tasks
open Microsoft.AspNetCore.Http
open Giraffe
open Npgsql
open Engine

[<NoEquality; NoComparison>]
type Env =
    { Db: NpgsqlDataSource
      /// The hot reads, batched (Engine.Reads).
      Reads: Reads.Gather
      /// Every write goes through group commit (Engine.Commit).
      Writes: Commit.Writer
      Jwt: Jwt.Signer }

let private now () = DateTimeOffset.UtcNow.ToUnixTimeSeconds()

// ------------------------------------------------------------- responses -------

/// Sends a rendered body once, then returns its buffer to the pool (Kestrel has copied it).
let private send (status: int) (body: Wire.Body) : HttpHandler =
    fun _ ctx ->
        task {
            try
                ctx.Response.StatusCode <- status
                ctx.Response.ContentType <- "application/json"
                ctx.Response.ContentLength <- int64 body.Length
                do! ctx.Response.Body.WriteAsync(body.Memory)
            finally
                body.Release()
            return Some ctx
        }

let private ok body = send 200 body
let private created body = send 201 body

let noContent: HttpHandler =
    fun _ ctx ->
        ctx.Response.StatusCode <- 204
        Task.FromResult(Some ctx)

/// Renders per request: `notFound` and friends are values, and a pooled body is sent only once.
let fail (status: int) (message: string) : HttpHandler =
    fun next ctx -> send status (Wire.error message) next ctx

let private unauthorized = fail 401 "unauthorized"
let private forbidden = fail 403 "forbidden"
let notFound: HttpHandler = fail 404 "not found"
let private unprocessable (message: string) = fail 422 message

// ------------------------------------------------------------------ auth --------

[<Struct>]
type private Caller =
    | Anonymous
    | Invalid
    | Signed of id: int64 * token: string

/// `Authorization: Token <jwt>`: RealWorld's scheme. Any other header value is invalid.
let private caller (env: Env) (ctx: HttpContext) : Caller =
    let values = ctx.Request.Headers.Authorization
    if values.Count = 0 then
        Anonymous
    else
        let header = values[0]
        if not (isNull header) && header.StartsWith("Token ", StringComparison.Ordinal) then
            let token = header.Substring 6
            match env.Jwt.Verify(token, now ()) with
            | ValueSome id -> Signed(id, token)
            | ValueNone -> Invalid
        else
            Invalid

/// Auth required: a missing or invalid token is a 401.
let private signedIn (env: Env) (f: int64 -> string -> HttpHandler) : HttpHandler =
    fun next ctx ->
        match caller env ctx with
        | Signed(id, token) -> f id token next ctx
        | Anonymous
        | Invalid -> unauthorized next ctx

/// Auth optional: no header is viewer 0; a header that is present but invalid is a 401.
let private viewing (env: Env) (f: ViewerId -> HttpHandler) : HttpHandler =
    fun next ctx ->
        match caller env ctx with
        | Signed(id, _) -> f id next ctx
        | Anonymous -> f 0L next ctx
        | Invalid -> unauthorized next ctx

// ------------------------------------------------------------------ input -------

/// Parses the body as JSON and hands its root to `f`; anything unparseable is a 422.
let private withJson (f: JsonElement -> HttpHandler) : HttpHandler =
    fun next ctx ->
        task {
            let! doc =
                task {
                    try
                        let! d = JsonDocument.ParseAsync(ctx.Request.Body)
                        return ValueSome d
                    with _ ->
                        return ValueNone
                }
            match doc with
            | ValueNone -> return! unprocessable "the body must be JSON" next ctx
            | ValueSome doc ->
                use doc = doc
                return! f doc.RootElement next ctx
        }

/// Decodes the body with `decode` and hands the value to `f`; a decode error is a 422.
let private body (decode: JsonElement -> Result<'a, string>) (f: 'a -> HttpHandler) : HttpHandler =
    withJson (fun root ->
        match decode root with
        | Ok value -> f value
        | Error message -> unprocessable message)

let private queryOf (ctx: HttpContext) (name: string) : string option =
    match ctx.Request.Query.TryGetValue name with
    | true, v when v.Count > 0 -> Some v[0]
    | _ -> None

let private respond (f: unit -> Task<HttpHandler>) : HttpHandler =
    fun next ctx ->
        task {
            let! handler = f ()
            return! handler next ctx
        }

// ------------------------------------------------------------- endpoints -------

let tags (env: Env) : HttpHandler =
    respond (fun () ->
        task {
            let! names = Tags.all env.Reads
            return ok (Wire.tags names)
        })

let register (env: Env) : HttpHandler =
    body Wire.registration (fun r ->
        respond (fun () ->
            task {
                // bcrypt is the expensive part: never hash for a name that is already taken.
                match! Users.taken env.Db 0L (Some r.Username) (Some r.Email) with
                | true -> return unprocessable "username or email is already taken"
                | false ->
                    let! hash = Passwords.hash r.Password
                    match! Users.register env.Writes r.Username r.Email hash with
                    | Stored u -> return created (Wire.user u (env.Jwt.Mint(u.Id, now ())))
                    | Taken -> return unprocessable "username or email is already taken"
                    | Missing -> return unprocessable "not registered"
            }))

let login (env: Env) : HttpHandler =
    body Wire.login (fun l ->
        respond (fun () ->
            task {
                match! Users.byEmail env.Db l.Email with
                | None -> return unauthorized
                | Some(u, storedHash) ->
                    let! matches = Passwords.verify l.Password storedHash
                    return if matches then ok (Wire.user u (env.Jwt.Mint(u.Id, now ()))) else unauthorized
            }))

let currentUser (env: Env) : HttpHandler =
    signedIn env (fun id token ->
        respond (fun () ->
            task {
                match! Users.byId env.Db id with
                | Some u -> return ok (Wire.user u token)
                | None -> return unauthorized
            }))

let private applyUserEdit (env: Env) (id: int64) (token: string) (edit: Wire.UserEdit) (hash: string option) =
    task {
        let changes: Users.Changes =
            { Email = edit.Email
              Username = edit.Username
              PasswordHash = hash
              Bio = edit.Bio
              Image = edit.Image }
        match! Users.update env.Writes id changes with
        | Stored u -> return ok (Wire.user u token)
        | Taken -> return unprocessable "username or email is already taken"
        | Missing -> return unauthorized
    }

let updateUser (env: Env) : HttpHandler =
    signedIn env (fun id token ->
        body Wire.userEdit (fun edit ->
            respond (fun () ->
                task {
                    let update = applyUserEdit env id token edit
                    match edit.Password with
                    | None -> return! update None
                    | Some password ->
                        // A new password costs a bcrypt hash: pay it only for an update that
                        // will go through (the user still exists, the new names are free).
                        match! Users.byId env.Db id with
                        | None -> return unauthorized
                        | Some _ ->
                            match! Users.taken env.Db id edit.Username edit.Email with
                            | true -> return unprocessable "username or email is already taken"
                            | false ->
                                let! hash = Passwords.hash password
                                return! update (Some hash)
                })))

let profile (env: Env) (username: string) : HttpHandler =
    viewing env (fun viewer ->
        respond (fun () ->
            task {
                match! Profiles.get env.Reads viewer username with
                | Some p -> return ok (Wire.profile p)
                | None -> return notFound
            }))

let follow (env: Env) (following: bool) (username: string) : HttpHandler =
    signedIn env (fun viewer _ ->
        respond (fun () ->
            task {
                match! Profiles.setFollowing env.Writes viewer username following with
                | Some p -> return ok (Wire.profile p)
                | None -> return notFound
            }))

let listArticles (env: Env) : HttpHandler =
    viewing env (fun viewer next ctx ->
        let query = queryOf ctx
        match Wire.paging query with
        | Error message -> unprocessable message next ctx
        | Ok paging ->
            task {
                let! page = Articles.list env.Reads viewer (Wire.filter query) paging
                return! ok (Wire.articles page) next ctx
            })

let feed (env: Env) : HttpHandler =
    signedIn env (fun viewer _ next ctx ->
        match Wire.paging (queryOf ctx) with
        | Error message -> unprocessable message next ctx
        | Ok paging ->
            task {
                let! page = Articles.feed env.Reads viewer paging
                return! ok (Wire.articles page) next ctx
            })

let article (env: Env) (slug: string) : HttpHandler =
    viewing env (fun viewer ->
        respond (fun () ->
            task {
                match! Articles.bySlug env.Reads viewer slug with
                | Some a -> return ok (Wire.article a)
                | None -> return notFound
            }))

let createArticle (env: Env) : HttpHandler =
    signedIn env (fun viewer _ ->
        body Wire.newArticle (fun a ->
            respond (fun () ->
                task {
                    let! stored = Articles.create env.Db env.Writes viewer a.Title a.Description a.Body a.Tags
                    return created (Wire.article stored)
                })))

let private guarded (result: Guarded<'a>) (onDone: 'a -> HttpHandler) : HttpHandler =
    match result with
    | Done value -> onDone value
    | NotFound -> notFound
    | NotYours -> forbidden

let updateArticle (env: Env) (slug: string) : HttpHandler =
    signedIn env (fun viewer _ ->
        body Wire.articleEdit (fun edit ->
            respond (fun () ->
                task {
                    let! result = Articles.update env.Db env.Writes viewer slug edit
                    return guarded result (Wire.article >> ok)
                })))

let deleteArticle (env: Env) (slug: string) : HttpHandler =
    signedIn env (fun viewer _ ->
        respond (fun () ->
            task {
                let! result = Articles.delete env.Writes viewer slug
                return guarded result (fun () -> noContent)
            }))

let favorite (env: Env) (on: bool) (slug: string) : HttpHandler =
    signedIn env (fun viewer _ ->
        respond (fun () ->
            task {
                match! Articles.setFavorite env.Writes viewer slug on with
                | Some a -> return ok (Wire.article a)
                | None -> return notFound
            }))

let comments (env: Env) (slug: string) : HttpHandler =
    viewing env (fun viewer ->
        respond (fun () ->
            task {
                match! Comments.list env.Reads viewer slug with
                | Some cs -> return ok (Wire.comments cs)
                | None -> return notFound
            }))

let addComment (env: Env) (slug: string) : HttpHandler =
    signedIn env (fun viewer _ ->
        body Wire.newComment (fun text ->
            respond (fun () ->
                task {
                    match! Comments.create env.Writes viewer slug text with
                    | Some c -> return created (Wire.comment c)
                    | None -> return notFound
                })))

let deleteComment (env: Env) (slug: string, idText: string) : HttpHandler =
    signedIn env (fun viewer _ ->
        match Wire.commentId idText with
        | ValueNone -> notFound
        | ValueSome id ->
            respond (fun () ->
                task {
                    let! result = Comments.delete env.Writes viewer slug id
                    return guarded result (fun () -> noContent)
                }))
