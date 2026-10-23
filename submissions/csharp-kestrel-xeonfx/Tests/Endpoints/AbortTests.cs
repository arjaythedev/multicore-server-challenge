using System;
using System.IO;
using System.IO.Pipelines;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Conduit.Security;
using Microsoft.AspNetCore.Http;
using Npgsql;
using Xunit;

// The timeouts turn a request that never completes into a failure instead of a hung run. Each request gets the
// abort token its client would have, not the test's.
#pragma warning disable xUnit1069, xUnit1051

namespace Conduit.Tests.Endpoints;

/// <summary>
/// A request whose client has gone by the time it is handled sends nothing to Postgres and reads no body, while
/// the other requests on the same reader go on. The tags table is locked by another transaction, so a
/// statement that did reach Postgres shows up waiting in pg_stat_activity.
/// </summary>
[Collection(ServerState.Collection)]
public sealed class AbortTests(AbortTests.Data data) : IClassFixture<AbortTests.Data>
{
    public sealed class Data : TestSchema
    {
        protected override Task Seed() => Exec("INSERT INTO tags (name) VALUES ('t')");
    }

    static async Task<int> Request(string method, string path, CancellationToken aborted, Stream? body = null)
    {
        var ctx = new DefaultHttpContext { RequestAborted = aborted };
        ctx.Request.Method = method;
        ctx.Request.Path = path;
        if (body is not null)
        {
            ctx.Request.Body = body;
            ctx.Request.Headers.Authorization = "Token " + Jwt.Issue(1);
        }
        ctx.Response.Body = new MemoryStream();
        await Router.Handle(ctx);
        return ctx.Response.StatusCode;
    }

    Task<long> Waiting() => data.Scalar<long>(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND query LIKE '%FROM tags%'");

    static CancellationToken Gone()
    {
        var cts = new CancellationTokenSource();
        cts.Cancel();
        return cts.Token;
    }

    [Fact(Timeout = 30_000)]
    public async Task AnAbortedReadNeverReachesPostgresAndTheOthersFinish()
    {
        TestSchema.Require();
        await using var conn = await data.Admin.OpenConnectionAsync();
        await using var tx = await conn.BeginTransactionAsync();
        await using (var lockTags = new NpgsqlCommand("LOCK TABLE tags IN ACCESS EXCLUSIVE MODE", conn, tx))
            await lockTags.ExecuteNonQueryAsync();

        // A live request reaches Postgres and waits there: the check below can see one.
        var live = Request("GET", "/api/tags", CancellationToken.None);
        for (var until = DateTime.UtcNow.AddSeconds(10); await Waiting() == 0; await Task.Delay(10))
            Assert.True(DateTime.UtcNow < until, "the live request never reached Postgres");

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Request("GET", "/api/tags", Gone()));
        await Task.Delay(300);
        Assert.Equal(1, await Waiting());

        await tx.RollbackAsync();
        Assert.Equal(200, await live);
        Assert.Equal(200, await Request("GET", "/api/tags", CancellationToken.None));
    }

    [Fact(Timeout = 30_000)]
    public async Task AnAbortedRequestStopsReadingItsBody()
    {
        TestSchema.Require();
        // a body that never arrives: without the abort token the parse would wait for it forever
        var never = new Pipe().Reader.AsStream();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Request("POST", "/api/articles", Gone(), never));

        // the same request with its client still there: the body is read and refused
        var body = new MemoryStream(Encoding.UTF8.GetBytes("""{"article":{}}"""));
        Assert.Equal(422, await Request("POST", "/api/articles", CancellationToken.None, body));
    }
}
