# Raw Linux syscalls for x86_64 and aarch64, written in Mojo with inline assembly. No libc, no external_call.
#
# Every wrapper returns the kernel's result: >= 0 on success, -errno on failure.

from std.sys import CompilationTarget
from std.sys._assembly import inlined_assembly

comptime X86 = CompilationTarget.is_x86()


@inline(.always)
def _nr(x86: Int, arm: Int) -> Int:
    return x86 if X86 else arm


# Syscall numbers. aarch64 uses the generic table: it has no fork, epoll_wait, accept or open.
comptime SYS_READ = _nr(0, 63)
comptime SYS_WRITE = _nr(1, 64)
comptime SYS_CLOSE = _nr(3, 57)
comptime SYS_MMAP = _nr(9, 222)
comptime SYS_MUNMAP = _nr(11, 215)
comptime SYS_RT_SIGACTION = _nr(13, 134)
comptime SYS_WRITEV = _nr(20, 66)
comptime SYS_SCHED_YIELD = _nr(24, 124)
comptime SYS_NANOSLEEP = _nr(35, 101)
comptime SYS_GETPID = _nr(39, 172)
comptime SYS_SOCKET = _nr(41, 198)
comptime SYS_CONNECT = _nr(42, 203)
comptime SYS_SENDTO = _nr(44, 206)
comptime SYS_RECVFROM = _nr(45, 207)
comptime SYS_SHUTDOWN = _nr(48, 210)
comptime SYS_BIND = _nr(49, 200)
comptime SYS_LISTEN = _nr(50, 201)
comptime SYS_SOCKETPAIR = _nr(53, 199)
comptime SYS_SETSOCKOPT = _nr(54, 208)
comptime SYS_CLONE = _nr(56, 220)
comptime SYS_EXIT = _nr(60, 93)
comptime SYS_WAIT4 = _nr(61, 260)
comptime SYS_KILL = _nr(62, 129)
comptime SYS_FCNTL = _nr(72, 25)
comptime SYS_PRCTL = _nr(157, 167)
comptime SYS_CLOCK_GETTIME = _nr(228, 113)
comptime SYS_EXIT_GROUP = _nr(231, 94)
comptime SYS_EPOLL_CTL = _nr(233, 21)
comptime SYS_EPOLL_PWAIT = _nr(281, 22)
comptime SYS_ACCEPT4 = _nr(288, 242)
comptime SYS_EPOLL_CREATE1 = _nr(291, 20)
comptime SYS_GETRANDOM = _nr(318, 278)

# Constants (the same values on both architectures).
comptime EAGAIN = 11
comptime EINTR = 4
comptime EINPROGRESS = 115

comptime AF_UNIX = 1
comptime AF_INET = 2
comptime SOCK_STREAM = 1
comptime SOCK_NONBLOCK = 0x800
comptime SOCK_CLOEXEC = 0x80000
comptime SOL_SOCKET = 1
comptime SO_REUSEADDR = 2
comptime SO_REUSEPORT = 15
comptime IPPROTO_TCP = 6
comptime TCP_NODELAY = 1
comptime MSG_NOSIGNAL = 0x4000
comptime SHUT_RDWR = 2

comptime EPOLL_CLOEXEC = 0x80000
comptime EPOLL_CTL_ADD = 1
comptime EPOLL_CTL_DEL = 2
comptime EPOLL_CTL_MOD = 3
comptime EPOLLIN: UInt32 = 0x001
comptime EPOLLOUT: UInt32 = 0x004
comptime EPOLLERR: UInt32 = 0x008
comptime EPOLLHUP: UInt32 = 0x010
comptime EPOLLRDHUP: UInt32 = 0x2000

# struct epoll_event is packed on x86_64 (12 bytes, data at offset 4) and naturally aligned on aarch64
# (16 bytes, data at offset 8). Getting this wrong works on one architecture and corrupts the other.
comptime EPOLL_EVENT_SIZE = 12 if X86 else 16
comptime EPOLL_DATA_OFFSET = 4 if X86 else 8

comptime SIGKILL = 9
comptime SIGTERM = 15
comptime SIGCHLD = 17
comptime PR_SET_PDEATHSIG = 1
comptime CLOCK_MONOTONIC = 1


@inline(.always)
def syscall6(nr: Int, a: Int, b: Int, c: Int, d: Int, e: Int, f: Int) -> Int:
    comptime if X86:
        return inlined_assembly[
            "syscall",
            Int,
            constraints="={rax},{rax},{rdi},{rsi},{rdx},{r10},{r8},{r9},~{rcx},~{r11},~{memory}",
            has_side_effect=True,
        ](nr, a, b, c, d, e, f)
    else:
        return inlined_assembly[
            "svc #0",
            Int,
            constraints="={x0},{x8},{x0},{x1},{x2},{x3},{x4},{x5},~{memory}",
            has_side_effect=True,
        ](nr, a, b, c, d, e, f)


@inline(.always)
def syscall3(nr: Int, a: Int, b: Int, c: Int) -> Int:
    comptime if X86:
        return inlined_assembly[
            "syscall",
            Int,
            constraints="={rax},{rax},{rdi},{rsi},{rdx},~{rcx},~{r11},~{memory}",
            has_side_effect=True,
        ](nr, a, b, c)
    else:
        return inlined_assembly[
            "svc #0",
            Int,
            constraints="={x0},{x8},{x0},{x1},{x2},~{memory}",
            has_side_effect=True,
        ](nr, a, b, c)


# --- files and processes ---------------------------------------------------------------------------------


@inline(.always)
def sys_read(fd: Int, buf: Int, n: Int) -> Int:
    return syscall3(SYS_READ, fd, buf, n)


@inline(.always)
def sys_write(fd: Int, buf: Int, n: Int) -> Int:
    return syscall3(SYS_WRITE, fd, buf, n)


@inline(.always)
def sys_close(fd: Int) -> Int:
    return syscall3(SYS_CLOSE, fd, 0, 0)


def sys_getpid() -> Int:
    return syscall3(SYS_GETPID, 0, 0, 0)


def sys_fork() -> Int:
    """Fork via clone(SIGCHLD): returns the child's pid in the parent, 0 in the child."""
    return syscall6(SYS_CLONE, SIGCHLD, 0, 0, 0, 0, 0)


def sys_wait4(pid: Int, status_ptr: Int, options: Int) -> Int:
    return syscall6(SYS_WAIT4, pid, status_ptr, options, 0, 0, 0)


def sys_kill(pid: Int, sig: Int) -> Int:
    return syscall3(SYS_KILL, pid, sig, 0)


def sys_prctl(option: Int, arg: Int) -> Int:
    return syscall6(SYS_PRCTL, option, arg, 0, 0, 0, 0)


def sys_exit_group(code: Int) -> Int:
    return syscall3(SYS_EXIT_GROUP, code, 0, 0)


def sys_getrandom(buf: Int, n: Int) -> Int:
    return syscall3(SYS_GETRANDOM, buf, n, 0)


def sys_clock_gettime(clock: Int, ts_ptr: Int) -> Int:
    return syscall3(SYS_CLOCK_GETTIME, clock, ts_ptr, 0)


# --- sockets -----------------------------------------------------------------------------------------------


def sys_socket(domain: Int, kind: Int, protocol: Int) -> Int:
    return syscall3(SYS_SOCKET, domain, kind, protocol)


def sys_socketpair(domain: Int, kind: Int, protocol: Int, fds_ptr: Int) -> Int:
    return syscall6(SYS_SOCKETPAIR, domain, kind, protocol, fds_ptr, 0, 0)


def sys_setsockopt(fd: Int, level: Int, name: Int, val_ptr: Int, val_len: Int) -> Int:
    return syscall6(SYS_SETSOCKOPT, fd, level, name, val_ptr, val_len, 0)


def sys_bind(fd: Int, addr_ptr: Int, addr_len: Int) -> Int:
    return syscall3(SYS_BIND, fd, addr_ptr, addr_len)


def sys_listen(fd: Int, backlog: Int) -> Int:
    return syscall3(SYS_LISTEN, fd, backlog, 0)


def sys_connect(fd: Int, addr_ptr: Int, addr_len: Int) -> Int:
    return syscall3(SYS_CONNECT, fd, addr_ptr, addr_len)


@inline(.always)
def sys_accept4(fd: Int, flags: Int) -> Int:
    return syscall6(SYS_ACCEPT4, fd, 0, 0, flags, 0, 0)


@inline(.always)
def sys_send(fd: Int, buf: Int, n: Int) -> Int:
    """send() with MSG_NOSIGNAL, so a closed peer gives -EPIPE instead of killing the process with SIGPIPE."""
    return syscall6(SYS_SENDTO, fd, buf, n, MSG_NOSIGNAL, 0, 0)


@inline(.always)
def sys_recv(fd: Int, buf: Int, n: Int) -> Int:
    return syscall6(SYS_RECVFROM, fd, buf, n, 0, 0, 0)


def sys_shutdown(fd: Int, how: Int) -> Int:
    return syscall3(SYS_SHUTDOWN, fd, how, 0)


# --- epoll -------------------------------------------------------------------------------------------------


def sys_epoll_create1(flags: Int) -> Int:
    return syscall3(SYS_EPOLL_CREATE1, flags, 0, 0)


@inline(.always)
def sys_epoll_ctl(epfd: Int, op: Int, fd: Int, event_ptr: Int) -> Int:
    return syscall6(SYS_EPOLL_CTL, epfd, op, fd, event_ptr, 0, 0)


@inline(.always)
def sys_epoll_wait(epfd: Int, events_ptr: Int, max_events: Int, timeout_ms: Int) -> Int:
    # epoll_pwait with a null sigmask is epoll_wait, and exists on both architectures.
    return syscall6(SYS_EPOLL_PWAIT, epfd, events_ptr, max_events, timeout_ms, 0, 8)


# --- helpers -----------------------------------------------------------------------------------------------


def write_all(fd: Int, s: StringSlice) -> Int:
    var p = Int(s.unsafe_ptr())
    var n = s.byte_length()
    while n > 0:
        var r = sys_write(fd, p, n)
        if r == -EINTR:
            continue
        if r < 0:
            return r
        p += r
        n -= r
    return 0


def log(msg: String):
    """Writes one line to stderr with a single write(2), so lines from different processes don't interleave."""
    var line = msg + "\n"
    _ = write_all(2, line)
