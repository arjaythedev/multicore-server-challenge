/// A minimal PostgreSQL client (protocol 3.0, extended query protocol, binary results), ported from #22
/// (csharp-sockets-jh-d, MIT): a few long-lived connections, every statement prepared once per connection at
/// startup, many queries pipelined on each connection. A query writes Bind/Execute.../Sync into the connection's
/// send buffer; replies are parsed in place and rows handed straight to the query (no row objects, no strings).
/// Unlike #22 there are no threads here: the connection's socket lives in an io_uring loop (Uring.fs), which sends
/// the buffer and hands received bytes to `Received`.
module Pg

#nowarn "9"

open System
open System.Buffers.Binary
open System.Collections.Generic
open System.Net
open System.Net.Sockets
open System.Runtime.InteropServices
open System.Security.Cryptography
open System.Text

module Oid =
    [<Literal>]
    let Bool = 16u
    [<Literal>]
    let Int8 = 20u
    [<Literal>]
    let Int4 = 23u
    [<Literal>]
    let Text = 25u
    [<Literal>]
    let Int4Array = 1007u
    [<Literal>]
    let TextArray = 1009u
    [<Literal>]
    let Int8Array = 1016u

/// A statement prepared on every connection (as "s<Id>").
[<AllowNullLiteral>]
type Stmt private (id: int, sql: string, oids: uint32[]) =
    static let all = List<Stmt>()
    member _.Id = id
    member _.Sql = sql
    member _.ParamOids = oids
    member val Name = Encoding.ASCII.GetBytes("s" + string id)
    static member Define(sql: string, [<ParamArray>] oids: uint32[]) =
        lock all (fun () ->
            let s = Stmt(all.Count, sql, oids)
            all.Add s
            s)
    static member All = all :> IReadOnlyList<Stmt>

[<AllowNullLiteral>]
type PgError(state: string, message: string) =
    member _.SqlState = state
    member _.Message = message
    override _.ToString() = state + ": " + message

/// A DataRow: column values as spans of the connection's receive buffer (valid during the Row callback).
[<Sealed; AllowNullLiteral>]
type PgRow() =
    let off = Array.zeroCreate<int> 1664
    let len = Array.zeroCreate<int> 1664
    let mutable buf: byte[] = null
    let mutable count = 0
    member _.Count = count
    member _.Set(b: byte[], start: int) =
        buf <- b
        let n = int (BinaryPrimitives.ReadInt16BigEndian(ReadOnlySpan(b, start, 2)))
        let mutable pos = start + 2
        for i in 0 .. n - 1 do
            let l = BinaryPrimitives.ReadInt32BigEndian(ReadOnlySpan(b, pos, 4))
            pos <- pos + 4
            off.[i] <- pos
            len.[i] <- l
            if l > 0 then pos <- pos + l
        count <- n
    member _.IsNull(i: int) = len.[i] < 0
    member _.Bytes(i: int) : ReadOnlySpan<byte> = if len.[i] < 0 then ReadOnlySpan.Empty else ReadOnlySpan(buf, off.[i], len.[i])
    member _.Int8(i: int) = BinaryPrimitives.ReadInt64BigEndian(ReadOnlySpan(buf, off.[i], 8))
    member _.Int4(i: int) = BinaryPrimitives.ReadInt32BigEndian(ReadOnlySpan(buf, off.[i], 4))
    member _.Bool(i: int) = buf.[off.[i]] <> 0uy
    /// timestamptz: microseconds since 2000-01-01 00:00:00 UTC
    member _.Micros(i: int) = BinaryPrimitives.ReadInt64BigEndian(ReadOnlySpan(buf, off.[i], 8))

/// Builds frontend messages in a growable, pinned buffer (io_uring sends straight from it).
[<Sealed; AllowNullLiteral>]
type PgWriter(initial: int) =
    let mutable b = GC.AllocateUninitializedArray<byte>(initial, pinned = true)
    let mutable n = 0
    let mutable bindStart = 0
    let mutable paramStart = 0
    let mutable arrayCount = 0
    new() = PgWriter(64 * 1024)
    member _.Length = n
    member _.Buffer = b
    member _.Reset() = n <- 0
    member _.Address(off: int) = Marshal.UnsafeAddrOfPinnedArrayElement(b, off)
    member private _.Ensure(more: int) =
        if n + more > b.Length then
            let bigger = GC.AllocateUninitializedArray<byte>(max (b.Length * 2) (n + more), pinned = true)
            Buffer.BlockCopy(b, 0, bigger, 0, n)
            b <- bigger
    member w.U8(v: byte) =
        w.Ensure 1
        b.[n] <- v
        n <- n + 1
    member w.I16(v: int) =
        w.Ensure 2
        BinaryPrimitives.WriteInt16BigEndian(Span(b, n, 2), int16 v)
        n <- n + 2
    member w.I32(v: int) =
        w.Ensure 4
        BinaryPrimitives.WriteInt32BigEndian(Span(b, n, 4), v)
        n <- n + 4
    member w.Raw(s: ReadOnlySpan<byte>) =
        w.Ensure s.Length
        s.CopyTo(Span(b, n, s.Length))
        n <- n + s.Length
    member w.CStr(s: ReadOnlySpan<byte>) =
        w.Raw s
        w.U8 0uy
    member private _.Patch(at: int, v: int) = BinaryPrimitives.WriteInt32BigEndian(Span(b, at, 4), v)

    /// Bind (unnamed portal, all parameters and results binary). Parameters follow, then EndBind.
    member w.Bind(s: Stmt) =
        bindStart <- n
        w.U8 'B'B
        w.I32 0
        w.U8 0uy // portal ""
        w.CStr(ReadOnlySpan s.Name)
        w.I16 1
        w.I16 1 // all parameters binary
        w.I16 s.ParamOids.Length

    member w.EndBind() =
        w.I16 1
        w.I16 1 // all results binary
        w.Patch(bindStart + 1, n - bindStart - 1)
        // Execute (unnamed portal, all rows)
        w.U8 'E'B
        w.I32 9
        w.U8 0uy
        w.I32 0

    member w.Sync() =
        w.U8 'S'B
        w.I32 4

    member w.Null() = w.I32 -1
    member w.Int8(v: int64) =
        w.I32 8
        w.Ensure 8
        BinaryPrimitives.WriteInt64BigEndian(Span(b, n, 8), v)
        n <- n + 8
    member w.Int4(v: int) =
        w.I32 4
        w.I32 v
    member w.Text(utf8: ReadOnlySpan<byte>) =
        w.I32 utf8.Length
        w.Raw utf8
    member w.Text(s: string) =
        if isNull s then w.Null()
        else
            let max = Encoding.UTF8.GetMaxByteCount s.Length
            w.Ensure(4 + max)
            let l = Encoding.UTF8.GetBytes(s.AsSpan(), Span(b, n + 4, max))
            BinaryPrimitives.WriteInt32BigEndian(Span(b, n, 4), l)
            n <- n + 4 + l

    /// A one-dimensional array parameter without NULLs: BeginArray, elements (Int8/Int4/Text), EndArray(count).
    member w.BeginArray(elementOid: uint32) =
        paramStart <- n
        w.I32 0 // parameter length
        w.I32 1 // ndim
        w.I32 0 // no NULLs
        w.I32(int elementOid)
        arrayCount <- n
        w.I32 0 // dimension size
        w.I32 1 // lower bound
    member w.EndArray(count: int) =
        w.Patch(arrayCount, count)
        w.Patch(paramStart, n - paramStart - 4)
    member w.TextArray(values: string[]) =
        w.BeginArray Oid.Text
        for v in values do w.Text v
        w.EndArray values.Length

    // ---------- startup ----------
    member w.Startup(user: string, database: string, options: string) =
        let start = n
        w.I32 0
        w.I32 196608 // protocol 3.0
        for (k, v) in [ "user", user; "database", database; "options", options; "client_encoding", "UTF8"; "application_name", "conduit-fs" ] do
            if not (String.IsNullOrEmpty v) then
                w.CStr(ReadOnlySpan(Encoding.UTF8.GetBytes k))
                w.CStr(ReadOnlySpan(Encoding.UTF8.GetBytes v))
        w.U8 0uy
        w.Patch(start, n - start)
    member w.Password(body: ReadOnlySpan<byte>) =
        w.U8 'p'B
        w.I32(4 + body.Length)
        w.Raw body
    member w.Parse(s: Stmt) =
        let start = n
        w.U8 'P'B
        w.I32 0
        w.CStr(ReadOnlySpan s.Name)
        w.CStr(ReadOnlySpan(Encoding.UTF8.GetBytes s.Sql))
        w.I16 s.ParamOids.Length
        for o in s.ParamOids do w.I32(int o)
        w.Patch(start + 1, n - start - 1)

/// One query = one Sync group: its Bind/Execute pairs and a Sync. Rows and command completions are numbered by
/// statement (result) within the group; Done comes once, after ReadyForQuery, with the first error if any.
[<AbstractClass; AllowNullLiteral>]
type PgQuery() =
    abstract Write: PgWriter -> unit
    abstract Row: result: int * row: PgRow -> unit
    default _.Row(_, _) = ()
    abstract Complete: result: int * tag: ReadOnlySpan<byte> -> unit
    default _.Complete(_, _) = ()
    abstract Done: PgError -> unit

let parseError (body: ReadOnlySpan<byte>) =
    let mutable state = "XX000"
    let mutable msg = ""
    let mutable body = body
    let mutable go = true
    while go && body.Length > 1 && body.[0] <> 0uy do
        let f = body.[0]
        let e = body.Slice(1).IndexOf 0uy
        if e < 0 then go <- false
        else
            let v = Encoding.UTF8.GetString(body.Slice(1, e))
            if f = 'C'B then state <- v
            elif f = 'M'B then msg <- v
            body <- body.Slice(e + 2)
    PgError(state, msg)

let private lost = PgError("08006", "connection lost")

/// A connection: the queries in flight, the send buffers and the receive buffer. Driven by one io_uring loop.
[<Sealed; AllowNullLiteral>]
type PgConn(sock: Socket, index: int, isWrite: bool) =
    let fd = int (sock.Handle)
    let inflight = Queue<PgQuery>()
    let mutable pending = PgWriter()
    let mutable sending = PgWriter()
    let mutable sendOff = 0
    let mutable r = GC.AllocateUninitializedArray<byte>(256 * 1024, pinned = true)
    let mutable rs = 0
    let mutable re = 0
    let row = PgRow()
    let mutable cur: PgQuery = null
    let mutable result = 0
    let mutable error: PgError = null
    member val Inflight = 0 with get, set
    member val Broken = false with get, set
    member val SendInFlight = false with get, set
    member val Dirty = false with get, set
    member val Busy = 0 with get, set
    member _.Socket = sock
    member _.Fd = fd
    member _.Index = index
    member _.IsWrite = isWrite
    member _.HasPending = pending.Length > 0

    /// Writes the query into the send buffer (the loop sends it). Returns false if the connection is broken.
    member c.Submit(q: PgQuery) =
        if c.Broken then
            q.Done lost
            false
        else
            q.Write pending
            inflight.Enqueue q
            c.Inflight <- c.Inflight + 1
            true

    /// The bytes to send now (swaps the buffers), or len 0.
    member c.TakeSend(addr: byref<nativeint>, len: byref<int>) =
        if c.SendInFlight || pending.Length = 0 then len <- 0
        else
            let w = sending
            sending <- pending
            pending <- w
            sendOff <- 0
            c.SendInFlight <- true
            addr <- sending.Address 0
            len <- sending.Length

    /// A send completed: false = failed. Sets addr/len when the rest must go out again.
    member c.Sent(res: int, addr: byref<nativeint>, len: byref<int>) =
        len <- 0
        if res < 0 then false
        else
            sendOff <- sendOff + res
            if sendOff < sending.Length then
                addr <- sending.Address sendOff
                len <- sending.Length - sendOff
            else
                sending.Reset()
                c.SendInFlight <- false
            true

    /// Where the next receive goes.
    member _.RecvTarget(addr: byref<nativeint>, len: byref<int>) =
        if re = r.Length then
            if rs > 0 then
                Buffer.BlockCopy(r, rs, r, 0, re - rs)
                re <- re - rs
                rs <- 0
            else
                let bigger = GC.AllocateUninitializedArray<byte>(r.Length * 2, pinned = true)
                Buffer.BlockCopy(r, 0, bigger, 0, re)
                r <- bigger
        addr <- Marshal.UnsafeAddrOfPinnedArrayElement(r, re)
        len <- r.Length - re

    /// `n` bytes arrived: handles every complete message. `freed` runs after each completed query.
    member c.Received(n: int, freed: PgConn -> unit) =
        re <- re + n
        let mutable go = true
        while go && re - rs >= 5 do
            let len = BinaryPrimitives.ReadInt32BigEndian(ReadOnlySpan(r, rs + 1, 4))
            if re - rs < 1 + len then
                if 1 + len > r.Length then
                    let bigger = GC.AllocateUninitializedArray<byte>(max (r.Length * 2) (1 + len), pinned = true)
                    Buffer.BlockCopy(r, rs, bigger, 0, re - rs)
                    re <- re - rs
                    rs <- 0
                    r <- bigger
                go <- false
            else
                let typ = r.[rs]
                let start = rs + 5
                let blen = len - 4
                rs <- rs + 1 + len
                c.Handle(typ, start, blen, freed)
        if rs = re then
            rs <- 0
            re <- 0

    member private c.Current() =
        if isNull cur then cur <- inflight.Peek()
        cur

    member private c.Handle(typ: byte, start: int, blen: int, freed: PgConn -> unit) =
        match typ with
        | 'D'B ->
            if isNull error then
                row.Set(r, start)
                c.Current().Row(result, row)
        | 'C'B ->
            if isNull error then
                let tag = ReadOnlySpan(r, start, blen)
                c.Current().Complete(result, (if tag.Length > 0 then tag.Slice(0, tag.Length - 1) else tag))
            result <- result + 1
        | 'E'B ->
            if isNull error then error <- parseError (ReadOnlySpan(r, start, blen))
        | 'Z'B ->
            let q = inflight.Dequeue()
            c.Inflight <- c.Inflight - 1
            cur <- null
            let err = error
            error <- null
            result <- 0
            (try q.Done err with e -> eprintfn "%O" e)
            freed c
        | _ -> () // BindComplete, ParseComplete, NoData, notices, parameter status: nothing

    member c.Fail(why: string) =
        if not c.Broken then
            c.Broken <- true
            eprintfn "postgres connection %d failed: %s" index why
            let err = PgError("08006", "connection lost: " + why)
            let qs = inflight.ToArray()
            inflight.Clear()
            c.Inflight <- 0
            (try sock.Close() with _ -> ())
            for q in qs do
                try q.Done err with e -> eprintfn "%O" e

// ---------- startup (blocking, before any traffic) ----------

let private readExactly (s: Socket) (dst: Span<byte>) =
    let mutable d = dst
    while d.Length > 0 do
        let n = s.Receive(d)
        if n <= 0 then raise (IO.IOException "connection closed during startup")
        d <- d.Slice n

let private readMessage (s: Socket) (body: byref<byte[]>) =
    let head = Array.zeroCreate<byte> 5
    readExactly s (Span head)
    let len = BinaryPrimitives.ReadInt32BigEndian(ReadOnlySpan(head, 1, 4))
    body <- Array.zeroCreate (len - 4)
    readExactly s (Span body)
    head.[0]

let private sendNow (s: Socket) (w: PgWriter) =
    let mutable off = 0
    while off < w.Length do
        off <- off + s.Send(w.Buffer, off, w.Length - off, SocketFlags.None)
    w.Reset()

let private handshake (s: Socket) (user: string) (password: string) (database: string) (options: string) =
    let w = PgWriter(4096)
    w.Startup(user, database, options)
    sendNow s w
    let mutable clientFirstBare: string = null
    let mutable nonce: string = null
    let mutable serverSignature: byte[] = null
    let mutable go = true
    while go do
        let mutable body: byte[] = null
        let t = readMessage s &body
        if t = 'E'B then failwithf "postgres: %O" (parseError (ReadOnlySpan body))
        elif t = 'Z'B then go <- false
        elif t = 'R'B then
            match BinaryPrimitives.ReadInt32BigEndian(ReadOnlySpan(body, 0, 4)) with
            | 0 -> () // AuthenticationOk
            | 3 ->
                w.Password(ReadOnlySpan(Encoding.UTF8.GetBytes(password + "\000")))
                sendNow s w
            | 5 ->
                let inner = Convert.ToHexStringLower(MD5.HashData(Encoding.UTF8.GetBytes(password + user)))
                let withSalt = Array.append (Encoding.ASCII.GetBytes inner) body.[4..7]
                w.Password(ReadOnlySpan(Encoding.ASCII.GetBytes("md5" + Convert.ToHexStringLower(MD5.HashData withSalt) + "\000")))
                sendNow s w
            | 10 ->
                nonce <- Convert.ToBase64String(RandomNumberGenerator.GetBytes 18)
                clientFirstBare <- "n=*,r=" + nonce
                let first = Encoding.ASCII.GetBytes("n,," + clientFirstBare)
                let lenBytes = Array.zeroCreate<byte> 4
                BinaryPrimitives.WriteInt32BigEndian(Span lenBytes, first.Length)
                let msg = Array.concat [ Encoding.ASCII.GetBytes "SCRAM-SHA-256\000"; lenBytes; first ]
                w.Password(ReadOnlySpan msg)
                sendNow s w
            | 11 ->
                let serverFirst = Encoding.ASCII.GetString(body, 4, body.Length - 4)
                let mutable rr: string = null
                let mutable salt: string = null
                let mutable iter = 0
                for part in serverFirst.Split ',' do
                    if part.StartsWith "r=" then rr <- part.Substring 2
                    elif part.StartsWith "s=" then salt <- part.Substring 2
                    elif part.StartsWith "i=" then iter <- int (part.Substring 2)
                if isNull rr || not (rr.StartsWith nonce) || isNull salt || iter <= 0 then
                    failwith "postgres: bad SCRAM server-first message"
                let withoutProof = "c=biws,r=" + rr
                let salted =
                    Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes password, Convert.FromBase64String salt, iter, HashAlgorithmName.SHA256, 32)
                let clientKey = HMACSHA256.HashData(salted, Encoding.ASCII.GetBytes "Client Key")
                let storedKey = SHA256.HashData clientKey
                let authMessage = Encoding.ASCII.GetBytes(clientFirstBare + "," + serverFirst + "," + withoutProof)
                let clientSig = HMACSHA256.HashData(storedKey, authMessage)
                let proof = Array.init 32 (fun i -> clientKey.[i] ^^^ clientSig.[i])
                let serverKey = HMACSHA256.HashData(salted, Encoding.ASCII.GetBytes "Server Key")
                serverSignature <- HMACSHA256.HashData(serverKey, authMessage)
                w.Password(ReadOnlySpan(Encoding.ASCII.GetBytes(withoutProof + ",p=" + Convert.ToBase64String proof)))
                sendNow s w
            | 12 ->
                let fin = Encoding.ASCII.GetString(body, 4, body.Length - 4)
                if not (fin.StartsWith "v=") || isNull serverSignature
                   || not (CryptographicOperations.FixedTimeEquals(ReadOnlySpan(Convert.FromBase64String(fin.Substring 2)), ReadOnlySpan serverSignature)) then
                    failwith "postgres: SCRAM server signature mismatch"
            | code -> failwithf "postgres: unsupported authentication method %d" code

let private prepareAll (s: Socket) =
    let w = PgWriter(64 * 1024)
    for st in Stmt.All do w.Parse st
    w.Sync()
    sendNow s w
    let mutable err: PgError = null
    let mutable go = true
    while go do
        let mutable body: byte[] = null
        let t = readMessage s &body
        if t = 'E'B && isNull err then err <- parseError (ReadOnlySpan body)
        if t = 'Z'B then go <- false
    if not (isNull err) then failwithf "postgres: preparing statements failed: %O" err

/// Connects and authenticates; prepares every statement when `prepare`.
let connect (url: string) (options: string) (prepare: bool) =
    let u = Uri url
    let ui = u.UserInfo.Split(':', 2)
    let user = Uri.UnescapeDataString ui.[0]
    let password = if ui.Length > 1 then Uri.UnescapeDataString ui.[1] else ""
    let db = Uri.UnescapeDataString(u.AbsolutePath.TrimStart '/')
    let host = u.Host
    let port = if u.Port > 0 then u.Port else 5432
    let addr =
        match IPAddress.TryParse host with
        | true, ip -> ip
        | _ -> Dns.GetHostAddresses(host).[0]
    let s = new Socket(addr.AddressFamily, SocketType.Stream, ProtocolType.Tcp, NoDelay = true)
    s.Connect(IPEndPoint(addr, port))
    handshake s user password db options
    if prepare then prepareAll s
    s

/// A one-off query on a fresh connection (startup only): the first row's columns as strings.
let queryOnce (url: string) (options: string) (sql: string) : string[] =
    use s = connect url options false
    let w = PgWriter(4096)
    // simple query protocol, text results
    let q = Encoding.UTF8.GetBytes sql
    w.U8 'Q'B
    w.I32(4 + q.Length + 1)
    w.CStr(ReadOnlySpan q)
    sendNow s w
    let mutable res: string[] = null
    let mutable err: PgError = null
    let mutable go = true
    while go do
        let mutable body: byte[] = null
        let t = readMessage s &body
        if t = 'E'B && isNull err then err <- parseError (ReadOnlySpan body)
        if t = 'D'B && isNull res then
            let n = int (BinaryPrimitives.ReadInt16BigEndian(ReadOnlySpan(body, 0, 2)))
            res <- Array.zeroCreate n
            let mutable pos = 2
            for i in 0 .. n - 1 do
                let l = BinaryPrimitives.ReadInt32BigEndian(ReadOnlySpan(body, pos, 4))
                pos <- pos + 4
                if l >= 0 then
                    res.[i] <- Encoding.UTF8.GetString(body, pos, l)
                    pos <- pos + l
        if t = 'Z'B then go <- false
    if not (isNull err) then failwithf "postgres: %O" err
    res
