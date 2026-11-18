using BenchmarkDotNet.Attributes;
using Npgsql;

namespace Conduit.Benchmarks;

/// <summary>
/// The reference SQL from Sql.cs against a real Postgres: one query at a time, so this is the latency of the
/// statement plus the driver (plan, run, stream the rows), the thing to watch when you change SQL or Npgsql settings.
/// Needs a database: see Benchmarks/README.md (BENCH_DATABASE_URL, default conduit_bench on port 5433).
/// </summary>
[MemoryDiagnoser]
public class QueryBenchmarks
{
    /// <summary>0 = Npgsql's default (plain statements); 20 = automatic prepared statements, so Postgres skips parse and plan.</summary>
    [Params(0, 20)]
    public int MaxAutoPrepare { get; set; }

    private NpgsqlDataSource _db = null!;
    private long _viewer, _feedViewer, _commentedArticle;
    private string _tag = "", _author = "", _favorited = "", _slug = "";

    [GlobalSetup]
    public async Task Setup()
    {
        var url = Environment.GetEnvironmentVariable("BENCH_DATABASE_URL")
                  ?? "postgres://conduit:conduit@127.0.0.1:5433/conduit_bench";
        var u = new Uri(url);
        var userInfo = u.UserInfo.Split(':', 2);
        _db = NpgsqlDataSource.Create(new NpgsqlConnectionStringBuilder
        {
            Host = u.Host,
            Port = u.Port > 0 ? u.Port : 5432,
            Username = Uri.UnescapeDataString(userInfo[0]),
            Password = userInfo.Length > 1 ? Uri.UnescapeDataString(userInfo[1]) : null,
            Database = u.AbsolutePath.TrimStart('/'),
            MaxPoolSize = 16,
            SslMode = SslMode.Disable,
            MaxAutoPrepare = MaxAutoPrepare,
        }.ConnectionString);

        try
        {
            // Pick real, busy values from the seed so every query returns rows.
            _tag = (string)await Scalar("SELECT t.name FROM tags t JOIN article_tags at ON at.tag_id = t.id GROUP BY t.name ORDER BY count(*) DESC LIMIT 1");
            _author = (string)await Scalar("SELECT u.username FROM articles a JOIN users u ON u.id = a.author_id GROUP BY u.username ORDER BY count(*) DESC LIMIT 1");
            _favorited = (string)await Scalar("SELECT u.username FROM favorites f JOIN users u ON u.id = f.user_id GROUP BY u.id, u.username ORDER BY count(*) DESC LIMIT 1");
            _viewer = (long)await Scalar("SELECT f.user_id FROM favorites f GROUP BY f.user_id ORDER BY count(*) DESC LIMIT 1");
            _feedViewer = (long)await Scalar("SELECT follower_id FROM follows GROUP BY follower_id ORDER BY count(*) DESC LIMIT 1");
            _commentedArticle = (long)await Scalar("SELECT article_id FROM comments GROUP BY article_id ORDER BY count(*) DESC LIMIT 1");
            _slug = (string)await Scalar($"SELECT slug FROM articles WHERE id = {_commentedArticle}");
        }
        catch (NpgsqlException e)
        {
            throw new InvalidOperationException(
                $"Cannot use the benchmark database ({url}). Create it with: psql -d postgres -c 'CREATE DATABASE conduit_bench TEMPLATE conduit_dev' " +
                "(PGHOST=127.0.0.1 PGPORT=5433 PGUSER=postgres PGPASSWORD=postgres), or point BENCH_DATABASE_URL at another copy of the seed.", e);
        }
    }

    [GlobalCleanup]
    public void Cleanup() => _db.Dispose();

    private async Task<object> Scalar(string sql)
    {
        await using var cmd = _db.CreateCommand(sql);
        return (await cmd.ExecuteScalarAsync())!;
    }

    /// <summary>Runs a list or article query ($1 viewer, $2 limit or key, $3 offset, $4 filter) and reads the slug of every row.</summary>
    private async Task<int> Rows(string sql, long viewer, long second, long? third = null, string? filter = null)
    {
        await using var cmd = _db.CreateCommand(sql);
        cmd.AddInt8(viewer);
        cmd.AddInt8(second);
        if (third is { } t) cmd.AddInt8(t);
        if (filter != null) cmd.AddText(filter);
        await using var r = await cmd.ExecuteReaderAsync();
        var n = 0;
        while (await r.ReadAsync()) n += r.GetString(1).Length;
        return n;
    }

    private async Task<long> Count(string sql, string? text = null, long? viewer = null)
    {
        await using var cmd = _db.CreateCommand(sql);
        if (text != null) cmd.AddText(text);
        if (viewer is { } v) cmd.AddInt8(v);
        return (long)(await cmd.ExecuteScalarAsync())!;
    }

    // ---------- GET /api/articles: a page, and the capped count that goes with it ----------

    [Benchmark] public Task<int> List_Page() => Rows(Sql.ListAll, _viewer, 20, 0);
    [Benchmark] public Task<long> List_Count() => Count(Sql.CountAll);
    [Benchmark] public Task<int> List_ByTag() => Rows(Sql.ListByTag, _viewer, 20, 0, _tag);
    [Benchmark] public Task<int> List_ByAuthor() => Rows(Sql.ListByAuthor, _viewer, 20, 0, _author);
    [Benchmark] public Task<int> List_ByFavorited() => Rows(Sql.ListByFavorite, _viewer, 20, 0, _favorited);
    [Benchmark] public Task<long> List_CountByTag() => Count(Sql.CountByTag, _tag);

    // ---------- the rest of the reads ----------

    [Benchmark] public Task<int> Feed_Page() => Rows(Sql.ListFeed, _feedViewer, 20, 0);
    [Benchmark] public Task<long> Feed_Count() => Count(Sql.CountFeed, viewer: _feedViewer);

    /// <summary>GET /api/articles/{slug}: $1 viewer, $2 slug.</summary>
    [Benchmark]
    public async Task<int> Article_BySlug()
    {
        await using var cmd = _db.CreateCommand(Sql.ArticleBySlug);
        cmd.AddInt8(_viewer);
        cmd.AddText(_slug);
        await using var r = await cmd.ExecuteReaderAsync();
        return await r.ReadAsync() ? r.GetString(1).Length : 0;
    }

    /// <summary>GET /api/articles/{slug}/comments: the newest 100 of the busiest article.</summary>
    [Benchmark] public Task<int> Comments() => RowsAt(Sql.ListComments, _viewer, _commentedArticle);

    private async Task<int> RowsAt(string sql, long viewer, long articleId)
    {
        await using var cmd = _db.CreateCommand(sql);
        cmd.AddInt8(viewer);
        cmd.AddInt8(articleId);
        await using var r = await cmd.ExecuteReaderAsync();
        var n = 0;
        while (await r.ReadAsync()) n += r.GetString(1).Length;
        return n;
    }

    [Benchmark]
    public async Task<int> Tags()
    {
        await using var cmd = _db.CreateCommand("SELECT name FROM tags ORDER BY name");
        await using var r = await cmd.ExecuteReaderAsync();
        var n = 0;
        while (await r.ReadAsync()) n += r.GetString(0).Length;
        return n;
    }
}
