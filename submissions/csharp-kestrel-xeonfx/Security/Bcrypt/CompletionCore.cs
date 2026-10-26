using System;
using System.Runtime.CompilerServices;
using System.Runtime.ExceptionServices;
using System.Threading;
using System.Threading.Tasks;
using System.Threading.Tasks.Sources;

namespace CodeFusion.Security;

/// <summary>
/// The completion half of the runtime's ManualResetValueTaskSourceCore, for the queue's pooled requests. A continuation
/// registered after completion (the result arrived between the awaiter's look and its registration) runs at once on
/// the registering thread, unless the stack is deep, instead of being queued to the pool as the runtime's core and
/// Task do: that queueing allocates a work item, which the queue's 0 B per call can't afford.
/// <para>
/// It claims the continuation slot before it marks the result ready and touches nothing after, so whoever sees the
/// result may read it and reset the core for its next operation at once. (The runtime's core marks the result first
/// and claims the slot after; it stays safe only because its GetStatus reports Pending until the slot is claimed, and
/// the queue releases a request only once its status isn't Pending.) The result itself lives in the request; this
/// keeps only whether it failed. The compiler's state machines touch nothing after registering. The
/// flags are honoured as the runtime's core honours them: the ExecutionContext flows, and a synchronization context or
/// task scheduler gets the continuation.
/// </para>
/// </summary>
internal struct CompletionCore
{
    static readonly Action<object?> Sentinel = static _ => throw new InvalidOperationException("the completion sentinel ran");

    Action<object?>? _continuation;
    object? _state;
    ExecutionContext? _context;
    object? _scheduler; // a SynchronizationContext or TaskScheduler that gets the continuation
    Exception? _error;
    bool _completed;
    short _version;

    public readonly short Version => _version;

    /// <summary>Ready for the next operation: a new version, nothing completed or waiting.</summary>
    public void Reset()
    {
        _version++;
        _completed = false;
        _error = null;
        _state = null;
        _context = null;
        _scheduler = null;
        _continuation = null;
    }

    /// <summary>Completes successfully; the result must already be written where the reader will look.</summary>
    public void SetResult() => Signal();

    public void SetException(Exception error)
    {
        _error = error;
        Signal();
    }

    public readonly ValueTaskSourceStatus GetStatus(short token)
    {
        Validate(token);
        return !Volatile.Read(ref Unsafe.AsRef(in _completed)) ? ValueTaskSourceStatus.Pending
            : _error is null ? ValueTaskSourceStatus.Succeeded
            : _error is OperationCanceledException ? ValueTaskSourceStatus.Canceled
            : ValueTaskSourceStatus.Faulted;
    }

    /// <summary>Throws the operation's exception, if it failed; after it is ready.</summary>
    public readonly void GetResult(short token)
    {
        Validate(token);
        if (!Volatile.Read(ref Unsafe.AsRef(in _completed))) throw new InvalidOperationException("the operation hasn't completed");
        if (_error is not null) ExceptionDispatchInfo.Throw(_error);
    }

    public void OnCompleted(Action<object?> continuation, object? state, short token, ValueTaskSourceOnCompletedFlags flags)
    {
        ArgumentNullException.ThrowIfNull(continuation);
        Validate(token);
        // A second await is refused before it writes anything: it must not overwrite the first one's state.
        Action<object?>? current = Volatile.Read(ref _continuation);
        if (current is not null && !ReferenceEquals(current, Sentinel)) throw new InvalidOperationException("a pooled ValueTask was awaited twice");
        // Everything goes in before the continuation: once it's published, Signal may run it at once.
        if ((flags & ValueTaskSourceOnCompletedFlags.FlowExecutionContext) != 0) _context = ExecutionContext.Capture();
        if ((flags & ValueTaskSourceOnCompletedFlags.UseSchedulingContext) != 0) _scheduler = CurrentScheduler();
        _state = state;
        Action<object?>? previous = Interlocked.CompareExchange(ref _continuation, continuation, null);
        if (previous is null) return;
        if (!ReferenceEquals(previous, Sentinel)) throw new InvalidOperationException("a pooled ValueTask was awaited twice");
        // Completed between the awaiter's look and now. Signal may be a few instructions short of marking the result
        // ready; then run the continuation here, unless the stack is deep.
        SpinWait spin = default;
        while (!Volatile.Read(ref _completed)) spin.SpinOnce();
        if (RuntimeHelpers.TryEnsureSufficientExecutionStack()) Invoke(continuation, state, _context, _scheduler);
        else ThreadPool.UnsafeQueueUserWorkItem(static p => p.Invoke(), new Late(continuation, state, _context, _scheduler), preferLocal: true);
    }

    /// <summary>
    /// Takes the waiting continuation (or leaves the sentinel for one that comes later) and its context before marking
    /// the result ready, and touches nothing after: whoever sees the result ready may read it and reset the core for
    /// its next operation at once.
    /// </summary>
    void Signal()
    {
        Action<object?>? waiting = Interlocked.Exchange(ref _continuation, Sentinel);
        if (ReferenceEquals(waiting, Sentinel)) throw new InvalidOperationException("the operation completed twice");
        object? state = _state, scheduler = _scheduler;
        ExecutionContext? context = _context;
        Volatile.Write(ref _completed, true); // after the result, and the last write here
        if (waiting is not null) Invoke(waiting, state, context, scheduler);
    }

    static object? CurrentScheduler()
    {
        if (SynchronizationContext.Current is { } sc && sc.GetType() != typeof(SynchronizationContext)) return sc;
        return TaskScheduler.Current is { } ts && ts != TaskScheduler.Default ? ts : null;
    }

    static void Invoke(Action<object?> continuation, object? state, ExecutionContext? context, object? scheduler)
    {
        if (context is null && scheduler is null) continuation(state); // every await: the state machine flows its own context
        else if (context is null) Dispatch(continuation, state, scheduler);
        else ExecutionContext.Run(context, static p => ((Late)p!).Dispatch(), new Late(continuation, state, null, scheduler));
    }

    static void Dispatch(Action<object?> continuation, object? state, object? scheduler)
    {
        switch (scheduler)
        {
            case SynchronizationContext sc:
                sc.Post(static p => ((Late)p!).Dispatch(), new Late(continuation, state, null, null));
                break;
            case TaskScheduler ts:
                _ = Task.Factory.StartNew(continuation, state, CancellationToken.None, TaskCreationOptions.DenyChildAttach, ts);
                break;
            default:
                continuation(state);
                break;
        }
    }

    /// <summary>A continuation carried to a context, a scheduler or the pool: only off the allocation-free path.</summary>
    sealed class Late(Action<object?> continuation, object? state, ExecutionContext? context, object? scheduler)
    {
        public void Invoke() => CompletionCore.Invoke(continuation, state, context, scheduler);
        public void Dispatch() => CompletionCore.Dispatch(continuation, state, scheduler);
    }

    readonly void Validate(short token)
    {
        if (token != _version) throw new InvalidOperationException("a BcryptQueue result was awaited twice or after it was reused; await each ValueTask once");
    }
}
