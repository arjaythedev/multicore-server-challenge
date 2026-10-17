using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;

namespace Conduit;

/// <summary>
/// bcrypt (cost 10) on a few dedicated threads, so a hash never occupies a request thread or a database connection.
/// A worker that gets a job waits a moment for more and runs up to four together (see <see cref="Bcrypt"/>), which costs far less CPU per hash.
/// Every hash and every verify does the full bcrypt work; nothing is remembered.
/// </summary>
static class Pw
{
    const int Cost = 10;
    static readonly int Workers = Math.Max(1, Env("BCRYPT_THREADS", 2));
    static readonly int BatchWindowMs = Env("BCRYPT_BATCH_MS", 200); // a login's latency is irrelevant next to the CPU a full batch saves
    static readonly BlockingCollection<Pending> Queue = new();

    sealed class Pending(Bcrypt.Job job) : TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously)
    {
        public readonly Bcrypt.Job Job = job;
    }

    static Pw()
    {
        for (int i = 0; i < Workers; i++) new Thread(Work) { IsBackground = true, Name = "bcrypt-" + i }.Start();
    }

    static int Env(string name, int fallback) => int.TryParse(Environment.GetEnvironmentVariable(name), out int v) ? v : fallback;

    static void Work()
    {
        var batch = new List<Pending>(Bcrypt.MaxLanes);
        var jobs = new Bcrypt.Job[Bcrypt.MaxLanes];
        foreach (var first in Queue.GetConsumingEnumerable())
        {
            batch.Clear();
            batch.Add(first);
            long deadline = Stopwatch.GetTimestamp() + BatchWindowMs * Stopwatch.Frequency / 1000;
            while (batch.Count < Bcrypt.MaxLanes)
            {
                int left = (int)((deadline - Stopwatch.GetTimestamp()) * 1000 / Stopwatch.Frequency);
                if (left <= 0 || !Queue.TryTake(out var next, left)) break;
                batch.Add(next);
            }
            for (int i = 0; i < batch.Count; i++) jobs[i] = batch[i].Job;
            try
            {
                Bcrypt.Run(jobs.AsSpan(0, batch.Count));
                foreach (var p in batch) p.SetResult();
            }
            catch (Exception e)
            {
                foreach (var p in batch) p.SetException(e);
            }
        }
    }

    /// <summary>bcrypt only uses the first 72 bytes; longer passwords are rejected rather than silently truncated.</summary>
    public static bool TooLong(string password) => Encoding.UTF8.GetByteCount(password) > Bcrypt.MaxKeyBytes;

    static Task Enqueue(Bcrypt.Job job)
    {
        var p = new Pending(job);
        Queue.Add(p);
        return p.Task;
    }

    public static async Task<string> Hash(string password)
    {
        var job = Bcrypt.Job.ForHash(password, Cost) ?? throw new ArgumentException("password is too long", nameof(password));
        await Enqueue(job);
        return job.Encoded();
    }

    /// <summary>False for a wrong password, a password over 72 bytes, or a malformed stored hash.</summary>
    public static async Task<bool> Verify(string password, string hash)
    {
        if (Bcrypt.Job.ForVerify(password, hash) is not { } job) return false;
        await Enqueue(job);
        return job.Matches(hash);
    }
}
