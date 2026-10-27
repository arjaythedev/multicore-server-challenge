namespace Conduit.Auth;

/// <summary>One bcrypt computation waiting for a batch.</summary>
internal sealed class BcryptJob {
    /// <summary>The password bytes.</summary>
    public required byte[] Key { get; init; }

    /// <summary>The 29-character setting (prefix, cost and salt).</summary>
    public required string Setting { get; init; }

    /// <summary>Receives the 60-character hash text on the bcrypt thread.</summary>
    public required Action<string> Complete { get; init; }

    /// <summary>Clock reading, in milliseconds, when the job was queued.</summary>
    public long EnqueuedMs { get; set; }
}

/// <summary>
/// When to start a bcrypt batch: once <c>lanes</c> jobs wait, or once the oldest job has waited <c>waitMs</c>, so a
/// lone login is not held for company forever. It holds no lock and reads no clock; the caller passes the time in and
/// provides locking.
/// </summary>
internal sealed class BcryptBatcher {
    /// <summary>Waiting jobs, oldest first.</summary>
    private readonly Queue<BcryptJob> _jobs = new();
    /// <summary>Jobs per batch.</summary>
    private readonly int _lanes;
    /// <summary>Longest the oldest job waits for a full batch, in milliseconds.</summary>
    private readonly long _waitMs;

    /// <summary>Creates a batcher for the given lane count and maximum wait.</summary>
    public BcryptBatcher(int lanes, int waitMs) {
        _lanes = lanes;
        _waitMs = waitMs;
    }

    /// <summary>Number of jobs waiting.</summary>
    public int Count => _jobs.Count;

    /// <summary>Queues a job and stamps it with <paramref name="nowMs"/>.</summary>
    public void Add(BcryptJob job, long nowMs) {
        job.EnqueuedMs = nowMs;
        _jobs.Enqueue(job);
    }

    /// <summary>
    /// Moves up to <c>lanes</c> jobs, oldest first, into <paramref name="batch"/> when the rule allows a batch
    /// to start at <paramref name="nowMs"/>. Returns false and leaves the queue alone otherwise.
    /// </summary>
    public bool TryTake(long nowMs, List<BcryptJob> batch) {
        if (MsUntilReady(nowMs) != 0) {
            return false;
        }

        for (int i = 0; i < _lanes && _jobs.Count > 0; i++) {
            batch.Add(_jobs.Dequeue());
        }

        return true;
    }

    /// <summary>
    /// Milliseconds from <paramref name="nowMs"/> until a batch may start: 0 when it may start now, -1 when no
    /// job waits (nothing to wait for).
    /// </summary>
    public long MsUntilReady(long nowMs) {
        if (_jobs.Count == 0) {
            return -1;
        }

        if (_jobs.Count >= _lanes) {
            return 0;
        }

        return Math.Max(0, _jobs.Peek().EnqueuedMs + _waitMs - nowMs);
    }
}
