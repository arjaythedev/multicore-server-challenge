/// HTTP/1.1 over epoll: N I/O threads, each with its own SO_REUSEPORT listener and epoll set.
///
/// A thread reads a request, parses it and calls the handler on the spot. The handler either answers at once or
/// hands the work on (to the Postgres lanes or the bcrypt threads), which answer later through post(): the reply
/// goes into the owning thread's inbox, and the thread is woken with one eventfd write per batch of replies.
/// A connection serves one request at a time; bytes that arrive meanwhile (pipelining) wait in its buffer.
/// Near the fd limit, the connection idle the longest is closed (the client's next request reconnects).
module Io

#nowarn "9"

open System
open System.Buffers.Text
open System.Collections.Concurrent
open System.Threading
open Microsoft.FSharp.NativeInterop

/// Where a reply goes: I/O thread, socket, and the socket's generation (fds are reused after close).
[<Struct>]
type Dest = { Loop: int; Fd: int; Gen: int }

/// One parsed request. The spans point into the I/O thread's read buffer: valid only during the handler call.
[<Struct; NoEquality; NoComparison>]
type Request =
    { Method: byte // 'G' GET, 'P' POST, 'U' PUT, 'D' DELETE, '?' other
      Path: ReadOnlyMemory<byte>
      Query: ReadOnlyMemory<byte>
      Auth: ReadOnlyMemory<byte> // the Authorization header's value, empty if absent
      HasAuth: bool
      Body: ReadOnlyMemory<byte> }

/// The application: returns the response now, or null when it will post() one later.
let mutable handler: Dest -> Request -> byte[] = fun _ _ -> null

[<Literal>]
let private TagListen = 0xFFFFFFFF00000001UL
[<Literal>]
let private TagWake = 0xFFFFFFFF00000002UL

/// per-fd state; each fd belongs to one loop, which alone touches it
[<AllowNullLiteral>]
type private Conn() =
    member val Gen = 0 with get, set
    member val Open = false with get, set
    member val Busy = false with get, set // a request is being answered
    member val CloseAfter = false with get, set
    member val In: byte[] = null with get, set // unparsed bytes
    member val InLen = 0 with get, set
    member val Out: byte[] = null with get, set // unsent reply bytes
    member val OutOff = 0 with get, set
    member val Prev = -1 with get, set // LRU of idle connections (fd links)
    member val Next = -1 with get, set
    member val InLru = false with get, set

let mutable private conns: Conn[] = [||]
let mutable private fdBudget = 1000
let mutable private openCount = 0

[<Sealed>]
type Loop(index: int, listenFd: int) =
    let ep = Sys.epoll_create1 0x80000
    let efd = Sys.eventfd (0u, 0x800 ||| 0x80000)
    let inbox = ConcurrentQueue<struct (int * int * byte[])>()
    let mutable wakePending = 0
    let rbuf: byte[] = Array.zeroCreate (256 * 1024)
    let mutable lruHead = -1 // oldest idle
    let mutable lruTail = -1

    let lruRemove (fd: int) =
        let c = conns.[fd]
        if c.InLru then
            if c.Prev >= 0 then conns.[c.Prev].Next <- c.Next else lruHead <- c.Next
            if c.Next >= 0 then conns.[c.Next].Prev <- c.Prev else lruTail <- c.Prev
            c.Prev <- -1
            c.Next <- -1
            c.InLru <- false

    let lruAdd (fd: int) =
        let c = conns.[fd]
        if not c.InLru then
            c.Prev <- lruTail
            c.Next <- -1
            if lruTail >= 0 then conns.[lruTail].Next <- fd else lruHead <- fd
            lruTail <- fd
            c.InLru <- true

    let closeFd (fd: int) =
        let c = conns.[fd]
        if c.Open then
            lruRemove fd
            c.Open <- false
            c.Busy <- false
            c.In <- null
            c.InLen <- 0
            c.Out <- null
            c.Gen <- c.Gen + 1
            Sys.close fd |> ignore
            Interlocked.Decrement(&openCount) |> ignore

    /// closes the connection idle the longest (one with no request in flight)
    let evictOne () =
        if lruHead >= 0 then
            closeFd lruHead
            true
        else
            false

    /// writes as much as the socket takes; keeps the rest for EPOLLOUT
    let rec sendBytes (fd: int) (c: Conn) (data: byte[]) (off: int) =
        let mutable o = off
        let mutable go = true
        while go && o < data.Length do
            let k =
                use p = fixed data
                Sys.write (fd, NativePtr.add p o, unativeint (data.Length - o))
            if k > 0n then o <- o + int k
            else
                let e = Sys.errno ()
                if k < 0n && e = Sys.EINTR then ()
                elif k < 0n && e = Sys.EAGAIN then
                    c.Out <- data
                    c.OutOff <- o
                    Sys.ctl ep Sys.EPOLL_CTL_MOD fd (Sys.EPOLLIN ||| Sys.EPOLLOUT ||| Sys.EPOLLRDHUP) (uint64 fd) |> ignore
                    go <- false
                else
                    closeFd fd
                    go <- false
        o >= data.Length

    let mutable dispatchRef: int -> unit = ignore

    /// a reply is ready for fd: send it, then serve any request already buffered
    let deliver (fd: int) (gen: int) (data: byte[]) =
        let c = conns.[fd]
        if c.Open && c.Gen = gen && c.Busy then
            c.Busy <- false
            if sendBytes fd c data 0 then
                if c.CloseAfter then closeFd fd
                elif c.Open then
                    if c.InLen > 0 then dispatchRef fd
                    if c.Open && not c.Busy then lruAdd fd

    /// Parses and dispatches buffered requests until one goes asynchronous or the buffer runs out.
    let dispatch (fd: int) =
        let c = conns.[fd]
        let mutable go = true
        while go && c.Open && not c.Busy && c.InLen > 0 do
            let buf = c.In
            let len = c.InLen
            let span = ReadOnlySpan(buf, 0, len)
            let hEnd = span.IndexOf "\r\n\r\n"B
            if hEnd < 0 then
                if len > 65536 then closeFd fd
                go <- false
            else
                // request line
                let lineEnd = span.IndexOf "\r\n"B
                let line = span.Slice(0, lineEnd)
                let sp1 = line.IndexOf ' 'B
                let sp2 = if sp1 > 0 then line.Slice(sp1 + 1).IndexOf ' 'B else -1
                if sp1 <= 0 || sp2 <= 0 then
                    closeFd fd
                    go <- false
                else
                    let m = line.[0]
                    let meth =
                        if sp1 = 3 && m = 'G'B then 'G'B
                        elif sp1 = 4 && m = 'P'B && line.[1] = 'O'B then 'P'B
                        elif sp1 = 3 && m = 'P'B && line.[1] = 'U'B then 'U'B
                        elif sp1 = 6 && m = 'D'B then 'D'B
                        else '?'B
                    let target = sp1 + 1
                    let tlen = sp2
                    let tspan = line.Slice(target, tlen)
                    let qm = tspan.IndexOf '?'B
                    let pathLen = if qm >= 0 then qm else tlen
                    let http10 = line.Slice(target + tlen + 1).SequenceEqual "HTTP/1.0"B
                    // headers
                    let mutable p = lineEnd + 2
                    let mutable clen = 0
                    let mutable authOff = 0
                    let mutable authLen = 0
                    let mutable hasAuth = false
                    let mutable close = http10
                    let mutable bad = false
                    while p < hEnd do
                        let rest = span.Slice(p, hEnd - p)
                        let e0 = rest.IndexOf "\r\n"B
                        let e = if e0 < 0 then rest.Length else e0
                        let h = rest.Slice(0, e)
                        let colon = h.IndexOf ':'B
                        if colon > 0 then
                            let name = h.Slice(0, colon)
                            let mutable vs = colon + 1
                            while vs < h.Length && (h.[vs] = ' 'B || h.[vs] = '\t'B) do
                                vs <- vs + 1
                            let mutable ve = h.Length
                            while ve > vs && (h.[ve - 1] = ' 'B || h.[ve - 1] = '\t'B) do
                                ve <- ve - 1
                            let v = h.Slice(vs, ve - vs)
                            if name.Length = 14 && Text.Ascii.EqualsIgnoreCase(name, "content-length"B) then
                                let mutable x = 0
                                let mutable used = 0
                                if Utf8Parser.TryParse(v, &x, &used) && used = v.Length && x >= 0 then clen <- x else bad <- true
                            elif name.Length = 13 && Text.Ascii.EqualsIgnoreCase(name, "authorization"B) then
                                hasAuth <- true
                                authOff <- p + vs
                                authLen <- ve - vs
                            elif name.Length = 10 && Text.Ascii.EqualsIgnoreCase(name, "connection"B) then
                                if Text.Ascii.EqualsIgnoreCase(v, "close"B) then close <- true
                                elif Text.Ascii.EqualsIgnoreCase(v, "keep-alive"B) then close <- false
                            elif name.Length = 17 && Text.Ascii.EqualsIgnoreCase(name, "transfer-encoding"B) then
                                bad <- true // chunked bodies are not supported
                        p <- p + e + 2
                    let total = hEnd + 4 + clen
                    if bad || clen > 1048576 then
                        closeFd fd
                        go <- false
                    elif len < total then
                        go <- false // body not complete yet
                    else
                        let mem = ReadOnlyMemory(buf)
                        let req =
                            { Method = meth
                              Path = mem.Slice(target, pathLen)
                              Query = (if qm >= 0 then mem.Slice(target + qm + 1, tlen - qm - 1) else ReadOnlyMemory.Empty)
                              Auth = mem.Slice(authOff, authLen)
                              HasAuth = hasAuth
                              Body = mem.Slice(hEnd + 4, clen) }
                        c.Busy <- true
                        c.CloseAfter <- close
                        lruRemove fd
                        let reply =
                            try handler { Loop = index; Fd = fd; Gen = c.Gen } req
                            with ex ->
                                eprintfn "handler: %O" ex
                                Json.error 500 "internal"
                        // consume the request bytes (the handler has copied what it needs)
                        if total < len then
                            let nb = Array.zeroCreate (max 4096 (len - total))
                            Buffer.BlockCopy(buf, total, nb, 0, len - total)
                            c.In <- nb
                            c.InLen <- len - total
                        else
                            c.In <- null
                            c.InLen <- 0
                        if not (isNull reply) then
                            c.Busy <- false
                            if sendBytes fd c reply 0 then
                                if c.CloseAfter then closeFd fd
                            else go <- false
                        else
                            go <- false
        if c.Open && not c.Busy then lruAdd fd

    let onReadable (fd: int) =
        let c = conns.[fd]
        let mutable go = true
        while go && c.Open do
            let k =
                use p = fixed rbuf
                Sys.read (fd, p, unativeint rbuf.Length)
            if k > 0n then
                let n = int k
                if c.InLen = 0 && not c.Busy && n < rbuf.Length then
                    // common case: a whole request in one read, parsed straight from the read buffer; whatever
                    // is left unparsed is copied out before the buffer is reused
                    c.In <- rbuf
                    c.InLen <- n
                    dispatch fd
                    if obj.ReferenceEquals(c.In, rbuf) then
                        let b = Array.zeroCreate (max 4096 c.InLen)
                        Buffer.BlockCopy(rbuf, 0, b, 0, c.InLen)
                        c.In <- b
                    go <- false
                else
                    let need = c.InLen + n
                    if isNull c.In || c.In.Length < need then
                        let nb = Array.zeroCreate (max need (if isNull c.In then 0 else c.In.Length * 2))
                        if c.InLen > 0 then Buffer.BlockCopy(c.In, 0, nb, 0, c.InLen)
                        c.In <- nb
                    Buffer.BlockCopy(rbuf, 0, c.In, c.InLen, n)
                    c.InLen <- need
                if n < rbuf.Length then go <- false
            elif k = 0n then
                closeFd fd
                go <- false
            else
                let e = Sys.errno ()
                if e <> Sys.EINTR then
                    if e <> Sys.EAGAIN then closeFd fd
                    go <- false
        if c.Open && not c.Busy && c.InLen > 0 then dispatch fd

    let onWritable (fd: int) =
        let c = conns.[fd]
        if c.Open && not (isNull c.Out) then
            let data = c.Out
            c.Out <- null
            Sys.ctl ep Sys.EPOLL_CTL_MOD fd (Sys.EPOLLIN ||| Sys.EPOLLRDHUP) (uint64 fd) |> ignore
            if sendBytes fd c data c.OutOff then
                if c.CloseAfter then closeFd fd
                elif c.InLen > 0 then dispatch fd

    let accept () =
        let mutable go = true
        while go do
            let fd = Sys.accept4 (listenFd, 0n, 0n, Sys.SOCK_NONBLOCK ||| Sys.SOCK_CLOEXEC)
            if fd >= 0 then
                if fd >= conns.Length then
                    Sys.close fd |> ignore
                else
                    if Interlocked.Increment(&openCount) > fdBudget then evictOne () |> ignore
                    Sys.setsockopt (fd, 6, 1, 1) |> ignore // TCP_NODELAY
                    let c =
                        match conns.[fd] with
                        | null ->
                            let c = Conn()
                            conns.[fd] <- c
                            c
                        | c -> c
                    c.Open <- true
                    c.Busy <- false
                    c.CloseAfter <- false
                    c.In <- null
                    c.InLen <- 0
                    c.Out <- null
                    Sys.ctl ep Sys.EPOLL_CTL_ADD fd (Sys.EPOLLIN ||| Sys.EPOLLRDHUP) (uint64 fd) |> ignore
                    lruAdd fd
            else
                let e = Sys.errno ()
                if (e = Sys.EMFILE || e = Sys.ENFILE) && evictOne () then ()
                else go <- false

    do dispatchRef <- dispatch

    member _.Index = index

    /// called from any thread
    member _.Post(fd: int, gen: int, data: byte[]) =
        inbox.Enqueue(struct (fd, gen, data))
        if Interlocked.Exchange(&wakePending, 1) = 0 then
            let one = NativePtr.stackalloc<uint64> 1
            NativePtr.write one 1UL
            Sys.write (efd, NativePtr.ofNativeInt (NativePtr.toNativeInt one), 8un) |> ignore

    member _.Run() =
        Sys.ctl ep Sys.EPOLL_CTL_ADD listenFd Sys.EPOLLIN TagListen |> ignore
        Sys.ctl ep Sys.EPOLL_CTL_ADD efd Sys.EPOLLIN TagWake |> ignore
        let evs = NativePtr.stackalloc<Sys.EpollEvent> 512
        let tmp = NativePtr.stackalloc<uint64> 1
        while true do
            let n = Sys.epoll_wait (ep, evs, 512, -1)
            for i in 0 .. n - 1 do
                let ev = NativePtr.get evs i
                if ev.Data = TagListen then accept ()
                elif ev.Data = TagWake then
                    Sys.read (efd, NativePtr.ofNativeInt (NativePtr.toNativeInt tmp), 8un) |> ignore
                    Volatile.Write(&wakePending, 0)
                    let mutable item = Unchecked.defaultof<struct (int * int * byte[])>
                    while inbox.TryDequeue(&item) do
                        let struct (fd, gen, data) = item
                        deliver fd gen data
                else
                    let fd = int ev.Data
                    if ev.Events &&& Sys.EPOLLOUT <> 0u then onWritable fd
                    if ev.Events &&& (Sys.EPOLLIN ||| Sys.EPOLLHUP ||| Sys.EPOLLERR ||| Sys.EPOLLRDHUP) <> 0u then
                        onReadable fd

let mutable private loops: Loop[] = [||]

/// Answers a request that went asynchronous. Safe from any thread.
let post (d: Dest) (data: byte[]) = loops.[d.Loop].Post(d.Fd, d.Gen, data)

/// Starts `count` I/O threads on host:port. reserve: fds kept free for Postgres, files and the runtime.
let start (host: string) (port: int) (count: int) (reserve: int) (nice: int) =
    let limit = Sys.raiseNoFile ()
    conns <- Array.zeroCreate (limit + 16)
    fdBudget <- max 64 (limit - reserve)
    loops <- Array.init count (fun i -> Loop(i, Sys.listenTcp host port))
    for l in loops do
        Thread((fun () ->
                    Sys.niceThread nice
                    l.Run()),
               IsBackground = true,
               Name = sprintf "io-%d" l.Index)
            .Start()
    limit
