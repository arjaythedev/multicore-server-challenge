// The Linux calls Glibc's Swift module leaves out, declared in Swift with `@_extern(c)` as the Rust declares them
// with `unsafe extern "C"` (reactor.rs's `mod sys`). Each is the C function itself: a call is a direct call to it.
import Glibc

@_extern(c, "prctl") public func sys_prctl(_ option: Int32, _ a2: UInt, _ a3: UInt, _ a4: UInt, _ a5: UInt) -> Int32
@_extern(c, "mallopt") public func sys_mallopt(_ param: Int32, _ value: Int32) -> Int32
@_extern(c, "sched_setscheduler") public func sys_sched_setscheduler(_ pid: Int32, _ policy: Int32, _ param: UnsafeRawPointer) -> Int32
@_extern(c, "unshare") public func sys_unshare(_ flags: Int32) -> Int32
@_extern(c, "getrlimit") public func sys_getrlimit(_ resource: Int32, _ rlim: UnsafeMutableRawPointer) -> Int32
@_extern(c, "setrlimit") public func sys_setrlimit(_ resource: Int32, _ rlim: UnsafeRawPointer) -> Int32
@_extern(c, "eventfd") public func sys_eventfd(_ initval: UInt32, _ flags: Int32) -> Int32
@_extern(c, "socket") public func sys_socket(_ domain: Int32, _ type: Int32, _ proto: Int32) -> Int32
@_extern(c, "setsockopt") public func sys_setsockopt(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: UnsafeRawPointer, _ len: UInt32) -> Int32
@_extern(c, "bind") public func sys_bind(_ fd: Int32, _ addr: UnsafeRawPointer, _ len: UInt32) -> Int32
@_extern(c, "listen") public func sys_listen(_ fd: Int32, _ backlog: Int32) -> Int32
@_extern(c, "accept4") public func sys_accept4(_ fd: Int32, _ addr: UnsafeMutableRawPointer?, _ len: UnsafeMutableRawPointer?, _ flags: Int32) -> Int32
@_extern(c, "epoll_create1") public func sys_epoll_create1(_ flags: Int32) -> Int32
@_extern(c, "epoll_ctl") public func sys_epoll_ctl(_ epfd: Int32, _ op: Int32, _ fd: Int32, _ event: UnsafeMutableRawPointer) -> Int32
@_extern(c, "epoll_wait") public func sys_epoll_wait(_ epfd: Int32, _ events: UnsafeMutableRawPointer, _ maxEvents: Int32, _ timeout: Int32) -> Int32
@_extern(c, "read") public func sys_read(_ fd: Int32, _ buf: UnsafeMutableRawPointer?, _ count: Int) -> Int
@_extern(c, "write") public func sys_write(_ fd: Int32, _ buf: UnsafeRawPointer?, _ count: Int) -> Int
@_extern(c, "writev") public func sys_writev(_ fd: Int32, _ iov: UnsafeRawPointer, _ iovcnt: Int32) -> Int
@_extern(c, "close") public func sys_close(_ fd: Int32) -> Int32
@_extern(c, "pthread_setname_np") public func sys_pthread_setname_np(_ thread: pthread_t, _ name: UnsafePointer<CChar>) -> Int32
@_extern(c, "sched_getaffinity") public func sys_sched_getaffinity(_ pid: Int32, _ size: Int, _ mask: UnsafeMutableRawPointer) -> Int32
@_extern(c, "getrandom") public func sys_getrandom(_ buf: UnsafeMutableRawPointer, _ len: Int, _ flags: UInt32) -> Int
