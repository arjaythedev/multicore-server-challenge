using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Threading;

/// <summary>
/// bcrypt at cost 10 on dedicated threads, never on a loop: a hash takes tens of milliseconds of CPU, which would
/// stall every connection of the loop. A worker takes up to <see cref="MaxLanes"/> waiting jobs and runs them
/// interleaved, then hands each back to its loop, which an eventfd wakes. A worker holding a lone job waits up to
/// <see cref="BatchWaitMs"/> for others to join it, and a job whose client has gone is dropped unrun. The queue is
/// bounded: past it a request gets 503 at once instead of waiting behind minutes of hashing.
/// </summary>
static unsafe class Passwords
{
    public const int Cost = 10;
    /// <summary>Lanes set by the cost-10 bench on the contest box shape (8 vCPUs, all busy): 4 lanes ran 216 hashes/s, 5
    /// ran 207/s and 3 ran 212/s.</summary>
    public const int MaxLanes = 4, MaxQueued = 1024;
    /// <summary>The kernel shares CPU per runnable thread, so 2 threads starved behind 40 Postgres backends; with 9
    /// backends, 4 held more users than 8, which took CPU from Postgres. A thread only takes CPU while hashes wait.</summary>
    const int Threads = 4;
    public const int BatchWaitMs = 50;

    static readonly Queue<Job> _queue = new();
    static readonly object _lock = new();
    static bool _gathering;

    /// <summary>A hash of a random password, checked when a login names an unknown email so that it costs the same
    /// bcrypt as a wrong password: response times don't tell which emails have accounts.</summary>
    public static readonly byte[] UnknownUserHash = HashOfRandomBytes();

    public static void Start()
    {
        for (int i = 0; i < Threads; i++) new Thread(Work) { IsBackground = true, Name = "bcrypt " + i }.Start();
    }

    /// <summary>Queues a hash (<see cref="Job.Hashing"/>) or a check; false when the queue is full.</summary>
    public static bool TrySubmit(Job job)
    {
        lock (_lock)
        {
            if (_queue.Count >= MaxQueued) return false;
            _queue.Enqueue(job);
            Monitor.PulseAll(_lock); // wakes a gathering worker too
        }
        return true;
    }

    static void Work()
    {
        var jobs = new Job[MaxLanes];
        Bcrypt.Input* inputs = stackalloc Bcrypt.Input[MaxLanes];
        uint* ct = stackalloc uint[6 * MaxLanes];
        int* lane = stackalloc int[MaxLanes];
        while (true)
        {
            int n = 0;
            lock (_lock)
            {
                // one worker at a time gathers, so a lone job isn't taken by the other worker mid-wait
                while (_queue.Count == 0 || _gathering) Monitor.Wait(_lock);
                if (_queue.Count == 1)
                {
                    _gathering = true;
                    long until = Environment.TickCount64 + BatchWaitMs;
                    for (long left; _queue.Count == 1 && (left = until - Environment.TickCount64) > 0;) Monitor.Wait(_lock, (int)left);
                    _gathering = false;
                }
                while (n < MaxLanes && _queue.Count > 0) jobs[n++] = _queue.Dequeue();
                if (_queue.Count > 0) Monitor.PulseAll(_lock); // the other worker takes the rest
            }
            Run(jobs, n, inputs, ct, lane);
            for (int i = 0; i < n; i++)
            {
                jobs[i].Owner.Hashed(jobs[i]);
                jobs[i] = null!;
            }
        }
    }

    /// <summary>Runs <paramref name="n"/> (up to <see cref="MaxLanes"/>) jobs interleaved. One whose client has gone, or
    /// whose input can't be bcrypt (a malformed stored hash), doesn't match and takes no lane.</summary>
    internal static void Run(Job[] jobs, int n, Bcrypt.Input* inputs, uint* ct, int* lane)
    {
        int lanes = 0;
        for (int i = 0; i < n; i++)
        {
            Job job = jobs[i];
            job.Match = false;
            job.Dropped = job.Gone;
            ReadOnlySpan<byte> password = job.Password.AsSpan(0, job.PasswordLength);
            bool ok = !job.Dropped && (job.Hashing
                ? Bcrypt.PrepareHash(password, Cost, inputs + lanes)
                : Bcrypt.PrepareVerify(password, job.Hash.AsSpan(0, job.HashLength), inputs + lanes));
            lane[i] = ok ? lanes++ : -1;
        }
        if (lanes > 0) Bcrypt.Run(inputs, lanes, ct);
        for (int i = 0; i < n; i++)
        {
            Job job = jobs[i];
            if (lane[i] < 0) continue;
            if (job.Hashing)
            {
                Bcrypt.Format(inputs + lane[i], ct + 6 * lane[i], job.Bind.Buf.AsSpan(job.HashAt, Bcrypt.HashLength));
                job.Match = true;
            }
            else job.Match = Bcrypt.Matches(ct + 6 * lane[i], job.Hash.AsSpan(job.HashLength - 31, 31));
        }
        Bcrypt.Wipe(inputs, MaxLanes);
    }

    static byte[] HashOfRandomBytes()
    {
        Span<byte> password = stackalloc byte[32];
        RandomNumberGenerator.Fill(password);
        var hash = new byte[Bcrypt.HashLength];
        Bcrypt.Hash(password, Cost, hash);
        return hash;
    }
}
