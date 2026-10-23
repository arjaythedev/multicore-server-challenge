using System;
using System.Diagnostics;
using System.Linq;
using System.Threading.Tasks;
using Conduit.Data;
using Npgsql;
using Xunit;

// The timeouts turn a write that is never completed into a failure instead of a hung run. A write's token is its
// client's abort, which the tests that need one pass themselves.
#pragma warning disable xUnit1069, xUnit1051

namespace Conduit.Tests.Data;

/// <summary>
/// Group commit against a real Postgres. Set CONDUIT_TEST_DB to an Npgsql connection string of a database the user
/// may create tables in; without it these tests are skipped. Each test uses its own table and drops it.
/// </summary>
public sealed class WriterTests : IAsyncDisposable
{
    static readonly string? ConnectionString = Environment.GetEnvironmentVariable("CONDUIT_TEST_DB");

    readonly string _table = "writer_test_" + Guid.NewGuid().ToString("N");
    NpgsqlDataSource? _db;

    /// <summary>A writer whose loops are not started yet, so writes queued now share the first group.</summary>
    async Task<Writer> NewWriter(TimeSpan? lockTimeout = null)
    {
        Assert.SkipWhen(ConnectionString is null, "CONDUIT_TEST_DB is not set");
        _db = NpgsqlDataSource.Create(ConnectionString!);
        await Sql($"CREATE TABLE {_table} (id bigserial PRIMARY KEY, v text NOT NULL UNIQUE)");
        var csb = new NpgsqlConnectionStringBuilder(ConnectionString) { Multiplexing = false };
        return new Writer(lockTimeout is { } t ? Db.WriterSource(csb, 2, t) : NpgsqlDataSource.Create(csb.ConnectionString));
    }

    async Task<object?> Sql(string sql)
    {
        await using var cmd = _db!.CreateCommand(sql);
        return await cmd.ExecuteScalarAsync();
    }

    async Task<string[]> Values() =>
        (await Sql($"SELECT coalesce(string_agg(v, ',' ORDER BY id), '') FROM {_table}") as string)!.Split(',', StringSplitOptions.RemoveEmptyEntries);

    NpgsqlBatchCommand Insert(string v) => Db.Command($"INSERT INTO {_table} (v) VALUES ($1) RETURNING v", Db.P(v));

    Task<string?> Run(Writer w, string v) => w.Run(Insert(v), r => r?.GetString(0));

    public async ValueTask DisposeAsync()
    {
        if (_db is null) return;
        await Sql($"DROP TABLE IF EXISTS {_table}, {_table}_d");
        await _db.DisposeAsync();
    }

    [Fact(Timeout = 30_000)]
    public async Task AFailingWriteFailsAloneAndTheRestOfItsGroupCommits()
    {
        var w = await NewWriter();
        await Sql($"INSERT INTO {_table} (v) VALUES ('taken')");
        var tasks = new[] { "a", "b", "taken", "c", "d" }.Select(v => Run(w, v)).ToArray();
        w.Start(1);

        var e = await Assert.ThrowsAsync<PostgresException>(() => tasks[2]);
        Assert.Equal(PostgresErrorCodes.UniqueViolation, e.SqlState);
        Assert.Equal(["a", "b", "c", "d"], new[] { tasks[0], tasks[1], tasks[3], tasks[4] }.Select(t => t.Result));
        Assert.Equal(["taken", "a", "b", "c", "d"], await Values());
    }

    [Fact(Timeout = 30_000)]
    public async Task OfTwoConflictingWritesInOneGroupTheFirstQueuedWins()
    {
        var w = await NewWriter();
        var first = w.Run(Insert("same"), r => r!.GetString(0) + "#1");
        var second = w.Run(Insert("same"), r => r!.GetString(0) + "#2");
        w.Start(1);

        Assert.Equal("same#1", await first);
        var e = await Assert.ThrowsAsync<PostgresException>(() => second);
        Assert.Equal(PostgresErrorCodes.UniqueViolation, e.SqlState);
        Assert.Equal(["same"], await Values());
    }

    [Fact(Timeout = 30_000)]
    public async Task SeveralFailuresInOneGroupEachFailAlone()
    {
        var w = await NewWriter();
        await Sql($"INSERT INTO {_table} (v) VALUES ('x'), ('y')");
        string[] values = ["x", "a", "y", "b", "x", "c"];
        var tasks = values.Select(v => Run(w, v)).ToArray();
        w.Start(1);

        for (int i = 0; i < values.Length; i++)
        {
            if (values[i] is "x" or "y") await Assert.ThrowsAsync<PostgresException>(() => tasks[i]);
            else Assert.Equal(values[i], await tasks[i]);
        }
        Assert.Equal(["x", "y", "a", "b", "c"], await Values());
    }

    [Fact(Timeout = 30_000)]
    public async Task WritesPastTheQueueLimitAreRefusedAtOnceAndTheQueuedOnesCommit()
    {
        var w = await NewWriter();
        var values = Enumerable.Range(0, Writer.MaxQueued).Select(i => $"q{i}").ToArray();
        var queued = values.Select(v => Run(w, v)).ToArray();
        var refused = Run(w, "one-too-many");

        Assert.True(refused.IsFaulted, "refused without waiting for a loop");
        await Assert.ThrowsAsync<ServerBusyException>(() => refused);
        Assert.Equal(Writer.MaxQueued, w.Queued);
        w.Start(2);
        Assert.Equal(values, await Task.WhenAll(queued));
        Assert.Equal(0, w.Queued);
        Assert.Equal("room-again", await Run(w, "room-again"));
        Assert.Equal(Writer.MaxQueued + 1, (await Values()).Length);
        Assert.DoesNotContain("one-too-many", await Values());
    }

    [Fact(Timeout = 30_000)]
    public async Task AWriteBlockedPastTheLockTimeoutFailsAloneAndItsGroupCommits()
    {
        var timeout = TimeSpan.FromMilliseconds(300);
        var w = await NewWriter(timeout);
        await Sql($"INSERT INTO {_table} (v) VALUES ('locked')");
        await using var holder = await _db!.OpenConnectionAsync();
        await using var tx = await holder.BeginTransactionAsync();
        await using (var lockRow = new NpgsqlCommand($"SELECT v FROM {_table} WHERE v = 'locked' FOR UPDATE", holder, tx))
            await lockRow.ExecuteScalarAsync();

        var blocked = w.Run(Db.Command($"UPDATE {_table} SET v = 'moved' WHERE v = 'locked' RETURNING v"), r => r?.GetString(0));
        var free = Run(w, "free");
        var sw = Stopwatch.StartNew();
        w.Start(1);

        var e = await Assert.ThrowsAsync<PostgresException>(() => blocked);
        Assert.Equal(PostgresErrorCodes.LockNotAvailable, e.SqlState);
        Assert.Equal("free", await free);
        // one wait for the lock, not the 30 s statement timeout
        Assert.InRange(sw.Elapsed, timeout, TimeSpan.FromSeconds(10));
        await tx.RollbackAsync();
        Assert.Equal(["locked", "free"], await Values());
    }

    [Fact(Timeout = 30_000)]
    public async Task MoreWritesThanAGroupHoldsEachGetTheirOwnRow()
    {
        var w = await NewWriter();
        var values = Enumerable.Range(0, 2 * Writer.MaxGroup + 3).Select(i => $"v{i}").ToArray();
        var tasks = values.Select(v => Run(w, v)).ToArray();
        w.Start(2);

        Assert.Equal(values, await Task.WhenAll(tasks));
        Assert.Equal(values.Order(), (await Values()).Order());
    }

    [Fact(Timeout = 30_000)]
    public async Task ConcurrentWritersEachGetTheirOwnRow()
    {
        var w = await NewWriter();
        w.Start(2);
        var values = Enumerable.Range(0, 1000).Select(i => $"c{i}").ToArray();

        var results = await Task.WhenAll(values.Select(v => Task.Run(() => Run(w, v))));

        Assert.Equal(values, results);
        Assert.Equal(values.Order(), (await Values()).Order());
    }

    /// <summary>
    /// Queues <paramref name="values"/> as one group against existing rows "taken" and "taken2" and checks that the
    /// writes end as if run one by one in order, and how often each good write ran (its read is called per run).
    /// </summary>
    async Task<int> MostRunsOfAGoodWrite(string[] values)
    {
        var w = await NewWriter();
        await Sql($"INSERT INTO {_table} (v) VALUES ('taken'), ('taken2')");
        var runs = new int[values.Length];
        var tasks = values.Select((v, i) => w.Run(Insert(v), r => { runs[i]++; return r!.GetString(0); })).ToArray();
        w.Start(1);

        var good = new System.Collections.Generic.List<string>();
        for (int i = 0; i < values.Length; i++)
        {
            if (values[i].StartsWith("taken") || Array.IndexOf(values, values[i]) < i)
                Assert.Equal(PostgresErrorCodes.UniqueViolation, (await Assert.ThrowsAsync<PostgresException>(() => tasks[i])).SqlState);
            else
            {
                Assert.Equal(values[i], await tasks[i]);
                good.Add(values[i]);
            }
        }
        string[] rows = await Values();
        Assert.Equal(["taken", "taken2", .. good], rows);
        return good.Count == 0 ? 0 : good.Select(v => runs[Array.IndexOf(values, v)]).Max();
    }

    [Theory(Timeout = 30_000)]
    [InlineData("taken,a,b,c")]
    [InlineData("a,b,taken,c,d")]
    [InlineData("a,b,c,taken")]
    [InlineData("taken,a,x,b,taken2,c,x,d")]
    [InlineData("a,a,a,b")]
    [InlineData("taken,taken2")]
    public async Task AGoodWriteRunsAtMostTwiceWhereverItsGroupFails(string values) =>
        Assert.InRange(await MostRunsOfAGoodWrite(values.Split(',')), 0, 2);

    [Fact(Timeout = 30_000)]
    public async Task AGroupOfHalfDuplicatesRunsEachGoodWriteAtMostTwice()
    {
        // 64 good writes, each followed by a duplicate of an existing row
        var values = Enumerable.Range(0, Writer.MaxGroup / 2).SelectMany(i => new[] { $"g{i}", i % 2 == 0 ? "taken" : "taken2" }).ToArray();
        Assert.InRange(await MostRunsOfAGoodWrite(values), 1, 2);
    }

    [Fact(Timeout = 30_000)]
    public async Task AWriteWhoseClientLeftBeforeItsGroupIsSkipped()
    {
        var w = await NewWriter();
        using var left = new System.Threading.CancellationTokenSource();
        left.Cancel();
        var before = Run(w, "a");
        var gone = w.Run(Insert("gone"), r => r?.GetString(0), left.Token);
        var after = Run(w, "b");
        w.Start(1);

        Assert.Equal(left.Token, (await Assert.ThrowsAnyAsync<OperationCanceledException>(() => gone)).CancellationToken);
        Assert.Equal("a", await before);
        Assert.Equal("b", await after);
        Assert.Equal(["a", "b"], await Values());
    }

    [Fact(Timeout = 30_000)]
    public async Task AWriteWhoseClientLeavesOnceItsGroupRunsStillCommits()
    {
        var w = await NewWriter();
        await Sql($"INSERT INTO {_table} (v) VALUES ('taken')");
        using var leaving = new System.Threading.CancellationTokenSource();
        // the group fails on "taken" after this write's read, so the write runs again after its client left
        var stays = w.Run(Insert("stays"), r => { leaving.Cancel(); return r!.GetString(0); }, leaving.Token);
        var failing = Run(w, "taken");
        w.Start(1);

        Assert.Equal("stays", await stays);
        await Assert.ThrowsAsync<PostgresException>(() => failing);
        Assert.Equal(["taken", "stays"], await Values());
    }

    [Fact(Timeout = 30_000)]
    public async Task ReadsTheLastCommandsRowAndNullWhenItHasNone()
    {
        var w = await NewWriter();
        var two = w.Run(
            [Db.Command($"INSERT INTO {_table} (v) VALUES ($1)", Db.P("q")), Db.Command($"SELECT v || '!' FROM {_table} WHERE v = $1", Db.P("q"))],
            r => r?.GetString(0));
        var none = w.Run(Db.Command($"SELECT v FROM {_table} WHERE v = $1", Db.P("missing")), r => r is null ? "no row" : "row");
        var after = Run(w, "after");
        w.Start(1);

        Assert.Equal("q!", await two);
        Assert.Equal("no row", await none);
        Assert.Equal("after", await after);
    }

    [Fact(Timeout = 30_000)]
    public async Task AWriteCompletesWithTheReadOfTheAttemptThatCommitted()
    {
        var w = await NewWriter();
        await Sql($"INSERT INTO {_table} (v) VALUES ('taken')");
        int reads = 0;
        var task = w.Run(Insert("a"), r => $"{r!.GetString(0)} read {++reads}");
        var failing = Run(w, "taken");
        w.Start(1);

        // the first attempt read its row, then rolled back with the failing write
        Assert.Equal("a read 2", await task);
        await Assert.ThrowsAsync<PostgresException>(() => failing);
    }

    /// <summary>A result that holds something to give back, as a pooled response buffer does.</summary>
    sealed class Held(string value) : IDisposable
    {
        public readonly string Value = value;
        public int Disposed;
        public void Dispose() => Disposed++;
    }

    [Fact(Timeout = 30_000)]
    public async Task AResultReadByAnAttemptThatRolledBackIsDisposed()
    {
        var w = await NewWriter();
        await Sql($"INSERT INTO {_table} (v) VALUES ('taken')");
        var made = new System.Collections.Generic.List<Held>();
        var task = w.Run(Insert("a"), r => { var h = new Held(r!.GetString(0)); made.Add(h); return h; });
        var failing = Run(w, "taken");
        w.Start(1);

        var kept = await task;
        await Assert.ThrowsAsync<PostgresException>(() => failing);
        Assert.Equal(2, made.Count);
        Assert.Same(made[1], kept);
        Assert.Equal(1, made[0].Disposed);
        Assert.Equal(0, kept.Disposed);
    }

    [Fact(Timeout = 30_000)]
    public async Task AResultReadBeforeTheConnectionBrokeIsDisposed()
    {
        var w = await NewWriter();
        Held? read = null;
        var before = w.Run(Insert("a"), r => read = new Held(r!.GetString(0)));
        var kill = w.Run(Db.Command("SELECT pg_terminate_backend(pg_backend_pid())"), r => r?.GetBoolean(0));
        w.Start(1);

        await Assert.ThrowsAnyAsync<Exception>(() => before);
        await Assert.ThrowsAnyAsync<Exception>(() => kill);
        Assert.Equal("a", read!.Value);
        Assert.Equal(1, read.Disposed);
    }

    [Fact(Timeout = 30_000)]
    public async Task AResultAlreadyHandedOverIsNotDisposedWhenItsGroupLaterBreaks()
    {
        var w = await NewWriter();
        Held? read = null;
        // the flag lives until the end of the transaction: inside the group the last write divides by zero, which
        // sets it aside; run alone it terminates the connection, after the other two committed
        var flag = w.Run(Db.Command("SELECT set_config('writer_test.flag', '1', true)"), r => r?.GetString(0));
        var committed = w.Run(Insert("a"), r => read = new Held(r!.GetString(0)));
        var breaker = w.Run(
            Db.Command($"SELECT CASE WHEN current_setting('writer_test.flag', true) = '1' THEN (SELECT 1 / count(*) FROM {_table} WHERE false) = 1 " +
                "ELSE pg_terminate_backend(pg_backend_pid()) END"),
            r => r?.GetBoolean(0));
        w.Start(1);

        var held = await committed;
        Assert.Same(read, held);
        Assert.Equal("1", await flag);
        await Assert.ThrowsAnyAsync<Exception>(() => breaker);
        Assert.Equal(0, read!.Disposed);
    }

    [Fact(Timeout = 30_000)]
    public async Task WhenTheCommitItselfFailsEachWriteRunsAlone()
    {
        var w = await NewWriter();
        // checked at COMMIT, after every statement and every read succeeded
        await Sql($"CREATE TABLE {_table}_d (k int UNIQUE DEFERRABLE INITIALLY DEFERRED, v text)");
        NpgsqlBatchCommand Deferred(int k, string v) => Db.Command($"INSERT INTO {_table}_d VALUES ($1, $2) RETURNING v", Db.P(k), Db.P(v));
        var first = w.Run(Deferred(1, "first"), r => r!.GetString(0));
        var second = w.Run(Deferred(1, "second"), r => r!.GetString(0));
        var other = w.Run(Deferred(2, "other"), r => r!.GetString(0));
        w.Start(1);

        Assert.Equal("first", await first);
        Assert.Equal(PostgresErrorCodes.UniqueViolation, (await Assert.ThrowsAsync<PostgresException>(() => second)).SqlState);
        Assert.Equal("other", await other);
        Assert.Equal("first,other", await Sql($"SELECT string_agg(v, ',' ORDER BY k) FROM {_table}_d"));
    }

    [Fact(Timeout = 30_000)]
    public async Task AWriteThatLosesADeadlockRunsAgainInsteadOfFailing()
    {
        var w = await NewWriter();
        await Sql($"INSERT INTO {_table} (v) VALUES ('r1'), ('r2')");
        w.Start(1);
        await using var other = await _db!.OpenConnectionAsync(TestContext.Current.CancellationToken);
        // Postgres aborts the transaction of the backend whose deadlock check finds the cycle: normally the writer's,
        // which waited first, but the other one's if the writer's check ran before the other started waiting.
        for (int attempt = 1; ; attempt++)
        {
            await using var tx = await other.BeginTransactionAsync(TestContext.Current.CancellationToken);
            await Exec(other, $"UPDATE {_table} SET v = v WHERE v = 'r2'");
            // locks r1, then waits for r2, which the other transaction holds
            var write = w.Run(
                [Db.Command($"UPDATE {_table} SET v = v WHERE v = 'r1'"), Db.Command($"UPDATE {_table} SET v = v WHERE v = 'r2' RETURNING v")],
                r => r?.GetString(0));
            while ((long)(await Sql("SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'"))! == 0)
                await Task.Delay(10, TestContext.Current.CancellationToken);
            try
            {
                await Exec(other, $"UPDATE {_table} SET v = v WHERE v = 'r1'");
            }
            catch (PostgresException e) when (e.SqlState == PostgresErrorCodes.DeadlockDetected && attempt < 5)
            {
                // the other transaction lost: the writer's write went through without a retry, so try again
                await tx.RollbackAsync(TestContext.Current.CancellationToken);
                Assert.Equal("r2", await write);
                continue;
            }
            // the other transaction got r1, so the writer's transaction was the one aborted
            await tx.CommitAsync(TestContext.Current.CancellationToken);
            Assert.Equal("r2", await write);
            return;
        }
    }

    static async Task Exec(NpgsqlConnection conn, string sql)
    {
        await using var cmd = new NpgsqlCommand(sql, conn);
        await cmd.ExecuteNonQueryAsync();
    }

    [Fact(Timeout = 30_000)]
    public async Task AReadThatThrowsFailsOnlyItsOwnWrite()
    {
        var w = await NewWriter();
        var ok1 = Run(w, "a");
        var bad = w.Run<string>(Insert("b"), _ => throw new InvalidOperationException("bad read"));
        var ok2 = Run(w, "c");
        w.Start(1);

        Assert.Equal("a", await ok1);
        Assert.Equal("bad read", (await Assert.ThrowsAsync<InvalidOperationException>(() => bad)).Message);
        Assert.Equal("c", await ok2);
    }

    [Fact(Timeout = 30_000)]
    public async Task ABrokenConnectionFailsItsGroupAndTheNextGroupReconnects()
    {
        var w = await NewWriter();
        var before = Run(w, "a");
        var kill = w.Run(Db.Command("SELECT pg_terminate_backend(pg_backend_pid())"), r => r?.GetBoolean(0));
        var after = Run(w, "b");
        w.Start(1);

        // whether the group committed is unknown to the writer, so none of it may report success
        await Assert.ThrowsAnyAsync<Exception>(() => before);
        await Assert.ThrowsAnyAsync<Exception>(() => kill);
        await Assert.ThrowsAnyAsync<Exception>(() => after);
        Assert.Equal("later", await Run(w, "later"));
        Assert.Equal(["later"], await Values());
    }
}
