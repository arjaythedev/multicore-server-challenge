/// The endpoints, ported from #22 (csharp-sockets-jh-d, MIT). A request is routed and authenticated on its I/O loop,
/// then either queued for its batched read (Db.fs) or sent as its own statement group (SingleQuery); rows are
/// written as JSON as they arrive (on the Postgres thread), and the response goes back to the I/O loop when the
/// statement completes.
module Handlers

#nowarn "9"

open System
open System.Buffers.Text
open System.Text
open System.Text.Json
open Microsoft.FSharp.NativeInterop
open Pg
open Ctx
open Json

let private bGet = "GET"B
let private bPost = "POST"B
let private bPut = "PUT"B
let private bDelete = "DELETE"B
let private bApi = "/api/"B
let private bArticles = "articles"B
let private bFeed = "feed"B
let private bComments = "comments"B
let private bFavorite = "favorite"B
let private bTags = "tags"B
let private bProfiles = "profiles"B
let private bFollow = "follow"B
let private bUser = "user"B
let private bUsers = "users"B
let private bLogin = "login"B
let private bToken = "Token "B
let private bLimit = "limit"B
let private bOffset = "offset"B
let private bTag = "tag"B
let private bAuthor = "author"B
let private bFavorited = "favorited"B

[<Literal>]
let private Get = 1
[<Literal>]
let private Post = 2
[<Literal>]
let private Put = 3
[<Literal>]
let private Delete = 4

let private backend () = Backend.Current

// ---------- the request's own statement group ----------

/// The kinds of single statements and their rows: see writeSingle / singleRow / singleDone below.
[<Sealed>]
type SingleQuery(c: Ctx, write: Ctx -> PgWriter -> unit, row: Ctx -> int -> PgRow -> unit,
                 complete: Ctx -> int -> int64 -> unit, isDone: Ctx -> PgError -> unit) =
    inherit PgQuery()
    override _.Write(w) = write c w
    override _.Row(result, r) = row c result r
    override _.Complete(result, tag) =
        // "DELETE n": rows deleted
        let sp = tag.LastIndexOf ' 'B
        let mutable n = 0L
        let mutable used = 0
        if sp >= 0 && Utf8Parser.TryParse(tag.Slice(sp + 1), &n, &used) then complete c result n
    override _.Done(err) =
        try isDone c err
        with e ->
            eprintfn "%O" e
            c.Error(500, "internal error")
            c.Finish()

let private notFound (c: Ctx) =
    c.Error(404, "not found")
    c.Finish()

let private unauthorized (c: Ctx) =
    c.Error(401, "unauthorized")
    c.Finish()

/// a = 1 valid token, 0 none, -1 present but invalid
let private optional (c: Ctx) (a: int) =
    if a >= 0 then true
    else
        unauthorized c
        false

let private required (c: Ctx) (a: int) =
    if a = 1 then true
    else
        unauthorized c
        false

let private hex (b: byte) =
    if b >= '0'B && b <= '9'B then int b - int '0'B
    elif b >= 'a'B && b <= 'f'B then int b - int 'a'B + 10
    elif b >= 'A'B && b <= 'F'B then int b - int 'A'B + 10
    else -1

/// %XX escapes (and '+' as space in query strings); a malformed escape is kept as is
let private unescape (src: ReadOnlySpan<byte>) (dst: Span<byte>) (plusIsSpace: bool) =
    let mutable n = 0
    let mutable i = 0
    while i < src.Length do
        let b = src.[i]
        if b = '%'B && i + 2 < src.Length && hex src.[i + 1] >= 0 && hex src.[i + 2] >= 0 then
            dst.[n] <- byte ((hex src.[i + 1] <<< 4) ||| hex src.[i + 2])
            i <- i + 3
        else
            dst.[n] <- (if plusIsSpace && b = '+'B then ' 'B else b)
            i <- i + 1
        n <- n + 1
    n

/// decimal digits only (leading zeros allowed), no sign, no spaces, no overflow
let private digits (s: ReadOnlySpan<byte>) (v: byref<int64>) =
    v <- 0L
    if s.Length = 0 then false
    else
        let mutable ok = true
        let mutable i = 0
        while ok && i < s.Length do
            let ch = s.[i]
            if ch < '0'B || ch > '9'B then ok <- false
            else
                let d = int64 (ch - '0'B)
                if v > (Int64.MaxValue - d) / 10L then ok <- false else v <- v * 10L + d
            i <- i + 1
        ok

/// Text Postgres would reject (NUL, invalid UTF-8) must never reach a batch: one bad value would fail all of it
/// (#79). The reference server answers such a request with 500.
let private badText (s: ReadOnlySpan<byte>) = s.IndexOf 0uy >= 0 || not (Unicode.Utf8.IsValid s)

/// a path segment, URL-decoded, as the request's key; false if it is not valid text
let private setKey (c: Ctx) (raw: ReadOnlySpan<byte>) =
    if raw.IndexOf '%'B < 0 then
        c.KeyOff <- c.Put raw
        c.KeyLen <- raw.Length
    else
        let tmp = Array.zeroCreate<byte> raw.Length
        let len = unescape raw (Span tmp) false
        c.KeyOff <- c.Put(ReadOnlySpan(tmp, 0, len))
        c.KeyLen <- len
    if badText c.Key then
        c.Error(500, "invalid text")
        c.Finish()
        false
    else true

let private read (c: Ctx) (r: Route) (k: Sql.Kind) (key: ReadOnlySpan<byte>) =
    c.Route <- r
    if setKey c key then backend().Enqueue(c, k)

// ---------- lists ----------

let private invalidList (c: Ctx) =
    c.Error(422, "limit must be 1-100 and offset >= 0")
    c.Finish()

/// limit (1-100, default 20), offset (>= 0, default 0) and one filter (tag, author or favorited; the first occurrence
/// of each parameter wins, empty filters are ignored, tag before author before favorited). Returns -1 if invalid.
let private parseList (c: Ctx) (query: ReadOnlySpan<byte>) =
    c.Limit <- 20
    c.Offset <- 0L
    let mutable s = query
    let mutable haveLimit = false
    let mutable haveOffset = false
    let mutable tagOff = -1
    let mutable tagLen = 0
    let mutable authorOff = -1
    let mutable authorLen = 0
    let mutable favOff = -1
    let mutable favLen = 0
    let mutable bad = false
    let keyBuf = Span<byte>(NativePtr.toVoidPtr (NativePtr.stackalloc<byte> 64), 64)
    let tmp = Span<byte>(NativePtr.toVoidPtr (NativePtr.stackalloc<byte> 256), 256)
    while not bad && s.Length > 0 do
        let amp = s.IndexOf '&'B
        let pair = if amp < 0 then s else s.Slice(0, amp)
        s <- if amp < 0 then ReadOnlySpan.Empty else s.Slice(amp + 1)
        if pair.Length > 0 then
            let eq = pair.IndexOf '='B
            let mutable key = if eq < 0 then pair else pair.Slice(0, eq)
            let raw = if eq < 0 then ReadOnlySpan.Empty else pair.Slice(eq + 1)
            let mutable known = true
            if key.IndexOfAny('%'B, '+'B) >= 0 then
                if key.Length > keyBuf.Length then known <- false
                else
                    let kl = unescape key keyBuf true
                    key <- Span<byte>.op_Implicit (keyBuf.Slice(0, kl))
            if known then
                let value = if raw.Length <= tmp.Length then tmp else Span(Array.zeroCreate<byte> raw.Length)
                let vl = unescape raw value true
                let v = Span<byte>.op_Implicit (value.Slice(0, vl))
                if key.SequenceEqual bLimit then
                    if not haveLimit then
                        haveLimit <- true
                        let mutable x = 0L
                        if not (digits v &x) || x < 1L || x > 100L then bad <- true else c.Limit <- int x
                elif key.SequenceEqual bOffset then
                    if not haveOffset then
                        haveOffset <- true
                        let mutable x = 0L
                        if not (digits v &x) then bad <- true
                        else c.Offset <- min x (Int64.MaxValue / 2L) // beyond any page; keeps limit + offset in range
                elif key.SequenceEqual bTag then
                    if tagOff < 0 && vl > 0 then
                        tagOff <- c.Put v
                        tagLen <- vl
                elif key.SequenceEqual bAuthor then
                    if authorOff < 0 && vl > 0 then
                        authorOff <- c.Put v
                        authorLen <- vl
                elif key.SequenceEqual bFavorited then
                    if favOff < 0 && vl > 0 then
                        favOff <- c.Put v
                        favLen <- vl
    if bad then -1
    elif tagOff >= 0 then
        c.KeyOff <- tagOff
        c.KeyLen <- tagLen
        1
    elif authorOff >= 0 then
        c.KeyOff <- authorOff
        c.KeyLen <- authorLen
        2
    elif favOff >= 0 then
        c.KeyOff <- favOff
        c.KeyLen <- favLen
        3
    else 0

let private list (c: Ctx) (query: ReadOnlySpan<byte>) =
    let f = parseList c query
    if f < 0 then invalidList c
    elif f > 0 && badText c.Key then
        c.Error(500, "invalid text")
        c.Finish()
    else
        match f with
        | 1 ->
            c.Route <- Route.ListTag
            backend().Enqueue(c, Sql.ListTag)
        | 2 ->
            c.Route <- Route.ListAuthor
            backend().Enqueue(c, Sql.ListAuthor)
        | 3 ->
            c.Route <- Route.ListFavorited
            backend().Enqueue(c, Sql.ListFavorited)
        | _ ->
            c.Route <- Route.ListAll
            backend().Enqueue(c, Sql.ListAll)

let private feed (c: Ctx) (query: ReadOnlySpan<byte>) =
    if parseList c query < 0 then invalidList c
    else
        c.Route <- Route.Feed
        backend().Enqueue(c, Sql.ListFeed)

// ---------- batched reads: rows and completion (Postgres thread) ----------

let batchRow (c: Ctx) (r: PgRow) =
    let w = c.W
    match c.Route with
    | Route.Tags ->
        w.WriteStartObject()
        w.WritePropertyName N.tags
        textArray w (r.Bytes 1)
        w.WriteEndObject()
        c.Found <- true
    | Route.Article
    | Route.Favorite
    | Route.Unfavorite ->
        if not c.Found then
            w.WriteStartObject()
            w.WritePropertyName N.article
            article w r 1 true
            w.WriteEndObject()
            c.Found <- true
    | Route.Comments ->
        if not c.Found then
            w.WriteStartObject()
            w.WritePropertyName N.comments
            w.WriteStartArray()
            c.Found <- true
        if not (r.IsNull 2) then
            w.WriteStartObject()
            w.WriteNumber(N.id, r.Int8 2)
            time w N.createdAt (r.Micros 4)
            time w N.updatedAt (r.Micros 5)
            text w N.body r 3
            w.WritePropertyName N.author
            profile w r 6 -1
            w.WriteEndObject()
    | Route.Profile
    | Route.Follow
    | Route.Unfollow ->
        if not c.Found then
            w.WriteStartObject()
            w.WritePropertyName N.profile
            profile w r 1 -1
            w.WriteEndObject()
            c.Found <- true
    | Route.User ->
        if not c.Found then
            user w r 1 c.Token
            c.Found <- true
    | Route.CreateComment ->
        if not c.Found then
            c.Status <- 201
            w.WriteStartObject()
            w.WritePropertyName N.comment
            w.WriteStartObject()
            w.WriteNumber(N.id, r.Int8 1)
            time w N.createdAt (r.Micros 3)
            time w N.updatedAt (r.Micros 4)
            text w N.body r 2
            w.WritePropertyName N.author
            profile w r 5 0
            w.WriteEndObject()
            w.WriteEndObject()
            c.Found <- true
    | _ ->
        // lists: (i, count, article columns or NULLs for an empty page)
        if not c.Found then
            c.Count <- r.Int8 1
            w.WriteStartObject()
            w.WritePropertyName N.articles
            w.WriteStartArray()
            c.Found <- true
        if not (r.IsNull 2) then article w r 2 false

/// a write batch whose transaction failed: each of its requests again on its own (set below, after `single`)
let mutable private retryAlone: Ctx -> unit = ignore

let private batchedWrite (r: Route) =
    r = Route.Favorite || r = Route.Unfavorite || r = Route.Follow || r = Route.Unfollow || r = Route.CreateComment

let batchDone (c: Ctx) (err: PgError) =
    if not (isNull err) && batchedWrite c.Route then
        eprintfn "batched %O: %O; retrying alone" c.Route err
        c.ClearBody()
        retryAlone c
    elif not (isNull err) then
        eprintfn "batched %O: %O" c.Route err
        c.Error(500, "internal error")
        c.Finish()
    else
        let w = c.W
        match c.Route with
        | Route.Tags -> if not c.Found then c.Error(500, "no tags row")
        | Route.Article
        | Route.Favorite
        | Route.Unfavorite
        | Route.CreateComment -> if not c.Found then c.Error(404, "article not found")
        | Route.Comments ->
            if not c.Found then c.Error(404, "article not found")
            else
                w.WriteEndArray()
                w.WriteEndObject()
        | Route.Profile
        | Route.Follow
        | Route.Unfollow -> if not c.Found then c.Error(404, "profile not found")
        | Route.User -> if not c.Found then c.Error(401, "unauthorized")
        | _ ->
            if not c.Found then
                w.WriteStartObject()
                w.WritePropertyName N.articles
                w.WriteStartArray()
            w.WriteEndArray()
            w.WriteNumber(N.articlesCount, c.Count)
            w.WriteEndObject()
        c.Finish()

// ---------- writes and logins ----------

module Slug =
    /// trim(both '-' from lower(regexp_replace(title, '[^A-Za-z0-9]+', '-', 'g')))
    let make (title: string) =
        let sb = StringBuilder(title.Length)
        let mutable dash = false
        for ch in title do
            let lower =
                if (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') then ch
                elif ch >= 'A' && ch <= 'Z' then char (int ch + 32)
                else '\000'
            if lower = '\000' then dash <- true
            else
                if dash && sb.Length > 0 then sb.Append '-' |> ignore
                dash <- false
                sb.Append lower |> ignore
        sb.ToString()

let private writeArticle (w: Utf8JsonWriter) (r: PgRow) =
    w.WriteStartObject()
    w.WritePropertyName N.article
    article w r 0 true
    w.WriteEndObject()

let private writeSingle (c: Ctx) (w: PgWriter) =
    match c.Route with
    | Route.CreateArticle ->
        w.Bind Sql.ArticleInsert
        w.Int8 c.Viewer
        w.Text c.S4
        w.Text c.S1
        w.Text c.S2
        w.Text c.S3
        w.EndBind()
        if c.Tags.Length > 0 then
            w.Bind Sql.TagsInsert
            w.TextArray c.Tags
            w.EndBind()
            w.Bind Sql.ArticleTagsInsert
            w.TextArray c.Tags
            w.EndBind()
        w.Bind Sql.ArticleByCurrval
        w.Int8 c.Viewer
        w.EndBind()
    | Route.UpdateArticle ->
        if c.Step = 0 then
            w.Bind Sql.ArticleUpdate
            w.Int8 c.Viewer
            w.Text c.Key
            w.Text c.S1
            w.Text c.S2
            w.Text c.S3
            w.Text c.S4
            w.EndBind()
        else
            w.Bind Sql.ArticleAuthorBySlug
            w.Text c.Key
            w.EndBind()
    | Route.DeleteArticle ->
        if c.Step = 0 then
            w.Bind Sql.ArticleDelete
            w.Text c.Key
            w.Int8 c.Viewer
            w.EndBind()
        else
            w.Bind Sql.ArticleAuthorBySlug
            w.Text c.Key
            w.EndBind()
    | Route.Favorite
    | Route.Unfavorite ->
        w.Bind(if c.Route = Route.Favorite then Sql.FavoriteInsert else Sql.FavoriteDelete)
        w.Int8 c.Viewer
        w.Text c.Key
        w.EndBind()
        w.Bind Sql.ArticleBySlug
        w.Int8 c.Viewer
        w.Text c.Key
        w.EndBind()
    | Route.CreateComment ->
        w.Bind Sql.CommentInsert
        w.Int8 c.Viewer
        w.Text c.Key
        w.Text c.S1
        w.EndBind()
    | Route.DeleteComment ->
        if c.Step = 0 then
            w.Bind Sql.CommentDelete
            w.Int8 c.CId
            w.Text c.Key
            w.Int8 c.Viewer
            w.EndBind()
        else
            w.Bind Sql.CommentAuthor
            w.Int8 c.CId
            w.Text c.Key
            w.EndBind()
    | Route.Follow
    | Route.Unfollow ->
        w.Bind(if c.Route = Route.Follow then Sql.Follow else Sql.Unfollow)
        w.Int8 c.Viewer
        w.Text c.Key
        w.EndBind()
    | Route.Register ->
        w.Bind Sql.UserInsert
        w.Text c.S1
        w.Text c.S2
        w.Text c.S3
        w.EndBind()
    | Route.Login ->
        w.Bind Sql.UserByEmail
        w.Text c.S1
        w.EndBind()
    | Route.UpdateUser ->
        w.Bind Sql.UserUpdate
        w.Int8 c.Viewer
        w.Text c.S1
        w.Text c.S2
        w.Text c.S3
        w.Text c.S4
        w.Text c.S5
        w.EndBind()
    | _ -> ()
    w.Sync()

let private singleRow (c: Ctx) (result: int) (r: PgRow) =
    let w = c.W
    match c.Route with
    | Route.CreateArticle ->
        if result = (if c.Tags.Length > 0 then 3 else 1) && not c.Found then
            c.Status <- 201
            writeArticle w r
            c.Found <- true
    | Route.UpdateArticle ->
        if c.Step = 0 then writeArticle w r
        c.Found <- true
    | Route.DeleteArticle
    | Route.DeleteComment -> c.Found <- true
    | Route.Favorite
    | Route.Unfavorite ->
        if result = 1 && not c.Found then
            writeArticle w r
            c.Found <- true
    | Route.CreateComment ->
        if not c.Found then
            c.Status <- 201
            w.WriteStartObject()
            w.WritePropertyName N.comment
            w.WriteStartObject()
            w.WriteNumber(N.id, r.Int8 0)
            time w N.createdAt (r.Micros 2)
            time w N.updatedAt (r.Micros 3)
            text w N.body r 1
            w.WritePropertyName N.author
            profile w r 4 0
            w.WriteEndObject()
            w.WriteEndObject()
            c.Found <- true
    | Route.Follow
    | Route.Unfollow ->
        if not c.Found then
            w.WriteStartObject()
            w.WritePropertyName N.profile
            profile w r 0 (if c.Route = Route.Follow then 1 else 0)
            w.WriteEndObject()
            c.Found <- true
    | Route.Register ->
        if not c.Found then
            c.Status <- 201
            user w r 0 (ReadOnlySpan(Jwt.issue (r.Int8 0)))
            c.Found <- true
    | Route.UpdateUser ->
        if not c.Found then
            user w r 0 c.Token
            c.Found <- true
    | Route.Login ->
        if not c.Found then
            c.CId <- r.Int8 0
            c.S2 <- Encoding.UTF8.GetString(r.Bytes 1)
            c.S3 <- Encoding.UTF8.GetString(r.Bytes 2)
            c.S4 <- (if r.IsNull 3 then null else Encoding.UTF8.GetString(r.Bytes 3))
            c.S5 <- (if r.IsNull 4 then null else Encoding.UTF8.GetString(r.Bytes 4))
            c.Stored <- r.Bytes(5).ToArray()
            c.Found <- true
    | _ -> ()

let private singleComplete (c: Ctx) (_result: int) (n: int64) =
    if (c.Route = Route.DeleteArticle || c.Route = Route.DeleteComment) && c.Step = 0 then c.Count <- n

let rec private singleDone (c: Ctx) (err: PgError) =
    if not (isNull err) then
        if err.SqlState = "23505" then c.Error(422, "already taken")
        elif err.SqlState = "23503" then c.Error(404, "not found")
        else
            eprintfn "%O: %O" c.Route err
            c.Error(500, "internal error")
        c.Finish()
    else
        let mutable finish = true
        match c.Route with
        | Route.CreateArticle -> if not c.Found then c.Error(500, "article not read back")
        | Route.UpdateArticle
        | Route.DeleteArticle
        | Route.DeleteComment ->
            if c.Step = 0 then
                let ok = if c.Route = Route.UpdateArticle then c.Found else c.Count > 0L
                if not ok then
                    // nothing matched: 404 if there is no such article/comment, else 403
                    c.Step <- 1
                    c.Found <- false
                    backend().Write(single c)
                    finish <- false
                elif c.Route <> Route.UpdateArticle then c.NoContent()
            else if not c.Found then
                c.Error(404, (if c.Route = Route.DeleteComment then "comment not found" else "article not found"))
            else c.Error(403, "not the author")
        | Route.Favorite
        | Route.Unfavorite
        | Route.CreateComment -> if not c.Found then c.Error(404, "article not found")
        | Route.Follow
        | Route.Unfollow -> if not c.Found then c.Error(404, "profile not found")
        | Route.Register -> if not c.Found then c.Error(500, "user not read back")
        | Route.UpdateUser -> if not c.Found then c.Error(401, "unauthorized")
        | Route.Login ->
            if not c.Found then c.Error(401, "invalid email or password")
            else
                let j = c.Job
                if j.SetPassword c.S6 && j.SetStored(ReadOnlySpan c.Stored) then
                    Bcrypt.run j // the response comes from afterBcrypt
                    finish <- false
                else c.Error(401, "invalid email or password")
        | _ -> ()
        if finish then c.Finish()

and single (c: Ctx) : PgQuery =
    if isNull c.Single then c.Single <- SingleQuery(c, writeSingle, singleRow, singleComplete, singleDone)
    c.Single

do retryAlone <- fun c -> backend().Write(single c)

/// on the Postgres thread (Backend.Post), with c.Job computed
let afterBcrypt (c: Ctx) =
    let j = c.Job
    match c.Route with
    | Route.Register
    | Route.UpdateUser ->
        if not j.Ok then
            c.Error(500, "internal error")
            c.Finish()
        else
            c.S3 <- j.HashString()
            backend().Write(single c)
    | Route.Login ->
        if not (j.Matches(ReadOnlySpan c.Stored)) then c.Error(401, "invalid email or password")
        else
            let w = c.W
            w.WriteStartObject()
            w.WritePropertyName N.user
            w.WriteStartObject()
            w.WriteString(N.email, c.S3)
            w.WriteString(N.token, ReadOnlySpan(Jwt.issue c.CId))
            w.WriteString(N.username, c.S2)
            if isNull c.S4 then w.WriteNull N.bio else w.WriteString(N.bio, c.S4)
            if isNull c.S5 then w.WriteNull N.image else w.WriteString(N.image, c.S5)
            w.WriteEndObject()
            w.WriteEndObject()
        c.Finish()
    | _ -> c.Finish()

let private unprocessable (c: Ctx) (message: string) =
    c.Error(422, message)
    c.Finish()

let private writeSingleRoute (c: Ctx) (r: Route) (key: ReadOnlySpan<byte>) =
    c.Route <- r
    if setKey c key then backend().Write(single c)

let private createArticle (c: Ctx) (body: ReadOnlySpan<byte>) =
    let msg = "title, description and body are required; tagList must be strings"
    use b = Body.Parse(body, "article")
    let mutable title = null
    let mutable description = null
    let mutable text = null
    let mutable tags: string[] = null
    if isNull b || not (b.Required("title", &title)) || not (b.Required("description", &description))
       || not (b.Required("body", &text)) || not (b.Tags(&tags)) then
        unprocessable c msg
    else
        c.Route <- Route.CreateArticle
        c.S1 <- title
        c.S2 <- description
        c.S3 <- text
        c.S4 <- Slug.make title + "-"
        c.Tags <- tags
        backend().Write(single c)

let private updateArticle (c: Ctx) (slug: ReadOnlySpan<byte>) (body: ReadOnlySpan<byte>) =
    use b = Body.Parse(body, "article")
    let mutable title = null
    let mutable description = null
    let mutable text = null
    if isNull b || not (b.Optional("title", false, &title)) || not (b.Optional("description", false, &description))
       || not (b.Optional("body", false, &text)) then
        unprocessable c "invalid article"
    else
        c.S1 <- title
        c.S2 <- description
        c.S3 <- text
        c.S4 <- (if isNull title then null else Slug.make title + "-")
        writeSingleRoute c Route.UpdateArticle slug

let private createComment (c: Ctx) (slug: ReadOnlySpan<byte>) (body: ReadOnlySpan<byte>) =
    use b = Body.Parse(body, "comment")
    let mutable text = null
    if isNull b || not (b.Required("body", &text)) then unprocessable c "body is required"
    else
        c.S1 <- text
        if Sql.CommentBatch then read c Route.CreateComment Sql.CommentW slug
        else writeSingleRoute c Route.CreateComment slug

let private register (c: Ctx) (body: ReadOnlySpan<byte>) =
    let msg = "username, email and password are required"
    use b = Body.Parse(body, "user")
    let mutable username = null
    let mutable email = null
    let mutable password = null
    if isNull b || not (b.Required("username", &username)) || not (b.Required("email", &email))
       || not (b.Required("password", &password)) then
        unprocessable c msg
    elif not (c.Job.SetPassword password) then unprocessable c "password is longer than 72 bytes"
    else
        c.Route <- Route.Register
        c.S1 <- username
        c.S2 <- email
        c.Job.NewSalt()
        Bcrypt.run c.Job

let private login (c: Ctx) (body: ReadOnlySpan<byte>) =
    use b = Body.Parse(body, "user")
    let mutable email = null
    let mutable password = null
    if isNull b || not (b.Required("email", &email)) || not (b.Required("password", &password)) then
        unprocessable c "email and password are required"
    else
        c.Route <- Route.Login
        c.S1 <- email
        c.S6 <- password
        backend().Read(single c) // a read: not behind commits

let private updateUser (c: Ctx) (body: ReadOnlySpan<byte>) =
    use b = Body.Parse(body, "user")
    let mutable email = null
    let mutable username = null
    let mutable password = null
    let mutable bio = null
    let mutable image = null
    if isNull b || not (b.Optional("email", false, &email)) || not (b.Optional("username", false, &username))
       || not (b.Optional("password", false, &password)) || not (b.Optional("bio", true, &bio))
       || not (b.Optional("image", true, &image)) then
        unprocessable c "invalid user"
    elif not (isNull password) && not (c.Job.SetPassword password) then
        unprocessable c "password is longer than 72 bytes"
    else
        c.Route <- Route.UpdateUser
        c.S1 <- email
        c.S2 <- username
        c.S4 <- bio
        c.S5 <- image
        if isNull password then backend().Write(single c)
        else
            c.Job.NewSalt()
            Bcrypt.run c.Job

// ---------- routing (I/O loop) ----------

let private methodOf (m: ReadOnlySpan<byte>) =
    if m.SequenceEqual bGet then Get
    elif m.SequenceEqual bPost then Post
    elif m.SequenceEqual bPut then Put
    elif m.SequenceEqual bDelete then Delete
    else 0

let private route (c: Ctx) (meth: ReadOnlySpan<byte>) (path: ReadOnlySpan<byte>) (query: ReadOnlySpan<byte>)
                  (hasAuth: bool) (auth: ReadOnlySpan<byte>) (body: ReadOnlySpan<byte>) =
    let m = methodOf meth
    if not (path.StartsWith bApi) then notFound c
    else
        let mutable rest = path.Slice 5
        if rest.Length > 0 && rest.[rest.Length - 1] = '/'B then rest <- rest.Slice(0, rest.Length - 1)
        // up to 4 segments separated by '/'
        let mutable n = 0
        let mutable s0 = ReadOnlySpan<byte>.Empty
        let mutable s1 = ReadOnlySpan<byte>.Empty
        let mutable s2 = ReadOnlySpan<byte>.Empty
        let mutable s3 = ReadOnlySpan<byte>.Empty
        let mutable r = rest
        let mutable go = true
        while go do
            let sl = r.IndexOf '/'B
            let seg = if sl < 0 then r else r.Slice(0, sl)
            match n with
            | 0 -> s0 <- seg
            | 1 -> s1 <- seg
            | 2 -> s2 <- seg
            | 3 -> s3 <- seg
            | _ -> ()
            n <- n + 1
            if sl < 0 then go <- false else r <- r.Slice(sl + 1)
        if n > 4 then notFound c
        else
            // authentication: 1 = valid token, 0 = none, -1 = present but invalid
            let mutable a = 0
            if hasAuth then
                a <- -1
                if auth.StartsWith bToken then
                    let tok = auth.Slice 6
                    let id = Jwt.verify tok
                    if id > 0L then
                        a <- 1
                        c.Viewer <- id
                        c.TokOff <- c.Put tok
                        c.TokLen <- tok.Length
            if s0.SequenceEqual bArticles then
                if n = 1 then
                    if m = Get then (if optional c a then list c query)
                    elif m = Post then (if required c a then createArticle c body)
                    else notFound c
                elif n = 2 then
                    if m = Get && s1.SequenceEqual bFeed then (if required c a then feed c query)
                    elif m = Get then (if optional c a then read c Route.Article Sql.Article s1)
                    elif m = Put then (if required c a then updateArticle c s1 body)
                    elif m = Delete then (if required c a then writeSingleRoute c Route.DeleteArticle s1)
                    else notFound c
                elif s2.SequenceEqual bComments then
                    if n = 3 && m = Get then (if optional c a then read c Route.Comments Sql.Comments s1)
                    elif n = 3 && m = Post then (if required c a then createComment c s1 body)
                    elif n = 4 && m = Delete then
                        if required c a then
                            let mutable id = 0L
                            if not (digits s3 &id) then
                                c.Error(404, "comment not found")
                                c.Finish()
                            else
                                c.CId <- id
                                writeSingleRoute c Route.DeleteComment s1
                    else notFound c
                elif n = 3 && s2.SequenceEqual bFavorite && (m = Post || m = Delete) then
                    if required c a then
                        if Sql.WriteBatch then
                            if m = Post then read c Route.Favorite Sql.FavoriteW s1 else read c Route.Unfavorite Sql.UnfavoriteW s1
                        else writeSingleRoute c (if m = Post then Route.Favorite else Route.Unfavorite) s1
                else notFound c
            elif s0.SequenceEqual bTags && n = 1 && m = Get then
                c.Route <- Route.Tags
                backend().Enqueue(c, Sql.Tags)
            elif s0.SequenceEqual bProfiles && n >= 2 then
                if n = 2 && m = Get then (if optional c a then read c Route.Profile Sql.Profile s1)
                elif n = 3 && s2.SequenceEqual bFollow && (m = Post || m = Delete) then
                    if required c a then
                        if Sql.WriteBatch then
                            if m = Post then read c Route.Follow Sql.FollowW s1 else read c Route.Unfollow Sql.UnfollowW s1
                        else writeSingleRoute c (if m = Post then Route.Follow else Route.Unfollow) s1
                else notFound c
            elif s0.SequenceEqual bUser && n = 1 then
                if m = Get then
                    if required c a then
                        c.Route <- Route.User
                        backend().Enqueue(c, Sql.User)
                elif m = Put then (if required c a then updateUser c body)
                else notFound c
            elif s0.SequenceEqual bUsers && m = Post && n = 1 then register c body
            elif s0.SequenceEqual bUsers && m = Post && n = 2 && s1.SequenceEqual bLogin then login c body
            else notFound c

/// A parsed request, on its I/O loop. The response comes back to the loop through c.Finish (Owner.Send).
let start (c: Ctx) (meth: ReadOnlySpan<byte>) (path: ReadOnlySpan<byte>) (query: ReadOnlySpan<byte>)
          (hasAuth: bool) (auth: ReadOnlySpan<byte>) (body: ReadOnlySpan<byte>) =
    try route c meth path query hasAuth auth body
    with e ->
        eprintfn "%O" e
        c.Error(500, "internal error")
        c.Finish()
