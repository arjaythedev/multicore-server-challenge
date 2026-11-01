package challenge;

import java.lang.foreign.Arena;
import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.Linker.Option;
import java.lang.foreign.MemoryLayout;
import java.lang.foreign.MemoryLayout.PathElement;
import java.lang.foreign.MemorySegment;
import java.lang.invoke.MethodHandle;
import java.lang.invoke.VarHandle;
import java.net.Inet4Address;
import java.net.Inet6Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.ByteOrder;

import static java.lang.foreign.ValueLayout.ADDRESS;
import static java.lang.foreign.ValueLayout.JAVA_BYTE;
import static java.lang.foreign.ValueLayout.JAVA_INT;
import static java.lang.foreign.ValueLayout.JAVA_INT_UNALIGNED;
import static java.lang.foreign.ValueLayout.JAVA_LONG;
import static java.lang.foreign.ValueLayout.JAVA_LONG_UNALIGNED;
import static java.lang.foreign.ValueLayout.JAVA_SHORT;

public final class Sys {
    static final int AF_INET = 2;
    static final int AF_INET6 = 10;
    static final int SOCK_STREAM = 1;
    static final int SOCK_NONBLOCK = 0x800;
    static final int SOCK_CLOEXEC = 0x80000;
    static final int SOL_SOCKET = 1;
    static final int SO_REUSEADDR = 2;
    static final int SO_LINGER = 13;
    static final int SO_REUSEPORT = 15;
    static final int SO_RCVTIMEO = 20;
    static final int SO_SNDTIMEO = 21;
    static final int IPPROTO_TCP = 6;
    static final int TCP_NODELAY = 1;
    static final int TCP_DEFER_ACCEPT = 9;
    static final int F_SETFL = 4;
    static final int O_NONBLOCK = 0x800;
    public static final int EPOLL_CLOEXEC = 0x80000;
    public static final int EPOLL_CTL_ADD = 1;
    public static final int EPOLL_CTL_MOD = 3;
    public static final int EPOLLIN = 0x1;
    public static final int EPOLLOUT = 0x4;
    public static final int EPOLLERR = 0x8;
    public static final int EPOLLHUP = 0x10;
    public static final int EINTR = 4;
    public static final int EAGAIN = 11;
    public static final int EBUSY = 16;
    public static final int ENFILE = 23;
    public static final int EMFILE = 24;
    public static final int ETIME = 62;
    public static final int ECONNABORTED = 103;
    public static final int ENOBUFS = 105;
    public static final int ECANCELED = 125;

    private static final boolean X86 = switch (System.getProperty("os.arch")) {
        case "amd64", "x86_64" -> true;
        default -> false;
    };
    public static final int EVENT_SIZE = X86 ? 12 : 16;
    private static final int EVENT_DATA = X86 ? 4 : 8;

    private static final Linker LINKER = Linker.nativeLinker();
    private static final Option CRITICAL = Option.critical(false);
    private static final Option ERRNO = Option.captureCallState("errno");
    private static final MemoryLayout STATE_LAYOUT = Option.captureStateLayout();
    private static final VarHandle ERRNO_VALUE = STATE_LAYOUT.varHandle(PathElement.groupElement("errno"));

    private static MethodHandle fn(String name, FunctionDescriptor fd, Option... options) {
        MemorySegment f = LINKER.defaultLookup()
                                .find(name)
                                .orElseThrow(() -> new UnsatisfiedLinkError(name));
        return LINKER.downcallHandle(f, fd, options);
    }

    private static final MethodHandle EVENTFD = fn("eventfd", FunctionDescriptor.of(JAVA_INT, JAVA_INT, JAVA_INT), ERRNO);
    private static final MethodHandle SOCKET = fn("socket", FunctionDescriptor.of(JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT), ERRNO);
    private static final MethodHandle SETSOCKOPT = fn("setsockopt", FunctionDescriptor.of(JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, ADDRESS, JAVA_INT), CRITICAL);
    private static final MethodHandle BIND = fn("bind", FunctionDescriptor.of(JAVA_INT, JAVA_INT, ADDRESS, JAVA_INT), ERRNO);
    private static final MethodHandle LISTEN = fn("listen", FunctionDescriptor.of(JAVA_INT, JAVA_INT, JAVA_INT), ERRNO);
    private static final MethodHandle CONNECT = fn("connect", FunctionDescriptor.of(JAVA_INT, JAVA_INT, ADDRESS, JAVA_INT), ERRNO);
    private static final MethodHandle FCNTL = fn("fcntl", FunctionDescriptor.of(JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT),
            Option.firstVariadicArg(2), ERRNO);
    private static final MethodHandle ACCEPT4 = fn("accept4", FunctionDescriptor.of(JAVA_INT, JAVA_INT, ADDRESS, ADDRESS, JAVA_INT),
            CRITICAL, ERRNO);
    private static final MethodHandle GETPEERNAME = fn("getpeername", FunctionDescriptor.of(JAVA_INT, JAVA_INT, ADDRESS, ADDRESS));
    private static final MethodHandle GETSOCKNAME = fn("getsockname", FunctionDescriptor.of(JAVA_INT, JAVA_INT, ADDRESS, ADDRESS));
    private static final MethodHandle EPOLL_CREATE1 = fn("epoll_create1", FunctionDescriptor.of(JAVA_INT, JAVA_INT), ERRNO);
    private static final MethodHandle EPOLL_CTL = fn("epoll_ctl", FunctionDescriptor.of(JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, ADDRESS), CRITICAL);
    private static final MethodHandle EPOLL_WAIT = fn("epoll_wait", FunctionDescriptor.of(JAVA_INT, JAVA_INT, ADDRESS, JAVA_INT, JAVA_INT), ERRNO);
    private static final MethodHandle READ = fn("read", FunctionDescriptor.of(JAVA_LONG, JAVA_INT, ADDRESS, JAVA_LONG), CRITICAL, ERRNO);
    private static final MethodHandle WRITE_WAKE = fn("write", FunctionDescriptor.of(JAVA_LONG, JAVA_INT, ADDRESS, JAVA_LONG), CRITICAL);
    private static final MemorySegment WAKE_VALUE = Arena.global().allocate(JAVA_LONG);

    static {
        WAKE_VALUE.set(JAVA_LONG, 0, 1L);
    }

    private static final MethodHandle WRITE = fn("write", FunctionDescriptor.of(JAVA_LONG, JAVA_INT, ADDRESS, JAVA_LONG), CRITICAL, ERRNO);
    private static final MethodHandle READ_BLOCKING = fn("read", FunctionDescriptor.of(JAVA_LONG, JAVA_INT, ADDRESS, JAVA_LONG), ERRNO);
    private static final MethodHandle WRITE_BLOCKING = fn("write", FunctionDescriptor.of(JAVA_LONG, JAVA_INT, ADDRESS, JAVA_LONG), ERRNO);
    private static final MethodHandle CLOSE = fn("close", FunctionDescriptor.of(JAVA_INT, JAVA_INT), CRITICAL);
    private static final MethodHandle GETSOCKOPT = fn("getsockopt", FunctionDescriptor.of(JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, ADDRESS, ADDRESS), CRITICAL);
    private static final MethodHandle MMAP = fn(
            "mmap",
            FunctionDescriptor.of(ADDRESS, ADDRESS, JAVA_LONG, JAVA_INT, JAVA_INT, JAVA_INT,
                    JAVA_LONG),
            ERRNO);
    private static final long SYS_IO_URING_SETUP = 425;
    private static final long SYS_IO_URING_ENTER = 426;
    private static final long SYS_IO_URING_REGISTER = 427;
    private static final MethodHandle URING_SETUP = fn("syscall", FunctionDescriptor.of(JAVA_LONG, JAVA_LONG, JAVA_INT, ADDRESS),
            Option.firstVariadicArg(1), ERRNO);
    private static final MethodHandle URING_REGISTER = fn("syscall", FunctionDescriptor.of(JAVA_LONG, JAVA_LONG, JAVA_INT, JAVA_INT, ADDRESS, JAVA_INT),
            Option.firstVariadicArg(1), ERRNO);
    private static final MethodHandle URING_ENTER = fn(
            "syscall",
            FunctionDescriptor.of(JAVA_LONG, JAVA_LONG, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT,
                    ADDRESS, JAVA_LONG),
            Option.firstVariadicArg(1),
            ERRNO);

    private final MemorySegment state = Arena.global().allocate(STATE_LAYOUT);
    private final MemorySegment scratch = Arena.global().allocate(64, 8);

    private static RuntimeException rethrow(Throwable t) {
        if (t instanceof RuntimeException r) {
            return r;
        }
        if (t instanceof Error e) {
            throw e;
        }
        return new IllegalStateException(t);
    }

    public int errno() {
        return (int) ERRNO_VALUE.get(state, 0L);
    }

    public int listen(InetAddress host, int port, int backlog) {
        int fd = socket(host, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC);
        setInt(fd, SOL_SOCKET, SO_REUSEADDR, 1);
        setInt(fd, SOL_SOCKET, SO_REUSEPORT, 1);
        setInt(fd, IPPROTO_TCP, TCP_NODELAY, 1);
        setInt(fd, IPPROTO_TCP, TCP_DEFER_ACCEPT, 5);
        MemorySegment sa = sockaddr(host, port);
        try {
            if ((int) BIND.invokeExact(state, fd, sa, (int) sa.byteSize()) != 0) {
                throw new IllegalStateException("bind "
                        + host.getHostAddress()
                        + ":"
                        + port
                        + ": errno "
                        + errno());
            }
            if ((int) LISTEN.invokeExact(state, fd, backlog) != 0) {
                throw new IllegalStateException("listen: errno " + errno());
            }
        } catch (Throwable t) {
            throw rethrow(t);
        }
        return fd;
    }

    int connect(InetAddress host, int port, int timeoutMillis) {
        int fd = socket(host, SOCK_STREAM | SOCK_CLOEXEC);
        setTimeout(fd, SO_SNDTIMEO, timeoutMillis);
        setTimeout(fd, SO_RCVTIMEO, timeoutMillis);
        MemorySegment sa = sockaddr(host, port);
        try {
            if ((int) CONNECT.invokeExact(state, fd, sa, (int) sa.byteSize()) != 0) {
                int e = errno();
                close(fd);
                return -e;
            }
        } catch (Throwable t) {
            throw rethrow(t);
        }
        setInt(fd, IPPROTO_TCP, TCP_NODELAY, 1);
        return fd;
    }

    public int connectNonBlocking(InetAddress host, int port) {
        int fd = socket(host, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC);
        setInt(fd, IPPROTO_TCP, TCP_NODELAY, 1);
        MemorySegment sa = sockaddr(host, port);
        try {
            if ((int) CONNECT.invokeExact(state, fd, sa, (int) sa.byteSize()) != 0 && errno() != 115) {
                int error = errno();
                close(fd);
                return -error;
            }
        } catch (Throwable t) {
            close(fd);
            throw rethrow(t);
        }
        return fd;
    }

    public int eventfd() {
        try {
            int fd = (int) EVENTFD.invokeExact(state, 0, SOCK_NONBLOCK | SOCK_CLOEXEC);
            if (fd < 0) {
                throw new IllegalStateException("eventfd: errno " + errno());
            }
            return fd;
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    void setNonBlocking(int fd) {
        try {
            if ((int) FCNTL.invokeExact(state, fd, F_SETFL, O_NONBLOCK) != 0) {
                throw new IllegalStateException("fcntl: errno " + errno());
            }
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    private int socket(InetAddress host, int type) {
        int fd;
        try {
            fd = (int) SOCKET.invokeExact(state, host instanceof Inet6Address ? AF_INET6 : AF_INET, type,
                    0);
        } catch (Throwable t) {
            throw rethrow(t);
        }
        if (fd < 0) {
            throw new IllegalStateException("socket: errno " + errno());
        }
        return fd;
    }

    private MemorySegment sockaddr(InetAddress host, int port) {
        boolean v6 = host instanceof Inet6Address;
        MemorySegment sa = scratch.asSlice(0, v6 ? 28 : 16).fill((byte) 0);
        sa.set(JAVA_SHORT, 0, (short) (v6 ? AF_INET6 : AF_INET));
        sa.set(JAVA_SHORT.withOrder(ByteOrder.BIG_ENDIAN), 2, (short) port);
        byte[] addr = host.getAddress();
        MemorySegment.copy(addr, 0, sa, JAVA_BYTE,
                host instanceof Inet4Address ? 4 : 8, addr.length);
        return sa;
    }

    /** The socket's peer (or local) address, or null if the call fails. */
    public InetSocketAddress address(int fd, boolean peer) {
        MemorySegment sa = scratch.asSlice(0, 28).fill((byte) 0);
        MemorySegment len = scratch.asSlice(32, 4);
        len.set(JAVA_INT, 0, 28);
        try {
            if ((int) (peer ? GETPEERNAME : GETSOCKNAME).invokeExact(fd, sa, len) != 0) {
                return null;
            }
            boolean v6 = sa.get(JAVA_SHORT, 0) == AF_INET6;
            byte[] addr = new byte[v6 ? 16 : 4];
            MemorySegment.copy(sa, JAVA_BYTE, v6 ? 8 : 4, addr,
                    0, addr.length);
            return new InetSocketAddress(InetAddress.getByAddress(addr), sa.get(JAVA_SHORT.withOrder(ByteOrder.BIG_ENDIAN), 2) & 0xffff);
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    int setInt(int fd, int level, int name,
               int value) {
        scratch.set(JAVA_INT, 32, value);
        try {
            return (int) SETSOCKOPT.invokeExact(fd, level, name, scratch.asSlice(32, 4), 4);
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    private void setTimeout(int fd, int name, int millis) {
        scratch.set(JAVA_LONG, 48, millis / 1000);
        scratch.set(JAVA_LONG, 56, (millis % 1000) * 1000L);
        try {
            int ignored = (int) SETSOCKOPT.invokeExact(fd, SOL_SOCKET, name, scratch.asSlice(48, 16), 16);
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    public int accept(int fd) {
        try {
            return (int) ACCEPT4.invokeExact(state, fd, MemorySegment.NULL, MemorySegment.NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    public int epollCreate() {
        try {
            int ep = (int) EPOLL_CREATE1.invokeExact(state, EPOLL_CLOEXEC);
            if (ep < 0) {
                throw new IllegalStateException("epoll_create1: errno " + errno());
            }
            return ep;
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    public int epollCtl(int ep, int op, int fd,
                        int events, int tag) {
        MemorySegment ev = scratch.asSlice(0, EVENT_SIZE);
        ev.set(JAVA_INT_UNALIGNED, 0, events);
        ev.set(JAVA_LONG_UNALIGNED, EVENT_DATA, (long) tag << 32 | (fd & 0xffffffffL));
        try {
            return (int) EPOLL_CTL.invokeExact(ep, op, fd, ev);
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    public int epollWait(int ep, MemorySegment events, int max,
                         int timeoutMillis) {
        try {
            return (int) EPOLL_WAIT.invokeExact(state, ep, events, max, timeoutMillis);
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    public static int eventFd(MemorySegment events, int i) {
        return events.get(JAVA_INT_UNALIGNED, (long) i * EVENT_SIZE + EVENT_DATA);
    }

    public static int eventTag(MemorySegment events, int i) {
        return events.get(JAVA_INT_UNALIGNED, (long) i * EVENT_SIZE + EVENT_DATA + 4);
    }

    public static int eventFlags(MemorySegment events, int i) {
        return events.get(JAVA_INT_UNALIGNED, (long) i * EVENT_SIZE);
    }

    public static void wake(int fd) {
        try {
            long ignored = (long) WRITE_WAKE.invokeExact(fd, WAKE_VALUE, 8L);
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    public long read(int fd, MemorySegment buf, long n) {
        try {
            return (long) READ.invokeExact(state, fd, buf, n);
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    public long write(int fd, MemorySegment buf, long n) {
        try {
            return (long) WRITE.invokeExact(state, fd, buf, n);
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    long readBlocking(int fd, MemorySegment buf, long n) {
        try {
            return (long) READ_BLOCKING.invokeExact(state, fd, buf, n);
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    long writeBlocking(int fd, MemorySegment buf, long n) {
        try {
            return (long) WRITE_BLOCKING.invokeExact(state, fd, buf, n);
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    public int getInt(int fd, int level, int name) {
        scratch.set(JAVA_INT, 32, 0);
        scratch.set(JAVA_INT, 36, 4);
        try {
            int r = (int) GETSOCKOPT.invokeExact(fd, level, name, scratch.asSlice(32, 4),
                    scratch.asSlice(36, 4));
            return r == 0 ? scratch.get(JAVA_INT, 32) : -1;
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    MemorySegment mmapShared(int fd, long size, long offset) {
        try {
            MemorySegment m = (MemorySegment) MMAP.invokeExact(state, MemorySegment.NULL, size, 3, 0x01 | 0x8000,
                    fd, offset);
            return m.address() == -1L ? null : m.reinterpret(size);
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    int uringSetup(int entries, MemorySegment params) {
        try {
            return (int) (long) URING_SETUP.invokeExact(state, SYS_IO_URING_SETUP, entries, params);
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    int uringRegister(int fd, int opcode, MemorySegment arg,
                      int n) {
        try {
            return (int) (long) URING_REGISTER.invokeExact(state, SYS_IO_URING_REGISTER, fd, opcode, arg, n);
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    int uringEnter(int fd, int toSubmit, int minComplete,
                   int flags, MemorySegment arg, long argSize) {
        try {
            return (int) (long) URING_ENTER.invokeExact(state, SYS_IO_URING_ENTER, fd, toSubmit, minComplete, flags,
                    arg, argSize);
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    private static final class Priority {
        static final MethodHandle GETTID = fn("gettid", FunctionDescriptor.of(JAVA_INT));
        static final MethodHandle SETPRIORITY = fn("setpriority", FunctionDescriptor.of(JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT), ERRNO);
    }

    public static int niceCurrentThread(int nice) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment state = arena.allocate(STATE_LAYOUT);
            int tid = (int) Priority.GETTID.invokeExact();
            int result = (int) Priority.SETPRIORITY.invokeExact(state, 0, tid, nice);
            return result == 0 ? 0 : (int) ERRNO_VALUE.get(state, 0L);
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    public static void close(int fd) {
        try {
            int ignored = (int) CLOSE.invokeExact(fd);
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }
}
