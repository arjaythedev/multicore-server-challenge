namespace Conduit.Tests;

/// <summary>
/// Tests that set or depend on the server's static state (the JWT key, Db's data sources and writer, the JsonOut
/// pool's counters) share this xUnit collection, so they run one at a time.
/// </summary>
public static class ServerState
{
    public const string Collection = "server state";
}
