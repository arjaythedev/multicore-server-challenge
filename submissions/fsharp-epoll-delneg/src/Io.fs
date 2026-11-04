/// HTTP/1.1 over epoll or io_uring: N I/O threads, each with its own SO_REUSEPORT listener and epoll set or ring.
///
/// A thread reads a request, parses it and calls the handler on the spot. The handler either answers at once or
/// hands the work on (to the Postgres lanes or the bcrypt threads), which answer later through post(): the reply
/// goes into the owning thread's inbox, and the thread is woken with one eventfd write per batch of replies.
/// A connection serves one request at a time; bytes that arrive meanwhile (pipelining) wait in its buffer.
/// Near the fd limit, the connection idle the longest is closed (the client's next request reconnects).
///
/// With io_uring (IO_MODE=uring) each thread keeps a multishot accept, a multishot recv per connection into a pool of
/// provided buffers, and the replies' sends in its ring, and waits for completions in one call that also submits.
/// Parsing, dispatch and connection state are the same code as with epoll; only waiting and sending differ.
module Io

#nowarn "9"

open System
open System.Buffers.Text
open System.Collections.Concurrent
open System.Collections.Generic
open System.Runtime.InteropServices
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

/// epoll's tag for a connection: fd and generation. An fd closed earlier in a batch of events can already belong to
/// another loop by the time its stale event comes up; the generation tells that event apart from a live one.
let inline private epTag (fd: int) (c: Conn) =
    uint64 (uint32 fd) ||| (uint64 (uint32 (c.Gen &&& 0x7FFFFFFF)) <<< 32)

/// io_uring settings (Main sets them): use it, force classic provided buffers (the path for kernels whose buffer
/// rings fail), ring and pool sizes
let mutable uring = false
let mutable uringClassic = false
let mutable uringBufs = 8192
let mutable uringBufLen = 2048

/// Each I/O thread gets its own fd table (Run), so RLIMIT_NOFILE, which is counted per table, holds per thread as
/// it does per worker in a multi-process server. FD_TABLES=shared turns it off.
let mutable ownFdTables = true

// completion kinds in the top 4 bits of user_data; fd in the low 32, generation (or send slot) in bits 32-59
[<Literal>]
let private KAccept = 1UL
[<Literal>]
let private KRecv = 2UL
[<Literal>]
let private KSend = 3UL
[<Literal>]
let private KWake = 4UL
let inline private ud (k: uint64) (mid: int) (fd: int) = (k <<< 60) ||| ((uint64 mid &&& 0xFFFFFFFUL) <<< 32) ||| uint64 (uint32 fd)
let inline private gen28 (g: int) = g &&& 0xFFFFFFF

[<Sealed>]
type Loop(index: int, listenFd: int, tableSize: int, sharedBudget: int) =
    // fd -> connection, for this loop's fds alone: with own fd tables the same number is a different socket per loop
    let conns: Conn[] = Array.zeroCreate tableSize
    let mutable fdBudget = sharedBudget
    let mutable openCount = 0
    let ep = Sys.epoll_create1 0x80000
    let efd = Sys.eventfd (0u, 0x800 ||| 0x80000)
    let inbox = ConcurrentQueue<struct (int * int * byte[])>()
    let mutable wakePending = 0
    let rbuf: byte[] = Array.zeroCreate (256 * 1024)
    let mutable spareFd = Sys.openDevNull ()
    let mutable lruHead = -1 // oldest idle
    let mutable lruTail = -1
    // io_uring state, set up in Run on this loop's own thread (a single-issuer ring belongs to the thread that made it)
    let mutable ring = 0n
    let mutable pool = 0n
    let mutable useRing = false
    // sends in flight: the reply stays pinned until its completion, even if its connection closes meanwhile
    let mutable slotData: byte[][] = Array.zeroCreate 1024
    let mutable slotPin: GCHandle[] = Array.zeroCreate 1024
    let mutable slotOff: int[] = Array.zeroCreate 1024
    let mutable slotFd: int[] = Array.zeroCreate 1024
    let mutable slotGen: int[] = Array.zeroCreate 1024
    let freeSlots = Stack<int>(Seq.rev (seq { 0 .. 1023 }))
    let starved = List<int>() // connections whose recv ran out of buffers, re-armed after the next batch

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
            // with a recv in flight in the ring, close alone would leave the socket open: shutdown ends the recv
            if useRing then Sys.shutdown (fd, 2) |> ignore
            Sys.close fd |> ignore
            openCount <- openCount - 1

    /// closes the connection idle the longest (one with no request in flight)
    let evictOne () =
        if lruHead >= 0 then
            closeFd lruHead
            true
        else
            false

    let newSlot () =
        if freeSlots.Count = 0 then
            let n = slotData.Length
            Array.Resize(&slotData, n * 2)
            Array.Resize(&slotPin, n * 2)
            Array.Resize(&slotOff, n * 2)
            Array.Resize(&slotFd, n * 2)
            Array.Resize(&slotGen, n * 2)
            for i in n * 2 - 1 .. -1 .. n do
                freeSlots.Push i
        freeSlots.Pop()

    let submitSend (slot: int) =
        let data = slotData.[slot]
        let off = slotOff.[slot]
        let p = NativePtr.add (NativePtr.ofNativeInt<byte> (slotPin.[slot].AddrOfPinnedObject())) off
        Sys.ur_send (ring, slotFd.[slot], p, uint32 (data.Length - off), ud KSend slot slotFd.[slot])

    let rec sendBytes (fd: int) (c: Conn) (data: byte[]) (off: int) =
        if useRing then
            // the ring sends it; the connection counts as having output pending until the completion
            let slot = newSlot ()
            slotData.[slot] <- data
            slotPin.[slot] <- GCHandle.Alloc(data, GCHandleType.Pinned)
            slotOff.[slot] <- off
            slotFd.[slot] <- fd
            slotGen.[slot] <- c.Gen
            c.Out <- data
            if submitSend slot < 0 then
                // no room in the ring even after submitting: drop the connection rather than leave it hanging
                slotPin.[slot].Free()
                slotData.[slot] <- null
                freeSlots.Push slot
                closeFd fd
            false
        else
            // writes as much as the socket takes; keeps the rest for EPOLLOUT
            let mutable o = off
            let mutable go = true
            while go && o < data.Length do
                let k =
                    use p = fixed data
                    Sys.send (fd, NativePtr.add p o, unativeint (data.Length - o), Sys.MSG_NOSIGNAL)
                if k > 0n then o <- o + int k
                else
                    let e = Sys.errno ()
                    if k < 0n && e = Sys.EINTR then ()
                    elif k < 0n && e = Sys.EAGAIN then
                        c.Out <- data
                        c.OutOff <- o
                        Sys.ctl ep Sys.EPOLL_CTL_MOD fd (Sys.EPOLLIN ||| Sys.EPOLLOUT ||| Sys.EPOLLRDHUP) (epTag fd c) |> ignore
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
        // one reply at a time: a pipelined request waits until the previous reply is fully sent
        while go && c.Open && not c.Busy && isNull c.Out && c.InLen > 0 do
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
                Sys.recv (fd, p, unativeint rbuf.Length, 0)
            if k > 0n then
                let n = int k
                if c.InLen = 0 && not c.Busy && isNull c.Out && n < rbuf.Length then
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

    /// io_uring: n received bytes at src for fd (same handling as one recv in onReadable)
    let onData (fd: int) (src: nativeptr<byte>) (n: int) =
        let c = conns.[fd]
        let data = ReadOnlySpan<byte>(NativePtr.toVoidPtr src, n)
        if c.InLen = 0 && not c.Busy && isNull c.Out && n <= rbuf.Length then
            data.CopyTo(Span rbuf)
            c.In <- rbuf
            c.InLen <- n
            dispatch fd
            if obj.ReferenceEquals(c.In, rbuf) then
                let b = Array.zeroCreate (max 4096 c.InLen)
                Buffer.BlockCopy(rbuf, 0, b, 0, c.InLen)
                c.In <- b
        else
            let need = c.InLen + n
            if isNull c.In || c.In.Length < need then
                let nb = Array.zeroCreate (max need (if isNull c.In then 4096 else c.In.Length * 2))
                if c.InLen > 0 then Buffer.BlockCopy(c.In, 0, nb, 0, c.InLen)
                c.In <- nb
            data.CopyTo(Span(c.In, c.InLen, n))
            c.InLen <- need
            if c.Open && not c.Busy && isNull c.Out then dispatch fd

    let onWritable (fd: int) =
        let c = conns.[fd]
        if c.Open && not (isNull c.Out) then
            let data = c.Out
            c.Out <- null
            Sys.ctl ep Sys.EPOLL_CTL_MOD fd (Sys.EPOLLIN ||| Sys.EPOLLRDHUP) (epTag fd c) |> ignore
            if sendBytes fd c data c.OutOff then
                if c.CloseAfter then closeFd fd
                elif c.InLen > 0 then dispatch fd

    /// a new connection: fresh state, watched for input
    let openConn (fd: int) =
        if fd >= conns.Length then
            Sys.close fd |> ignore
        else
            openCount <- openCount + 1
            if openCount > fdBudget then evictOne () |> ignore
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
            if not useRing then Sys.ctl ep Sys.EPOLL_CTL_ADD fd (Sys.EPOLLIN ||| Sys.EPOLLRDHUP) (epTag fd c) |> ignore
            lruAdd fd
            if useRing && Sys.ur_recv (ring, fd, ud KRecv (gen28 c.Gen) fd) < 0 then closeFd fd

    /// at the fd limit: close the connection idle the longest, or, with none idle, free the spare fd, take the
    /// newcomer and close it at once, so the listener doesn't stay readable (a loop spinning on accept)
    let atFdLimit () =
        if evictOne () then true
        elif spareFd >= 0 then
            Sys.close spareFd |> ignore
            let x = Sys.accept4 (listenFd, 0n, 0n, Sys.SOCK_CLOEXEC)
            if x >= 0 then Sys.close x |> ignore
            spareFd <- Sys.openDevNull ()
            false
        else false

    let accept () =
        let mutable go = true
        while go do
            let fd = Sys.accept4 (listenFd, 0n, 0n, Sys.SOCK_NONBLOCK ||| Sys.SOCK_CLOEXEC)
            if fd >= 0 then openConn fd
            else
                let e = Sys.errno ()
                if e = Sys.EMFILE || e = Sys.ENFILE then go <- atFdLimit ()
                else go <- false

    let drainInbox () =
        let mutable item = Unchecked.defaultof<struct (int * int * byte[])>
        while inbox.TryDequeue(&item) do
            let struct (fd, gen, data) = item
            try
                deliver fd gen data
            with ex ->
                eprintfn "io: deliver fd %d: %s" fd ex.Message
                closeFd fd

    let armRecv (fd: int) (g: int) =
        if Sys.ur_recv (ring, fd, ud KRecv g fd) < 0 then closeFd fd

    let live (fd: int) (g: int) =
        let c = conns.[fd]
        not (isNull c) && c.Open && gen28 c.Gen = g

    /// one io_uring completion
    let complete (cq: Sys.UrCqe) =
        let kind = cq.Ud >>> 60
        let fd = int (uint32 cq.Ud)
        let mid = int ((cq.Ud >>> 32) &&& 0xFFFFFFFUL)
        let more = cq.Flags &&& 2u <> 0u // IORING_CQE_F_MORE: a multishot request stays armed
        if kind = KRecv then
            let hasBuf = cq.Flags &&& 1u <> 0u // IORING_CQE_F_BUFFER
            let bid = int (cq.Flags >>> 16)
            if live fd mid then
                let c = conns.[fd]
                if cq.Res > 0 then
                    try
                        onData fd (NativePtr.add (NativePtr.ofNativeInt<byte> pool) (bid * uringBufLen)) cq.Res
                    with ex ->
                        eprintfn "io: fd %d: %s" fd ex.Message
                        closeFd fd
                    if hasBuf then Sys.ur_buf_return (ring, bid)
                    if not more && c.Open then armRecv fd mid
                else
                    if hasBuf then Sys.ur_buf_return (ring, bid)
                    if cq.Res = -Sys.ENOBUFS then (if not more then starved.Add fd)
                    elif cq.Res = -Sys.EINVAL && Sys.ur_ms_recv ring <> 0 then
                        Sys.ur_no_ms_recv ring // kernel without multishot recv: one-shot from now on
                        armRecv fd mid
                    elif cq.Res = -Sys.EINTR || cq.Res = -Sys.EAGAIN then
                        if not more then armRecv fd mid
                    else closeFd fd // 0: the client closed; other errors: drop the connection
            elif hasBuf then Sys.ur_buf_return (ring, bid)
        elif kind = KSend then
            let slot = mid
            let data = slotData.[slot]
            let sfd = slotFd.[slot]
            let g = slotGen.[slot]
            let c = conns.[sfd]
            let alive = not (isNull c) && c.Open && c.Gen = g
            if alive && cq.Res > 0 && slotOff.[slot] + cq.Res < data.Length then
                slotOff.[slot] <- slotOff.[slot] + cq.Res // partial send: the rest, from the same pinned reply
                if submitSend slot < 0 then
                    slotPin.[slot].Free()
                    slotData.[slot] <- null
                    freeSlots.Push slot
                    closeFd sfd
            else
                slotPin.[slot].Free()
                slotData.[slot] <- null
                freeSlots.Push slot
                if alive then
                    if cq.Res < 0 then closeFd sfd
                    else
                        c.Out <- null
                        if c.CloseAfter then closeFd sfd
                        else dispatch sfd // serves a pipelined request if one is buffered, else back to idle
        elif kind = KAccept then
            if cq.Res >= 0 then openConn cq.Res
            elif cq.Res = -Sys.EINVAL && Sys.ur_ms_accept ring <> 0 then Sys.ur_no_ms_accept ring
            elif cq.Res = -Sys.EMFILE || cq.Res = -Sys.ENFILE then atFdLimit () |> ignore
            if not more then Sys.ur_accept (ring, listenFd, ud KAccept 0 0) |> ignore
        elif kind = KWake then
            Volatile.Write(&wakePending, 0)
            drainInbox ()
            Sys.ur_read_efd (ring, efd, ud KWake 0 0) |> ignore
        elif cq.Res < 0 then
            eprintfn "io: ring completion %x failed: %d" cq.Ud cq.Res // handing buffers back (classic mode)

    /// the io_uring loop; false if this kernel can't give us a ring (the caller then runs epoll)
    let runRing () =
        let mutable info = 0
        let mutable err = 0
        ring <- Sys.ur_open (4096u, 65536u, uint32 uringBufs, uint32 uringBufLen, (if uringClassic then 1 else 0), &info, &err)
        if ring = 0n then
            eprintfn "io-%d: io_uring unavailable (errno %d), using epoll" index err
            false
        else
            useRing <- true
            pool <- Sys.ur_pool ring
            if index = 0 then
                eprintfn "io_uring: %s receive buffers%s, %s"
                    (if info &&& 1 <> 0 then "buffer ring of" else "classic provided")
                    (if info &&& 2 <> 0 then " (registered with the 6.8 reserved-byte workaround)" else "")
                    (if info &&& 4 <> 0 then "single issuer, deferred task work"
                     elif info &&& 8 <> 0 then "single issuer, cooperative task work"
                     elif info &&& 16 <> 0 then "cooperative task work"
                     else "default task work")
            Sys.ur_accept (ring, listenFd, ud KAccept 0 0) |> ignore
            Sys.ur_read_efd (ring, efd, ud KWake 0 0) |> ignore
            let cqes = NativePtr.stackalloc<Sys.UrCqe> 1024
            while true do
                let n = Sys.ur_wait (ring, cqes, 1024)
                if n < 0 && n <> -Sys.EINTR then
                    eprintfn "io-%d: io_uring_enter failed: %d" index n
                    Thread.Sleep 1
                for i in 0 .. n - 1 do
                    let cq = NativePtr.get cqes i
                    try
                        complete cq
                    with ex ->
                        eprintfn "io: completion %x: %s" cq.Ud ex.Message
                        let fd = int (uint32 cq.Ud)
                        if cq.Ud >>> 60 = KRecv && fd < conns.Length && not (isNull conns.[fd]) then closeFd fd
                // connections whose recv found no buffer: buffers were handed back above, so arm them again
                if starved.Count > 0 then
                    for fd in starved do
                        let c = conns.[fd]
                        if not (isNull c) && c.Open then armRecv fd (gen28 c.Gen)
                    starved.Clear()
            true

    do dispatchRef <- dispatch

    member _.Index = index

    /// from any thread: a stale answer only means a job is done for nobody, or skipped a moment after its client left
    member _.Alive(fd: int, gen: int) =
        let c = conns.[fd]
        not (isNull c) && c.Open && c.Gen = gen

    /// called from any thread
    member _.Post(fd: int, gen: int, data: byte[]) =
        inbox.Enqueue(struct (fd, gen, data))
        if Interlocked.Exchange(&wakePending, 1) = 0 then
            let one = NativePtr.stackalloc<uint64> 1
            NativePtr.write one 1UL
            Sys.write (efd, NativePtr.ofNativeInt (NativePtr.toNativeInt one), 8un) |> ignore

    member _.Run() =
        // the copy keeps every fd opened so far under the same number (this loop's listener and eventfd, the runtime's);
        // what this thread opens from here on, and closes, stays in its own table
        if ownFdTables && Sys.unshare Sys.CLONE_FILES = 0 then fdBudget <- tableSize - 16 - 256
        if not (uring && runRing ()) then
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
                        drainInbox ()
                    else
                        let fd = int (uint32 ev.Data)
                        let c = conns.[fd]
                        if c.Open && (c.Gen &&& 0x7FFFFFFF) = int (ev.Data >>> 32) then
                            try
                                if ev.Events &&& Sys.EPOLLOUT <> 0u then onWritable fd
                                if ev.Events &&& (Sys.EPOLLIN ||| Sys.EPOLLHUP ||| Sys.EPOLLERR ||| Sys.EPOLLRDHUP) <> 0u then
                                    onReadable fd
                            with ex ->
                                // one connection's failure closes that connection, never the loop
                                eprintfn "io: fd %d: %s" fd ex.Message
                                closeFd fd

let mutable private loops: Loop[] = [||]

/// Whether the client of a queued request is still connected
let alive (d: Dest) = loops.[d.Loop].Alive(d.Fd, d.Gen)

/// Answers a request that went asynchronous. Safe from any thread.
let post (d: Dest) (data: byte[]) = loops.[d.Loop].Post(d.Fd, d.Gen, data)

/// Starts `count` I/O threads on host:port. reserve: fds kept free for Postgres, files and the runtime.
let start (host: string) (port: int) (count: int) (reserve: int) (nice: int) =
    let limit = Sys.raiseNoFile ()
    // Files a loop thread opened and kept would be invisible to every other thread. So nothing that keeps one may be
    // opened there for the first time: stderr's stream and the assemblies are opened now.
    Console.Error.Flush()
    let seen = HashSet<string>()
    let rec load (a: Reflection.Assembly) =
        for n in a.GetReferencedAssemblies() do
            if seen.Add n.FullName then
                try load (Reflection.Assembly.Load n) with _ -> ()
    load (Reflection.Assembly.GetEntryAssembly())
    loops <- Array.init count (fun i -> Loop(i, Sys.listenTcp host port, limit + 16, max 64 ((limit - reserve) / count)))
    for l in loops do
        Thread((fun () ->
                    Sys.schedThread ()
                    Sys.niceThread nice
                    l.Run()),
               IsBackground = true,
               Name = sprintf "io-%d" l.Index)
            .Start()
    limit
