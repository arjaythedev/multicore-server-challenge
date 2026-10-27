using System.Runtime.InteropServices;

namespace Conduit.Http;

/// <summary>
/// Direct libc calls for the epoll server (Linux only). Each import sets the thread's last error on failure,
/// which <see cref="Errno"/> reads.
/// </summary>
internal static unsafe partial class Libc {
    /// <summary>Address family for IPv4 sockets.</summary>
    public const int AF_INET = 2;
    /// <summary>Socket type for a TCP byte stream.</summary>
    public const int SOCK_STREAM = 1;
    /// <summary>Flag for socket, accept4 and eventfd (as EFD_NONBLOCK): the new descriptor is non-blocking.</summary>
    public const int SOCK_NONBLOCK = 0x800;
    /// <summary>Flag: close the new descriptor on exec. Same value as EPOLL_CLOEXEC and EFD_CLOEXEC, which the code also passes this way.</summary>
    public const int SOCK_CLOEXEC = 0x80000;
    /// <summary>Option level for socket-wide options.</summary>
    public const int SOL_SOCKET = 1;
    /// <summary>Socket option: allow binding an address that has old connections in TIME_WAIT.</summary>
    public const int SO_REUSEADDR = 2;
    /// <summary>Socket option: let several listeners bind the same port; the kernel spreads new connections across them.</summary>
    public const int SO_REUSEPORT = 15;
    /// <summary>Option level for TCP options.</summary>
    public const int IPPROTO_TCP = 6;
    /// <summary>TCP option: send small writes at once instead of waiting to coalesce them.</summary>
    public const int TCP_NODELAY = 1;
    /// <summary>send flag: writing to a closed peer returns EPIPE instead of raising SIGPIPE.</summary>
    public const int MSG_NOSIGNAL = 0x4000;
    /// <summary>shutdown mode: stop both sending and receiving.</summary>
    public const int SHUT_RDWR = 2;

    /// <summary>epoll event: the descriptor is readable.</summary>
    public const uint EPOLLIN = 0x1;
    /// <summary>epoll event: the descriptor is writable.</summary>
    public const uint EPOLLOUT = 0x4;
    /// <summary>epoll event: the descriptor has an error.</summary>
    public const uint EPOLLERR = 0x8;
    /// <summary>epoll event: the peer hung up.</summary>
    public const uint EPOLLHUP = 0x10;
    /// <summary>epoll flag: edge-triggered. Events fire on new readiness only, so callers read or write until EAGAIN.</summary>
    public const uint EPOLLET = 0x80000000;
    /// <summary>epoll_ctl operation: add a descriptor to the set.</summary>
    public const int EPOLL_CTL_ADD = 1;

    /// <summary>errno: the call was interrupted by a signal; retry.</summary>
    public const int EINTR = 4;
    /// <summary>errno: the call would block (also EWOULDBLOCK).</summary>
    public const int EAGAIN = 11;
    /// <summary>errno: the system-wide open file limit is reached.</summary>
    public const int ENFILE = 23;
    /// <summary>errno: the process has no free descriptors.</summary>
    public const int EMFILE = 24;
    /// <summary>errno: a pending connection was reset before accept took it; take the next one.</summary>
    public const int ECONNABORTED = 103;

    /// <summary>getrlimit resource: the most descriptors the process may hold.</summary>
    public const int RLIMIT_NOFILE = 7;

    /// <summary>Size of one epoll_event: packed (12 bytes) on x86-64, padded (16 bytes) elsewhere.</summary>
    public static readonly int EpollEventSize =
        RuntimeInformation.ProcessArchitecture == Architecture.X64 ? 12 : 16;

    /// <summary>Byte offset of the 64-bit data field inside an epoll_event: 4 when packed, 8 when padded.</summary>
    private static readonly int EpollDataOffset = EpollEventSize == 12 ? 4 : 8;

    /// <summary>socket(2): creates the listening socket in <c>HttpServer.Listen</c>.</summary>
    [LibraryImport("libc", SetLastError = true)]
    public static partial int socket(int domain, int type, int protocol);

    /// <summary>bind(2): binds the listening socket to Host and Port.</summary>
    [LibraryImport("libc", SetLastError = true)]
    public static partial int bind(int fd, byte* addr, int len);

    /// <summary>listen(2): starts the listening socket with the server backlog.</summary>
    [LibraryImport("libc", SetLastError = true)]
    public static partial int listen(int fd, int backlog);

    /// <summary>getrlimit(2): reads a resource limit into two 64-bit values, soft then hard. Used by <c>HttpServer.Start</c>.</summary>
    [LibraryImport("libc", SetLastError = true)]
    public static partial int getrlimit(int resource, ulong* limits);

    /// <summary>accept4(2): takes one pending connection as a non-blocking descriptor; the peer address is not read. Used by <c>HttpLoop.AcceptAll</c>.</summary>
    [LibraryImport("libc", SetLastError = true)]
    public static partial int accept4(int fd, byte* addr, int* len, int flags);

    /// <summary>setsockopt(2): sets integer options through <see cref="SetOption"/> and <see cref="TrySetOption"/>.</summary>
    [LibraryImport("libc", SetLastError = true)]
    public static partial int setsockopt(int fd, int level, int name, int* value, int len);

    /// <summary>epoll_create1(2): makes the epoll set of one event loop.</summary>
    [LibraryImport("libc", SetLastError = true)]
    public static partial int epoll_create1(int flags);

    /// <summary>epoll_ctl(2): changes the epoll set; the code calls it through <see cref="EpollAdd"/>.</summary>
    [LibraryImport("libc", SetLastError = true)]
    public static partial int epoll_ctl(int epfd, int op, int fd, byte* ev);

    /// <summary>epoll_wait(2): waits for events in the loop thread. <paramref name="timeoutMs"/> of -1 waits without limit.</summary>
    [LibraryImport("libc", SetLastError = true)]
    public static partial int epoll_wait(int epfd, byte* events, int maxEvents, int timeoutMs);

    /// <summary>recv(2): reads from a connection into the receive buffer.</summary>
    [LibraryImport("libc", SetLastError = true)]
    public static partial nint recv(int fd, byte* buf, nuint len, int flags);

    /// <summary>send(2): writes response bytes to a connection, with MSG_NOSIGNAL.</summary>
    [LibraryImport("libc", SetLastError = true)]
    public static partial nint send(int fd, byte* buf, nuint len, int flags);

    /// <summary>close(2): closes a descriptor.</summary>
    [LibraryImport("libc", SetLastError = true)]
    public static partial int close(int fd);

    /// <summary>shutdown(2): ends a connection so the loop sees the hang-up and closes it.</summary>
    [LibraryImport("libc", SetLastError = true)]
    public static partial int shutdown(int fd, int how);

    /// <summary>eventfd(2): makes the counter descriptor that wakes a loop from other threads.</summary>
    [LibraryImport("libc", SetLastError = true)]
    public static partial int eventfd(uint initial, int flags);

    /// <summary>read(2): drains the wake-up eventfd.</summary>
    [LibraryImport("libc", SetLastError = true)]
    public static partial nint read(int fd, byte* buf, nuint len);

    /// <summary>write(2): signals the wake-up eventfd.</summary>
    [LibraryImport("libc", SetLastError = true)]
    public static partial nint write(int fd, byte* buf, nuint len);

    /// <summary>The errno of the last failed call on this thread.</summary>
    public static int Errno => Marshal.GetLastPInvokeError();

    /// <summary>Registers <paramref name="fd"/> in the epoll set with the given events and a 64-bit tag.</summary>
    public static int EpollAdd(int epfd, int fd, uint events, ulong data) {
        byte* ev = stackalloc byte[16];
        *(uint*)ev = events;
        *(ulong*)(ev + EpollDataOffset) = data;
        return epoll_ctl(epfd, EPOLL_CTL_ADD, fd, ev);
    }

    /// <summary>Reads the flag word of event <paramref name="i"/> from an epoll_wait result buffer.</summary>
    public static uint EventFlags(byte* events, int i) => *(uint*)(events + (long)i * EpollEventSize);

    /// <summary>Reads the tag of event <paramref name="i"/> from an epoll_wait result buffer.</summary>
    public static ulong EventData(byte* events, int i) => *(ulong*)(events + (long)i * EpollEventSize + EpollDataOffset);

    /// <summary>Sets an integer socket option and returns false instead of throwing when the call fails.</summary>
    public static bool TrySetOption(int fd, int level, int name, int value) =>
        setsockopt(fd, level, name, &value, sizeof(int)) == 0;

    /// <summary>Sets an integer socket option, throwing if the call fails.</summary>
    public static void SetOption(int fd, int level, int name, int value) {
        if (setsockopt(fd, level, name, &value, sizeof(int)) != 0) {
            throw new InvalidOperationException($"setsockopt({level},{name}) failed, errno {Errno}");
        }
    }
}
