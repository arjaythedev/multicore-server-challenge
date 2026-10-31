using System.Collections.Concurrent;
using System.Diagnostics;

namespace Conduit;

/// <summary>
/// Dedicated threads that run bcrypt for the request handlers. A hash takes about 25 to 75 ms of CPU, so it must not
/// run on a thread-pool thread (a burst of logins would starve every other request), and hashes that are waiting at
/// the same time are run together, up to <see cref="BcryptCore.MaxLanes"/> at once, for about 2.5 times less CPU each.
/// </summary>
internal sealed class BcryptPool
{
    /// <summary>One hash to run, with the completion the handler awaits.</summary>
    internal sealed class Job : BcryptItem
    {
        internal readonly TaskCompletionSource Done = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal readonly long EnqueuedAt = Stopwatch.GetTimestamp();

        internal Job(byte[] password, byte[] salt)
        {
            Password = password;
            Salt = salt;
        }
    }

    private readonly BlockingCollection<Job> _queue = new();
    private readonly object _collector = new(); // one worker at a time gathers a batch, so batches fill up instead of fragmenting
    private readonly int _cost;
    private readonly long _windowTicks;

    /// <param name="threads">Worker threads: the most hashes that run at the same moment is threads times MaxLanes.</param>
    /// <param name="batchWindowMs">How long the first waiting hash waits for others to join it (0 = run what is waiting now).</param>
    internal BcryptPool(int cost, int threads, int batchWindowMs)
    {
        _cost = cost;
        _windowTicks = batchWindowMs * Stopwatch.Frequency / 1000;
        for (var i = 0; i < threads; i++)
            new Thread(Work) { IsBackground = true, Name = $"bcrypt-{i}" }.Start();
    }

    /// <summary>Runs the job on a worker; the job's Output is filled in when the task completes.</summary>
    internal Task Run(Job job)
    {
        _queue.Add(job);
        return job.Done.Task;
    }

    private void Work()
    {
        using var workspace = new BcryptCore.Workspace();
        var batch = new BcryptItem[BcryptCore.MaxLanes];
        while (true)
        {
            var n = Gather(batch);
            try
            {
                BcryptCore.Compute(workspace, _cost, batch.AsSpan(0, n));
                for (var i = 0; i < n; i++) ((Job)batch[i]).Done.SetResult();
            }
            catch (Exception e)
            {
                for (var i = 0; i < n; i++) ((Job)batch[i]).Done.TrySetException(e);
            }
            Array.Clear(batch, 0, n);
        }
    }

    /// <summary>
    /// Takes the next waiting job, then waits until the window since it was enqueued has passed (or the lanes are full)
    /// for more. A job that already waited while a batch ran does not wait again.
    /// </summary>
    private int Gather(BcryptItem[] batch)
    {
        lock (_collector)
        {
            var first = _queue.Take();
            batch[0] = first;
            var n = 1;
            var deadline = first.EnqueuedAt + _windowTicks;
            while (n < BcryptCore.MaxLanes)
            {
                var remainingMs = (int)Math.Ceiling((deadline - Stopwatch.GetTimestamp()) * 1000.0 / Stopwatch.Frequency);
                if (!_queue.TryTake(out var next, Math.Max(remainingMs, 0))) break;
                batch[n++] = next;
            }
            return n;
        }
    }
}
