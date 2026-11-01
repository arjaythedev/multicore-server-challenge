using System.Threading.Channels;

namespace ConduitChallenge;

sealed class Passwords : IDisposable
{
    readonly Channel<Work> _queue;
    readonly Thread[] _workers;
    readonly PasswordMetrics? _metrics;
    int _disposed;

    public Passwords(int workers = 5, int capacity = 256)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(workers);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(capacity);
        _metrics = PasswordMetrics.Create();
        _queue = Channel.CreateBounded<Work>(new BoundedChannelOptions(capacity)
        {
            FullMode = BoundedChannelFullMode.Wait,
            SingleReader = workers == 1,
            AllowSynchronousContinuations = false
        });
        _workers = new Thread[workers];
        for (var i = 0; i < workers; i++)
        {
            _workers[i] = new Thread(Run) { IsBackground = true, Name = $"bcrypt-{i + 1}" };
            _workers[i].Start();
        }
    }

    public async ValueTask<string> HashAsync(string password, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(password);
        return (await Enqueue(password, null, cancellationToken)).Hash!;
    }

    public async ValueTask<bool> VerifyAsync(string password, string hash, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(password);
        ArgumentNullException.ThrowIfNull(hash);
        return (await Enqueue(password, hash, cancellationToken)).Matches;
    }

    async ValueTask<Result> Enqueue(string password, string? hash, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);
        var work = new Work(password, hash, cancellationToken);
        work.QueuedAt = _metrics?.Enqueue(work.Operation) ?? 0;
        try { await _queue.Writer.WriteAsync(work, cancellationToken).ConfigureAwait(false); }
        catch
        {
            _metrics?.Abandon(work.Operation, work.QueuedAt, cancellationToken.IsCancellationRequested, admissionPending: true);
            throw;
        }
        _metrics?.AdmissionCompleted(work.QueuedAt);
        return await work.Completion.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
    }

    void Run()
    {
        var reader = _queue.Reader;
        while (reader.WaitToReadAsync().AsTask().GetAwaiter().GetResult())
        {
            while (reader.TryRead(out var work))
            {
                if (Volatile.Read(ref _disposed) != 0)
                {
                    _metrics?.Abandon(work.Operation, work.QueuedAt, false);
                    work.Completion.TrySetException(new ObjectDisposedException(nameof(Passwords)));
                    continue;
                }
                if (work.CancellationToken.IsCancellationRequested)
                {
                    _metrics?.Abandon(work.Operation, work.QueuedAt, true);
                    work.Completion.TrySetCanceled(work.CancellationToken);
                    continue;
                }
                var started = _metrics?.Start(work.Operation, work.QueuedAt) ?? 0;
                var failed = false;
                try
                {
                    var result = work.Hash is null
                        ? new Result(BCrypt.Net.BCrypt.HashPassword(work.Password, workFactor: 10), false)
                        : new Result(null, BCrypt.Net.BCrypt.Verify(work.Password, work.Hash));
                    work.Completion.TrySetResult(result);
                }
                catch (Exception exception)
                {
                    failed = true;
                    work.Completion.TrySetException(exception);
                }
                finally { _metrics?.Finish(work.Operation, started, failed); }
            }
        }
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        _queue.Writer.TryComplete();
        foreach (var worker in _workers) worker.Join();
        _metrics?.Dispose();
    }

    readonly record struct Result(string? Hash, bool Matches);

    sealed class Work(string password, string? hash, CancellationToken cancellationToken)
    {
        public string Password { get; } = password;
        public string? Hash { get; } = hash;
        public CancellationToken CancellationToken { get; } = cancellationToken;
        public int Operation => Hash is null ? 0 : 1;
        public long QueuedAt;
        public TaskCompletionSource<Result> Completion { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    }
}
