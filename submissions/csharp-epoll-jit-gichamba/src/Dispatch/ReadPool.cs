using Conduit.Pg;

namespace Conduit.Dispatch;

/// <summary>
/// Opens the read connections of a <see cref="ReadDispatcher"/> and keeps them open. One thread per
/// connection connects, prepares the statements, attaches the connection and sleeps; when the connection breaks it
/// connects again after a short pause. The HTTP server can start before Postgres is up: requests wait in the queues.
/// </summary>
public sealed class ReadPool {
    /// <summary>Pause in milliseconds before a failed or lost connection is opened again.</summary>
    private const int RetryMs = 1000;

    /// <summary>Session settings of every read connection.</summary>
    internal static readonly KeyValuePair<string, string>[] Session =
    [
        new("plan_cache_mode", "force_generic_plan"),
        new("jit", "off"),
        new("max_parallel_workers_per_gather", "0"),
        // A generic plan's Memoize rebuilds its cache on every execution; most keys in a batch are distinct anyway.
        new("enable_memoize", "off"),
    ];

    /// <summary>Where and how to connect.</summary>
    private readonly PgConnectionString _cs;
    /// <summary>The dispatcher that gets each working connection.</summary>
    private readonly ReadDispatcher _dispatcher;
    /// <summary>Number of connections to keep open.</summary>
    private readonly int _connections;
    /// <summary>The statements every connection prepares: each family's.</summary>
    private readonly (string Name, string Sql, uint[] Oids)[] _statements;

    /// <summary>Creates the pool of <paramref name="connections"/> connections; nothing connects until <see cref="Start"/>.</summary>
    public ReadPool(PgConnectionString cs, ReadDispatcher dispatcher, int connections, IEnumerable<ReadFamily> families) {
        _cs = cs;
        _dispatcher = dispatcher;
        _connections = connections;
        _statements = [.. families.SelectMany(f => f.Statements)];
    }

    /// <summary>Starts one connector thread per connection.</summary>
    public void Start() {
        for (int i = 0; i < _connections; i++) {
            int slot = i;
            new Thread(() => Run(slot)) { IsBackground = true, Name = "pg-connect-" + slot }.Start();
        }
    }

    /// <summary>The loop of one connector thread: connect, prepare, attach, wait until the connection breaks, pause, repeat. A failed attempt is counted as a read error.</summary>
    private void Run(int slot) {
        using SemaphoreSlim broken = new(0);
        while (true) {
            PgConnection? conn = null;
            try {
                conn = PgConnection.Connect(_cs, "read", Session);
                foreach ((string Name, string Sql, uint[] Oids) s in _statements) {
                    conn.Prepare(s.Name, s.Sql, s.Oids);
                }

                PgLink link = new(conn);
                conn.Broken += (_, lost, ex) => {
                    _dispatcher.LinkBroken(slot, link, lost, ex);
                    broken.Release();
                };
                _dispatcher.SetLink(slot, link);
            } catch (Exception ex) {
                _dispatcher.Stats?.RecordReadError($"read connection {slot}: {ex.Message}");
                conn?.Dispose();
                Thread.Sleep(RetryMs);
                continue;
            }
            broken.Wait();
            Thread.Sleep(RetryMs);
        }
    }
}
