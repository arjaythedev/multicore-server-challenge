// Sockets and threads, straight from the C library: non-blocking TCP sockets for the loops (Loop.swift), and the
// threads the loops and the bcrypt workers run on, and how many cores there are.
import CEventLoop
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

struct SystemError: Error, CustomStringConvertible {
    let call: String
    let code: Int32

    init(_ call: String, _ code: Int32 = errno) {
        self.call = call
        self.code = code
    }

    var description: String { "\(call): \(String(cString: strerror(code)))" }
}

enum Sockets {
    #if os(Linux)
    private static let stream = Int32(SOCK_STREAM.rawValue)
    #else
    private static let stream = SOCK_STREAM
    #endif

    /// A non-blocking listening socket on `host:port`. With `reusePort`, every loop can bind one of its own, and the
    /// kernel spreads new connections over them.
    static func listen(host: String, port: Int, reusePort: Bool, backlog: Int32) throws(SystemError) -> Int32 {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { throw SystemError("inet_pton \(host)", EINVAL) }
        let fd = try socket()
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        if reusePort { setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            let error = SystemError("bind \(host):\(port)")
            closeDescriptor(fd)
            throw error
        }
        guard systemListen(fd, backlog) == 0 else {
            let error = SystemError("listen")
            closeDescriptor(fd)
            throw error
        }
        return fd
    }

    /// The next connection waiting on `listener`, non-blocking and with Nagle off; nil once none is waiting.
    static func accept(_ listener: Int32) -> Int32? {
        while true {
            #if os(Linux)
            let fd = CEventLoop_accept(listener, Int32(SOCK_NONBLOCK.rawValue | SOCK_CLOEXEC.rawValue))
            #else
            let fd = Darwin.accept(listener, nil, nil)
            #endif
            if fd < 0 {
                switch errno {
                case EINTR, ECONNABORTED: continue
                case EAGAIN, EWOULDBLOCK: return nil
                default:
                    // Out of descriptors, most likely: the connection waits in the backlog until one closes.
                    App.logger.error("\(SystemError("accept"))")
                    return nil
                }
            }
            #if !os(Linux)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            #endif
            noDelay(fd)
            return fd
        }
    }

    /// Starts connecting a non-blocking socket to `host:port` (resolved here, which can block: it is done only when a
    /// lane opens a connection). Writable once connected; then `connectError` says how it went.
    static func connect(host: String, port: Int) throws(SystemError) -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = stream
        var list: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &list)
        guard rc == 0, let first = list else { throw SystemError("getaddrinfo \(host): \(String(cString: gai_strerror(rc)))", EINVAL) }
        defer { freeaddrinfo(list) }
        var lastError = SystemError("connect \(host):\(port)", ECONNREFUSED)
        var candidate: UnsafeMutablePointer<addrinfo>? = first
        while let info = candidate {
            candidate = info.pointee.ai_next
            guard let fd = try? socket(family: info.pointee.ai_family) else { continue }
            if systemConnect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 || errno == EINPROGRESS {
                noDelay(fd)
                return fd
            }
            lastError = SystemError("connect \(host):\(port)")
            closeDescriptor(fd)
        }
        throw lastError
    }

    /// The outcome of a connect, once its socket is writable: 0, or the errno it failed with.
    static func connectError(_ fd: Int32) -> Int32 {
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return errno }
        return error
    }

    private static func socket(family: Int32 = AF_INET) throws(SystemError) -> Int32 {
        #if os(Linux)
        let fd = Glibc.socket(family, stream | Int32(SOCK_NONBLOCK.rawValue | SOCK_CLOEXEC.rawValue), 0)
        guard fd >= 0 else { throw SystemError("socket") }
        #else
        let fd = Darwin.socket(family, stream, 0)
        guard fd >= 0 else { throw SystemError("socket") }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        return fd
    }

    private static func noDelay(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    }
}

/// close(2), for types that have a `close()` of their own.
func closeDescriptor(_ fd: Int32) {
    _ = close(fd)
}

/// read(2) into `buffer`: the byte count, 0 at end of stream, or -1 with `errno` set.
func readDescriptor(_ fd: Int32, _ buffer: UnsafeMutableRawBufferPointer) -> Int {
    read(fd, buffer.baseAddress, buffer.count)
}

/// write(2) from `buffer`: the byte count taken, or -1 with `errno` set.
func writeDescriptor(_ fd: Int32, _ buffer: UnsafeRawBufferPointer) -> Int {
    write(fd, buffer.baseAddress, buffer.count)
}

// listen(2) and connect(2), which `Sockets.listen` and `Sockets.connect` would otherwise shadow.
private func systemListen(_ fd: Int32, _ backlog: Int32) -> Int32 { listen(fd, backlog) }
private func systemConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>!, _ length: socklen_t) -> Int32 {
    connect(fd, address, length)
}

// ---------- cores ----------

enum System {
    /// The cores this process may use: the CPUs it may run on, capped by its cgroup's CPU limit (a container's
    /// `--cpus`), rounded up.
    static let coreCount: Int = {
        #if os(Linux)
        var cores = Int(CEventLoop_cpusAllowed())
        if cores < 1 { cores = Int(sysconf(Int32(_SC_NPROCESSORS_ONLN))) }
        // cgroup v2: "max 100000", or "<quota> <period>" in microseconds.
        if let limit = try? String(contentsOfFile: "/sys/fs/cgroup/cpu.max", encoding: .utf8) {
            let fields = limit.split(whereSeparator: \.isWhitespace)
            if fields.count == 2, let quota = Int(fields[0]), let period = Int(fields[1]), quota > 0, period > 0 {
                cores = min(cores, max(1, (quota + period - 1) / period))
            }
        }
        return max(1, cores)
        #else
        return max(1, Int(sysconf(_SC_NPROCESSORS_ONLN)))
        #endif
    }()
}

// ---------- threads ----------

private final class ThreadBody {
    let name: String
    let body: @Sendable () -> Void

    init(name: String, body: @escaping @Sendable () -> Void) {
        self.name = name
        self.body = body
    }

    func run() {
        #if os(Linux)
        _ = CEventLoop_nameThread(String(name.prefix(15)))
        #else
        pthread_setname_np(name)
        #endif
        body()
    }
}

/// Starts a thread of its own (detached) running `body`.
func startThread(name: String, _ body: @escaping @Sendable () -> Void) {
    let box = Unmanaged.passRetained(ThreadBody(name: name, body: body)).toOpaque()
    #if os(Linux)
    var thread = pthread_t()
    let rc = pthread_create(&thread, nil, { raw in
        Unmanaged<ThreadBody>.fromOpaque(raw!).takeRetainedValue().run()
        return nil
    }, box)
    precondition(rc == 0, "pthread_create: \(rc)")
    pthread_detach(thread)
    #else
    var thread: pthread_t?
    let rc = pthread_create(&thread, nil, { raw in
        Unmanaged<ThreadBody>.fromOpaque(raw).takeRetainedValue().run()
        return nil
    }, box)
    precondition(rc == 0, "pthread_create: \(rc)")
    pthread_detach(thread!)
    #endif
}
