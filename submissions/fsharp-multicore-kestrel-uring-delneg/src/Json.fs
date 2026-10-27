/// Response JSON, written straight from Postgres's binary rows (Pg.PgRow) with Utf8JsonWriter: text columns are
/// UTF-8 in the row and go in as UTF-8, no strings. Request bodies (writes only) are parsed with JsonDocument.
/// Ported from #22 (csharp-sockets-jh-d, MIT).
module Json

open System
open System.Buffers
open System.Buffers.Binary
open System.Buffers.Text
open System.Text.Json
open Pg

/// JSON property names, encoded once.
module N =
    let article = JsonEncodedText.Encode "article"
    let articles = JsonEncodedText.Encode "articles"
    let articlesCount = JsonEncodedText.Encode "articlesCount"
    let author = JsonEncodedText.Encode "author"
    let bio = JsonEncodedText.Encode "bio"
    let body = JsonEncodedText.Encode "body"
    let comment = JsonEncodedText.Encode "comment"
    let comments = JsonEncodedText.Encode "comments"
    let createdAt = JsonEncodedText.Encode "createdAt"
    let description = JsonEncodedText.Encode "description"
    let email = JsonEncodedText.Encode "email"
    let errors = JsonEncodedText.Encode "errors"
    let favorited = JsonEncodedText.Encode "favorited"
    let favoritesCount = JsonEncodedText.Encode "favoritesCount"
    let following = JsonEncodedText.Encode "following"
    let id = JsonEncodedText.Encode "id"
    let image = JsonEncodedText.Encode "image"
    let profile = JsonEncodedText.Encode "profile"
    let slug = JsonEncodedText.Encode "slug"
    let tagList = JsonEncodedText.Encode "tagList"
    let tags = JsonEncodedText.Encode "tags"
    let title = JsonEncodedText.Encode "title"
    let token = JsonEncodedText.Encode "token"
    let updatedAt = JsonEncodedText.Encode "updatedAt"
    let user = JsonEncodedText.Encode "user"
    let username = JsonEncodedText.Encode "username"

/// true when the database orders text by code point (C / C.UTF-8 / POSIX): the app then sorts tag names itself by
/// UTF-8 bytes, which is exactly ORDER BY name (#22, #59).
let mutable appSortsTags = false

let inline text (w: Utf8JsonWriter) (name: JsonEncodedText) (r: PgRow) (i: int) = w.WriteString(name, r.Bytes i)

let nullableText (w: Utf8JsonWriter) (name: JsonEncodedText) (r: PgRow) (i: int) =
    if r.IsNull i then w.WriteNull name else w.WriteString(name, r.Bytes i)

/// per-thread scratch (a module cannot hold [<ThreadStatic>] fields)
type private Tls =
    [<ThreadStatic; DefaultValue>]
    static val mutable private items: struct (int * int)[]
    [<ThreadStatic; DefaultValue>]
    static val mutable private iso: byte[]
    static member Items
        with get () = Tls.items
        and set v = Tls.items <- v
    static member Iso
        with get () = Tls.iso
        and set v = Tls.iso <- v

let private greater (b: ReadOnlySpan<byte>) (struct (xo: int, xl: int)) (struct (yo: int, yl: int)) =
    if xl < 0 then yl >= 0
    elif yl < 0 then false
    else b.Slice(xo, xl).SequenceCompareTo(b.Slice(yo, yl)) > 0

/// "tagList": a text[] column decoded from its binary form (ndim, has-null flag, element type, per dimension size
/// and lower bound, then per element a length (-1 = NULL) and the UTF-8 bytes).
let rec tagList (w: Utf8JsonWriter) (r: PgRow) (i: int) = tagListBytes w (r.Bytes i)

and tagListBytes (w: Utf8JsonWriter) (b: ReadOnlySpan<byte>) =
    w.WritePropertyName N.tagList
    w.WriteStartArray()
    if b.Length >= 12 && BinaryPrimitives.ReadInt32BigEndian b = 1 then
        let count = BinaryPrimitives.ReadInt32BigEndian(b.Slice 12)
        if isNull Tls.Items || Tls.Items.Length < count then Tls.Items <- Array.zeroCreate (max 64 count)
        let it = Tls.Items
        let mutable pos = 20
        for k in 0 .. count - 1 do
            let len = BinaryPrimitives.ReadInt32BigEndian(b.Slice pos)
            pos <- pos + 4
            it.[k] <- struct (pos, len)
            if len > 0 then pos <- pos + len
        if appSortsTags then
            for k in 1 .. count - 1 do // insertion sort: a handful of tags
                let mutable j = k
                while j > 0 && greater b it.[j - 1] it.[j] do
                    let t = it.[j - 1]
                    it.[j - 1] <- it.[j]
                    it.[j] <- t
                    j <- j - 1
        for k in 0 .. count - 1 do
            let struct (off, len) = it.[k]
            if len < 0 then w.WriteNullValue() else w.WriteStringValue(b.Slice(off, len))
    w.WriteEndArray()

/// a text[] in its binary form, elements in the array's order
let textArray (w: Utf8JsonWriter) (b: ReadOnlySpan<byte>) =
    w.WriteStartArray()
    if b.Length >= 12 && BinaryPrimitives.ReadInt32BigEndian b = 1 then
        let count = BinaryPrimitives.ReadInt32BigEndian(b.Slice 12)
        let mutable pos = 20
        for _ in 0 .. count - 1 do
            let len = BinaryPrimitives.ReadInt32BigEndian(b.Slice pos)
            pos <- pos + 4
            if len < 0 then w.WriteNullValue()
            else
                w.WriteStringValue(b.Slice(pos, len))
                pos <- pos + len
    w.WriteEndArray()

let private epoch2000 = DateTime(2000, 1, 1, 0, 0, 0, DateTimeKind.Utc).Ticks
let private roundTrip = StandardFormat('O')


/// RFC 3339 in UTC with exactly three fractional digits, truncated. Postgres sends microseconds since 2000-01-01.
let time (w: Utf8JsonWriter) (name: JsonEncodedText) (micros: int64) =
    if isNull Tls.Iso then Tls.Iso <- Array.zeroCreate 40
    let iso = Tls.Iso
    let s = Span iso
    let mutable n = 0
    Utf8Formatter.TryFormat(DateTime(epoch2000 + micros * 10L, DateTimeKind.Utc), s, &n, roundTrip) |> ignore
    s.[23] <- 'Z'B // cut after the milliseconds
    w.WriteString(name, ReadOnlySpan(iso, 0, 24))

/// Profile from (username, bio, image, following) at columns i..i+3; following >= 0 overrides the column.
let profile (w: Utf8JsonWriter) (r: PgRow) (i: int) (following: int) =
    w.WriteStartObject()
    text w N.username r i
    nullableText w N.bio r (i + 1)
    nullableText w N.image r (i + 2)
    w.WriteBoolean(N.following, (if following >= 0 then following = 1 else r.Bool(i + 3)))
    w.WriteEndObject()

/// Article from column o: id, slug, title, description, [body], created_at, updated_at, tag_list,
/// favorites_count, favorited, username, bio, image, following
let article (w: Utf8JsonWriter) (r: PgRow) (o: int) (full: bool) =
    w.WriteStartObject()
    text w N.slug r (o + 1)
    text w N.title r (o + 2)
    text w N.description r (o + 3)
    let mutable k = o + 4
    if full then
        text w N.body r k
        k <- k + 1
    time w N.createdAt (r.Micros k)
    time w N.updatedAt (r.Micros(k + 1))
    tagList w r (k + 2)
    w.WriteNumber(N.favoritesCount, r.Int8(k + 3))
    w.WriteBoolean(N.favorited, r.Bool(k + 4))
    w.WritePropertyName N.author
    profile w r (k + 5) -1
    w.WriteEndObject()

/// {"user": {...}} from (id, username, email, bio, image) at column o
let user (w: Utf8JsonWriter) (r: PgRow) (o: int) (token: ReadOnlySpan<byte>) =
    w.WriteStartObject()
    w.WritePropertyName N.user
    w.WriteStartObject()
    text w N.email r (o + 2)
    w.WriteString(N.token, token)
    text w N.username r (o + 1)
    nullableText w N.bio r (o + 3)
    nullableText w N.image r (o + 4)
    w.WriteEndObject()
    w.WriteEndObject()

/// A parsed request body {"<wrapper>": {...}}. Fields are absent, null, a string or something else (bad).
[<AllowNullLiteral>]
type Body(doc: JsonDocument, obj: JsonElement) =
    static member Parse(bytes: ReadOnlySpan<byte>, wrapper: string) : Body =
        if bytes.Length = 0 then null
        else
            let doc =
                try JsonDocument.Parse(ReadOnlyMemory(bytes.ToArray()))
                with :? JsonException -> null
            if isNull doc then null
            else
                let mutable o = Unchecked.defaultof<JsonElement>
                if doc.RootElement.ValueKind <> JsonValueKind.Object
                   || not (doc.RootElement.TryGetProperty(wrapper, &o)) || o.ValueKind <> JsonValueKind.Object then
                    doc.Dispose()
                    null
                else Body(doc, o)

    /// 0 absent, 1 null, 2 string, 3 bad
    member _.Get(name: string, value: byref<string>) =
        value <- null
        let mutable e = Unchecked.defaultof<JsonElement>
        if not (obj.TryGetProperty(name, &e)) then 0
        else
            match e.ValueKind with
            | JsonValueKind.Null -> 1
            | JsonValueKind.String ->
                value <- e.GetString()
                2
            | _ -> 3

    /// a required non-empty string
    member b.Required(name: string, value: byref<string>) = b.Get(name, &value) = 2 && value.Length > 0

    /// absent or null -> null; a string must be non-empty unless allowEmpty
    member b.Optional(name: string, allowEmpty: bool, value: byref<string>) =
        match b.Get(name, &value) with
        | 0
        | 1 -> true
        | 2 -> allowEmpty || value.Length > 0
        | _ -> false

    /// tagList: absent or null -> empty; otherwise an array of non-empty strings
    member _.Tags(tags: byref<string[]>) =
        tags <- [||]
        let mutable e = Unchecked.defaultof<JsonElement>
        if not (obj.TryGetProperty("tagList", &e)) || e.ValueKind = JsonValueKind.Null then true
        elif e.ValueKind <> JsonValueKind.Array then false
        else
            let list = Array.zeroCreate<string> (e.GetArrayLength())
            let mutable ok = true
            let mutable i = 0
            for t in e.EnumerateArray() do
                if t.ValueKind <> JsonValueKind.String then ok <- false
                else
                    let s = t.GetString()
                    if s.Length = 0 then ok <- false
                    else
                        list.[i] <- s
                        i <- i + 1
            if ok then tags <- list
            ok

    interface IDisposable with
        member _.Dispose() = doc.Dispose()
