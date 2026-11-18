/// A small PostgreSQL v3 wire-protocol client, written for this entry: one blocking socket per connection,
/// the extended protocol with named prepared statements, binary parameters and binary result columns.
/// A caller builds a pipeline of Bind/Execute messages and one or more Syncs, sends it with one write, then reads
/// the replies message by message.
module Pg

open System
open System.Buffers.Binary
open System.Net.Sockets
open System.Security.Cryptography
open System.Text

exception PgError of code: string * message: string

[<Literal>]
let OidBool = 16
[<Literal>]
let OidInt8 = 20
[<Literal>]
let OidInt4 = 23
[<Literal>]
let OidText = 25
[<Literal>]
let OidBoolArr = 1000
[<Literal>]
let OidInt4Arr = 1007
[<Literal>]
let OidTextArr = 1009
[<Literal>]
let OidInt8Arr = 1016

/// Frontend bytes, built in place: messages, then Bind parameters inside them.
[<Sealed; AllowNullLiteral>]
type Out() =
    let mutable buf: byte[] = Array.zeroCreate 65536
    let mutable n = 0
    let mutable msgStart = 0
    let mutable paramStart = 0
    member _.Buffer = buf
    member _.Length = n
    member _.Reset() = n <- 0

    member _.Ensure(k: int) =
        if n + k > buf.Length then
            let nb = Array.zeroCreate (max (buf.Length * 2) (n + k + 1024))
            Buffer.BlockCopy(buf, 0, nb, 0, n)
            buf <- nb

    member o.U8(b: byte) =
        o.Ensure 1
        buf.[n] <- b
        n <- n + 1

    member o.I16(v: int) =
        o.Ensure 2
        BinaryPrimitives.WriteInt16BigEndian(Span(buf, n, 2), int16 v)
        n <- n + 2

    member o.I32(v: int) =
        o.Ensure 4
        BinaryPrimitives.WriteInt32BigEndian(Span(buf, n, 4), v)
        n <- n + 4

    member o.I64(v: int64) =
        o.Ensure 8
        BinaryPrimitives.WriteInt64BigEndian(Span(buf, n, 8), v)
        n <- n + 8

    member o.Raw(s: ReadOnlySpan<byte>) =
        o.Ensure s.Length
        s.CopyTo(Span(buf, n, s.Length))
        n <- n + s.Length

    /// UTF-8 of a string, no terminator
    member o.Utf8(s: string) =
        o.Ensure(Encoding.UTF8.GetMaxByteCount s.Length)
        n <- n + Encoding.UTF8.GetBytes(s, 0, s.Length, buf, n)

    member o.CStr(s: string) =
        o.Utf8 s
        o.U8 0uy

    member o.Begin(tag: byte) =
        o.U8 tag
        msgStart <- n
        o.I32 0

    member _.End() =
        BinaryPrimitives.WriteInt32BigEndian(Span(buf, msgStart, 4), n - msgStart)

    /// Bind of the named statement to the unnamed portal; parameters follow (Param*), then EndBind.
    member o.Bind(stmt: string, nparams: int) =
        o.Begin 'B'B
        o.U8 0uy
        o.CStr stmt
        o.I16 1
        o.I16 1 // every parameter binary
        o.I16 nparams

    member o.EndBind() =
        o.I16 1
        o.I16 1 // every result column binary
        o.End()

    member o.Execute() =
        o.Begin 'E'B
        o.U8 0uy
        o.I32 0
        o.End()

    member o.Sync() =
        o.Begin 'S'B
        o.End()

    // ---- parameters ----
    member o.ParamBegin() =
        o.I32 0
        paramStart <- n

    member _.ParamEnd() =
        BinaryPrimitives.WriteInt32BigEndian(Span(buf, paramStart - 4, 4), n - paramStart)

    member o.Null() = o.I32 -1

    member o.PInt8(v: int64) =
        o.I32 8
        o.I64 v

    member o.PInt4(v: int) =
        o.I32 4
        o.I32 v

    member o.PBool(v: bool) =
        o.I32 1
        o.U8(if v then 1uy else 0uy)

    member o.PText(s: string) =
        if isNull s then o.Null()
        else
            o.ParamBegin()
            o.Utf8 s
            o.ParamEnd()

    /// text parameter from raw UTF-8 bytes
    member o.PBytes(s: ReadOnlySpan<byte>) =
        o.I32 s.Length
        o.Raw s

    /// one-dimensional array header; elements follow with Elem*
    member o.ArrBegin(elemOid: int, count: int, hasNull: bool) =
        o.ParamBegin()
        o.I32 1
        o.I32(if hasNull then 1 else 0)
        o.I32 elemOid
        o.I32 count
        o.I32 1

    member o.ArrEnd() = o.ParamEnd()
    member o.EInt8(v: int64) = o.PInt8 v
    member o.EInt4(v: int) = o.PInt4 v
    member o.EBool(v: bool) = o.PBool v

    member o.EText(s: string) =
        if isNull s then o.I32 -1
        else
            let lenAt = n
            o.I32 0
            o.Utf8 s
            BinaryPrimitives.WriteInt32BigEndian(Span(buf, lenAt, 4), n - lenAt - 4)

    member o.EBytes(s: ReadOnlySpan<byte>) =
        o.I32 s.Length
        o.Raw s

// ---- reading binary values ----
let inline i16 (b: byte[]) (o: int) = int (BinaryPrimitives.ReadInt16BigEndian(ReadOnlySpan(b, o, 2)))
let inline i32 (b: byte[]) (o: int) = BinaryPrimitives.ReadInt32BigEndian(ReadOnlySpan(b, o, 4))
let inline i64 (b: byte[]) (o: int) = BinaryPrimitives.ReadInt64BigEndian(ReadOnlySpan(b, o, 8))

/// Postgres timestamps: microseconds since 2000-01-01 UTC. Returns Unix microseconds.
let inline pgTime (b: byte[]) (o: int) = i64 b o + 946684800000000L

type Conn(url: string, options: string) =
    let uri = Uri url
    let user, password =
        match uri.UserInfo.Split(':', 2) with
        | [| u; p |] -> Uri.UnescapeDataString u, Uri.UnescapeDataString p
        | [| u |] -> Uri.UnescapeDataString u, ""
        | _ -> "postgres", ""
    let db = uri.AbsolutePath.TrimStart('/')
    let port = if uri.Port > 0 then uri.Port else 5432
    let sock = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp)
    let out = Out()
    let mutable rb: byte[] = Array.zeroCreate (256 * 1024)
    let mutable rStart = 0
    let mutable rEnd = 0
    let mutable msgPos = 0
    let mutable msgLen = 0
    let cols: int[] = Array.zeroCreate 64 // offset, length pairs for the current DataRow (-1 length = NULL)

    let fill () =
        if rStart > 0 && rStart = rEnd then
            rStart <- 0
            rEnd <- 0
        if rEnd = rb.Length then
            if rStart > 0 then
                Buffer.BlockCopy(rb, rStart, rb, 0, rEnd - rStart)
                rEnd <- rEnd - rStart
                rStart <- 0
            else
                let nb = Array.zeroCreate (rb.Length * 2)
                Buffer.BlockCopy(rb, 0, nb, 0, rEnd)
                rb <- nb
        let k = sock.Receive(rb, rEnd, rb.Length - rEnd, SocketFlags.None)
        if k <= 0 then raise (PgError("08006", "postgres closed the connection"))
        rEnd <- rEnd + k

    let parseError () =
        let mutable code = ""
        let mutable msg = ""
        let mutable p = msgPos
        let e = msgPos + msgLen
        while p < e && rb.[p] <> 0uy do
            let f = rb.[p]
            let s = p + 1
            let mutable z = s
            while rb.[z] <> 0uy do
                z <- z + 1
            let v = Encoding.UTF8.GetString(rb, s, z - s)
            if f = 'C'B then code <- v
            elif f = 'M'B then msg <- v
            p <- z + 1
        PgError(code, msg)

    member _.Out = out
    member _.Buf = rb
    member _.Pos = msgPos
    member _.Len = msgLen

    member _.Send() =
        let mutable off = 0
        while off < out.Length do
            off <- off + sock.Send(out.Buffer, off, out.Length - off, SocketFlags.None)
        out.Reset()

    /// Reads the next backend message; its body is Buf[Pos .. Pos+Len). Skips notices and parameter statuses.
    member c.Next() : byte =
        let mutable tag = 0uy
        let mutable go = true
        while go do
            while rEnd - rStart < 5 do
                fill ()
            let len = i32 rb (rStart + 1) - 4
            if rb.Length < len + 5 && rStart = 0 then
                let nb = Array.zeroCreate (len + 5 + 1024)
                Buffer.BlockCopy(rb, 0, nb, 0, rEnd)
                rb <- nb
            while rEnd - rStart < len + 5 do
                if rb.Length - rStart < len + 5 then
                    Buffer.BlockCopy(rb, rStart, rb, 0, rEnd - rStart)
                    rEnd <- rEnd - rStart
                    rStart <- 0
                    if rb.Length < len + 5 then
                        let nb = Array.zeroCreate (len + 5 + 1024)
                        Buffer.BlockCopy(rb, 0, nb, 0, rEnd)
                        rb <- nb
                fill ()
            tag <- rb.[rStart]
            msgPos <- rStart + 5
            msgLen <- len
            rStart <- rStart + 5 + len
            go <- tag = 'N'B || tag = 'S'B || tag = 'A'B
        tag

    /// the PgError of the current 'E' message
    member _.Error() = parseError ()

    /// Splits the current DataRow into columns; returns the column count.
    member _.Row() =
        let n = i16 rb msgPos
        let mutable p = msgPos + 2
        for i in 0 .. n - 1 do
            let l = i32 rb p
            cols.[2 * i] <- p + 4
            cols.[2 * i + 1] <- l
            p <- p + 4 + (if l > 0 then l else 0)
        n

    member _.Off(i: int) = cols.[2 * i]
    member _.ColLen(i: int) = cols.[2 * i + 1]
    member _.IsNull(i: int) = cols.[2 * i + 1] < 0
    member _.Int4(i: int) = i32 rb cols.[2 * i]
    member _.Int8(i: int) = i64 rb cols.[2 * i]
    member _.Bool(i: int) = rb.[cols.[2 * i]] <> 0uy
    member _.Time(i: int) = pgTime rb cols.[2 * i]
    member _.Text(i: int) = if cols.[2 * i + 1] < 0 then null else Encoding.UTF8.GetString(rb, cols.[2 * i], cols.[2 * i + 1])
    member _.Span(i: int) = ReadOnlySpan(rb, cols.[2 * i], max 0 cols.[2 * i + 1])

    /// Reads until ReadyForQuery, raising the first error seen.
    member c.Drain() =
        let mutable err = None
        let mutable go = true
        while go do
            match c.Next() with
            | 'Z'B -> go <- false
            | 'E'B -> if err.IsNone then err <- Some(c.Error())
            | _ -> ()
        match err with
        | Some e -> raise e
        | None -> ()

    member c.Prepare(name: string, sql: string, oids: int[]) =
        out.Begin 'P'B
        out.CStr name
        out.CStr sql
        out.I16 oids.Length
        for o in oids do
            out.I32 o
        out.End()
        out.Sync()
        c.Send()
        try
            c.Drain()
        with PgError(code, msg) ->
            failwithf "prepare %s failed: %s %s\n%s" name code msg sql

    member private c.Sasl(mechs: string) =
        if not (mechs.Contains "SCRAM-SHA-256") then failwith "postgres offers no SCRAM-SHA-256"
        let nonce = Convert.ToBase64String(RandomNumberGenerator.GetBytes 18)
        let first = "n=,r=" + nonce
        let init = "n,," + first
        out.Begin 'p'B
        out.CStr "SCRAM-SHA-256"
        out.I32(Encoding.UTF8.GetByteCount init)
        out.Utf8 init
        out.End()
        c.Send()
        if c.Next() <> 'R'B || i32 rb msgPos <> 11 then raise (c.Error())
        let server = Encoding.UTF8.GetString(rb, msgPos + 4, msgLen - 4)
        let attrs =
            server.Split(',')
            |> Array.map (fun kv -> kv.Substring(0, 1), kv.Substring 2)
            |> dict
        let r = attrs.["r"]
        if not (r.StartsWith nonce) then failwith "SCRAM: bad server nonce"
        let salted = Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes password, Convert.FromBase64String attrs.["s"], int attrs.["i"], HashAlgorithmName.SHA256, 32)
        let clientKey = HMACSHA256.HashData(salted, Encoding.ASCII.GetBytes "Client Key")
        let stored = SHA256.HashData clientKey
        let final = "c=biws,r=" + r
        let auth = first + "," + server + "," + final
        let sign = HMACSHA256.HashData(stored, Encoding.UTF8.GetBytes auth)
        let proof = Array.map2 (^^^) clientKey sign
        let msg = final + ",p=" + Convert.ToBase64String proof
        out.Begin 'p'B
        out.Utf8 msg
        out.End()
        c.Send()

    /// Connects, authenticates (SCRAM-SHA-256, MD5, cleartext or trust) and waits for ReadyForQuery.
    /// shown in pg_stat_activity (which lane the connection serves)
    member val AppName = "conduit" with get, set

    member c.Open() =
        sock.NoDelay <- true
        sock.Connect(uri.Host, port)
        let mutable p = 0
        out.I32 0
        out.I32 196608
        for k, v in [ "user", user; "database", db; "options", options; "application_name", c.AppName ] do
            if v <> "" then
                out.CStr k
                out.CStr v
        out.U8 0uy
        BinaryPrimitives.WriteInt32BigEndian(Span(out.Buffer, 0, 4), out.Length)
        c.Send()
        let mutable go = true
        while go do
            match c.Next() with
            | 'R'B ->
                match i32 rb msgPos with
                | 0 -> ()
                | 3 ->
                    out.Begin 'p'B
                    out.CStr password
                    out.End()
                    c.Send()
                | 5 ->
                    let hex (b: byte[]) = Convert.ToHexString(b).ToLowerInvariant()
                    let inner = hex (MD5.HashData(Encoding.UTF8.GetBytes(password + user)))
                    let salt = rb.[msgPos + 4 .. msgPos + 7]
                    let outer = hex (MD5.HashData(Array.append (Encoding.ASCII.GetBytes inner) salt))
                    out.Begin 'p'B
                    out.CStr("md5" + outer)
                    out.End()
                    c.Send()
                | 10 -> c.Sasl(Encoding.UTF8.GetString(rb, msgPos + 4, msgLen - 4))
                | 12 -> ()
                | code -> failwithf "unsupported postgres auth %d" code
            | 'K'B -> ()
            | 'E'B -> raise (c.Error())
            | 'Z'B -> go <- false
            | _ -> ()
        p <- 0

    interface IDisposable with
        // shutdown first: an I/O thread's copy of the fd table may still hold this socket, and Postgres must see it end
        member _.Dispose() =
            (try sock.Shutdown(SocketShutdown.Both) with _ -> ())
            sock.Dispose()
