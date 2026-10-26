/// One request: what was asked (route, viewer, parameters as UTF-8), the response being built and the state of
/// multi-step requests. Pooled per loop; nothing in it is allocated per request on the read paths. (#22's Ctx.)
module Ctx

#nowarn "9"

open System
open System.Buffers
open System.Buffers.Text
open System.Runtime.InteropServices
open System.Text
open System.Text.Encodings.Web
open System.Text.Json
open Pg

type Route =
    | None = 0
    | Tags = 1
    | ListAll = 2
    | ListTag = 3
    | ListAuthor = 4
    | ListFavorited = 5
    | Feed = 6
    | Article = 7
    | Comments = 8
    | Profile = 9
    | User = 10
    | CreateArticle = 11
    | UpdateArticle = 12
    | DeleteArticle = 13
    | Favorite = 14
    | Unfavorite = 15
    | CreateComment = 16
    | DeleteComment = 17
    | Follow = 18
    | Unfollow = 19
    | Register = 20
    | Login = 21
    | UpdateUser = 22

/// "Date: <IMF-fixdate>\r\n", refreshed every second
module HttpDate =
    let private make () = Encoding.ASCII.GetBytes("Date: " + DateTime.UtcNow.ToString("r") + "\r\n")
    let mutable line = make ()
    let private tick = new Threading.Timer((fun _ -> line <- make ()), null, 1000, 1000)
    let keep () = tick |> ignore

let private status200 = "HTTP/1.1 200 OK\r\n"B
let private status201 = "HTTP/1.1 201 Created\r\n"B
let private status204 = "HTTP/1.1 204 No Content\r\n"B
let private status400 = "HTTP/1.1 400 Bad Request\r\n"B
let private status401 = "HTTP/1.1 401 Unauthorized\r\n"B
let private status403 = "HTTP/1.1 403 Forbidden\r\n"B
let private status404 = "HTTP/1.1 404 Not Found\r\n"B
let private status411 = "HTTP/1.1 411 Length Required\r\n"B
let private status413 = "HTTP/1.1 413 Content Too Large\r\n"B
let private status422 = "HTTP/1.1 422 Unprocessable Entity\r\n"B
let private status431 = "HTTP/1.1 431 Request Header Fields Too Large\r\n"B
let private status500 = "HTTP/1.1 500 Internal Server Error\r\n"B
let private status503 = "HTTP/1.1 503 Service Unavailable\r\n"B
let private hJson = "Content-Type: application/json\r\nContent-Length: "B
let private hCrlf = "\r\n"B
let private hClose = "Connection: close\r\n"B

[<Literal>]
let private Reserve = 192

/// The response, in a pinned buffer (io_uring sends straight from it): headers are written last, right in front
/// of the JSON body, into space reserved at the start.
[<Sealed>]
type Buf() =
    let mutable a = GC.AllocateUninitializedArray<byte>(8 * 1024, pinned = true)
    let mutable n = Reserve
    let mutable head = Reserve
    member _.Capacity = a.Length
    member _.BodyLength = n - Reserve
    member _.Reset() =
        n <- Reserve
        head <- Reserve
    member private _.Ensure(hint: int) =
        let hint = max hint 256
        if a.Length - n < hint then
            let bigger = GC.AllocateUninitializedArray<byte>(max (a.Length * 2) (n + hint), pinned = true)
            Buffer.BlockCopy(a, 0, bigger, 0, n)
            a <- bigger
    /// drops an outsized buffer (a big list) for a fresh small one
    member _.Shrink() =
        if a.Length > 64 * 1024 then a <- GC.AllocateUninitializedArray<byte>(8 * 1024, pinned = true)
    interface IBufferWriter<byte> with
        member _.Advance(count) = n <- n + count
        member b.GetMemory(hint) =
            b.Ensure hint
            Memory<byte>(a, n, a.Length - n)
        member b.GetSpan(hint) =
            b.Ensure hint
            Span<byte>(a, n, a.Length - n)

    member _.WriteHead(status: int, close: bool) =
        let mutable k = 0
        let line =
            match status with
            | 200 -> status200
            | 201 -> status201
            | 204 -> status204
            | 400 -> status400
            | 401 -> status401
            | 403 -> status403
            | 404 -> status404
            | 411 -> status411
            | 413 -> status413
            | 422 -> status422
            | 431 -> status431
            | 503 -> status503
            | _ -> status500
        // build into a stack buffer, then copy in front of the body
        let st = NativeInterop.NativePtr.stackalloc<byte> Reserve
        let s = Span<byte>(NativeInterop.NativePtr.toVoidPtr st, Reserve)
        line.AsSpan().CopyTo(s)
        k <- line.Length
        if status <> 204 then
            hJson.AsSpan().CopyTo(s.Slice k)
            k <- k + hJson.Length
            let mutable w = 0
            Utf8Formatter.TryFormat(n - Reserve, s.Slice k, &w) |> ignore
            k <- k + w
            hCrlf.AsSpan().CopyTo(s.Slice k)
            k <- k + 2
        else n <- Reserve
        if close then
            hClose.AsSpan().CopyTo(s.Slice k)
            k <- k + hClose.Length
        let d = HttpDate.line
        d.AsSpan().CopyTo(s.Slice k)
        k <- k + d.Length
        hCrlf.AsSpan().CopyTo(s.Slice k)
        k <- k + 2
        head <- Reserve - k
        s.Slice(0, k).CopyTo(Span<byte>(a, head, k))

    member _.Address(off: int) = Marshal.UnsafeAddrOfPinnedArrayElement(a, head + off)
    member _.ResponseLength = n - head

let private writerOptions = JsonWriterOptions(Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping, SkipValidation = true)

/// The I/O loop a request's connection belongs to (Uring.Loop): where its response goes.
[<AbstractClass>]
type Owner() =
    /// the response is complete: send it (any thread)
    abstract Send: Ctx -> unit
    /// the client is gone (any thread; a hint)
    abstract Gone: Ctx -> bool

/// The Postgres side (Db.fs): one thread owns the connections and the shared batch queues. Thread-safe.
and [<AbstractClass>] Backend() =
    static member val Current: Backend = Unchecked.defaultof<Backend> with get, set
    /// queue for the kind's batched read
    abstract Enqueue: c: Ctx * kind: Sql.Kind -> unit
    /// a statement group on a read connection (logins)
    abstract Read: PgQuery -> unit
    /// a statement group on a write connection
    abstract Write: PgQuery -> unit
    /// from a bcrypt thread: continue the request on the Postgres thread (Handlers.afterBcrypt)
    abstract Post: Ctx -> unit

and [<Sealed; AllowNullLiteral>] Ctx(owner: Owner, id: int) as this =
    let out = Buf()
    let w = new Utf8JsonWriter(out, writerOptions)
    let job =
        { new Bcrypt.Job() with
            member _.Gone = owner.Gone this
            member _.Completed() = Backend.Current.Post this }
    member _.Owner = owner
    member _.Id = id
    member _.Out = out
    member _.W = w
    member _.Job = job
    // the connection: ring, slot and generation in the loop
    member val Ring = 0 with get, set
    member val Slot = 0 with get, set
    member val Gen = 0u with get, set
    member val SentOff = 0 with get, set
    member val CloseAfter = false with get, set
    member val Route = Route.None with get, set
    member val Viewer = 0L with get, set
    member val Status = 200 with get, set
    member val Step = 0 with get, set
    member val Count = 0L with get, set
    member val Found = false with get, set
    member val Queued = 0L with get, set
    member val InUse = false with get, set
    // parameters: Key = slug, username or list filter (UTF-8, URL-decoded); Tok = the token
    member val P = Array.zeroCreate<byte> 512 with get, set
    member val PLen = 0 with get, set
    member val KeyOff = 0 with get, set
    member val KeyLen = 0 with get, set
    member val TokOff = 0 with get, set
    member val TokLen = 0 with get, set
    member val Limit = 0 with get, set
    member val Offset = 0L with get, set
    member val CId = 0L with get, set
    // write requests (rare): the decoded body
    member val S1: string = null with get, set
    member val S2: string = null with get, set
    member val S3: string = null with get, set
    member val S4: string = null with get, set
    member val S5: string = null with get, set
    member val S6: string = null with get, set
    member val Tags: string[] = null with get, set
    member val Stored: byte[] = null with get, set
    member val Single: PgQuery = null with get, set

    member c.Key = ReadOnlySpan<byte>(c.P, c.KeyOff, c.KeyLen)
    member c.Token = ReadOnlySpan<byte>(c.P, c.TokOff, c.TokLen)

    /// appends bytes to the parameter buffer, returning their offset
    member c.Put(s: ReadOnlySpan<byte>) =
        let at = c.PLen
        if at + s.Length > c.P.Length then
            let bigger = Array.zeroCreate<byte> (max (c.P.Length * 2) (at + s.Length))
            Buffer.BlockCopy(c.P, 0, bigger, 0, at)
            c.P <- bigger
        s.CopyTo(Span<byte>(c.P, at, s.Length))
        c.PLen <- at + s.Length
        at

    member c.Reset() =
        c.CloseAfter <- false
        c.Route <- Route.None
        c.Viewer <- 0L
        c.Status <- 200
        c.Step <- 0
        c.Count <- 0L
        c.Found <- false
        c.PLen <- 0
        c.KeyOff <- 0
        c.KeyLen <- 0
        c.TokOff <- 0
        c.TokLen <- 0
        c.Limit <- 0
        c.Offset <- 0L
        c.CId <- 0L
        c.SentOff <- 0
        c.S1 <- null
        c.S2 <- null
        c.S3 <- null
        c.S4 <- null
        c.S5 <- null
        c.S6 <- null
        c.Tags <- null
        c.Stored <- null
        if c.P.Length > 4096 then c.P <- Array.zeroCreate 512
        out.Shrink()
        out.Reset()
        w.Reset(out)

    // ---------- responses ----------
    member c.Error(status: int, message: string) =
        out.Reset()
        w.Reset(out)
        c.Status <- status
        w.WriteStartObject()
        w.WritePropertyName Json.N.errors
        w.WriteStartObject()
        w.WritePropertyName Json.N.body
        w.WriteStartArray()
        w.WriteStringValue message
        w.WriteEndArray()
        w.WriteEndObject()
        w.WriteEndObject()

    member c.NoContent() =
        out.Reset()
        w.Reset(out)
        c.Status <- 204

    /// Completes the request: the response goes out from the loop.
    member c.Finish() =
        w.Flush()
        out.WriteHead(c.Status, c.CloseAfter)
        owner.Send c
