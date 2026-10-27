using System.Net;

namespace Conduit.Http;

/// <summary>
/// The HTTP server: <c>HttpLoops</c> event loops, each with its own SO_REUSEPORT listener, so the kernel spreads new
/// connections across the loops and no accept lock is shared.
/// </summary>
public sealed class HttpServer : IDisposable {
    /// <summary>Backlog passed to listen(2).</summary>
    private const int Backlog = 65535;
    /// <summary>Descriptors kept from clients for the process itself: the runtime, Postgres connections and the console.</summary>
    private const int ReservedFds = 256;
    /// <summary>The started loops, one per listener.</summary>
    private readonly List<HttpLoop> _loops;

    /// <summary>Wraps loops that are already started.</summary>
    private HttpServer(List<HttpLoop> loops) => _loops = loops;

    /// <summary>
    /// Binds Host:Port once per loop and starts the loops. Throws if the address cannot be bound.
    /// Accepted sockets are non-blocking and get TCP_NODELAY; a failure to set it is counted, not fatal.
    /// </summary>
    public static HttpServer Start(Settings settings, IRequestHandler handler, Stats? stats = null) {
        stats ??= new Stats([]);
        int fdCeiling = FdCeiling();
        List<HttpLoop> loops = [];
        try {
            for (int i = 0; i < settings.HttpLoops; i++) {
                int listener = Listen(settings.Host, settings.Port);
                try {
                    loops.Add(new HttpLoop(handler, stats, listener, fdCeiling));
                } catch {
                    Libc.close(listener);
                    throw;
                }
            }
        } catch {
            foreach (HttpLoop l in loops) {
                l.Dispose();
            }

            throw;
        }
        foreach (HttpLoop l in loops) {
            l.Start();
        }

        return new HttpServer(loops);
    }

    /// <summary>
    /// The first descriptor number a client socket may not have, for a soft descriptor limit of <paramref name="soft"/>:
    /// the limit less <see cref="ReservedFds"/>, but never below half of it. Linux hands out the lowest free number, so
    /// this caps the open client sockets.
    /// </summary>
    internal static int CeilingFor(ulong soft) {
        long limit = (long)Math.Min(soft, int.MaxValue);
        return (int)Math.Max(limit - ReservedFds, limit / 2);
    }

    /// <summary>The ceiling for this process's soft RLIMIT_NOFILE, or none if the limit cannot be read.</summary>
    private static unsafe int FdCeiling() {
        ulong* limits = stackalloc ulong[2];
        return Libc.getrlimit(Libc.RLIMIT_NOFILE, limits) == 0 ? CeilingFor(limits[0]) : int.MaxValue;
    }

    /// <summary>Stops every loop and closes all connections.</summary>
    public void Dispose() {
        foreach (HttpLoop l in _loops) {
            l.Dispose();
        }
    }

    /// <summary>
    /// Opens a non-blocking IPv4 listener with SO_REUSEADDR and SO_REUSEPORT, bound to <paramref name="host"/>:<paramref name="port"/>.
    /// Returns its descriptor. Throws, after closing the socket, if any step fails or the host is not an IPv4 address.
    /// </summary>
    private static unsafe int Listen(string host, int port) {
        if (!IPAddress.TryParse(host, out IPAddress? ip) || ip.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork) {
            throw new InvalidOperationException($"HOST '{host}' is not an IPv4 address");
        }

        int fd = Libc.socket(Libc.AF_INET, Libc.SOCK_STREAM | Libc.SOCK_NONBLOCK | Libc.SOCK_CLOEXEC, 0);
        if (fd < 0) {
            throw new InvalidOperationException($"socket failed, errno {Libc.Errno}");
        }

        try {
            Libc.SetOption(fd, Libc.SOL_SOCKET, Libc.SO_REUSEADDR, 1);
            Libc.SetOption(fd, Libc.SOL_SOCKET, Libc.SO_REUSEPORT, 1);

            byte* addr = stackalloc byte[16];
            new Span<byte>(addr, 16).Clear();
            addr[0] = Libc.AF_INET;                 // sin_family, little endian
            addr[2] = (byte)(port >> 8);            // sin_port, network order
            addr[3] = (byte)port;
            ip.GetAddressBytes().CopyTo(new Span<byte>(addr + 4, 4));

            if (Libc.bind(fd, addr, 16) != 0) {
                throw new InvalidOperationException($"bind {host}:{port} failed, errno {Libc.Errno}");
            }

            if (Libc.listen(fd, Backlog) != 0) {
                throw new InvalidOperationException($"listen failed, errno {Libc.Errno}");
            }

            return fd;
        } catch {
            Libc.close(fd);
            throw;
        }
    }
}
