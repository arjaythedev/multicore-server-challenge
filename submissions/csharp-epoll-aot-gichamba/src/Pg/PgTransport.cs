using System.Net.Sockets;

namespace Conduit.Pg;

/// <summary>Blocking byte pipe to the server. Tests replace it with a fake.</summary>
public interface IPgTransport {
    /// <summary>Reads at least one byte into <paramref name="buffer"/>. Throws when the peer closes.</summary>
    int Read(Span<byte> buffer);

    /// <summary>Writes all of <paramref name="data"/>. Callers serialize writes.</summary>
    void Write(ReadOnlySpan<byte> data);

    /// <summary>Closes the pipe and wakes a blocked <see cref="Read"/>.</summary>
    void Close();
}

/// <summary>TCP transport with Nagle off.</summary>
internal sealed class SocketTransport : IPgTransport {
    /// <summary>The connected socket.</summary>
    private readonly Socket _socket;

    /// <summary>Wraps a connected socket. <see cref="Connect"/> is the way in.</summary>
    private SocketTransport(Socket socket) => _socket = socket;

    /// <summary>Connects to host and port.</summary>
    public static SocketTransport Connect(string host, int port) {
        Socket s = new(SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
        try {
            s.Connect(host, port);
        } catch {
            s.Dispose();
            throw;
        }
        return new SocketTransport(s);
    }

    /// <inheritdoc />
    public int Read(Span<byte> buffer) {
        int n = _socket.Receive(buffer);
        if (n == 0) {
            throw new IOException("connection closed by server");
        }

        return n;
    }

    /// <inheritdoc />
    public void Write(ReadOnlySpan<byte> data) {
        while (!data.IsEmpty) {
            int n = _socket.Send(data);
            data = data[n..];
        }
    }

    /// <inheritdoc />
    public void Close() {
        try {
            _socket.Shutdown(SocketShutdown.Both);
        } catch (Exception ex) when (ex is SocketException or ObjectDisposedException) {
            // Already disconnected or closed: Dispose below still frees the socket.
        }
        _socket.Dispose();
    }
}
