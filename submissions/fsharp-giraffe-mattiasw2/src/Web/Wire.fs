/// The wire: request bodies and query strings in, JSON out. Pure, no HttpContext, so every
/// rule SPEC.md and the conformance suite state about shapes is a plain unit test.
module Web.Wire

#nowarn "9" // NativePtr.stackalloc: the timestamp's 32-byte stack buffer

open System
open System.Buffers
open System.Globalization
open Microsoft.FSharp.NativeInterop
open System.Text.Encodings.Web
open System.Text.Json
open Engine

// ------------------------------------------------------------------ out --------

let private writerOptions =
    JsonWriterOptions(Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping, SkipValidation = true)

/// A response body in a buffer rented from the shared pool. It is sent once, and `Release`
/// returns the buffer (the body must not be used after that).
[<Struct; NoEquality; NoComparison>]
type Body =
    { Buffer: byte[]
      Length: int }

    member b.Memory = ReadOnlyMemory<byte>(b.Buffer, 0, b.Length)
    member b.Span = ReadOnlySpan<byte>(b.Buffer, 0, b.Length)
    member b.Release() = ArrayPool<byte>.Shared.Return b.Buffer

/// An IBufferWriter over pooled arrays: grows by renting a bigger one, and `Take` hands the
/// written bytes over as a Body (the writer then starts afresh).
[<Sealed; AllowNullLiteral>]
type private PooledWriter() =
    let mutable buffer: byte[] = null
    let mutable written = 0

    member private _.Ensure(hint: int) =
        let need = written + max hint 1
        if isNull buffer then
            buffer <- ArrayPool<byte>.Shared.Rent(max need 16384)
        elif need > buffer.Length then
            let bigger = ArrayPool<byte>.Shared.Rent(max need (buffer.Length * 2))
            Buffer.BlockCopy(buffer, 0, bigger, 0, written)
            ArrayPool<byte>.Shared.Return buffer
            buffer <- bigger

    member _.Take() : Body =
        let body = { Buffer = buffer; Length = written }
        buffer <- null
        written <- 0
        body

    interface IBufferWriter<byte> with
        member _.Advance(count: int) = written <- written + count

        member this.GetMemory(hint: int) =
            this.Ensure hint
            Memory<byte>(buffer, written, buffer.Length - written)

        member this.GetSpan(hint: int) =
            this.Ensure hint
            Span<byte>(buffer, written, buffer.Length - written)

/// One writer and one Utf8JsonWriter per thread: rendering is synchronous, so a thread never
/// renders two bodies at once.
[<Sealed; AbstractClass>]
type private Scratch =
    [<ThreadStatic; DefaultValue>]
    static val mutable private output: PooledWriter

    [<ThreadStatic; DefaultValue>]
    static val mutable private json: Utf8JsonWriter

    static member Get() : struct (PooledWriter * Utf8JsonWriter) =
        if isNull Scratch.output then
            Scratch.output <- PooledWriter()
            Scratch.json <- new Utf8JsonWriter(Scratch.output, writerOptions)
        else
            Scratch.json.Reset(Scratch.output)
        struct (Scratch.output, Scratch.json)

/// One response body, written into a pooled buffer by this thread's writer.
let render (write: Utf8JsonWriter -> unit) : Body =
    let struct (output, w) = Scratch.Get()
    write w
    w.Flush()
    output.Take()

let private timestampFormat = "yyyy-MM-dd'T'HH:mm:ss.fff'Z'"

/// RFC 3339, UTC, exactly three fractional digits, truncated (`fff` truncates, never rounds).
let timestamp (d: DateTime) : string =
    d.ToUniversalTime().ToString(timestampFormat, CultureInfo.InvariantCulture)

/// `timestamp`, written as UTF-8 straight from a stack buffer: no string per field.
let private writeTimestamp (w: Utf8JsonWriter) (name: JsonEncodedText) (d: DateTime) =
    let utf8 = Span<byte>(NativePtr.toVoidPtr (NativePtr.stackalloc<byte> 32), 32)
    let mutable written = 0
    if d.ToUniversalTime().TryFormat(utf8, &written, timestampFormat.AsSpan(), CultureInfo.InvariantCulture) then
        let value: ReadOnlySpan<byte> = Span.op_Implicit (utf8.Slice(0, written))
        w.WriteString(name, value)
    else
        w.WriteString(name, timestamp d)

let private k (name: string) = JsonEncodedText.Encode name
let private kUser = k "user"
let private kEmail = k "email"
let private kToken = k "token"
let private kUsername = k "username"
let private kBio = k "bio"
let private kImage = k "image"
let private kFollowing = k "following"
let private kProfile = k "profile"
let private kSlug = k "slug"
let private kTitle = k "title"
let private kDescription = k "description"
let private kBody = k "body"
let private kTagList = k "tagList"
let private kCreatedAt = k "createdAt"
let private kUpdatedAt = k "updatedAt"
let private kFavorited = k "favorited"
let private kFavoritesCount = k "favoritesCount"
let private kAuthor = k "author"
let private kArticle = k "article"
let private kArticles = k "articles"
let private kArticlesCount = k "articlesCount"
let private kId = k "id"
let private kComment = k "comment"
let private kComments = k "comments"
let private kTags = k "tags"
let private kErrors = k "errors"

let private nullable (w: Utf8JsonWriter) (name: JsonEncodedText) (value: string option) =
    match value with
    | Some s -> w.WriteString(name, s)
    | None -> w.WriteNull name

let private writeProfile (w: Utf8JsonWriter) (p: Profile) =
    w.WriteStartObject()
    w.WriteString(kUsername, p.Username)
    nullable w kBio p.Bio
    nullable w kImage p.Image
    w.WriteBoolean(kFollowing, p.Following)
    w.WriteEndObject()

let private writeAuthor (w: Utf8JsonWriter) (a: Author) (following: bool) =
    w.WriteStartObject()
    w.WriteString(kUsername, a.Username)
    nullable w kBio a.Bio
    nullable w kImage a.Image
    w.WriteBoolean(kFollowing, following)
    w.WriteEndObject()

/// A list never shows a body, even when the shared card has one (an article page in the same
/// batch needed it).
let private writeArticle (w: Utf8JsonWriter) (withBody: bool) (a: Article) =
    let c = a.Card
    w.WriteStartObject()
    w.WriteString(kSlug, c.Slug)
    w.WriteString(kTitle, c.Title)
    w.WriteString(kDescription, c.Description)
    match c.Body with
    | Some body when withBody -> w.WriteString(kBody, body)
    | _ -> ()
    w.WriteStartArray kTagList
    for t in c.TagList do
        w.WriteStringValue t
    w.WriteEndArray()
    writeTimestamp w kCreatedAt c.CreatedAt
    writeTimestamp w kUpdatedAt c.UpdatedAt
    w.WriteBoolean(kFavorited, a.Favorited)
    w.WriteNumber(kFavoritesCount, c.FavoritesCount)
    w.WritePropertyName kAuthor
    writeAuthor w c.Author a.Following
    w.WriteEndObject()

let private writeComment (w: Utf8JsonWriter) (c: Comment) =
    w.WriteStartObject()
    w.WriteNumber(kId, c.Card.Id)
    writeTimestamp w kCreatedAt c.Card.CreatedAt
    writeTimestamp w kUpdatedAt c.Card.UpdatedAt
    w.WriteString(kBody, c.Card.Body)
    w.WritePropertyName kAuthor
    writeAuthor w c.Card.Author c.Following
    w.WriteEndObject()

/// `{"user": User}`
let user (u: User) (token: string) =
    render (fun w ->
        w.WriteStartObject()
        w.WriteStartObject kUser
        w.WriteString(kEmail, u.Email)
        w.WriteString(kToken, token)
        w.WriteString(kUsername, u.Username)
        nullable w kBio u.Bio
        nullable w kImage u.Image
        w.WriteEndObject()
        w.WriteEndObject())

let profile (p: Profile) =
    render (fun w ->
        w.WriteStartObject()
        w.WritePropertyName kProfile
        writeProfile w p
        w.WriteEndObject())

let article (a: Article) =
    render (fun w ->
        w.WriteStartObject()
        w.WritePropertyName kArticle
        writeArticle w true a
        w.WriteEndObject())

let articles (page: ArticlePage) =
    render (fun w ->
        w.WriteStartObject()
        w.WriteStartArray kArticles
        for a in page.Articles do
            writeArticle w false a
        w.WriteEndArray()
        w.WriteNumber(kArticlesCount, page.Count)
        w.WriteEndObject())

let comment (c: Comment) =
    render (fun w ->
        w.WriteStartObject()
        w.WritePropertyName kComment
        writeComment w c
        w.WriteEndObject())

let comments (cs: Comment list) =
    render (fun w ->
        w.WriteStartObject()
        w.WriteStartArray kComments
        for c in cs do
            writeComment w c
        w.WriteEndArray()
        w.WriteEndObject())

let tags (names: string list) =
    render (fun w ->
        w.WriteStartObject()
        w.WriteStartArray kTags
        for n in names do
            w.WriteStringValue n
        w.WriteEndArray()
        w.WriteEndObject())

/// `{"errors": {"body": ["<message>"]}}`, every error status.
let error (message: string) =
    render (fun w ->
        w.WriteStartObject()
        w.WriteStartObject kErrors
        w.WriteStartArray kBody
        w.WriteStringValue message
        w.WriteEndArray()
        w.WriteEndObject()
        w.WriteEndObject())

// ------------------------------------------------------------------- in --------

type ResultBuilder() =
    member _.Bind(r: Result<'a, 'e>, f: 'a -> Result<'b, 'e>) = Result.bind f r
    member _.Return(x: 'a) : Result<'a, 'e> = Ok x
    member _.ReturnFrom(r: Result<'a, 'e>) = r

let private result = ResultBuilder()

/// One property of a request object. Keys match case-sensitively (`"User"` is not `"user"`).
type Field =
    | Absent
    | Null
    | Text of string
    | Wrong

let field (o: JsonElement) (name: string) : Field =
    match o.TryGetProperty name with
    | false, _ -> Absent
    | true, v when v.ValueKind = JsonValueKind.Null -> Null
    | true, v when v.ValueKind = JsonValueKind.String -> Text(v.GetString())
    | true, _ -> Wrong

/// The `{"<wrapper>": {...}}` object every request body is wrapped in.
let wrapped (root: JsonElement) (wrapper: string) : Result<JsonElement, string> =
    if root.ValueKind <> JsonValueKind.Object then
        Error "the body must be a JSON object"
    else
        match root.TryGetProperty wrapper with
        | true, v when v.ValueKind = JsonValueKind.Object -> Ok v
        | _ -> Error $"the body must be {{\"{wrapper}\": {{...}}}}"

let private required (o: JsonElement) (name: string) : Result<string, string> =
    match field o name with
    | Text s when s <> "" -> Ok s
    | _ -> Error $"{name} must be a non-empty string"

/// Absent or null = unchanged; otherwise a string, non-empty unless `emptyOk`.
let private optional (o: JsonElement) (name: string) (emptyOk: bool) : Result<string option, string> =
    match field o name with
    | Absent
    | Null -> Ok None
    | Text s when emptyOk || s <> "" -> Ok(Some s)
    | Text _ -> Error $"{name} must not be empty"
    | Wrong -> Error $"{name} must be a string"

let private bcryptable (password: string) =
    if Passwords.fits password then Ok password else Error "password must be at most 72 bytes"

type Registration = { Username: string; Email: string; Password: string }

let registration (root: JsonElement) : Result<Registration, string> =
    result {
        let! u = wrapped root "user"
        let! username = required u "username"
        let! email = required u "email"
        let! password = required u "password" |> Result.bind bcryptable
        return { Username = username; Email = email; Password = password }
    }

type Login = { Email: string; Password: string }

let login (root: JsonElement) : Result<Login, string> =
    result {
        let! u = wrapped root "user"
        let! email = required u "email"
        let! password = required u "password"
        return { Email = email; Password = password }
    }

type UserEdit =
    { Email: string option
      Username: string option
      Password: string option
      Bio: string option
      Image: string option }

let userEdit (root: JsonElement) : Result<UserEdit, string> =
    result {
        let! u = wrapped root "user"
        let! email = optional u "email" false
        let! username = optional u "username" false
        let! password = optional u "password" false
        let! _ =
            match password with
            | Some p -> bcryptable p |> Result.map ignore
            | None -> Ok()
        let! bio = optional u "bio" true
        let! image = optional u "image" true
        return
            { Email = email
              Username = username
              Password = password
              Bio = bio
              Image = image }
    }

type NewArticle =
    { Title: string
      Description: string
      Body: string
      Tags: string[] }

/// tagList: absent, null or an array of non-empty strings.
let private tagList (o: JsonElement) : Result<string[], string> =
    match o.TryGetProperty "tagList" with
    | false, _ -> Ok [||]
    | true, v when v.ValueKind = JsonValueKind.Null -> Ok [||]
    | true, v when v.ValueKind = JsonValueKind.Array ->
        let tags = Array.zeroCreate (v.GetArrayLength())
        let mutable ok = true
        let mutable i = 0
        for t in v.EnumerateArray() do
            if t.ValueKind = JsonValueKind.String && t.GetString() <> "" then
                tags[i] <- t.GetString()
            else
                ok <- false
            i <- i + 1
        if ok then Ok tags else Error "tagList must hold non-empty strings"
    | true, _ -> Error "tagList must be an array"

let newArticle (root: JsonElement) : Result<NewArticle, string> =
    result {
        let! a = wrapped root "article"
        let! title = required a "title"
        let! description = required a "description"
        let! body = required a "body"
        let! tags = tagList a
        return
            { Title = title
              Description = description
              Body = body
              Tags = tags }
    }

let articleEdit (root: JsonElement) : Result<Articles.Edit, string> =
    result {
        let! a = wrapped root "article"
        let! title = optional a "title" false
        let! description = optional a "description" false
        let! body = optional a "body" false
        return
            { Title = title
              Description = description
              Body = body }
    }

let newComment (root: JsonElement) : Result<string, string> =
    result {
        let! c = wrapped root "comment"
        return! required c "body"
    }

/// A query integer: ASCII digits only (leading zeros fine; no sign, space, point or overflow).
let private integer (s: string) : int64 voption =
    match Int64.TryParse(s, NumberStyles.None, CultureInfo.InvariantCulture) with
    | true, v -> ValueSome v
    | _ -> ValueNone

/// `limit` (default 20, 1–100) and `offset` (default 0, ≥ 0); anything else is a 422.
let paging (query: string -> string option) : Result<Paging, string> =
    let limit =
        match query "limit" with
        | None -> Ok 20L
        | Some s ->
            match integer s with
            | ValueSome v when v >= 1L && v <= 100L -> Ok v
            | _ -> Error "limit must be an integer from 1 to 100"
    let offset =
        match query "offset" with
        | None -> Ok 0L
        | Some s ->
            match integer s with
            | ValueSome v -> Ok v
            | ValueNone -> Error "offset must be a non-negative integer"
    match limit, offset with
    | Ok l, Ok o -> Ok { Limit = l; Offset = o }
    | Error e, _
    | _, Error e -> Error e

/// The first non-empty of tag, author, favorited (an empty value counts as not given).
let filter (query: string -> string option) : ArticleFilter =
    let given name =
        match query name with
        | Some v when v <> "" -> Some v
        | _ -> None
    match given "tag", given "author", given "favorited" with
    | Some t, _, _ -> ByTag t
    | None, Some a, _ -> ByAuthor a
    | None, None, Some f -> FavoritedBy f
    | None, None, None -> Everything

/// A comment id in the path: an integer, or the route does not exist (404).
let commentId (s: string) : int64 voption =
    match integer s with
    | ValueSome v when v > 0L -> ValueSome v
    | _ -> ValueNone
