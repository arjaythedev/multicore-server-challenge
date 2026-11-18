/// Routing, authentication and request validation, on the I/O thread. Valid requests become jobs for the
/// Postgres lanes (or the bcrypt threads first); invalid ones are answered at once.
module Api

open System
open System.Buffers.Text
open System.Text
open System.Text.Json
open Io
open Json
open Store

// ---------------- request pieces ----------------

/// percent-decoding (and '+' as space in query strings) to a .NET string
let private decode (s: ReadOnlySpan<byte>) (plus: bool) : string =
    if s.IndexOfAny("%+"B) < 0 then Encoding.UTF8.GetString s
    else
        let out = Array.zeroCreate<byte> s.Length
        let mutable n = 0
        let mutable i = 0
        let hex (b: byte) =
            if b >= '0'B && b <= '9'B then int b - 48
            elif b >= 'a'B && b <= 'f'B then int b - 87
            elif b >= 'A'B && b <= 'F'B then int b - 55
            else -1
        while i < s.Length do
            let b = s.[i]
            if b = '%'B && i + 2 < s.Length && hex s.[i + 1] >= 0 && hex s.[i + 2] >= 0 then
                out.[n] <- byte (hex s.[i + 1] * 16 + hex s.[i + 2])
                i <- i + 3
            elif b = '+'B && plus then
                out.[n] <- ' 'B
                i <- i + 1
            else
                out.[n] <- b
                i <- i + 1
            n <- n + 1
        Encoding.UTF8.GetString(out, 0, n)

/// the first value of a query parameter (decoded), or null when absent
let private queryGet (q: ReadOnlySpan<byte>) (key: ReadOnlySpan<byte>) : string =
    let mutable rest = q
    let mutable found: string = null
    let mutable go = true
    while go && rest.Length > 0 do
        let amp = rest.IndexOf '&'B
        let part = if amp >= 0 then rest.Slice(0, amp) else rest
        let eq = part.IndexOf '='B
        let k = if eq >= 0 then part.Slice(0, eq) else part
        if k.SequenceEqual key then
            found <- (if eq >= 0 then decode (part.Slice(eq + 1)) true else "")
            go <- false
        rest <- if amp >= 0 then rest.Slice(amp + 1) else ReadOnlySpan.Empty
    found

/// a non-negative decimal integer (digits only); -1 if malformed or out of range
let private parseNat (s: string) : int64 =
    if isNull s || s.Length = 0 || s.Length > 19 then -1L
    elif s |> Seq.forall Char.IsAsciiDigit then
        match Int64.TryParse(s, Globalization.NumberStyles.None, Globalization.CultureInfo.InvariantCulture) with
        | true, v -> v
        | _ -> -1L
    else -1L

/// Authorization: "Token <jwt>". The user id, 0 when there is no header, -1 when it's present but not valid.
let private viewerOf (r: Request) : int64 =
    if not r.HasAuth then 0L
    else
        let v = r.Auth.Span
        if v.Length > 6 && v.StartsWith "Token "B then Auth.verify (v.Slice 6) else -1L

let private tokenOf (r: Request) = Encoding.ASCII.GetString(r.Auth.Span.Slice 6)

type private Field =
    | Absent
    | Null
    | Str of string
    | Bad

/// {"<wrapper>": {...}} parsed; None when malformed or the wrapper isn't an object
let private wrapped (body: ReadOnlyMemory<byte>) (wrapper: string) : JsonElement option =
    try
        use doc = JsonDocument.Parse(body)
        let root = doc.RootElement
        if root.ValueKind = JsonValueKind.Object then
            match root.TryGetProperty wrapper with
            | true, o when o.ValueKind = JsonValueKind.Object -> Some(o.Clone())
            | _ -> None
        else None
    with _ -> None

let private field (o: JsonElement) (name: string) =
    match o.TryGetProperty name with
    | false, _ -> Absent
    | true, v ->
        match v.ValueKind with
        | JsonValueKind.Null -> Null
        | JsonValueKind.String -> Str(v.GetString())
        | _ -> Bad

/// a required non-empty string
let private required (f: Field) =
    match f with
    | Str s when s.Length > 0 -> s
    | _ -> null

/// an optional field: Some null = unchanged, Some s = new value, None = invalid
let private optional (nonEmpty: bool) (f: Field) =
    match f with
    | Absent
    | Null -> Some null
    | Str s when not nonEmpty || s.Length > 0 -> Some s
    | _ -> None

let private bad = unprocessable "invalid request"

// ---------------- endpoints ----------------

let private list (d: Dest) (r: Request) (kind: int) (viewer: int64) =
    let q = r.Query.Span
    let lim = queryGet q "limit"B
    let off = queryGet q "offset"B
    let limit = if isNull lim then 20L else parseNat lim
    let offset = if isNull off then 0L else parseNat off
    if limit < 1L || limit > 100L || offset < 0L then bad
    else
        let j = RJob(RKind.List, d, Viewer = viewer, Limit = int limit, Offset = offset, ListKind = kind)
        if kind <> ListFeed then
            // only the first filter given applies, in this order; an empty value counts as absent
            let tag = queryGet q "tag"B
            let author = queryGet q "author"B
            let fav = queryGet q "favorited"B
            if not (String.IsNullOrEmpty tag) then
                j.ListKind <- ListTag
                j.Key <- tag
            elif not (String.IsNullOrEmpty author) then
                j.ListKind <- ListAuthor
                j.Key <- author
            elif not (String.IsNullOrEmpty fav) then
                j.ListKind <- ListFavorited
                j.Key <- fav
        pushRead j
        null

let private register (d: Dest) (r: Request) =
    match wrapped r.Body "user" with
    | None -> bad
    | Some o ->
        let u = required (field o "username")
        let e = required (field o "email")
        let p = required (field o "password")
        if isNull u || isNull e || isNull p then bad
        else
            let pw = Encoding.UTF8.GetBytes p
            if pw.Length > 72 then bad
            else
                Auth.hash pw (fun h ->
                    if isNull h then post d (Json.error 500 "hash failed")
                    else pushWrite (WJob(WKind.Signup, d, Username = u, Email = e, Hash = h)))
                null

let private login (d: Dest) (r: Request) =
    match wrapped r.Body "user" with
    | None -> bad
    | Some o ->
        let e = required (field o "email")
        let p = required (field o "password")
        if isNull e || isNull p then bad
        else
            pushRead (RJob(RKind.Login, d, Key = e, Password = Encoding.UTF8.GetBytes p))
            null

let private updateUser (d: Dest) (r: Request) (viewer: int64) =
    match wrapped r.Body "user" with
    | None -> bad
    | Some o ->
        match optional true (field o "email"), optional true (field o "username"), optional true (field o "password"),
              optional false (field o "bio"), optional false (field o "image") with
        | Some email, Some username, Some password, Some bio, Some image ->
            let j = WJob(WKind.UpdateUser, d, Viewer = viewer, Token = tokenOf r, Email = email, Username = username, Bio = bio, Image = image)
            if isNull password then
                pushWrite j
                null
            else
                let pw = Encoding.UTF8.GetBytes password
                if pw.Length > 72 then bad
                else
                    Auth.hash pw (fun h ->
                        j.Hash <- h
                        pushWrite j)
                    null
        | _ -> bad

let private createArticle (d: Dest) (r: Request) (viewer: int64) =
    match wrapped r.Body "article" with
    | None -> bad
    | Some o ->
        let t = required (field o "title")
        let ds = required (field o "description")
        let b = required (field o "body")
        let tags =
            match o.TryGetProperty "tagList" with
            | false, _ -> Some [||]
            | true, v when v.ValueKind = JsonValueKind.Null -> Some [||]
            | true, v when v.ValueKind = JsonValueKind.Array ->
                let items = [| for x in v.EnumerateArray() -> if x.ValueKind = JsonValueKind.String then x.GetString() else null |]
                if items |> Array.exists String.IsNullOrEmpty then None else Some items
            | _ -> None
        match tags with
        | Some tl when not (isNull t || isNull ds || isNull b) ->
            pushWrite (WJob(WKind.ArticleCreate, d, Viewer = viewer, Title = t, Description = ds, Body = b, TagList = Array.distinct tl))
            null
        | _ -> bad

let private updateArticle (d: Dest) (r: Request) (viewer: int64) (slug: string) =
    match wrapped r.Body "article" with
    | None -> bad
    | Some o ->
        match optional true (field o "title"), optional true (field o "description"), optional true (field o "body") with
        | Some t, Some ds, Some b ->
            pushWrite (WJob(WKind.ArticleUpdate, d, Viewer = viewer, Key = slug, Title = t, Description = ds, Body = b))
            null
        | _ -> bad

let private addComment (d: Dest) (r: Request) (viewer: int64) (slug: string) =
    match wrapped r.Body "comment" with
    | None -> bad
    | Some o ->
        match required (field o "body") with
        | null -> bad
        | b ->
            pushWrite (WJob(WKind.CommentAdd, d, Viewer = viewer, Key = slug, Text = b))
            null

/// The handler: returns the response now, or null when a lane will answer.
let handle (d: Dest) (r: Request) : byte[] =
    let path = r.Path.Span
    if not (path.StartsWith "/api/"B) then notFound
    else
        let p = path.Slice 5
        let m = r.Method
        // split the rest into up to 5 segments
        let segs = Array.zeroCreate<string> 5
        let mutable n = 0
        let mutable rest = p
        let mutable tooMany = false
        while rest.Length > 0 && not tooMany do
            let s = rest.IndexOf '/'B
            let seg = if s >= 0 then rest.Slice(0, s) else rest
            if n = 5 then tooMany <- true
            else
                segs.[n] <- decode seg false
                n <- n + 1
            rest <- if s >= 0 then rest.Slice(s + 1) else ReadOnlySpan.Empty
        if tooMany || (n > 0 && segs.[n - 1] = "") then notFound
        else
            let viewer = lazy (viewerOf r)
            /// auth required: the user id, or None (answer 401)
            let need () = let v = viewer.Value in if v > 0L then Some v else None
            /// auth optional: 0 anonymous, the user id, or None (header present but invalid: 401)
            let opt () = let v = viewer.Value in if v >= 0L then Some v else None
            match n, segs.[0] with
            | 1, "tags" when m = 'G'B ->
                pushRead (RJob(RKind.Tags, d))
                null
            | 1, "users" when m = 'P'B -> register d r
            | 2, "users" when m = 'P'B && segs.[1] = "login" -> login d r
            | 1, "user" when m = 'G'B ->
                match need () with
                | Some v ->
                    pushRead (RJob(RKind.User, d, Viewer = v, Token = tokenOf r))
                    null
                | None -> unauthorized
            | 1, "user" when m = 'U'B ->
                match need () with
                | Some v -> updateUser d r v
                | None -> unauthorized
            | 2, "profiles" when m = 'G'B ->
                match opt () with
                | Some v ->
                    pushRead (RJob(RKind.Profile, d, Viewer = v, Key = segs.[1]))
                    null
                | None -> unauthorized
            | 3, "profiles" when segs.[2] = "follow" && (m = 'P'B || m = 'D'B) ->
                match need () with
                | Some v ->
                    pushWrite (WJob((if m = 'P'B then WKind.FollowAdd else WKind.FollowDel), d, Viewer = v, Key = segs.[1]))
                    null
                | None -> unauthorized
            | 1, "articles" when m = 'G'B ->
                match opt () with
                | Some v -> list d r ListGlobal v
                | None -> unauthorized
            | 1, "articles" when m = 'P'B ->
                match need () with
                | Some v -> createArticle d r v
                | None -> unauthorized
            | 2, "articles" when segs.[1] = "feed" && m = 'G'B ->
                match need () with
                | Some v -> list d r ListFeed v
                | None -> unauthorized
            | 2, "articles" ->
                let slug = segs.[1]
                match m with
                | 'G'B ->
                    match opt () with
                    | Some v ->
                        pushRead (RJob(RKind.Article, d, Viewer = v, Key = slug))
                        null
                    | None -> unauthorized
                | 'U'B ->
                    match need () with
                    | Some v -> updateArticle d r v slug
                    | None -> unauthorized
                | 'D'B ->
                    match need () with
                    | Some v ->
                        pushWrite (WJob(WKind.ArticleDelete, d, Viewer = v, Key = slug))
                        null
                    | None -> unauthorized
                | _ -> notFound
            | 3, "articles" when segs.[2] = "favorite" && (m = 'P'B || m = 'D'B) ->
                match need () with
                | Some v ->
                    pushWrite (WJob((if m = 'P'B then WKind.FavAdd else WKind.FavDel), d, Viewer = v, Key = segs.[1]))
                    null
                | None -> unauthorized
            | 3, "articles" when segs.[2] = "comments" ->
                match m with
                | 'G'B ->
                    match opt () with
                    | Some v ->
                        pushRead (RJob(RKind.Comments, d, Viewer = v, Key = segs.[1]))
                        null
                    | None -> unauthorized
                | 'P'B ->
                    match need () with
                    | Some v -> addComment d r v segs.[1]
                    | None -> unauthorized
                | _ -> notFound
            | 4, "articles" when segs.[2] = "comments" && m = 'D'B ->
                match need () with
                | Some v ->
                    let id = parseNat segs.[3]
                    if id <= 0L then notFound
                    else
                        pushWrite (WJob(WKind.CommentDel, d, Viewer = v, Key = segs.[1], CommentId = id))
                        null
                | None -> unauthorized
            | _ -> notFound
