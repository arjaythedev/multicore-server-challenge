using System;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Conduit.Data;
using Npgsql;
using Xunit;

// The timeouts turn a read that never completes into a failure instead of a hung run. A read's token is its client's
// abort, which the tests that need one pass themselves.
#pragma warning disable xUnit1069, xUnit1051

namespace Conduit.Tests.Data;

/// <summary>
/// Read groups against a real Postgres (CONDUIT_TEST_DB): reads queued together run as one batch with one Sync, each
/// gets its own rows, and a failure stays with its own read.
/// </summary>
public sealed class ReaderTests : IAsyncDisposable
{
    static readonly string? ConnectionString = Environment.GetEnvironmentVariable("CONDUIT_TEST_DB");
    NpgsqlDataSource? _admin;
    Reader? _reader;

    /// <summary>A reader whose loops are not started yet, so reads queued now share its first group.</summary>
    Reader NewReader()
    {
        Assert.SkipWhen(ConnectionString is null, "CONDUIT_TEST_DB is not set");
        var csb = new NpgsqlConnectionStringBuilder(ConnectionString) { Multiplexing = false };
        Db.Plan(csb);
        _admin = NpgsqlDataSource.Create(ConnectionString!);
        return _reader = new Reader(NpgsqlDataSource.Create(csb.ConnectionString));
    }

    static NpgsqlBatchCommand Sql(string sql, params long[] args) => Db.Command(sql, [.. args.Select(a => (NpgsqlParameter)Db.P(a))]);

    static readonly Func<NpgsqlDataReader, ValueTask<long>> One = static async r =>
    {
        Assert.True(await r.ReadAsync());
        return r.GetInt64(0);
    };

    static Task<long> Read(Reader reader, string sql, params long[] args) => reader.Run(Sql(sql, args), One, CancellationToken.None);

    [Fact(Timeout = 30_000)]
    public async Task ReadsQueuedTogetherRunInOneTransactionAndEachGetsItsOwnRow()
    {
        var reader = NewReader();
        var values = Enumerable.Range(0, 10).Select(i => Read(reader, "SELECT $1::bigint * 10", i)).ToArray();
        // statements of one implicit transaction (one Sync) see the same transaction id
        var txids = Enumerable.Range(0, 5).Select(_ => Read(reader, "SELECT txid_current()")).ToArray();
        reader.Start(1);

        Assert.Equal(Enumerable.Range(0, 10).Select(i => i * 10L), await Task.WhenAll(values));
        Assert.Single((await Task.WhenAll(txids)).Distinct());
    }

    [Fact(Timeout = 30_000)]
    public async Task AFailingReadFailsAloneAndTheReadsAfterItRunAgain()
    {
        var reader = NewReader();
        var tasks = new[] { 1L, 0, 2, 5 }.Select(d => Read(reader, "SELECT 10 / $1::bigint", d)).ToArray();
        reader.Start(1);

        Assert.Equal(10, await tasks[0]);
        var e = await Assert.ThrowsAsync<PostgresException>(() => tasks[1]);
        Assert.Equal(PostgresErrorCodes.DivisionByZero, e.SqlState);
        Assert.Equal(5, await tasks[2]);
        Assert.Equal(2, await tasks[3]);
    }

    [Fact(Timeout = 30_000)]
    public async Task AStatementFailingAfterTheRowItsReadTookFailsThatReadAndNoOther()
    {
        var reader = NewReader();
        // rows 1 and 2 go out before row 3 divides by zero; the handler takes only the first row
        const string FailsOnRow3 = "SELECT 10 / (3 - g) FROM generate_series(1, 5) g";
        var failing = Read(reader, FailsOnRow3);
        var next = Read(reader, "SELECT 7");
        var last = Read(reader, FailsOnRow3); // the group's last statement: its error comes at the batch's end
        reader.Start(1);

        Assert.Equal(PostgresErrorCodes.DivisionByZero, (await Assert.ThrowsAsync<PostgresException>(() => failing)).SqlState);
        Assert.Equal(7, await next);
        Assert.Equal(PostgresErrorCodes.DivisionByZero, (await Assert.ThrowsAsync<PostgresException>(() => last)).SqlState);
        long pid = await Read(reader, "SELECT pg_backend_pid()");
        Assert.Equal(pid, await Read(reader, "SELECT pg_backend_pid()")); // the loop kept its connection
    }

    [Fact(Timeout = 30_000)]
    public async Task AReadWhoseClientLeftIsDroppedWithoutRunning()
    {
        var reader = NewReader();
        // run, these would fail with a division by zero
        var gone = reader.Run(Sql("SELECT 1 / 0"), One, new CancellationToken(canceled: true));
        using var leaves = new CancellationTokenSource();
        var leaving = reader.Run(Sql("SELECT 1 / 0"), One, leaves.Token);
        var staying = Read(reader, "SELECT 7");
        leaves.Cancel(); // after it queued, before a loop takes it
        reader.Start(1);

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => gone);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => leaving);
        Assert.Equal(7, await staying);
        Assert.Equal(0, reader.Queued);
    }

    [Fact(Timeout = 30_000)]
    public async Task ABugInOneReadsHandlerFailsOnlyThatRead()
    {
        var reader = NewReader();
        var before = Read(reader, "SELECT 1");
        var buggy = reader.Run<long>(Sql("SELECT 2"), static _ => throw new InvalidOperationException("bug"), CancellationToken.None);
        var after = Read(reader, "SELECT 3");
        reader.Start(1);

        Assert.Equal(1, await before);
        await Assert.ThrowsAsync<InvalidOperationException>(() => buggy);
        Assert.Equal(3, await after);
    }

    [Fact(Timeout = 30_000)]
    public async Task ABrokenConnectionFailsItsReadsAndTheNextGroupReconnects()
    {
        var reader = NewReader();
        reader.Start(1);
        long pid = await Read(reader, "SELECT pg_backend_pid()");
        var slow = Read(reader, "SELECT 1 FROM pg_sleep(5)");
        await Task.Delay(300);
        await using (var cmd = _admin!.CreateCommand($"SELECT pg_terminate_backend({pid})")) await cmd.ExecuteScalarAsync();

        await Assert.ThrowsAnyAsync<NpgsqlException>(() => slow);
        Assert.NotEqual(pid, await Read(reader, "SELECT pg_backend_pid()"));
    }

    [Fact(Timeout = 60_000)]
    public async Task ReadsPastTheQueueLimitAreRefusedAtOnce()
    {
        var reader = NewReader();
        var queued = Enumerable.Range(0, Reader.MaxQueued).Select(_ => Read(reader, "SELECT 1")).ToArray();
        var refused = Read(reader, "SELECT 1");

        Assert.True(refused.IsFaulted, "refused without waiting for a loop");
        await Assert.ThrowsAsync<ServerBusyException>(() => refused);
        reader.Start(2);
        Assert.All(await Task.WhenAll(queued), v => Assert.Equal(1, v));
        Assert.Equal(1, await Read(reader, "SELECT 1"));
    }

    [Fact(Timeout = 60_000)]
    public async Task ConcurrentReadsFromManyRequestsEachGetTheirOwnAnswer()
    {
        var reader = NewReader();
        reader.Start(4);
        var results = await Task.WhenAll(Enumerable.Range(0, 2000).Select(i => Task.Run(() => Read(reader, "SELECT $1::bigint + 1", i))));
        Assert.Equal(Enumerable.Range(1, 2000).Select(i => (long)i), results);
    }

    public async ValueTask DisposeAsync()
    {
        _reader?.Complete();
        if (_admin is not null) await _admin.DisposeAsync();
    }
}
