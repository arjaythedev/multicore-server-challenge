using Conduit.Http;

namespace Conduit.Dispatch;

/// <summary>The client end of a request, as the dispatcher sees it. A small interface so tests can fake it.</summary>
public interface IClient {
    /// <summary>True once the client is gone. The dispatchers then drop its waiting requests unsent.</summary>
    bool IsClosed { get; }

    /// <summary>Sends a complete HTTP response. Safe from any thread; a closed client drops the bytes.</summary>
    void Send(ReadOnlySpan<byte> response);
}

/// <summary>An <see cref="IClient"/> backed by an HTTP <see cref="Connection"/>.</summary>
public sealed class ConnectionClient : IClient {
    /// <summary>The HTTP connection that receives the response.</summary>
    private readonly Connection _conn;

    /// <summary>Wraps <paramref name="conn"/>.</summary>
    public ConnectionClient(Connection conn) => _conn = conn;

    /// <inheritdoc />
    public bool IsClosed => _conn.IsClosed;

    /// <inheritdoc />
    public void Send(ReadOnlySpan<byte> response) => _conn.Send(response);
}
