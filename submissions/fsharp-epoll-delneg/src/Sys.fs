/// The few libc calls the server makes itself: epoll, sockets, eventfd, thread priority.
module Sys

#nowarn "9"

open System
open System.Runtime.InteropServices

[<Literal>]
let private C = "libc.so.6"

[<Struct; StructLayout(LayoutKind.Sequential, Pack = 1)>]
type EpollEvent =
    val mutable Events: uint32
    val mutable Data: uint64

[<DllImport(C, SetLastError = true)>]
extern int epoll_create1(int flags)

[<DllImport(C, SetLastError = true)>]
extern int epoll_ctl(int epfd, int op, int fd, EpollEvent& ev)

[<DllImport(C, SetLastError = true)>]
extern int epoll_wait(int epfd, EpollEvent* events, int maxevents, int timeout)

[<DllImport(C, SetLastError = true)>]
extern nativeint read(int fd, byte* buf, unativeint count)

[<DllImport(C, SetLastError = true)>]
extern nativeint write(int fd, byte* buf, unativeint count)

[<DllImport(C, SetLastError = true)>]
extern int close(int fd)

[<DllImport(C, SetLastError = true, EntryPoint = "open")>]
extern int private open_(string path, int flags)

/// a spare descriptor, given up when accept hits the fd limit
let openDevNull () = open_ ("/dev/null", 0x80000)

/// sockets use recv/send rather than read/write: they skip the VFS layer (file position lock, LSM file check)
[<DllImport(C, SetLastError = true)>]
extern nativeint recv(int fd, byte* buf, unativeint count, int flags)

[<DllImport(C, SetLastError = true)>]
extern nativeint send(int fd, byte* buf, unativeint count, int flags)

[<Literal>]
let MSG_NOSIGNAL = 0x4000

[<DllImport(C, SetLastError = true)>]
extern int socket(int domain, int typ, int protocol)

[<DllImport(C, SetLastError = true, EntryPoint = "setsockopt")>]
extern int private setsockopt_(int fd, int level, int name, int* value, int len)

[<DllImport(C, SetLastError = true)>]
extern int bind(int fd, byte* addr, int len)

[<DllImport(C, SetLastError = true)>]
extern int listen(int fd, int backlog)

[<DllImport(C, SetLastError = true)>]
extern int accept4(int fd, nativeint addr, nativeint len, int flags)

[<DllImport(C, SetLastError = true)>]
extern int eventfd(uint32 initval, int flags)

[<DllImport(C, SetLastError = true)>]
extern int getrlimit(int resource, uint64* rlim)

[<DllImport(C, SetLastError = true)>]
extern int setrlimit(int resource, uint64* rlim)

[<DllImport(C, SetLastError = true)>]
extern int setpriority(int which, int who, int prio)

[<DllImport(C, SetLastError = true)>]
extern int64 syscall(int64 n)

/// sleeps the calling thread for microseconds (Thread.Sleep rounds down to whole milliseconds: 0 is a yield)
[<DllImport(C)>]
extern int usleep(uint32 usec)

[<DllImport(C, SetLastError = true, EntryPoint = "sched_setscheduler")>]
extern int private sched_setscheduler_(int pid, int policy, int* param)

let errno () = Marshal.GetLastPInvokeError()

/// setsockopt with an int value
let setsockopt (fd: int, level: int, name: int, value: int) =
    let p = NativeInterop.NativePtr.stackalloc<int> 1
    NativeInterop.NativePtr.write p value
    setsockopt_ (fd, level, name, p, 4)

[<Literal>]
let EPOLLIN = 0x001u
[<Literal>]
let EPOLLOUT = 0x004u
[<Literal>]
let EPOLLERR = 0x008u
[<Literal>]
let EPOLLHUP = 0x010u
[<Literal>]
let EPOLLRDHUP = 0x2000u
[<Literal>]
let EPOLLET = 0x80000000u

[<Literal>]
let EPOLL_CTL_ADD = 1
[<Literal>]
let EPOLL_CTL_DEL = 2
[<Literal>]
let EPOLL_CTL_MOD = 3

[<Literal>]
let EAGAIN = 11
[<Literal>]
let EINTR = 4
[<Literal>]
let EMFILE = 24
[<Literal>]
let ENFILE = 23

[<Literal>]
let SOCK_NONBLOCK = 0x800
[<Literal>]
let SOCK_CLOEXEC = 0x80000

/// the calling thread's id (gettid), for setpriority on one thread
let tid () = int (syscall 186L)

/// lowers (or raises, if allowed) the calling thread's nice value
let niceThread (n: int) = setpriority (0, tid (), n) |> ignore

[<Literal>]
let SCHED_OTHER = 0
[<Literal>]
let SCHED_BATCH = 3

/// The calling thread's scheduling policy. SCHED_BATCH keeps its CPU share but doesn't preempt a running task
/// (a Postgres backend mid-query) when it wakes. Call before niceThread: the nice value is set after.
let mutable threadPolicy = SCHED_BATCH

let schedThread () =
    let policy = threadPolicy
    let p = NativeInterop.NativePtr.stackalloc<int> 1
    NativeInterop.NativePtr.write p 0
    sched_setscheduler_ (0, policy, p) |> ignore

let ctl (ep: int) (op: int) (fd: int) (events: uint32) (data: uint64) =
    let mutable ev = EpollEvent()
    ev.Events <- events
    ev.Data <- data
    epoll_ctl (ep, op, fd, &ev)

/// A non-blocking IPv4 TCP listener on host:port with SO_REUSEPORT, so each I/O thread can have its own.
let listenTcp (host: string) (port: int) : int =
    let fd = socket (2, 1 ||| SOCK_NONBLOCK ||| SOCK_CLOEXEC, 0)
    if fd < 0 then failwithf "socket: errno %d" (errno ())
    if setsockopt (fd, 1, 2, 1) <> 0 then failwithf "SO_REUSEADDR: errno %d" (errno ())
    if setsockopt (fd, 1, 15, 1) <> 0 then failwithf "SO_REUSEPORT: errno %d" (errno ())
    let addr = Array.zeroCreate<byte> 16
    addr.[0] <- 2uy // AF_INET, little-endian sa_family
    addr.[2] <- byte (port >>> 8)
    addr.[3] <- byte port
    let ip = Net.IPAddress.Parse(host).GetAddressBytes()
    Array.blit ip 0 addr 4 4
    let rc =
        use p = fixed addr
        bind (fd, p, 16)
    if rc <> 0 then failwithf "bind %s:%d: errno %d" host port (errno ())
    if listen (fd, 65535) <> 0 then failwithf "listen: errno %d" (errno ())
    fd

/// RLIMIT_NOFILE: raises the soft limit to the hard limit and returns it
let raiseNoFile () : int =
    let lim = NativeInterop.NativePtr.stackalloc<uint64> 2
    if getrlimit (7, lim) = 0 then
        NativeInterop.NativePtr.set lim 0 (NativeInterop.NativePtr.get lim 1)
        setrlimit (7, lim) |> ignore
        getrlimit (7, lim) |> ignore
        int (min (NativeInterop.NativePtr.get lim 0) 100000000UL)
    else
        1024
