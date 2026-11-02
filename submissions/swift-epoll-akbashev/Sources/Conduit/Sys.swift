// The Linux interface (reactor.rs's `mod sys`): the calls Glibc's Swift module leaves out are declared here with
// `@_extern(c)`, as the Rust declares them with `unsafe extern "C"`, and the constants are the Linux ABI's.
import Glibc

enum Sys {
    static let PR_SET_THP_DISABLE: Int32 = 41
    static let M_ARENA_MAX: Int32 = -8
    static let SCHED_BATCH: Int32 = 3
    static let CLONE_FILES: Int32 = 0x0000_0400
    static let RLIMIT_NOFILE: Int32 = 7
    static let EFD_NONBLOCK: Int32 = 0o4000
    static let EFD_CLOEXEC: Int32 = 0o2000000
    static let AF_INET: Int32 = 2
    static let AF_INET6: Int32 = 10
    static let SOCK_STREAM: Int32 = 1
    static let SOCK_NONBLOCK: Int32 = 0o4000
    static let SOCK_CLOEXEC: Int32 = 0o2000000
    static let SOL_SOCKET: Int32 = 1
    static let SO_REUSEADDR: Int32 = 2
    static let SO_REUSEPORT: Int32 = 15
    static let IPPROTO_TCP: Int32 = 6
    static let TCP_NODELAY: Int32 = 1
    static let IPPROTO_IPV6: Int32 = 41
    static let IPV6_V6ONLY: Int32 = 26
    static let EPOLL_CLOEXEC: Int32 = 0o2000000
    static let EPOLL_CTL_ADD: Int32 = 1
    static let EPOLL_CTL_MOD: Int32 = 3
    static let EPOLLIN: UInt32 = 0x001
    static let EPOLLOUT: UInt32 = 0x004
    static let EPOLLERR: UInt32 = 0x008
    static let EPOLLHUP: UInt32 = 0x010
    static let EPOLLRDHUP: UInt32 = 0x2000
    static let EINTR: Int32 = 4
    static let EAGAIN: Int32 = 11
    static let ENFILE: Int32 = 23
    static let EMFILE: Int32 = 24
    static let ECONNABORTED: Int32 = 103

    /// `struct epoll_event` is `{ u32 events; u64 data; }`, packed on x86_64 (12 bytes) and naturally aligned
    /// elsewhere (16 bytes), as the Rust's `#[cfg_attr(target_arch = "x86_64", repr(C, packed))]` says. Swift has no
    /// packed structs, so events are read and written at these offsets.
    #if arch(x86_64)
    static let epollEventStride = 12
    static let epollDataOffset = 4
    #else
    static let epollEventStride = 16
    static let epollDataOffset = 8
    #endif
}

struct RLimit {
    var cur: UInt64 = 0
    var max: UInt64 = 0
}

@_extern(c, "prctl") func sys_prctl(_ option: Int32, _ a2: UInt, _ a3: UInt, _ a4: UInt, _ a5: UInt) -> Int32
@_extern(c, "mallopt") func sys_mallopt(_ param: Int32, _ value: Int32) -> Int32
@_extern(c, "sched_setscheduler") func sys_sched_setscheduler(_ pid: Int32, _ policy: Int32, _ param: UnsafeRawPointer) -> Int32
@_extern(c, "unshare") func sys_unshare(_ flags: Int32) -> Int32
@_extern(c, "getrlimit") func sys_getrlimit(_ resource: Int32, _ rlim: UnsafeMutableRawPointer) -> Int32
@_extern(c, "setrlimit") func sys_setrlimit(_ resource: Int32, _ rlim: UnsafeRawPointer) -> Int32
@_extern(c, "eventfd") func sys_eventfd(_ initval: UInt32, _ flags: Int32) -> Int32
@_extern(c, "socket") func sys_socket(_ domain: Int32, _ type: Int32, _ proto: Int32) -> Int32
@_extern(c, "setsockopt") func sys_setsockopt(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: UnsafeRawPointer, _ len: UInt32) -> Int32
@_extern(c, "bind") func sys_bind(_ fd: Int32, _ addr: UnsafeRawPointer, _ len: UInt32) -> Int32
@_extern(c, "listen") func sys_listen(_ fd: Int32, _ backlog: Int32) -> Int32
@_extern(c, "accept4") func sys_accept4(_ fd: Int32, _ addr: UnsafeMutableRawPointer?, _ len: UnsafeMutableRawPointer?, _ flags: Int32) -> Int32
@_extern(c, "epoll_create1") func sys_epoll_create1(_ flags: Int32) -> Int32
@_extern(c, "epoll_ctl") func sys_epoll_ctl(_ epfd: Int32, _ op: Int32, _ fd: Int32, _ event: UnsafeMutableRawPointer) -> Int32
@_extern(c, "epoll_wait") func sys_epoll_wait(_ epfd: Int32, _ events: UnsafeMutableRawPointer, _ maxEvents: Int32, _ timeout: Int32) -> Int32
@_extern(c, "read") func sys_read(_ fd: Int32, _ buf: UnsafeMutableRawPointer?, _ count: Int) -> Int
@_extern(c, "write") func sys_write(_ fd: Int32, _ buf: UnsafeRawPointer?, _ count: Int) -> Int
@_extern(c, "writev") func sys_writev(_ fd: Int32, _ iov: UnsafeRawPointer, _ iovcnt: Int32) -> Int
@_extern(c, "close") func sys_close(_ fd: Int32) -> Int32
@_extern(c, "pthread_setname_np") func sys_pthread_setname_np(_ thread: pthread_t, _ name: UnsafePointer<CChar>) -> Int32
@_extern(c, "sched_getaffinity") func sys_sched_getaffinity(_ pid: Int32, _ size: Int, _ mask: UnsafeMutableRawPointer) -> Int32
@_extern(c, "getrandom") func sys_getrandom(_ buf: UnsafeMutableRawPointer, _ len: Int, _ flags: UInt32) -> Int

/// Monotonic time in nanoseconds (Rust's `Instant`).
@inline(__always) func monotonicNanos() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
}

/// Seconds since the Unix epoch, as a Double (Rust's `SystemTime::now()...as_secs_f64()`).
@inline(__always) func unixNowF64() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_REALTIME, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
}

@inline(__always) func unixNowSecs() -> Int64 {
    var ts = timespec()
    clock_gettime(CLOCK_REALTIME, &ts)
    return Int64(ts.tv_sec)
}

/// The CPUs this process may run on: its affinity mask, which a cpuset narrows (Rust's `available_parallelism`).
func availableParallelism() -> Int {
    var mask = InlineArray<16, UInt64>(repeating: 0)
    var span = mask.mutableSpan
    let rc = span.withUnsafeMutableBytes { sys_sched_getaffinity(0, $0.count, $0.baseAddress!) }
    guard rc == 0 else { return max(Int(sysconf(Int32(_SC_NPROCESSORS_ONLN))), 1) }
    var cpus = 0
    for i in 0..<16 { cpus += mask[i].nonzeroBitCount }
    return max(cpus, 1)
}

/// main.rs's start-up tuning: no transparent huge pages, 4 malloc arenas, SCHED_BATCH (inherited by every thread).
func tuneProcess() {
    _ = sys_prctl(Sys.PR_SET_THP_DISABLE, 1, 0, 0, 0)
    _ = sys_mallopt(Sys.M_ARENA_MAX, 4)
    var priority: Int32 = 0
    _ = sys_sched_setscheduler(0, Sys.SCHED_BATCH, &priority)
}

/// The calling thread gets a file descriptor table of its own (reactor.rs `unshare_files`).
func unshareFiles() {
    _ = sys_unshare(Sys.CLONE_FILES)
}

/// Raises the descriptor soft limit towards min(hard, 262144) and returns how many connections a reactor may hold.
func probeNofileLimit() -> Int {
    var rl = RLimit()
    if sys_getrlimit(Sys.RLIMIT_NOFILE, &rl) == 0 {
        let target = min(rl.max, 262_144)
        if rl.cur < target {
            var raised = RLimit(cur: target, max: rl.max)
            if sys_setrlimit(Sys.RLIMIT_NOFILE, &raised) == 0 { rl.cur = target }
        }
        return max(Int(rl.cur) - 256, 256)
    }
    return 65536
}

struct SystemError: Error, CustomStringConvertible {
    let call: String
    let code: Int32
    init(_ call: String, _ code: Int32 = errno) {
        self.call = call
        self.code = code
    }
    var description: String { "\(call): \(String(cString: strerror(code)))" }
}

@inline(__always) private func setIntOption(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: Int32) -> Int32 {
    var v = value
    return sys_setsockopt(fd, level, name, &v, 4)
}

/// A non-blocking listener on `host:port` with SO_REUSEPORT, so every reactor binds one of its own.
func bindListener(host: String, port: UInt16) throws(SystemError) -> Int32 {
    var v4 = in_addr()
    var v6 = in6_addr()
    let isV4 = inet_pton(Sys.AF_INET, host, &v4) == 1
    guard isV4 || inet_pton(Sys.AF_INET6, host, &v6) == 1 else { throw SystemError("invalid HOST address \(host)", EINVAL) }
    let fd = sys_socket(isV4 ? Sys.AF_INET : Sys.AF_INET6, Sys.SOCK_STREAM | Sys.SOCK_NONBLOCK | Sys.SOCK_CLOEXEC, 0)
    guard fd >= 0 else { throw SystemError("socket") }
    for opt in [Sys.SO_REUSEADDR, Sys.SO_REUSEPORT] {
        guard setIntOption(fd, Sys.SOL_SOCKET, opt, 1) == 0 else { throw SystemError("setsockopt") }
    }
    let bound: Int32
    if isV4 {
        var sa = sockaddr_in()
        sa.sin_family = sa_family_t(Sys.AF_INET)
        sa.sin_port = port.bigEndian
        sa.sin_addr = v4
        bound = sys_bind(fd, &sa, UInt32(MemoryLayout<sockaddr_in>.size))
    } else {
        guard setIntOption(fd, Sys.IPPROTO_IPV6, Sys.IPV6_V6ONLY, 0) == 0 else { throw SystemError("setsockopt") }
        var sa = sockaddr_in6()
        sa.sin6_family = sa_family_t(Sys.AF_INET6)
        sa.sin6_port = port.bigEndian
        sa.sin6_addr = v6
        bound = sys_bind(fd, &sa, UInt32(MemoryLayout<sockaddr_in6>.size))
    }
    guard bound == 0 else { throw SystemError("bind \(host):\(port)") }
    guard sys_listen(fd, 65535) == 0 else { throw SystemError("listen") }
    return fd
}

/// TCP_NODELAY on an accepted or connected socket.
@inline(__always) func setNoDelay(_ fd: Int32) {
    _ = setIntOption(fd, Sys.IPPROTO_TCP, Sys.TCP_NODELAY, 1)
}

/// Writes all of `bytes` to a blocking descriptor.
func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) throws(SystemError) {
    var off = 0
    while off < bytes.count {
        let n = sys_write(fd, bytes.baseAddress! + off, bytes.count - off)
        if n < 0 {
            if errno == Sys.EINTR { continue }
            throw SystemError("write")
        }
        off += n
    }
}

/// A line on standard error (Rust's `eprintln!`).
func logLine(_ line: String) {
    var text = line + "\n"
    text.withUTF8 { _ = sys_write(2, $0.baseAddress, $0.count) }
}

/// A thread's body on its way through pthread_create.
private final class ThreadStart: Sendable {
    let name: String
    let body: @Sendable () -> Void
    init(name: String, body: @escaping @Sendable () -> Void) {
        self.name = name
        self.body = body
    }
}

/// Starts a detached thread named `name` running `body`.
func startThread(name: String, _ body: @escaping @Sendable () -> Void) {
    let start = Unmanaged.passRetained(ThreadStart(name: name, body: body)).toOpaque()
    var thread = pthread_t()
    let rc = pthread_create(&thread, nil, { raw in
        let start = Unmanaged<ThreadStart>.fromOpaque(raw!).takeRetainedValue()
        _ = sys_pthread_setname_np(pthread_self(), String(start.name.prefix(15)))
        start.body()
        return nil
    }, start)
    if rc != 0 { fatalError("pthread_create: \(rc)") }
    pthread_detach(thread)
}
