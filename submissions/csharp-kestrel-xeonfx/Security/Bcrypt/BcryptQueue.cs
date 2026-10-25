using System;
using System.Diagnostics;
using System.Diagnostics.CodeAnalysis;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Threading.Tasks.Sources;
using SyncRoot = System.Threading.Lock;

namespace CodeFusion.Security;

/// <summary>
/// Runs bcrypt on dedicated threads, up to <see cref="BcryptQueueOptions.Lanes"/> hashes interleaved per run: five
/// hashes cost 1.3 to 2 times the CPU of one. A hash takes tens of milliseconds; on the thread pool a burst of
/// sign-ins would hold every pool thread and stall all other requests until the pool grows.
/// <para>
/// One worker at a time collects a run, waiting up to <see cref="BcryptQueueOptions.BatchWindow"/> after the first
/// hash arrived for more to join, while the others compute. A call allocates nothing once the queue has warmed up:
/// each is a pooled request that is its own <see cref="IValueTaskSource{TResult}"/> and its own thread-pool work
/// item. Await each returned <see cref="ValueTask{TResult}"/> exactly once.
/// </para>
/// </summary>
[SuppressMessage("Naming", "CA1711", Justification = "It is a queue.")]
public sealed unsafe class BcryptQueue : IDisposable
{
    // A request's stage: being queued (registered for cancellation, not yet linked), linked and waiting, or out of the
    // queue (taken by a worker or Drain, or cancelled).
    const int Linking = 0, Queued = 1, Out = 2;

    /// <summary>One hash or check. Two references keep it from reuse: the queue's entry and the caller's await.</summary>
    sealed class Request(BcryptQueue owner) : IValueTaskSource<bool>, IValueTaskSource<string>, IThreadPoolWorkItem
    {
        CompletionCore _core; // continuations run inline: Execute already runs on the pool
        public Bcrypt.Input Input; // prepared on the caller's thread; cleared once a worker has copied it
        /// <summary>A check: the stored hash's last 31 characters, copied on the caller's thread. A new hash: the hash,
        /// once made.</summary>
        public HashBuffer Bytes;
        public bool Verifying;
        public long Enqueued;
        public CancellationToken Token;
        public CancellationTokenRegistration Registration;
        public Request? Prev, Next; // its place in the queue while Queued
        public int Stage; // Linking, Queued or Out; changed only under the queue's list lock
        public bool CancelledWhileLinking;
        public int Refs;
        int _consumed;
        bool _matched;
        Exception? _error;

        public short Version => _core.Version;

        /// <summary>Completes on a pool thread, so the caller's continuation never runs on a bcrypt worker.</summary>
        public void Complete(bool matched, Exception? error)
        {
            _matched = matched;
            _error = error;
            ThreadPool.UnsafeQueueUserWorkItem(this, preferLocal: false);
        }

        /// <summary>Completes a request whose token fired before a worker took it.</summary>
        public void CompleteCancelled()
        {
            fixed (Bcrypt.Input* input = &Input) Bcrypt.Wipe(input, 1);
            Complete(false, new OperationCanceledException(Token));
        }

        void IThreadPoolWorkItem.Execute()
        {
            if (_error is null) _core.SetResult();
            else _core.SetException(_error);
        }

        /// <summary>A worker or Drain has taken the request out of the queue: no cancellation can reach it after this.</summary>
        public void Taken()
        {
            Registration.Dispose(); // waits for a cancellation callback still running, so none outlives this use
            Registration = default;
            Release(); // the queue's reference; the caller's stays until its result is read
        }

        /// <summary>The token fired: a request still waiting leaves the queue at once and never runs.</summary>
        public void Cancel()
        {
            if (!owner.CancelWaiting(this)) return; // not linked yet (Enqueue cancels it), or a worker or Drain has it
            owner._ready.Wait(0); // drop its wake-up; if a worker already has that one, it wakes to fewer requests
            Interlocked.Decrement(ref owner._queued);
            Interlocked.Increment(ref owner._cancelled);
            CompleteCancelled();
            Release(); // last: once the caller has read the result too, the request is reused
        }

        public void Release()
        {
            if (Interlocked.Decrement(ref Refs) == 0) owner.Recycle(this);
        }

        public void Reset()
        {
            fixed (Bcrypt.Input* input = &Input) Bcrypt.Wipe(input, 1);
            ((Span<byte>)Bytes).Clear();
            Verifying = false;
            Token = default;
            Registration = default;
            Prev = Next = null;
            Stage = Linking;
            CancelledWhileLinking = false;
            _consumed = 0;
            _matched = false;
            _error = null;
            _core.Reset();
        }

        /// <summary>Checks the caller's token, throws a failure, and releases the request once its result is copied.</summary>
        T Read<T>(short token, Func<Request, T> result)
        {
            // Reading a result before it's ready (.Result or .GetAwaiter().GetResult() on a pending ValueTask) must not
            // release the request: a worker still holds it, and it would be reused for another caller meanwhile.
            if (token == _core.Version && _core.GetStatus(token) == ValueTaskSourceStatus.Pending)
                throw new InvalidOperationException("a BcryptQueue result was read before it was ready; await the ValueTask instead");
            // A second await of the same ValueTask would release the request twice and hand it to two callers.
            if (token != _core.Version || Interlocked.Exchange(ref _consumed, 1) != 0)
                throw new InvalidOperationException("a BcryptQueue result was awaited twice or after it was reused; await each ValueTask once");
            try
            {
                _core.GetResult(token);
                return result(this);
            }
            finally { Release(); }
        }

        bool IValueTaskSource<bool>.GetResult(short token) => Read(token, static r => r._matched);

        string IValueTaskSource<string>.GetResult(short token) => Read(token, static r => Encoding.ASCII.GetString(r.Bytes));

        public ValueTaskSourceStatus GetStatus(short token) => _core.GetStatus(token);

        public void OnCompleted(Action<object?> continuation, object? state, short token, ValueTaskSourceOnCompletedFlags flags) =>
            _core.OnCompleted(continuation, state, token, flags);
    }

    // The waiting requests, oldest first: a list linked through the requests themselves, so a cancelled one leaves at
    // once and nothing is allocated. The semaphore counts wake-ups: never fewer than the requests waiting, more only
    // after a cancellation or Dispose, which a worker then finds empty. (Not BlockingCollection: its TryTake with a
    // timeout links a new CancellationTokenSource each time it waits.)
    readonly SyncRoot _listLock = new();
    Request? _head, _tail;
    readonly SemaphoreSlim _ready = new(0);
    readonly SyncRoot _collecting = new();
    readonly SyncRoot _poolLock = new();
    readonly Request[] _pool;
    readonly Thread[] _threads;
    readonly int _lanes, _maxQueued;
    readonly long _window;
    int _pooled, _queued, _disposed;
    long _batches, _hashes, _refused, _cancelled;

    /// <summary>Starts the workers.</summary>
    /// <exception cref="ArgumentOutOfRangeException">An option is out of range.</exception>
    public BcryptQueue(BcryptQueueOptions? options = null)
    {
        options ??= new BcryptQueueOptions();
        _maxQueued = options.MaxQueued ?? (int)Math.Min(256L * options.Threads, int.MaxValue);
        if (options.Threads < 1) throw new ArgumentOutOfRangeException(nameof(options), options.Threads, "Threads must be at least 1");
        if (options.Lanes is < 1 or > Bcrypt.MaxLanes) throw new ArgumentOutOfRangeException(nameof(options), options.Lanes, "Lanes must be 1 to 5");
        if (options.BatchWindow < TimeSpan.Zero || options.BatchWindow.TotalMilliseconds > int.MaxValue)
            throw new ArgumentOutOfRangeException(nameof(options), options.BatchWindow, "BatchWindow must be zero or more");
        if (_maxQueued < 1) throw new ArgumentOutOfRangeException(nameof(options), _maxQueued, "MaxQueued must be at least 1");
        _lanes = options.Lanes;
        _window = (long)(options.BatchWindow.TotalSeconds * Stopwatch.Frequency);
        // Every request that can be queued or running; more are made and left to the GC only when callers hold
        // finished results unawaited.
        _pool = new Request[Math.Min((long)_maxQueued + (long)options.Threads * _lanes, 4096)];
        _threads = new Thread[options.Threads];
        for (int i = 0; i < _threads.Length; i++)
        {
            _threads[i] = new Thread(Work) { IsBackground = true, Name = $"bcrypt-{i}" };
            _threads[i].Start();
        }
    }

    /// <summary>Hashes waiting for a worker.</summary>
    public int QueueLength => Volatile.Read(ref _queued);

    /// <summary>Runs so far; <see cref="HashesRun"/> / <see cref="Batches"/> is the average number interleaved.</summary>
    public long Batches => Interlocked.Read(ref _batches);

    /// <summary>Hashes and checks run so far.</summary>
    public long HashesRun => Interlocked.Read(ref _hashes);

    /// <summary>Calls refused because the queue was full.</summary>
    public long Refused => Interlocked.Read(ref _refused);

    /// <summary>Calls cancelled before a worker took them.</summary>
    public long Cancelled => Interlocked.Read(ref _cancelled);

    /// <summary>
    /// Whether <paramref name="password"/> matches <paramref name="hash"/>; see <see cref="Bcrypt.Verify(string, string)"/>.
    /// A malformed hash or an unusable password is false at once, without queueing. Cancelled, unrun, if
    /// <paramref name="cancellationToken"/> fires before a worker takes it.
    /// </summary>
    /// <exception cref="BcryptQueueFullException">The queue is full (in the returned task).</exception>
    public ValueTask<bool> VerifyAsync(string password, string hash, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(password);
        ArgumentNullException.ThrowIfNull(hash);
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);
        if (cancellationToken.IsCancellationRequested) return ValueTask.FromCanceled<bool>(cancellationToken);
        var r = Rent();
        bool ok;
        fixed (Bcrypt.Input* input = &r.Input) ok = Bcrypt.PrepareVerify(password, hash, input);
        if (!ok)
        {
            Recycle(r);
            return new ValueTask<bool>(false);
        }
        r.Verifying = true;
        Encoding.ASCII.GetBytes(hash.AsSpan(hash.Length - Bcrypt.HashChars), r.Bytes); // checked: all ASCII
        return Enqueue(r, cancellationToken, out short version) ? new ValueTask<bool>(r, version) : ValueTask.FromException<bool>(new BcryptQueueFullException());
    }

    /// <summary>A new "$2b$" hash of <paramref name="password"/>; see <see cref="Bcrypt.Hash(string, int)"/>.</summary>
    /// <exception cref="ArgumentException">The password is over 72 UTF-8 bytes or isn't valid UTF-16.</exception>
    /// <exception cref="BcryptQueueFullException">The queue is full (in the returned task).</exception>
    public ValueTask<string> HashAsync(string password, int cost, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(password);
        Bcrypt.CheckCost(cost);
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);
        if (cancellationToken.IsCancellationRequested) return ValueTask.FromCanceled<string>(cancellationToken);
        var r = Rent();
        Span<byte> salt = stackalloc byte[Bcrypt.SaltBytes];
        RandomNumberGenerator.Fill(salt);
        bool ok;
        fixed (Bcrypt.Input* input = &r.Input) ok = Bcrypt.Prepare(password, salt, cost, 'b', input);
        if (!ok)
        {
            Recycle(r);
            throw new ArgumentException(Bcrypt.RefusalOf(password), nameof(password));
        }
        return Enqueue(r, cancellationToken, out short version) ? new ValueTask<string>(r, version) : ValueTask.FromException<string>(new BcryptQueueFullException());
    }

    /// <summary>
    /// Stops the workers once they finish the runs they hold. Hashes still waiting fail with
    /// <see cref="ObjectDisposedException"/>; later calls throw it.
    /// </summary>
    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        _ready.Release(_threads.Length);
        foreach (var t in _threads) t.Join();
        Drain();
    }

    /// <summary>Queues <paramref name="r"/> and gives the version its ValueTask needs; false when the queue is full,
    /// and <paramref name="r"/> is recycled.</summary>
    bool Enqueue(Request r, CancellationToken cancellationToken, out short version)
    {
        version = r.Version; // read before a worker can complete and recycle r
        // A slot is taken only when there is one, so a refused call never holds one that another call could use.
        int queued;
        do
        {
            queued = Volatile.Read(ref _queued);
            if (queued >= _maxQueued)
            {
                Interlocked.Increment(ref _refused);
                Recycle(r);
                return false;
            }
        }
        while (Interlocked.CompareExchange(ref _queued, queued + 1, queued) != queued);
        r.Refs = 2;
        r.Enqueued = Stopwatch.GetTimestamp();
        r.Token = cancellationToken;
        // Registered before it's linked, so a callback only ever sees this call's request, never one reused for another
        // call. A token that fires before the link (even during the registration itself) marks the request, and it's
        // cancelled here instead of linked: it never runs.
        if (cancellationToken.CanBeCanceled)
            r.Registration = cancellationToken.UnsafeRegister(static (s, _) => ((Request)s!).Cancel(), r);
        if (!Append(r))
        {
            r.Registration.Dispose(); // waits if the callback that marked it is still running on another thread
            r.Registration = default;
            Interlocked.Decrement(ref _queued);
            Interlocked.Increment(ref _cancelled);
            r.CompleteCancelled();
            r.Release(); // the queue's reference
            return true;
        }
        _ready.Release();
        if (Volatile.Read(ref _disposed) != 0) Drain(); // raced Dispose: nothing would take it
        return true;
    }

    /// <summary>Fails every request still queued; after Dispose.</summary>
    void Drain()
    {
        while (TakeFirst() is { } r)
        {
            Interlocked.Decrement(ref _queued);
            r.Complete(false, new ObjectDisposedException(nameof(BcryptQueue)));
            r.Taken();
        }
    }

    /// <summary>Links <paramref name="r"/> at the end; false when its token fired first.</summary>
    bool Append(Request r)
    {
        lock (_listLock)
        {
            if (r.CancelledWhileLinking) return false;
            r.Prev = _tail;
            r.Next = null;
            if (_tail is null) _head = r;
            else _tail.Next = r;
            _tail = r;
            r.Stage = Queued;
            return true;
        }
    }

    Request? TakeFirst()
    {
        lock (_listLock)
        {
            var r = _head;
            if (r is not null) Remove(r);
            return r;
        }
    }

    /// <summary>
    /// The token of <paramref name="r"/> fired. True when it was waiting and is now out of the queue, for the caller
    /// to cancel. False when it isn't linked yet (it's marked, and Enqueue cancels it) or a worker or Drain has it.
    /// </summary>
    bool CancelWaiting(Request r)
    {
        lock (_listLock)
        {
            switch (r.Stage)
            {
                case Linking:
                    r.CancelledWhileLinking = true;
                    return false;
                case Queued:
                    Remove(r);
                    return true;
                default:
                    return false;
            }
        }
    }

    void Remove(Request r) // under _listLock
    {
        if (r.Prev is null) _head = r.Next;
        else r.Prev.Next = r.Next;
        if (r.Next is null) _tail = r.Prev;
        else r.Next.Prev = r.Prev;
        r.Prev = r.Next = null;
        r.Stage = Out;
    }

    Request Rent()
    {
        lock (_poolLock)
            if (_pooled > 0)
            {
                var r = _pool[--_pooled];
                _pool[_pooled] = null!;
                return r;
            }
        return new Request(this); // until the pool has warmed up
    }

    void Recycle(Request r)
    {
        r.Reset();
        lock (_poolLock)
            if (_pooled < _pool.Length) _pool[_pooled++] = r;
    }

    void Work()
    {
        var batch = new Request?[_lanes];
        Bcrypt.Input* inputs = stackalloc Bcrypt.Input[Bcrypt.MaxLanes];
        uint* ct = stackalloc uint[6 * Bcrypt.MaxLanes];
        while (true)
        {
            int n;
            lock (_collecting) n = Collect(batch);
            if (n == 0)
            {
                if (Volatile.Read(ref _disposed) != 0) return;
                continue;
            }
            Interlocked.Increment(ref _batches);
            Interlocked.Add(ref _hashes, n);
            for (int i = 0; i < n; i++)
            {
                inputs[i] = batch[i]!.Input;
                fixed (Bcrypt.Input* input = &batch[i]!.Input) Bcrypt.Wipe(input, 1);
            }
            var finished = new Finisher { Batch = batch, Inputs = inputs, Ct = ct };
            try
            {
                Bcrypt.Run(inputs, n, ct, ref finished);
            }
            catch (Exception e)
            {
                for (int i = 0; i < n; i++)
                {
                    batch[i]?.Complete(false, e);
                    batch[i] = null;
                }
            }
            Bcrypt.Wipe(inputs, n);
        }
    }

    /// <summary>Completes each request as soon as its lane is done: a cheap check sharing a run with a costlier hash
    /// doesn't wait for it.</summary>
    struct Finisher : Bcrypt.IFinished
    {
        public Request?[] Batch;
        public Bcrypt.Input* Inputs;
        public uint* Ct;

        public readonly void Finished(int i)
        {
            var r = Batch[i]!;
            Batch[i] = null;
            if (r.Verifying) r.Complete(Bcrypt.Matches(Ct + 6 * i, ((ReadOnlySpan<byte>)r.Bytes)[..Bcrypt.HashChars]), null);
            else
            {
                Bcrypt.Format(Inputs + i, Ct + 6 * i, r.Bytes);
                r.Complete(false, null);
            }
        }
    }

    /// <summary>Waits for a first request, then takes more until the run is full or the window after the first
    /// one's arrival has passed (a backlog older than the window is taken without waiting). Dispose ends the wait:
    /// 0 with nothing taken yet, else the run so far.</summary>
    int Collect(Request?[] batch)
    {
        int n = 0;
        long deadline = 0;
        while (n < batch.Length)
        {
            if (Volatile.Read(ref _disposed) != 0) break;
            int ms;
            if (n == 0) ms = 1000; // wakes now and then to notice Dispose even if another worker took its wake-up
            else
            {
                long left = deadline - Stopwatch.GetTimestamp();
                ms = left > 0 ? (int)((left * 1000 + Stopwatch.Frequency - 1) / Stopwatch.Frequency) : 0;
            }
            if (!_ready.Wait(ms))
            {
                if (n == 0) continue;
                break;
            }
            // Empty after a cancellation took its request, or after Dispose (checked at the top).
            if (TakeFirst() is not { } r) continue;
            Interlocked.Decrement(ref _queued);
            r.Taken();
            if (n == 0) deadline = r.Enqueued + _window;
            batch[n++] = r;
        }
        return n;
    }

    /// <summary>A check's stored hash characters, or a new hash's bytes, inline.</summary>
    [InlineArray(Bcrypt.HashLength)]
    struct HashBuffer
    {
        byte _first;
    }
}
