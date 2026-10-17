using Npgsql;
using NpgsqlTypes;

namespace Conduit;

/// <summary>Npgsql data source: one pool, opened at startup, prepared statements kept per connection, one batch per request.</summary>
static class Db
{
    public static NpgsqlDataSource Ds = null!;

    public static async Task Init(string databaseUrl, int poolSize)
    {
        var u = new Uri(databaseUrl);
        string[] ui = u.UserInfo.Split(':', 2);
        var b = new NpgsqlConnectionStringBuilder
        {
            Host = u.Host,
            Port = u.Port > 0 ? u.Port : 5432,
            Database = Uri.UnescapeDataString(u.AbsolutePath.TrimStart('/')),
            Username = Uri.UnescapeDataString(ui[0]),
            Password = ui.Length > 1 ? Uri.UnescapeDataString(ui[1]) : null,
            MinPoolSize = poolSize,
            MaxPoolSize = poolSize,
            ConnectionLifetime = 0,
            NoResetOnClose = true,
            // Many requests share each connection: commands from concurrent requests are pipelined onto a few connections instead of each
            // request holding one, so Postgres runs a few busy backends instead of many mostly idle ones (20% less Postgres CPU per request).
            Multiplexing = true,
            SslMode = SslMode.Disable,
            GssEncryptionMode = GssEncryptionMode.Disable,
            Enlist = false,
            MaxAutoPrepare = 512,
            AutoPrepareMinUsages = 1,
            Timeout = 30,
            CommandTimeout = 30,
            // Session-level settings only (rule 2): generic plans (every statement here is plan-safe with them), no JIT, no parallel query.
            Options = Environment.GetEnvironmentVariable("PG_SESSION_OPTIONS")
                      ?? "-c plan_cache_mode=force_generic_plan -c jit=off -c max_parallel_workers_per_gather=0",
        };
        Ds = new NpgsqlDataSourceBuilder(b.ConnectionString).Build();

        // Wait for Postgres: the box starts it alongside the server, and the health check must not pass before queries work.
        for (int attempt = 0; ; attempt++)
        {
            try
            {
                await Ds.CreateCommand("SELECT 1").ExecuteScalarAsync();
                return;
            }
            catch (Exception) when (attempt < 30)
            {
                await Task.Delay(1000);
            }
        }
    }

    // ---- parameters (always typed: a NULL never costs a describe round trip, and generic plans get exact types) ----

    public static NpgsqlParameter L(long v) => new NpgsqlParameter<long> { TypedValue = v, NpgsqlDbType = NpgsqlDbType.Bigint };

    public static NpgsqlParameter S(string v) => new NpgsqlParameter<string> { TypedValue = v, NpgsqlDbType = NpgsqlDbType.Text };

    public static NpgsqlParameter NS(string? v) => new NpgsqlParameter { NpgsqlDbType = NpgsqlDbType.Text, Value = (object?)v ?? DBNull.Value };

    public static NpgsqlParameter TextArray(string[] v) => new NpgsqlParameter<string[]> { TypedValue = v, NpgsqlDbType = NpgsqlDbType.Array | NpgsqlDbType.Text };

    public static NpgsqlBatch Batch() => Ds.CreateBatch();

    public static NpgsqlBatch Add(this NpgsqlBatch batch, string sql, params NpgsqlParameter[] ps)
    {
        var c = new NpgsqlBatchCommand(sql);
        foreach (var p in ps) c.Parameters.Add(p);
        batch.BatchCommands.Add(c);
        return batch;
    }
}
