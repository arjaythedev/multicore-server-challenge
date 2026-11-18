/// JSON output written as UTF-8 bytes, plus the HTTP response framing around it.
module Json

open System
open System.Buffers
open System.Buffers.Text
open System.Text

let private needEscape = SearchValues.Create(Array.append [| for b in 0uy .. 31uy -> b |] [| '"'B; '\\'B |])
let private hexDigits = "0123456789abcdef"B

/// A growable byte buffer with JSON helpers. Reused: Reset() keeps the memory.
[<Sealed; AllowNullLiteral>]
type W(size: int) =
    let mutable buf: byte[] = Array.zeroCreate size
    let mutable n = 0
    new() = W(16384)
    member _.Buffer = buf
    member _.Length = n
    member _.Reset() = n <- 0
    member _.Truncate(k: int) = n <- k
    member _.Span(start: int, len: int) = ReadOnlySpan(buf, start, len)

    member _.Ensure(k: int) =
        if n + k > buf.Length then
            let nb = Array.zeroCreate (max (buf.Length * 2) (n + k + 256))
            Buffer.BlockCopy(buf, 0, nb, 0, n)
            buf <- nb

    member w.Raw(s: ReadOnlySpan<byte>) =
        w.Ensure s.Length
        s.CopyTo(Span(buf, n, s.Length))
        n <- n + s.Length

    member w.Byte(b: byte) =
        w.Ensure 1
        buf.[n] <- b
        n <- n + 1

    member w.Int(v: int64) =
        w.Ensure 20
        let mutable k = 0
        Utf8Formatter.TryFormat(v, Span(buf, n, 20), &k) |> ignore
        n <- n + k

    member w.Bool(v: bool) = w.Raw(if v then "true"B else "false"B)

    /// a JSON string from UTF-8 bytes (non-ASCII passes through; quotes, backslashes and controls escaped)
    member w.Str(s: ReadOnlySpan<byte>) =
        w.Ensure(s.Length + 2)
        buf.[n] <- '"'B
        n <- n + 1
        let mutable rest = s
        let mutable go = true
        while go do
            let i = rest.IndexOfAny needEscape
            if i < 0 then
                w.Raw rest
                go <- false
            else
                w.Raw(rest.Slice(0, i))
                let c = rest.[i]
                w.Ensure 6
                buf.[n] <- '\\'B
                match c with
                | 34uy -> buf.[n + 1] <- '"'B; n <- n + 2
                | 92uy -> buf.[n + 1] <- '\\'B; n <- n + 2
                | 10uy -> buf.[n + 1] <- 'n'B; n <- n + 2
                | 13uy -> buf.[n + 1] <- 'r'B; n <- n + 2
                | 9uy -> buf.[n + 1] <- 't'B; n <- n + 2
                | _ ->
                    buf.[n + 1] <- 'u'B
                    buf.[n + 2] <- '0'B
                    buf.[n + 3] <- '0'B
                    buf.[n + 4] <- hexDigits.[int c >>> 4]
                    buf.[n + 5] <- hexDigits.[int c &&& 15]
                    n <- n + 6
                rest <- rest.Slice(i + 1)
        w.Byte '"'B

    member w.StrS(s: string) =
        if isNull s then w.Raw "null"B
        else
            let tmp = Encoding.UTF8.GetBytes s
            w.Str(ReadOnlySpan tmp)

    /// RFC 3339 UTC with exactly 3 fractional digits, truncated: "2025-04-01T12:00:00.000Z"
    member w.Time(unixMicros: int64) =
        let ms = if unixMicros >= 0L then unixMicros / 1000L else (unixMicros - 999L) / 1000L
        let days = if ms >= 0L then ms / 86400000L else (ms - 86399999L) / 86400000L
        let msOfDay = int (ms - days * 86400000L)
        // civil date from days since 1970-01-01 (Howard Hinnant's algorithm)
        let z = days + 719468L
        let era = (if z >= 0L then z else z - 146096L) / 146097L
        let doe = z - era * 146097L
        let yoe = (doe - doe / 1460L + doe / 36524L - doe / 146096L) / 365L
        let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
        let mp = (5L * doy + 2L) / 153L
        let d = int (doy - (153L * mp + 2L) / 5L + 1L)
        let m = int (if mp < 10L then mp + 3L else mp - 9L)
        let y = int (yoe + era * 400L + (if m <= 2 then 1L else 0L))
        w.Ensure 26
        let b = buf
        let p = n
        let inline dig (at: int) (v: int) = b.[p + at] <- byte (48 + v)
        b.[p] <- '"'B
        dig 1 (y / 1000 % 10)
        dig 2 (y / 100 % 10)
        dig 3 (y / 10 % 10)
        dig 4 (y % 10)
        b.[p + 5] <- '-'B
        dig 6 (m / 10)
        dig 7 (m % 10)
        b.[p + 8] <- '-'B
        dig 9 (d / 10)
        dig 10 (d % 10)
        b.[p + 11] <- 'T'B
        let hh = msOfDay / 3600000
        let mi = msOfDay / 60000 % 60
        let ss = msOfDay / 1000 % 60
        let fff = msOfDay % 1000
        dig 12 (hh / 10)
        dig 13 (hh % 10)
        b.[p + 14] <- ':'B
        dig 15 (mi / 10)
        dig 16 (mi % 10)
        b.[p + 17] <- ':'B
        dig 18 (ss / 10)
        dig 19 (ss % 10)
        b.[p + 20] <- '.'B
        dig 21 (fff / 100)
        dig 22 (fff / 10 % 10)
        dig 23 (fff % 10)
        b.[p + 24] <- 'Z'B
        b.[p + 25] <- '"'B
        n <- n + 26

// ---- HTTP framing ----

let private statusLine (code: int) =
    match code with
    | 200 -> "HTTP/1.1 200 OK\r\n"B
    | 201 -> "HTTP/1.1 201 Created\r\n"B
    | 204 -> "HTTP/1.1 204 No Content\r\n"B
    | 401 -> "HTTP/1.1 401 Unauthorized\r\n"B
    | 403 -> "HTTP/1.1 403 Forbidden\r\n"B
    | 404 -> "HTTP/1.1 404 Not Found\r\n"B
    | 422 -> "HTTP/1.1 422 Unprocessable Entity\r\n"B
    | 503 -> "HTTP/1.1 503 Service Unavailable\r\n"B
    | _ -> "HTTP/1.1 500 Internal Server Error\r\n"B

let private ctype = "Content-Type: application/json\r\nContent-Length: "B
let private crlf2 = "\r\n\r\n"B

/// A whole HTTP response (status, headers, body) in a fresh array.
let response (code: int) (body: ReadOnlySpan<byte>) : byte[] =
    let sl = statusLine code
    if code = 204 then
        let r = Array.zeroCreate (sl.Length + 2)
        sl.CopyTo(r, 0)
        r.[sl.Length] <- 13uy
        r.[sl.Length + 1] <- 10uy
        r
    else
        let mutable digits = 1
        let mutable x = body.Length
        while x >= 10 do
            x <- x / 10
            digits <- digits + 1
        let total = sl.Length + ctype.Length + digits + 4 + body.Length
        let r = Array.zeroCreate total
        let mutable p = 0
        sl.CopyTo(r, p)
        p <- p + sl.Length
        ctype.CopyTo(r, p)
        p <- p + ctype.Length
        let mutable k = 0
        Utf8Formatter.TryFormat(body.Length, Span(r, p, digits), &k) |> ignore
        p <- p + k
        crlf2.CopyTo(r, p)
        p <- p + 4
        body.CopyTo(Span(r, p, body.Length))
        r

let private errA = "{\"errors\":{\"body\":[\""B
let private errB = "\"]}}"B

let error (code: int) (msg: string) : byte[] =
    let w = W(128)
    w.Raw errA
    w.Raw(ReadOnlySpan(Encoding.ASCII.GetBytes msg))
    w.Raw errB
    response code (w.Span(0, w.Length))

let unauthorized = error 401 "unauthorized"
let forbidden = error 403 "forbidden"
let notFound = error 404 "not found"
let unprocessable (what: string) = error 422 what
let noContent = response 204 ReadOnlySpan.Empty
