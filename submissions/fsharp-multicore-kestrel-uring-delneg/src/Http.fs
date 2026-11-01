/// The I/O loops (from our twelve-dollar entry's Uring.fs, made multicore): N threads, each with its own io_uring
/// ring and its own SO_REUSEPORT listening socket. Per loop:
/// - multishot accept straight into the ring's fixed-file table (IORING_FILE_INDEX_ALLOC): client sockets never
///   get a process fd, so they do not count against LimitNOFILE;
/// - one multishot recv per socket into provided buffers (kernel 6.8.0-147 refuses buffer rings with EINVAL, so the
///   classic IORING_OP_PROVIDE_BUFFERS path is the main one); a request is parsed in place and the buffer goes back;
/// - one request at a time per connection (pipelined bytes wait in the connection's buffer), as #22;
/// - the response is sent from the request's own pinned buffer; the Postgres thread hands finished requests back
///   through the loop's mailbox (an eventfd read in the ring).
module Http

#nowarn "9"

open System
open System.Buffers
open System.Buffers.Text
open System.Collections.Generic
open System.Net
open System.Net.Sockets
open System.Runtime.InteropServices
open System.Threading
open System.Threading.Tasks
open Microsoft.AspNetCore.Connections
open Microsoft.FSharp.NativeInterop
open Ring
open Ctx

// user_data: op (3 bits) | slot (20) | gen (23) | extra (18: the request's id in the loop's pool)
[<Literal>]
let private OpAccept = 1UL
[<Literal>]
let private OpRecv = 2UL
[<Literal>]
let private OpSend = 3UL
[<Literal>]
let private OpEvent = 4UL
[<Literal>]
let private OpIgnore = 5UL

let inline private ud (op: uint64) (slot: int) (gen: uint32) (extra: int) =
    op ||| (uint64 slot <<< 3) ||| (uint64 (gen &&& 0x7FFFFFu) <<< 23) ||| (uint64 extra <<< 46)

let inline private udSlot (u: uint64) = int ((u >>> 3) &&& 0xFFFFFUL)
let inline private udGen (u: uint64) = uint32 ((u >>> 23) &&& 0x7FFFFFUL)
let inline private udExtra (u: uint64) = int (u >>> 46)

// slot state bits
let private Live = 1uy
let private Recving = 2uy
let private Busy = 4uy // a request of this connection is being served
let private Closing = 8uy
let private ContinueSent = 16uy

let private NBufs =
    let n = envInt "MC_NBUFS" 8192
    if n > 0 && n &&& (n - 1) = 0 && n <= 32768 then n else 8192
let private BufSize = 2048
let private BufGroup = 0us
/// io_uring_enter waits for this many completions (with the timeout below; 1 = no timeout needed)
let private WaitN = uint32 (max 1 (envInt "MC_WAIT_N" 1))
let private WaitNs = int64 (envInt "MC_WAIT_US" 0) * 1000L
let private MaxRequest = (1 <<< 20) + 64 * 1024

/// The process's fd limit: a ring's fixed-file table can be at most this big.
let private FdLimit =
    let lim = Array.zeroCreate<uint64> 2
    let soft = if Native.getrlimit (7, lim) = 0 then lim.[0] else 65535UL
    int (min soft (1UL <<< 20))

let private bCrlf2 = "\r\n\r\n"B
let private bCrlf = "\r\n"B
let private bHttp10 = "HTTP/1.0"B
let private hContentLength = "content-length"B
let private hAuthorization = "authorization"B
let private hConnection = "connection"B
let private hTransferEncoding = "transfer-encoding"B
let private hExpect = "expect"B
let private vClose = "close"B
let private vKeepAlive = "keep-alive"B
let private continue100 = GC.AllocateArray<byte>(25, pinned = true)
do "HTTP/1.1 100 Continue\r\n\r\n"B.CopyTo(continue100, 0)

let private isName (name: ReadOnlySpan<byte>) (lower: byte[]) =
    if name.Length <> lower.Length then false
    else
        let mutable ok = true
        let mutable i = 0
        while ok && i < name.Length do
            let mutable b = name.[i]
            if b >= 'A'B && b <= 'Z'B then b <- b + 32uy
            if b <> lower.[i] then ok <- false
            i <- i + 1
        ok

let private contains (value: ReadOnlySpan<byte>) (lower: byte[]) =
    let mutable found = false
    let mutable i = 0
    while not found && i + lower.Length <= value.Length do
        if isName (value.Slice(i, lower.Length)) lower then found <- true
        i <- i + 1
    found

[<Sealed>]
type Loop(index: int, listenFd: int) as this =
    inherit Owner()
    /// created on the loop's thread: SINGLE_ISSUER makes the creating thread the only one that may enter it
    let mutable ring: Ring = null
    let slots = FdLimit
    let gen = Array.zeroCreate<uint32> slots
    let state = Array.zeroCreate<byte> slots
    let inBuf = Array.zeroCreate<byte[]> slots
    let inLen = Array.zeroCreate<int> slots
    let mailbox = Mailbox<Ctx>()
    let pool = Stack<Ctx>()
    let ctxs = List<Ctx>()
    let cqes = List<Cqe>(8192)
    let rearm = Queue<struct (int * uint32)>()
    let returned = List<int>()
    let mutable openCount = 0
    let mutable accepting = false
    let mutable threadId = -1
    let ready = new ManualResetEventSlim(false)
    let mutable initError: exn = null
    let stats = not (isNull (Environment.GetEnvironmentVariable "MC_STATS"))
    let mutable stPasses = 0L
    let mutable stCqes = 0L
    let mutable stNoBufs = 0L
    let mutable stLast = Environment.TickCount64

    // receive buffers
    let bufMem =
        let m = Native.mmap (0n, unativeint (NBufs * BufSize), 3, 0x2 ||| 0x20, -1, 0L)
        if m = -1n then raise (OutOfMemoryException "receive buffers")
        m

    do
        let t = Thread((fun () -> this.Run()), 1024 * 1024, IsBackground = true, Name = "io-" + string index)
        t.Start()
        ready.Wait()
        if not (isNull initError) then raise initError

    member _.Open = openCount

    member private _.Buffer(bid: int) = bufMem + nativeint (bid * BufSize)

    /// classic provided buffers: one PROVIDE_BUFFERS per run of consecutive ids given back in this pass
    member private _.PublishBuffers() =
        if returned.Count > 0 then
            returned.Sort()
            let mutable i = 0
            while i < returned.Count do
                let first = returned.[i]
                let mutable n = 1
                while i + n < returned.Count && returned.[i + n] = first + n do
                    n <- n + 1
                ring.Provide(BufGroup, first, n, bufMem + nativeint (first * BufSize), BufSize, OpIgnore)
                i <- i + n
            returned.Clear()

    member private _.Rent() =
        let c =
            if pool.Count > 0 then pool.Pop()
            elif ctxs.Count >= (1 <<< 18) then raise (InvalidOperationException "too many requests in flight")
            else
                let c = Ctx(this, ctxs.Count)
                ctxs.Add c
                c
        c.InUse <- true
        c

    member private _.Return(c: Ctx) =
        c.InUse <- false
        c.Reset()
        pool.Push c

    member private _.Recv(slot: int) =
        ring.RecvMulti(slot, BufGroup, ud OpRecv slot gen.[slot] 0)
        state.[slot] <- state.[slot] ||| Recving

    /// Ends a connection: frees its buffer and queues SHUTDOWN + CLOSE. The generation changes, so completions still
    /// in flight for it are recognised as stale; a request of it still being served is dropped when it comes back.
    member private _.CloseSlot(slot: int) =
        let st = state.[slot]
        if st &&& Live <> 0uy then
            let b = inBuf.[slot]
            if not (isNull b) then
                ArrayPool<byte>.Shared.Return b
                inBuf.[slot] <- null
            inLen.[slot] <- 0
            state.[slot] <- Closing
            gen.[slot] <- (gen.[slot] + 1u) &&& 0x7FFFFFu
            openCount <- openCount - 1
            ring.ShutdownClose(slot, OpIgnore)

    member private this.OnAccept(res: int, flags: uint32) =
        if flags &&& CQE_F_MORE = 0u then accepting <- false
        if res >= 0 then
            let slot = res
            state.[slot] <- Live
            openCount <- openCount + 1
            this.Recv slot

    /// a response that the loop itself makes (errors before a request starts)
    member private this.Reject(slot: int, status: int) =
        let c = this.Rent()
        c.Slot <- slot
        c.Gen <- gen.[slot]
        c.CloseAfter <- true
        state.[slot] <- state.[slot] ||| Busy
        c.Error(status, (if status = 413 then "body too large" else "bad request"))
        c.Finish()

    /// Parses one request from the connection's bytes and starts it. Returns the bytes it used (0: need more).
    member private this.TryServe(slot: int, data: ReadOnlySpan<byte>) : int =
        let headEnd = data.IndexOf(ReadOnlySpan bCrlf2)
        if headEnd < 0 then
            if data.Length >= 64 * 1024 then
                this.Reject(slot, 431)
                data.Length
            else 0
        else
            let head = data.Slice(0, headEnd)
            let lineEnd = head.IndexOf(ReadOnlySpan bCrlf)
            let line = if lineEnd < 0 then head else head.Slice(0, lineEnd)
            let sp1 = line.IndexOf ' 'B
            let sp2 = if sp1 < 0 then -1 else line.Slice(sp1 + 1).IndexOf ' 'B
            if sp1 <= 0 || sp2 <= 0 then
                this.Reject(slot, 400)
                data.Length
            else
                let meth = line.Slice(0, sp1)
                let target = line.Slice(sp1 + 1, sp2)
                let version = line.Slice(sp1 + 2 + sp2)
                let http10 = version.SequenceEqual(ReadOnlySpan bHttp10)
                let mutable contentLength = 0L
                let mutable closeReq = http10
                let mutable keepAlive = false
                let mutable chunked = false
                let mutable expect = false
                let mutable bad = false
                let mutable auth = ReadOnlySpan<byte>.Empty
                let mutable hasAuth = false
                let mutable rest = if lineEnd < 0 then ReadOnlySpan<byte>.Empty else head.Slice(lineEnd + 2)
                while rest.Length > 0 do
                    let e = rest.IndexOf(ReadOnlySpan bCrlf)
                    let h = if e < 0 then rest else rest.Slice(0, e)
                    rest <- if e < 0 then ReadOnlySpan<byte>.Empty else rest.Slice(e + 2)
                    let colon = h.IndexOf ':'B
                    if colon > 0 then
                        let name = h.Slice(0, colon)
                        let value = h.Slice(colon + 1).Trim(' 'B).Trim('\t'B)
                        match name.Length with
                        | 14 when isName name hContentLength ->
                            let mutable used = 0
                            if not (Utf8Parser.TryParse(value, &contentLength, &used)) || used <> value.Length || contentLength < 0L then
                                bad <- true
                        | 13 when isName name hAuthorization ->
                            auth <- value
                            hasAuth <- true
                        | 10 when isName name hConnection ->
                            if contains value vClose then closeReq <- true
                            elif contains value vKeepAlive then keepAlive <- true
                        | 17 when isName name hTransferEncoding -> chunked <- true
                        | 6 when isName name hExpect -> expect <- true
                        | _ -> ()
                if bad then
                    this.Reject(slot, 400)
                    data.Length
                elif chunked then
                    this.Reject(slot, 411)
                    data.Length
                elif contentLength > int64 (1 <<< 20) then
                    this.Reject(slot, 413)
                    data.Length
                else
                    let total = headEnd + 4 + int contentLength
                    if data.Length < total then
                        if expect && state.[slot] &&& ContinueSent = 0uy then
                            state.[slot] <- state.[slot] ||| ContinueSent
                            ring.Send(slot, true, Marshal.UnsafeAddrOfPinnedArrayElement(continue100, 0), continue100.Length,
                                      MSG_NOSIGNAL, OpIgnore)
                        0
                    else
                        state.[slot] <- (state.[slot] &&& ~~~ContinueSent) ||| Busy
                        let q = target.IndexOf '?'B
                        let path = if q < 0 then target else target.Slice(0, q)
                        let query = if q < 0 then ReadOnlySpan<byte>.Empty else target.Slice(q + 1)
                        let c = this.Rent()
                        c.Slot <- slot
                        c.Gen <- gen.[slot]
                        c.CloseAfter <- closeReq && not (http10 && keepAlive)
                        Handlers.start c meth path query hasAuth auth (data.Slice(headEnd + 4, int contentLength))
                        total

    /// keeps bytes not used yet in the connection's own buffer
    member private _.Keep(slot: int, data: ReadOnlySpan<byte>) =
        let il = inLen.[slot]
        let mutable b = inBuf.[slot]
        if isNull b || b.Length - il < data.Length then
            let bigger = ArrayPool<byte>.Shared.Rent(max 4096 (il + data.Length))
            if not (isNull b) then
                Buffer.BlockCopy(b, 0, bigger, 0, il)
                ArrayPool<byte>.Shared.Return b
            b <- bigger
            inBuf.[slot] <- b
        data.CopyTo(Span<byte>(b, il, data.Length))
        inLen.[slot] <- il + data.Length

    /// serves the next request waiting in the connection's own buffer, if complete
    member private this.ServeBuffered(slot: int) =
        let il = inLen.[slot]
        if il > 0 && state.[slot] &&& (Live ||| Busy ||| Closing) = Live then
            let b = inBuf.[slot]
            let used = this.TryServe(slot, ReadOnlySpan<byte>(b, 0, il))
            if state.[slot] &&& Live <> 0uy && inBuf.[slot] = b then
                if used >= il then
                    ArrayPool<byte>.Shared.Return b
                    inBuf.[slot] <- null
                    inLen.[slot] <- 0
                elif used > 0 then
                    Buffer.BlockCopy(b, used, b, 0, il - used)
                    inLen.[slot] <- il - used

    member private this.OnData(slot: int, src: nativeint, n: int) =
        let data = ReadOnlySpan<byte>(NativePtr.toVoidPtr (NativePtr.ofNativeInt<byte> src), n)
        if state.[slot] &&& Busy <> 0uy || inLen.[slot] > 0 then
            if inLen.[slot] + n > MaxRequest then this.CloseSlot slot
            else
                this.Keep(slot, data)
                this.ServeBuffered slot
        else
            let used = this.TryServe(slot, data)
            if used < n && state.[slot] &&& Live <> 0uy then this.Keep(slot, data.Slice used)

    member private this.OnRecv(u: uint64, res: int, flags: uint32) =
        let slot = udSlot u
        let valid = state.[slot] &&& Live <> 0uy && gen.[slot] = udGen u
        if valid then
            if flags &&& CQE_F_MORE = 0u then state.[slot] <- state.[slot] &&& ~~~Recving
            if res > 0 then
                (try this.OnData(slot, this.Buffer(int (flags >>> 16)), res)
                 with e ->
                     eprintfn "%O" e
                     this.CloseSlot slot)
                if state.[slot] &&& (Live ||| Recving) = Live then this.Recv slot
            elif res = -ENOBUFS then
                stNoBufs <- stNoBufs + 1L
                if state.[slot] &&& Recving = 0uy then rearm.Enqueue(struct (slot, gen.[slot]))
            else this.CloseSlot slot
        if flags &&& CQE_F_BUFFER <> 0u then returned.Add(int (flags >>> 16))

    /// queues the send of a finished response (loop thread)
    member private this.SendNow(c: Ctx) =
        let slot = c.Slot
        if state.[slot] &&& Live = 0uy || gen.[slot] <> c.Gen then this.Return c
        else
            ring.Send(slot, true, c.Out.Address c.SentOff, c.Out.ResponseLength - c.SentOff, MSG_NOSIGNAL, ud OpSend slot c.Gen c.Id)

    member private this.OnSend(u: uint64, res: int) =
        let c = ctxs.[udExtra u]
        let slot = udSlot u
        let valid = state.[slot] &&& Live <> 0uy && gen.[slot] = udGen u
        if not valid then this.Return c
        elif res = -EAGAIN || res = -EINTR then this.SendNow c
        elif res <= 0 then
            this.Return c
            this.CloseSlot slot
        elif c.SentOff + res < c.Out.ResponseLength then
            c.SentOff <- c.SentOff + res
            this.SendNow c
        else
            let close = c.CloseAfter
            this.Return c
            state.[slot] <- state.[slot] &&& ~~~Busy
            if close then this.CloseSlot slot else this.ServeBuffered slot

    override this.Send(c) =
        if Thread.CurrentThread.ManagedThreadId = threadId then this.SendNow c else mailbox.Post c

    override _.Gone(c) = gen.[c.Slot] <> c.Gen || state.[c.Slot] &&& Live = 0uy

    member private this.Handle(e: Cqe) =
        match e.U &&& 7UL with
        | OpAccept -> this.OnAccept(e.Res, e.Flags)
        | OpRecv -> this.OnRecv(e.U, e.Res, e.Flags)
        | OpSend -> this.OnSend(e.U, e.Res)
        | OpEvent ->
            mailbox.Rearmed()
            ring.Read(mailbox.Fd, mailbox.Sink, 8, OpEvent)
        | _ -> ()

    member private this.Run() =
        try
            try
                threadId <- Thread.CurrentThread.ManagedThreadId
                ring <- Ring(4096u, 16384u)
                // fixed-file table, sparse
                let reg = Marshal.AllocHGlobal 32
                NativeMemory.Clear(NativePtr.toVoidPtr (NativePtr.ofNativeInt<byte> reg), unativeint 32)
                wr32 reg (uint32 slots)
                wr32 (reg + 4n) 1u // IORING_RSRC_REGISTER_SPARSE
                try ring.Register(REGISTER_FILES2, reg, 32L) finally Marshal.FreeHGlobal reg
                ring.Provide(BufGroup, 0, NBufs, bufMem, BufSize, OpIgnore)
                ring.AcceptMulti(listenFd, OpAccept)
                accepting <- true
                ring.Read(mailbox.Fd, mailbox.Sink, 8, OpEvent)
                ring.Submit() |> ignore
            with e -> initError <- e
        finally
            ready.Set()
        if isNull initError then
            while true do
                ring.Enter(WaitN, WaitNs) |> ignore
                cqes.Clear()
                ring.Reap(cqes, Int32.MaxValue) |> ignore
                for i in 0 .. cqes.Count - 1 do
                    try this.Handle cqes.[i] with e -> eprintfn "%O" e
                // responses finished on the Postgres thread
                let mutable c: Ctx = null
                while mailbox.TryTake(&c) do
                    try this.SendNow c with e -> eprintfn "%O" e
                let back = returned.Count
                this.PublishBuffers()
                // receives that found no buffer: re-arm as many as buffers came back
                let mutable budget = min rearm.Count (max back 32)
                while budget > 0 do
                    let struct (slot, g) = rearm.Dequeue()
                    if gen.[slot] = g && state.[slot] &&& (Live ||| Recving) = Live then this.Recv slot
                    budget <- budget - 1
                if not accepting then
                    ring.AcceptMulti(listenFd, OpAccept)
                    accepting <- true
                if stats then
                    stPasses <- stPasses + 1L
                    stCqes <- stCqes + int64 cqes.Count
                    if Environment.TickCount64 - stLast > 5000L then
                        stLast <- Environment.TickCount64
                        eprintfn "io-%d passes=%d cqes=%d nobufs=%d open=%d ctxs=%d gc=%d/%d/%d" index stPasses stCqes stNoBufs openCount
                            ctxs.Count (GC.CollectionCount 0) (GC.CollectionCount 1) (GC.CollectionCount 2)
                        stPasses <- 0L
                        stCqes <- 0L
                        stNoBufs <- 0L

// ---------- Kestrel transport ----------

let private AF_INET = 2
let private SOCK_STREAM = 1
let private SOCK_CLOEXEC = 0x80000
let private SOL_SOCKET = 1
let private SO_REUSEADDR = 2
let private SO_REUSEPORT = 15
let private IPPROTO_TCP = 6
let private TCP_NODELAY = 1

/// a listening socket of its own for each loop (SO_REUSEPORT: the kernel spreads new connections over them)
let private listenSocket (ip: IPEndPoint) =
    let fd = Native.socket (AF_INET, SOCK_STREAM ||| SOCK_CLOEXEC, 0)
    if fd < 0 then failwithf "socket: errno %d" (Native.errno ())
    let mutable one = 1
    Native.setsockopt (fd, SOL_SOCKET, SO_REUSEADDR, &one, 4) |> ignore
    Native.setsockopt (fd, SOL_SOCKET, SO_REUSEPORT, &one, 4) |> ignore
    // accepted sockets inherit TCP_NODELAY (a fixed file has no fd for setsockopt)
    Native.setsockopt (fd, IPPROTO_TCP, TCP_NODELAY, &one, 4) |> ignore
    let addr = Array.zeroCreate<byte> 16
    addr.[0] <- byte AF_INET
    addr.[2] <- byte (ip.Port >>> 8)
    addr.[3] <- byte ip.Port
    ip.Address.GetAddressBytes().CopyTo(addr, 4)
    let rc =
        use p = fixed addr
        Native.bind (fd, NativePtr.toNativeInt p, 16)
    if rc <> 0 then raise (IO.IOException(sprintf "Failed to bind to address %O: errno %d" ip (Native.errno ())))
    if Native.listen (fd, 65535) <> 0 then failwithf "listen: errno %d" (Native.errno ())
    fd

/// The loops own every connection from accept to close; Kestrel's accept loop just waits here until shutdown.
type private Listener(endpoint: EndPoint) =
    let never = TaskCompletionSource<ConnectionContext>(TaskCreationOptions.RunContinuationsAsynchronously)
    interface IConnectionListener with
        member _.EndPoint = endpoint
        member _.AcceptAsync(_) = ValueTask<ConnectionContext>(never.Task)
        member _.UnbindAsync(_) =
            never.TrySetResult null |> ignore
            ValueTask.CompletedTask
        member _.DisposeAsync() =
            never.TrySetResult null |> ignore
            ValueTask.CompletedTask

let mutable loopCount = 2
let loops = List<Loop>()

/// Kestrel's IConnectionListenerFactory: starts the io_uring loops on the endpoint.
type UringTransportFactory() =
    interface IConnectionListenerFactory with
        member _.BindAsync(endpoint, _) =
            let ip =
                match endpoint with
                | :? IPEndPoint as ip when ip.AddressFamily = AddressFamily.InterNetwork -> ip
                | _ -> raise (NotSupportedException "io_uring transport: IPv4 endpoints only")
            for i in 0 .. loopCount - 1 do
                loops.Add(Loop(i, listenSocket ip))
            ValueTask<IConnectionListener>(Listener(ip))
