using System;
using System.IO;
using System.Text.Json;
using System.Threading.Tasks;
using Conduit.Data;
using Conduit.Security;
using Microsoft.AspNetCore.Http;
using Npgsql;
using Xunit;

// The timeouts turn a request that never completes into a failure instead of a hung run. The requests take their
// client's abort token, which these tests leave unset.
#pragma warning disable xUnit1069, xUnit1051

namespace Conduit.Tests.Endpoints;

/// <summary>
/// Favorite and unfavorite through the router and the writer, against a toggle another transaction makes at the
/// same moment. The other transaction holds its change uncommitted until the server's statement is seen waiting
/// for it in pg_stat_activity, then commits: the interleaving is fixed, not left to timing. Each test uses its own
/// article.
/// </summary>
[Collection(ServerState.Collection)]
public sealed class FavoriteTests(FavoriteTests.Data data) : IClassFixture<FavoriteTests.Data>
{
    public sealed class Data : TestSchema
    {
        public long Viewer, Other;

        protected override async Task Seed()
        {
            await Exec("""
                INSERT INTO users (username, email, password_hash) VALUES ('viewer', 'viewer@x', 'h'), ('other', 'other@x', 'h'), ('author', 'author@x', 'h');
                INSERT INTO articles (slug, author_id, title, description, body)
                    SELECT 'a-' || i, u.id, 'title', 'description', 'body' FROM users u, generate_series(1, 10) i WHERE u.username = 'author';
                """);
            Viewer = await Scalar<long>("SELECT id FROM users WHERE username = 'viewer'");
            Other = await Scalar<long>("SELECT id FROM users WHERE username = 'other'");
        }
    }

    async Task<(int Status, bool Favorited, long Count)> Toggle(string slug, bool favorite)
    {
        var ctx = new DefaultHttpContext();
        ctx.Request.Method = favorite ? "POST" : "DELETE";
        ctx.Request.Path = $"/api/articles/{slug}/favorite";
        ctx.Request.Headers.Authorization = "Token " + Jwt.Issue(data.Viewer);
        var body = new MemoryStream();
        ctx.Response.Body = body;
        await Router.Handle(ctx);
        await ctx.Response.BodyWriter.FlushAsync();
        if (ctx.Response.StatusCode != 200) return (ctx.Response.StatusCode, false, -1);
        using var doc = JsonDocument.Parse(body.ToArray());
        var a = doc.RootElement.GetProperty("article");
        return (200, a.GetProperty("favorited").GetBoolean(), a.GetProperty("favoritesCount").GetInt64());
    }

    Task Favor(long user, string slug) =>
        data.Exec($"INSERT INTO favorites (user_id, article_id) SELECT {user}, id FROM articles WHERE slug = '{slug}'");

    Task<long> Favorites(string slug) =>
        data.Scalar<long>($"SELECT count(*) FROM favorites f JOIN articles a ON a.id = f.article_id WHERE a.slug = '{slug}'");

    /// <summary>Opens a transaction on its own connection and runs <paramref name="sql"/> in it, uncommitted.</summary>
    async Task<(NpgsqlConnection, NpgsqlTransaction)> Hold(string sql)
    {
        var conn = await data.Admin.OpenConnectionAsync();
        var tx = await conn.BeginTransactionAsync();
        await using var cmd = new NpgsqlCommand(sql, conn, tx);
        await cmd.ExecuteNonQueryAsync();
        return (conn, tx);
    }

    /// <summary>Returns once a statement matching <paramref name="like"/> waits on a lock in this database.</summary>
    async Task Blocked(string like)
    {
        for (var until = DateTime.UtcNow.AddSeconds(10); DateTime.UtcNow < until; await Task.Delay(10))
            if (await data.Scalar<long>($"SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND query LIKE '{like}'") > 0)
                return;
        throw new TimeoutException($"no statement like {like} waited on a lock");
    }

    [Fact(Timeout = 30_000)]
    public async Task AFavoriteThatWaitedForTheSameFavoriteCountsItOnce()
    {
        TestSchema.Require();
        var (conn, tx) = await Hold($"INSERT INTO favorites (user_id, article_id) SELECT {data.Viewer}, id FROM articles WHERE slug = 'a-1'");
        await using (conn)
        {
            var toggle = Toggle("a-1", true);
            await Blocked("%INSERT INTO favorites%");
            await tx.CommitAsync();
            Assert.Equal((200, true, 1L), await toggle);
        }
        Assert.Equal(1, await Favorites("a-1"));
    }

    [Fact(Timeout = 30_000)]
    public async Task AnUnfavoriteThatWaitedForTheSameUnfavoriteCountsNone()
    {
        TestSchema.Require();
        await Favor(data.Viewer, "a-2");
        var (conn, tx) = await Hold($"DELETE FROM favorites WHERE user_id = {data.Viewer} AND article_id = (SELECT id FROM articles WHERE slug = 'a-2')");
        await using (conn)
        {
            var toggle = Toggle("a-2", false);
            await Blocked("%DELETE FROM favorites%");
            await tx.CommitAsync();
            Assert.Equal((200, false, 0L), await toggle);
        }
        Assert.Equal(0, await Favorites("a-2"));
    }

    [Fact(Timeout = 30_000)]
    public async Task AFavoriteThatReplacesOneRemovedMeanwhileCountsItOnce()
    {
        TestSchema.Require();
        await Favor(data.Viewer, "a-3");
        await Favor(data.Other, "a-3");
        // The server's insert waits for the delete; once it commits, the insert goes in. The snapshot still holds
        // the removed row, so counting the inserted row on top of the snapshot's count would say 3.
        var (conn, tx) = await Hold($"DELETE FROM favorites WHERE user_id = {data.Viewer} AND article_id = (SELECT id FROM articles WHERE slug = 'a-3')");
        await using (conn)
        {
            var toggle = Toggle("a-3", true);
            await Blocked("%INSERT INTO favorites%");
            await tx.CommitAsync();
            Assert.Equal((200, true, 2L), await toggle);
        }
        Assert.Equal(2, await Favorites("a-3"));
    }

    [Fact(Timeout = 30_000)]
    public async Task AFavoriteAfterTheOtherTransactionRolledBackInsertsItsOwn()
    {
        TestSchema.Require();
        await Favor(data.Other, "a-4");
        var (conn, tx) = await Hold($"INSERT INTO favorites (user_id, article_id) SELECT {data.Viewer}, id FROM articles WHERE slug = 'a-4'");
        await using (conn)
        {
            var toggle = Toggle("a-4", true);
            await Blocked("%INSERT INTO favorites%");
            await tx.RollbackAsync();
            Assert.Equal((200, true, 2L), await toggle);
        }
        Assert.Equal(2, await Favorites("a-4"));
    }

    [Fact(Timeout = 30_000)]
    public async Task TogglesRepeatedInOneGroupAgreeWithTheRows()
    {
        TestSchema.Require();
        await Favor(data.Other, "a-5");
        var running = Db.Writer;
        // not started yet, so all four writes queue and go into its first group, one transaction
        var writer = new Writer(data.WriterSource());
        Db.Writer = writer;
        try
        {
            var toggles = new[] { Toggle("a-5", true), Toggle("a-5", true), Toggle("a-5", false), Toggle("a-5", false) };
            writer.Start(1);
            Assert.Equal([(200, true, 2L), (200, true, 2L), (200, false, 1L), (200, false, 1L)], await Task.WhenAll(toggles));
        }
        finally
        {
            Db.Writer = running;
            writer.Complete();
        }
        Assert.Equal(1, await Favorites("a-5"));
    }
}
