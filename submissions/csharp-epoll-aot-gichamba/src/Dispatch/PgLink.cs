using Conduit.Pg;

namespace Conduit.Dispatch;

/// <summary>An <see cref="IPgLink"/> over a real Postgres connection.</summary>
internal sealed class PgLink : IPgLink {
    /// <summary>The connection requests are sent on.</summary>
    private readonly PgConnection _conn;

    /// <summary>Wraps <paramref name="conn"/>.</summary>
    public PgLink(PgConnection conn) => _conn = conn;

    /// <inheritdoc />
    public void Send(PgRequest request) => _conn.Send(request);

    /// <inheritdoc />
    public void Abort(Exception reason) => _conn.Abort(reason);
}
