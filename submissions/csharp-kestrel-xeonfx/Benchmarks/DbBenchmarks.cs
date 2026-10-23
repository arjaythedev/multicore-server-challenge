using System;
using System.Threading.Tasks;
using BenchmarkDotNet.Attributes;
using Conduit.Data;
using Npgsql;

namespace Conduit.Benchmarks;

/// <summary>
/// Ways to run a group of reads against the full seed (BENCH_DB): one command each on pooled connections, the same
/// multiplexed, one batch with one Sync and new commands (the read groups), and one batch reusing its commands. Each
/// operation is <see cref="Group"/> reads, alternating an article by slug and the global list's first page, so the
/// bytes per read are the operation's divided by the group. Times compare only within a method: one command per read
/// spreads a group over as many connections, which run in parallel on an idle server, while a batch runs on one; under
/// full load no core is idle and CPU per read decides.
/// </summary>
[MemoryDiagnoser]
public class DbBenchmarks
{
    [Params(1, 8, 32)] public int Group;
    [Params(true, false)] public bool Prepare;
    [Params(TextRead.Bytes, TextRead.String)] public TextRead Text;

    static readonly string Url = Environment.GetEnvironmentVariable("BENCH_DB") ?? "Host=127.0.0.1;Username=conduit;Password=conduit;Database=conduit";
    readonly string[] _slugs = new string[64];
    readonly byte[] _buf = new byte[64 * 1024];
    NpgsqlDataSource _pooled = null!, _multiplexed = null!;
    NpgsqlConnection _conn = null!;
    NpgsqlBatch _reused = null!;
    int _next;

    [GlobalSetup]
    public async Task Setup()
    {
        var csb = new NpgsqlConnectionStringBuilder(Url) { Multiplexing = false, MaxPoolSize = 64 };
        Db.Plan(csb);
        if (!Prepare) csb.MaxAutoPrepare = 0;
        _pooled = NpgsqlDataSource.Create(csb.ConnectionString);
        _multiplexed = NpgsqlDataSource.Create(new NpgsqlConnectionStringBuilder(csb.ConnectionString) { Multiplexing = true, MaxPoolSize = 16 }.ConnectionString);
        _conn = await _pooled.OpenConnectionAsync();
        await using (var cmd = new NpgsqlCommand("SELECT slug FROM articles ORDER BY id DESC LIMIT 64", _conn))
        await using (var r = await cmd.ExecuteReaderAsync())
            for (int i = 0; await r.ReadAsync(); i++) _slugs[i] = r.GetString(0);
        _reused = new NpgsqlBatch(_conn);
        for (int i = 0; i < Group; i++) _reused.BatchCommands.Add(NewBatchCommand(i));
        // the statements are prepared on every connection before the measured runs
        for (int i = 0; i < 4; i++) { await PerCommand(); await Multiplexed(); await BatchNew(); await BatchReused(); }
    }

    [GlobalCleanup]
    public async Task Cleanup()
    {
        await _reused.DisposeAsync();
        await _conn.DisposeAsync();
        await _pooled.DisposeAsync();
        await _multiplexed.DisposeAsync();
    }

    string Slug() => _slugs[_next++ & 63];

    NpgsqlBatchCommand NewBatchCommand(int i)
    {
        var c = new NpgsqlBatchCommand(i % 2 == 0 ? Sql.ArticleBySlug : Sql.List[0]);
        if (i % 2 == 0) { c.Parameters.Add(new NpgsqlParameter<long> { TypedValue = 2 }); c.Parameters.Add(new NpgsqlParameter<string> { TypedValue = Slug() }); }
        else { c.Parameters.Add(new NpgsqlParameter<long> { TypedValue = 2 }); c.Parameters.Add(new NpgsqlParameter<long> { TypedValue = 20 }); c.Parameters.Add(new NpgsqlParameter<long> { TypedValue = 0 }); }
        return c;
    }

    NpgsqlCommand NewCommand(NpgsqlDataSource source, int i)
    {
        var c = source.CreateCommand(i % 2 == 0 ? Sql.ArticleBySlug : Sql.List[0]);
        if (i % 2 == 0) { c.Parameters.Add(new NpgsqlParameter<long> { TypedValue = 2 }); c.Parameters.Add(new NpgsqlParameter<string> { TypedValue = Slug() }); }
        else { c.Parameters.Add(new NpgsqlParameter<long> { TypedValue = 2 }); c.Parameters.Add(new NpgsqlParameter<long> { TypedValue = 20 }); c.Parameters.Add(new NpgsqlParameter<long> { TypedValue = 0 }); }
        return c;
    }

    /// <summary>Reads every row of the current result set, text columns as the server would write them.</summary>
    async ValueTask<int> Consume(NpgsqlDataReader r)
    {
        int n = 0;
        while (await r.ReadAsync())
            for (int c = 0; c < r.FieldCount; c++)
            {
                if (r.IsDBNull(c)) continue;
                if (r.GetFieldType(c) == typeof(string))
                    n += Text == TextRead.Bytes ? (int)r.GetBytes(c, 0, _buf, 0, _buf.Length) : r.GetString(c).Length;
                else if (r.GetFieldType(c) == typeof(long)) n += (int)r.GetInt64(c);
                else if (r.GetFieldType(c) == typeof(int)) n += r.GetInt32(c);
                else if (r.GetFieldType(c) == typeof(bool)) n += r.GetBoolean(c) ? 1 : 0;
                else if (r.GetFieldType(c) == typeof(DateTime)) n += r.GetDateTime(c).Second;
                else if (r.GetFieldType(c) == typeof(byte[])) n += (int)r.GetBytes(c, 0, _buf, 0, _buf.Length);
                else n += r.GetValue(c).GetHashCode();
            }
        return n;
    }

    async Task<int> One(NpgsqlCommand cmd)
    {
        await using (cmd)
        await using (var r = await cmd.ExecuteReaderAsync())
            return await Consume(r);
    }

    /// <summary>The library's usual way: each read its own command and connection from the pool, all at once.</summary>
    [Benchmark(Baseline = true)]
    public async Task<int> PerCommand()
    {
        var tasks = new Task<int>[Group];
        for (int i = 0; i < Group; i++) tasks[i] = One(NewCommand(_pooled, i));
        int n = 0;
        foreach (var t in tasks) n += await t;
        return n;
    }

    /// <summary>Each read its own command; Npgsql's multiplexing coalesces them onto shared connections.</summary>
    [Benchmark]
    public async Task<int> Multiplexed()
    {
        var tasks = new Task<int>[Group];
        for (int i = 0; i < Group; i++) tasks[i] = One(NewCommand(_multiplexed, i));
        int n = 0;
        foreach (var t in tasks) n += await t;
        return n;
    }

    /// <summary>The read groups: one batch, one Sync, new commands each time.</summary>
    [Benchmark]
    public async Task<int> BatchNew()
    {
        await using var batch = new NpgsqlBatch(_conn);
        for (int i = 0; i < Group; i++) batch.BatchCommands.Add(NewBatchCommand(i));
        return await Drain(batch);
    }

    /// <summary>One batch, one Sync, its commands kept on their connection and only their values changed.</summary>
    [Benchmark]
    public async Task<int> BatchReused()
    {
        for (int i = 0; i < Group; i += 2) ((NpgsqlParameter<string>)_reused.BatchCommands[i].Parameters[1]).TypedValue = Slug();
        return await Drain(_reused);
    }

    async Task<int> Drain(NpgsqlBatch batch)
    {
        int n = 0;
        await using var r = await batch.ExecuteReaderAsync();
        do n += await Consume(r);
        while (await r.NextResultAsync());
        return n;
    }
}

public enum TextRead { Bytes, String }
