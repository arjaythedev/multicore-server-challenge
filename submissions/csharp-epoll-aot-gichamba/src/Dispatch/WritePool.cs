using Conduit.Pg;

namespace Conduit.Dispatch;

/// <summary>
/// Opens the write connections of a <see cref="WriteDispatcher"/> and keeps them open. One thread per
/// connection connects as application_name "write", prepares the statements, attaches the connection and sleeps; when the
/// connection breaks it connects again after a short pause, so a lost connection is replaced.
/// </summary>
public sealed class WritePool {
    /// <summary>Pause in milliseconds before a failed or lost connection is opened again.</summary>
    private const int RetryMs = 1000;

    /// <summary>Session settings of every write connection.</summary>
    private static readonly KeyValuePair<string, string>[] Session =
    [
        new("plan_cache_mode", "force_generic_plan"),
        new("jit", "off"),
        new("max_parallel_workers_per_gather", "0"),
    ];

    /// <summary>Where and how to connect.</summary>
    private readonly PgConnectionString _cs;
    /// <summary>The dispatcher that gets each working connection.</summary>
    private readonly WriteDispatcher _dispatcher;
    /// <summary>Number of connections to keep open.</summary>
    private readonly int _connections;
    /// <summary>The statements prepared on every connection: the transaction frame first, then the writes' own, without duplicate names.</summary>
    private readonly WriteStatement[] _statements;

    /// <summary>
    /// Creates the pool; nothing connects until <see cref="Start"/>. <paramref name="statements"/> are prepared on every
    /// connection next to the transaction frame statements of <see cref="WriteBatch"/>.
    /// </summary>
    public WritePool(PgConnectionString cs, WriteDispatcher dispatcher, int connections, IEnumerable<WriteStatement> statements) {
        _cs = cs;
        _dispatcher = dispatcher;
        _connections = connections;
        _statements = [.. WriteBatch.FrameStatements.Concat(statements).DistinctBy(s => s.Name)];
    }

    /// <summary>Starts one connector thread per connection.</summary>
    public void Start() {
        for (int i = 0; i < _connections; i++) {
            int slot = i;
            new Thread(() => Run(slot)) { IsBackground = true, Name = "pg-write-connect-" + slot }.Start();
        }
    }

    /// <summary>The loop of one connector thread: connect, prepare, attach, wait until the connection breaks, pause, repeat. A failed attempt is counted as a write error.</summary>
    private void Run(int slot) {
        using SemaphoreSlim broken = new(0);
        while (true) {
            PgConnection? conn = null;
            try {
                conn = PgConnection.Connect(_cs, "write", Session);
                foreach (WriteStatement s in _statements) {
                    conn.Prepare(s.Name, s.Sql, s.ParamOids);
                }

                PgLink link = new(conn);
                conn.Broken += (_, lost, ex) => {
                    _dispatcher.LinkBroken(slot, link, lost, ex);
                    broken.Release();
                };
                _dispatcher.SetLink(slot, link);
            } catch (Exception ex) {
                _dispatcher.Stats?.RecordWriteError($"write connection {slot}: {ex.Message}");
                conn?.Dispose();
                Thread.Sleep(RetryMs);
                continue;
            }
            broken.Wait();
            Thread.Sleep(RetryMs);
        }
    }
}
