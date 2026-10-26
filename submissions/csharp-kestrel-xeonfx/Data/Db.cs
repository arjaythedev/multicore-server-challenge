using System;
using Npgsql;
using NpgsqlTypes;

namespace Conduit.Data;

public static class Db
{
    /// <summary>Every statement that writes goes through here, grouped into shared commits.</summary>
    public static Writer Writer = null!;

    /// <summary>Every statement that only reads goes through here, grouped into batches with one Sync.</summary>
    public static Reader Reader = null!;

    public static void Init(string databaseUrl, int readers, int writers)
    {
        var uri = new Uri(databaseUrl);
        string[] userInfo = uri.UserInfo.Split(':', 2);
        Init(new NpgsqlConnectionStringBuilder
        {
            Host = uri.Host,
            Port = uri.Port > 0 ? uri.Port : 5432,
            Database = Uri.UnescapeDataString(uri.AbsolutePath.TrimStart('/')),
            Username = Uri.UnescapeDataString(userInfo[0]),
            Password = userInfo.Length > 1 ? Uri.UnescapeDataString(userInfo[1]) : null,
            SslMode = SslMode.Disable,
        }, readers, writers);
    }

    /// <summary>
    /// The reader and the writer on <paramref name="csb"/>'s database (the tests pass theirs): <paramref name="readers"/>
    /// and <paramref name="writers"/> loops, each on a connection of its own. Requests never hold a connection, so
    /// Postgres runs few busy backends, and the reads queued while a loop is busy go out together.
    /// </summary>
    public static void Init(NpgsqlConnectionStringBuilder csb, int readers, int writers)
    {
        csb.Multiplexing = false;
        csb.MaxPoolSize = readers;
        csb.NoResetOnClose = true;
        csb.Enlist = false;
        Plan(csb);
        Reader = new Reader(NpgsqlDataSource.Create(csb.ConnectionString));
        Reader.Start(readers);
        Writer = new Writer(WriterSource(csb, writers, WriterLockTimeout));
        Writer.Start(writers);
    }

    /// <summary>
    /// How long a write waits for a row lock another transaction holds. Past it the statement fails (503) and only its
    /// own write fails; the rest of its group commits without it. The other writer loop's group holds locks for a
    /// commit's milliseconds, and deadlocks between the two are detected after 1 s (deadlock_timeout) and run again,
    /// so only a lock held by something else waits this long; without it the group would wait the 30 s statement timeout.
    /// </summary>
    public static readonly TimeSpan WriterLockTimeout = TimeSpan.FromSeconds(2);

    /// <summary>The writer loops' connections, from <paramref name="csb"/>'s settings: one per loop, with a lock timeout.</summary>
    public static NpgsqlDataSource WriterSource(NpgsqlConnectionStringBuilder csb, int writers, TimeSpan lockTimeout)
    {
        var w = new NpgsqlConnectionStringBuilder(csb.ConnectionString) { Multiplexing = false, MaxPoolSize = writers };
        w.Options = $"{w.Options} -c lock_timeout={(long)lockTimeout.TotalMilliseconds}ms".TrimStart();
        return NpgsqlDataSource.Create(w.ConnectionString);
    }

    /// <summary>How every connection prepares and plans statements; the list tests run under the same settings.</summary>
    public static void Plan(NpgsqlConnectionStringBuilder csb)
    {
        // Every statement is prepared once per connection (Parse/plan once, then only Bind/Execute).
        csb.MaxAutoPrepare = 64;
        csb.AutoPrepareMinUsages = 2;
        // Session settings. The reference queries take LIMIT/OFFSET as parameters, which makes Postgres's plan cache
        // keep choosing custom plans and re-plan every execution. Our statements are written so the generic plan is
        // the right plan, so it is planned once per connection. JIT and parallel workers never pay off for statements
        // this short. The statement timeout replaces Npgsql's client-side one (CommandTimeout 0), which costs a timer
        // per command.
        csb.CommandTimeout = 0;
        csb.Options = "-c plan_cache_mode=force_generic_plan -c jit=off -c max_parallel_workers_per_gather=0 -c statement_timeout=30s";
    }

    public static NpgsqlBatchCommand Command(string sql, params ReadOnlySpan<NpgsqlParameter> parameters)
    {
        var c = new NpgsqlBatchCommand(sql);
        foreach (var p in parameters) c.Parameters.Add(p);
        return c;
    }

    public static NpgsqlParameter<long> P(long v) => new() { TypedValue = v };
    public static NpgsqlParameter<string> P(string v) => new() { TypedValue = v };
    public static NpgsqlParameter<string[]> P(string[] v) => new() { TypedValue = v };
    public static NpgsqlParameter Text(string? v) => new() { NpgsqlDbType = NpgsqlDbType.Text, Value = (object?)v ?? DBNull.Value };
}
