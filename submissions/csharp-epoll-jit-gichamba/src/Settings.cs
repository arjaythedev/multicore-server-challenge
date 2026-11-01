namespace Conduit;

/// <summary>
/// Every runtime setting, read once at startup from the environment by <see cref="Config.Load"/>. The box sets
/// DATABASE_URL, JWT_SECRET, HOST and PORT. The rest are tuning values whose defaults are the measured configuration;
/// set one in the environment only to experiment.
/// </summary>
public sealed record Settings {
    /// <summary>Postgres URL (DATABASE_URL), required. <see cref="Pg.PgConnectionString.Parse"/> reads it.</summary>
    public required string DatabaseUrl { get; init; }
    /// <summary>Secret behind the JWT signature (JWT_SECRET), required. Its UTF-8 bytes are the signing key.</summary>
    public required string JwtSecret { get; init; }
    /// <summary>IPv4 address the HTTP listeners bind to (HOST).</summary>
    public string Host { get; init; } = "0.0.0.0";
    /// <summary>TCP port of the HTTP listeners (PORT), 1 to 65535.</summary>
    public int Port { get; init; } = 80;

    /// <summary>Number of HTTP event loops (HTTP_LOOPS, 1 to 64). Each has its own listening socket on the same port.</summary>
    public int HttpLoops { get; init; } = 2;

    /// <summary>Number of read connections to Postgres (PG_READ, 1 to 95).</summary>
    public int PgRead { get; init; } = 8;
    /// <summary>Number of write connections to Postgres (PG_WRITE, 1 to 95).</summary>
    public int PgWrite { get; init; } = 2;
    /// <summary>Most read batches in flight on one read connection (PG_DEPTH, 1 to 64).</summary>
    public int PgDepth { get; init; } = 1;
    /// <summary>Most requests in one read batch (BATCH_MAX, 1 to 4096).</summary>
    public int BatchMax { get; init; } = 2048;
    /// <summary>
    /// How long a family's oldest read may wait for more requests to join its batch (GATHER_MS, 0 to 1000 ms). A full
    /// batch goes sooner; 0 sends at once. A lone request waits the whole window.
    /// </summary>
    public int GatherMs { get; init; } = 20;

    /// <summary>Passwords hashed together in one bcrypt call (BCRYPT_LANES, 1 to 16). The service caps it at 8, and drops to 1 if its self-test fails.</summary>
    public int BcryptLanes { get; init; } = 4;
    /// <summary>Number of bcrypt worker threads (BCRYPT_THREADS, 1 to 64).</summary>
    public int BcryptThreads { get; init; } = 2;
    /// <summary>How long the oldest queued password waits for a full set of lanes (BCRYPT_WAIT_MS, 0 to 60000 ms).</summary>
    public int BcryptWaitMs { get; init; } = 150;

    /// <summary>Seconds between stats lines on stderr (STATS_SECONDS, 1 to 3600).</summary>
    public int StatsSeconds { get; init; } = 10;
}
