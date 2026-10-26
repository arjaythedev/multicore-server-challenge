using System;
using System.Collections.Generic;
using System.Data;
using System.Diagnostics;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;
using Npgsql;

namespace Conduit.Data;

/// <summary>
/// Group commit. Writes from concurrent requests queue up, and a few loops, each on its own connection, send what
/// has queued as one <see cref="NpgsqlBatch"/>: one round trip and one implicit transaction, so a single WAL flush
/// commits them all. Each write's row is read inside the batch, and its task completes only after the commit.
/// </summary>
public sealed class Writer
{
    /// <summary>The most writes in one transaction.</summary>
    public const int MaxGroup = 128;

    /// <summary>
    /// The most writes waiting for a loop. More are refused at once (503) rather than queued, so a stalled database
    /// can't pile up requests and their bodies without limit. Under the workload's closed loop of users the writes in
    /// flight stay in the tens; this many only queue when commits have stopped.
    /// </summary>
    public const int MaxQueued = 4096;

    readonly Channel<Job> _jobs = Channel.CreateUnbounded<Job>();
    readonly NpgsqlDataSource _source;
    int _queued;

    /// <summary>Writes waiting for a loop.</summary>
    public int Queued => Volatile.Read(ref _queued);

    /// <param name="source">Opens the loops' connections; they must not be multiplexed.</param>
    public Writer(NpgsqlDataSource source) => _source = source;

    /// <summary>Starts <paramref name="loops"/> loops. Writes queued before this are grouped from the start.</summary>
    public void Start(int loops)
    {
        for (int i = 0; i < loops; i++) _ = Loop();
    }

    /// <summary>
    /// Queues a write. <paramref name="read"/> gets the reader on the last command's first row, or null when it
    /// returned none, and runs again if the group is retried; the task completes with its result once committed.
    /// A result the write does not complete with (its attempt rolled back, or the write failed) is disposed.
    /// Every command but the last must return no columns, and the last must return columns (a SELECT or RETURNING,
    /// even with no rows): a write without a result set would be handed the next write's row. If
    /// <paramref name="aborted"/> fires before a loop takes the write into a group, it is cancelled without running.
    /// </summary>
    public Task<T> Run<T>(NpgsqlBatchCommand[] commands, Func<NpgsqlDataReader?, T> read, CancellationToken aborted = default) =>
        Run(commands, static (r, read) => ((Func<NpgsqlDataReader?, T>)read!)(r), read, aborted);

    /// <summary>As <see cref="Run{T}(NpgsqlBatchCommand[], Func{NpgsqlDataReader?, T}, CancellationToken)"/>, with
    /// <paramref name="state"/> handed to <paramref name="read"/>, so a static handler needs no closure.</summary>
    public Task<T> Run<T>(NpgsqlBatchCommand[] commands, Func<NpgsqlDataReader?, object?, T> read, object? state, CancellationToken aborted)
    {
        var job = new Job<T>(commands, read, state, aborted);
        if (Interlocked.Increment(ref _queued) > MaxQueued)
        {
            Interlocked.Decrement(ref _queued);
            Interlocked.Increment(ref Stats.WritesRefused);
            job.Fail(new ServerBusyException("too many writes are waiting"));
        }
        else if (!_jobs.Writer.TryWrite(job))
        {
            Interlocked.Decrement(ref _queued);
            job.Fail(new InvalidOperationException("the writer is stopped"));
        }
        return job.Done.Task;
    }

    /// <summary>Takes no more writes. Each loop commits what has queued, closes its connection and ends.</summary>
    public void Complete() => _jobs.Writer.TryComplete();

    public Task<T> Run<T>(NpgsqlBatchCommand command, Func<NpgsqlDataReader?, T> read, CancellationToken aborted = default) =>
        Run([command], read, aborted);

    public Task<T> Run<T>(NpgsqlBatchCommand command, Func<NpgsqlDataReader?, object?, T> read, object? state, CancellationToken aborted) =>
        Run([command], read, state, aborted);

    async Task Loop()
    {
        var group = new List<Job>(MaxGroup);
        NpgsqlConnection? conn = null;
        while (await _jobs.Reader.WaitToReadAsync())
        {
            long taken = Stopwatch.GetTimestamp();
            while (group.Count < MaxGroup && _jobs.Reader.TryRead(out var job))
            {
                Interlocked.Decrement(ref _queued);
                Stats.Max(ref Stats.WriteWaitTicksMax, taken - job.Enqueued);
                // Its client is gone and nothing ran yet: the write is dropped. Once in a group, it runs to the end.
                if (job.Aborted.IsCancellationRequested) job.Cancel();
                else group.Add(job);
            }
            if (group.Count == 0) continue; // a write wakes every idle loop; another one took it
            try
            {
                conn ??= await _source.OpenConnectionAsync();
                await Commit(conn, group);
            }
            catch (Exception e)
            {
                // The connection broke or never opened: whether the group committed is unknown, so every write
                // still waiting fails (those already completed stay completed), and the next group reconnects.
                foreach (var job in group) job.Fail(e);
                if (conn is not null)
                {
                    try { await conn.DisposeAsync(); } catch { }
                    conn = null;
                }
            }
            long took = Stopwatch.GetTimestamp() - taken;
            Interlocked.Increment(ref Stats.WriteGroups);
            Interlocked.Add(ref Stats.WritesGrouped, group.Count);
            Interlocked.Add(ref Stats.CommitTicks, took);
            Stats.Max(ref Stats.CommitTicksMax, took);
            Stats.Max(ref Stats.WriteGroupMax, group.Count);
            group.Clear();
        }
        if (conn is not null) await conn.DisposeAsync();
    }

    /// <summary>
    /// Commits the group with the outcome of running its writes one by one in order. A failing statement rolls back
    /// the whole transaction; the writes before it ran without error, so they commit together, then the failing
    /// one gets its error (it ran on exactly what they wrote), and the writes after it are tried as the next group.
    /// So a write runs at most twice before it commits (three times when the writes before the failing one then fail
    /// together, and each runs alone), and of two writes that conflict the one queued first wins.
    /// </summary>
    static async Task Commit(NpgsqlConnection conn, List<Job> group)
    {
        int from = 0;
        while (from < group.Count)
        {
            var (failed, error) = await TryCommit(conn, group, from, group.Count, rerun: from > 0);
            if (failed < 0) return;
            if (failed == group.Count)
            {
                // The commit itself failed after every statement succeeded: no write to blame.
                for (int i = from; i < group.Count; i++) await Alone(conn, group, i);
                return;
            }
            bool before = failed == from || (await TryCommit(conn, group, from, failed)).Failed < 0;
            if (!before)
                for (int i = from; i < failed; i++) await Alone(conn, group, i);
            await Alone(conn, group, failed, before ? error : null);
            from = failed + 1;
        }
    }

    /// <summary>
    /// Commits write <paramref name="i"/> in its own transaction, after <paramref name="error"/> if it already
    /// failed once on the same data. A deadlock or serialization failure is not the write's own error (the other
    /// loop's group held the locks it needed), so it runs again, up to <see cref="Retries"/> times.
    /// </summary>
    static async Task Alone(NpgsqlConnection conn, List<Job> jobs, int i, PostgresException? error = null)
    {
        for (int retries = 0; error is null || Transient(error) && retries++ < Retries;)
        {
            int failed;
            (failed, error) = await TryCommit(conn, jobs, i, i + 1);
            if (failed < 0) return;
        }
        jobs[i].Fail(error);
    }

    const int Retries = 3;

    static bool Transient(PostgresException e) =>
        e.SqlState is PostgresErrorCodes.DeadlockDetected or PostgresErrorCodes.SerializationFailure;

    /// <summary>
    /// Runs writes <paramref name="from"/> to <paramref name="to"/> (exclusive) as one batch and completes them after
    /// the commit. On an error from Postgres returns the index of the write whose statement failed
    /// (<paramref name="to"/> if the commit failed) and the error; nothing committed.
    /// </summary>
    static async Task<(int Failed, PostgresException? Error)> TryCommit(NpgsqlConnection conn, List<Job> jobs, int from, int to, bool rerun = true)
    {
        if (rerun) Interlocked.Increment(ref Stats.WriteRetries);
        int i = from;
        try
        {
            await using var batch = conn.CreateBatch();
            for (int j = from; j < to; j++)
                foreach (var c in jobs[j].Commands) batch.BatchCommands.Add(c);
            // Default behavior, not sequential: a write reads its columns in any order.
            await using (var r = await batch.ExecuteReaderAsync())
            {
                // NextResult skips commands without columns, so each write's result set is its last command's.
                for (; i < to; i++)
                {
                    if (i > from) await r.NextResultAsync();
                    while (r.FieldCount == 0 && await r.NextResultAsync()) { }
                    jobs[i].Read(await r.ReadAsync() ? r : null);
                }
            } // disposing the reader reads up to ReadyForQuery: the commit
        }
        catch (PostgresException e) when (conn.State == ConnectionState.Open)
        {
            return (i, e);
        }
        for (int j = from; j < to; j++) jobs[j].Complete();
        return (-1, null);
    }

    abstract class Job(NpgsqlBatchCommand[] commands, CancellationToken aborted)
    {
        public readonly NpgsqlBatchCommand[] Commands = commands;
        public readonly CancellationToken Aborted = aborted;
        public readonly long Enqueued = Stopwatch.GetTimestamp();
        public abstract void Read(NpgsqlDataReader? row);
        public abstract void Complete();
        public abstract void Fail(Exception e);
        public abstract void Cancel();
    }

    sealed class Job<T>(NpgsqlBatchCommand[] commands, Func<NpgsqlDataReader?, object?, T> read, object? state, CancellationToken aborted)
        : Job(commands, aborted)
    {
        // Continuations run on the thread pool, not on the loop that commits the next group.
        public readonly TaskCompletionSource<T> Done = new(TaskCreationOptions.RunContinuationsAsynchronously);
        T _result = default!;
        bool _read;
        Exception? _error;

        public override void Read(NpgsqlDataReader? row)
        {
            Discard(); // the attempt that read the last one rolled back
            try { _result = read(row, state); _read = true; _error = null; }
            catch (Exception e) { _error = e; } // a bug in one write's read fails that write, not the group
        }

        public override void Complete()
        {
            if (_error is null) Done.TrySetResult(_result);
            else Done.TrySetException(_error);
        }

        public override void Cancel() => Done.TrySetCanceled(Aborted);

        public override void Fail(Exception e)
        {
            if (Done.TrySetException(e)) Discard(); // a result already handed over belongs to the request
        }

        /// <summary>Disposes a result the write will not complete with, so a pooled response buffer goes back.</summary>
        void Discard()
        {
            if (_read && _result is IDisposable d) d.Dispose();
            _result = default!;
            _read = false;
        }
    }
}
