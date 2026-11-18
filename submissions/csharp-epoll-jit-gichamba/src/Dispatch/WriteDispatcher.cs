using System.Diagnostics;
using Conduit.Pg;

namespace Conduit.Dispatch;

/// <summary>Where the API hands a write request. <see cref="WriteDispatcher"/> is the real one.</summary>
public interface IWriteQueue {
    /// <summary>Queues a job; it is sent in the next transaction a write connection takes.</summary>
    void Enqueue(WriteJob job);
}

/// <summary>Time source and one-shot timer of the write dispatcher, replaceable in tests.</summary>
public interface IWriteClock {
    /// <summary>Monotonic time in microseconds.</summary>
    long NowMicros { get; }

    /// <summary>Runs <paramref name="action"/> once, about <paramref name="delayMicros"/> from now, on any thread.</summary>
    void CallAfterMicros(long delayMicros, Action action);
}

/// <summary>
/// The real clock: <see cref="Stopwatch"/> time, and one background thread that runs the delayed calls, so a call needs
/// no timer object and no thread-pool hop. Actions run on that thread; an exception from one is dropped.
/// </summary>
public sealed class StopwatchClock : IWriteClock {
    /// <summary>Guards the pending calls and wakes the clock thread.</summary>
    private readonly object _gate = new();
    /// <summary>Pending calls with the time they are due, in microseconds on this clock.</summary>
    private readonly List<(long At, Action Action)> _due = [];

    /// <summary>Starts the clock's thread.</summary>
    public StopwatchClock() => new Thread(Run) { IsBackground = true, Name = "write-clock" }.Start();

    /// <inheritdoc />
    public long NowMicros => ToMicros(Stopwatch.GetTimestamp(), Stopwatch.Frequency);

    /// <summary>
    /// Converts <paramref name="ticks"/> at <paramref name="frequency"/> ticks per second to microseconds. The product is
    /// 128-bit because Linux counts nanoseconds since boot, and times a million that passes a long after 2.56 hours.
    /// </summary>
    internal static long ToMicros(long ticks, long frequency) => (long)((Int128)ticks * 1_000_000 / frequency);

    /// <inheritdoc />
    public void CallAfterMicros(long delayMicros, Action action) {
        lock (_gate) {
            _due.Add((NowMicros + Math.Max(1, delayMicros), action));
            Monitor.Pulse(_gate);
        }
    }

    /// <summary>The clock thread: waits for the earliest pending call and runs it.</summary>
    private void Run() {
        while (true) {
            Action action;
            lock (_gate) {
                while (true) {
                    int next = -1;
                    for (int i = 0; i < _due.Count; i++) {
                        if (next < 0 || _due[i].At < _due[next].At) {
                            next = i;
                        }
                    }
                    if (next < 0) {
                        Monitor.Wait(_gate);
                        continue;
                    }

                    long wait = _due[next].At - NowMicros;
                    if (wait > 0) {
                        // Monitor.Wait counts whole milliseconds; round up so a call never runs early.
                        Monitor.Wait(_gate, (int)Math.Min(1000, (wait + 999) / 1000));
                        continue;
                    }

                    action = _due[next].Action;
                    _due.RemoveAt(next);
                    break;
                }
            }
            try {
                action();
            } catch (Exception) {
                // An action answers its own clients; one that fails must not stop the clock.
            }
        }
    }
}

/// <summary>
/// Queue and write connections, with group commit. A free connection takes up to 128 waiting writes as one transaction,
/// and each write is answered only after its transaction commits. When an arrival finds the system idle and only that
/// write waiting, it waits up to 1 ms for company; a connection that has just finished a transaction never waits. A
/// failed transaction is rolled back and each of its writes runs again alone, so one bad write never fails the others.
/// A write lost with its connection is answered with 500 and never replayed, since it may have committed.
/// </summary>
public sealed class WriteDispatcher : IWriteQueue {
    /// <summary>Most writes in one transaction.</summary>
    public const int MaxGroup = 128;

    /// <summary>How long a lone write waits for company when the system is idle, in microseconds.</summary>
    public const long WaitMicros = 1000;

    /// <summary>The state of one write connection.</summary>
    private sealed class Slot {
        /// <summary>The attached connection, or null while it is down.</summary>
        public IPgLink? Link;
        /// <summary>True while a transaction is in flight on the connection.</summary>
        public bool Busy;
        /// <summary>The last request failed, so the connection's transaction may be left aborted. The next transaction starts with ROLLBACK.</summary>
        public bool Dirty;
        /// <summary>Changes with every new link or loss. A batch keeps the value it was sent on, so a stale batch is recognised.</summary>
        public int Generation;
    }

    /// <summary>Guards the queues, slots, wake flag and arrival counter.</summary>
    private readonly object _gate = new();
    /// <summary>Time source and timer for the 1 ms wait.</summary>
    private readonly IWriteClock _clock;
    /// <summary>Counters to report to, or null.</summary>
    private readonly Stats? _stats;
    /// <summary>One slot per write connection.</summary>
    private readonly Slot[] _slots;
    /// <summary>Waiting writes, oldest first.</summary>
    private readonly JobQueue<WriteJob> _queue = new();
    /// <summary>Writes of failed groups, run alone before anything else.</summary>
    private readonly JobQueue<WriteJob> _reruns = new();
    /// <summary>The last arrival number handed out.</summary>
    private long _seq;
    /// <summary>True while a delayed call to <see cref="OnWake"/> is scheduled.</summary>
    private bool _wakePending;

    /// <summary>The counters this dispatcher reports to, or null.</summary>
    internal Stats? Stats => _stats;

    /// <summary>Creates a dispatcher with <c>settings.PgWrite</c> connection slots. Attach connections with <see cref="SetLink"/>.</summary>
    public WriteDispatcher(Settings settings, IWriteClock clock, Stats? stats) {
        _clock = clock;
        _stats = stats;
        _slots = [.. Enumerable.Range(0, settings.PgWrite).Select(_ => new Slot())];
    }

    /// <summary>Queues <paramref name="job"/> and sends what can go now.</summary>
    public void Enqueue(WriteJob job) {
        lock (_gate) {
            job.Seq = ++_seq;
            job.EnqueuedMicros = _clock.NowMicros;
            _queue.PushBack(job);
        }
        Pump(mayWait: true);
    }

    /// <summary>Attaches a working connection to slot <paramref name="slot"/> (also after a reconnect) and sends what is waiting.</summary>
    public void SetLink(int slot, IPgLink link) {
        lock (_gate) {
            Slot s = _slots[slot];
            Forget(s);
            s.Link = link;
        }
        Pump(mayWait: true);
    }

    /// <summary>
    /// A connection broke with <paramref name="lost"/> requests in flight. Every write in them gets a 500 and none is
    /// replayed: once COMMIT may have reached the server the outcome is unknown, and a replay could apply a write twice.
    /// Writes not yet sent stay queued for another connection. Never throws.
    /// </summary>
    public void LinkBroken(int slot, IPgLink link, IReadOnlyList<PgRequest> lost, Exception error) {
        List<WriteJob>? failed = null;
        bool disconnected = false;
        lock (_gate) {
            Slot s = _slots[slot];
            if (ReferenceEquals(s.Link, link)) {
                Forget(s);
                disconnected = true;
            }
            foreach (PgRequest request in lost) {
                if (request is WriteBatch batch && batch.TryAbandon()) {
                    (failed ??= []).AddRange(batch.Jobs);
                }
            }
        }
        if (disconnected) {
            _stats?.RecordWriteError($"write connection {slot} lost: {error.Message}");
        }

        if (failed is not null) {
            foreach (WriteJob job in failed) {
                FailQuietly(job, "database unavailable");
            }
        }
        Pump(mayWait: true);
    }

    /// <summary>A transaction finished: free its connection and send what is waiting. No wait follows a finished group.</summary>
    internal void BatchDone(WriteBatch batch, bool failed) {
        lock (_gate) {
            Slot s = _slots[batch.Slot];
            if (s.Generation == batch.Generation) {
                s.Busy = false;
                s.Dirty = failed;
            }
        }
        Pump(mayWait: false);
    }

    /// <summary>A group of several writes failed: its writes run again one by one, each in its own transaction.</summary>
    internal void GroupFailed(WriteBatch batch) {
        lock (_gate) {
            Slot s = _slots[batch.Slot];
            if (s.Generation == batch.Generation) {
                s.Busy = false;
                s.Dirty = true;
            }
            foreach (WriteJob job in batch.Jobs) {
                _reruns.PushBack(job);
            }
        }
        Pump(mayWait: false);
    }

    /// <summary>Answers <paramref name="job"/> with a 500, ignoring a client that is already gone.</summary>
    private static void FailQuietly(WriteJob job, string message) {
        try {
            job.ResetResult();
            job.Fail(500, message);
        } catch (Exception) {
            // The client is gone; there is no one left to answer.
        }
    }

    /// <summary>The link of a slot is gone or replaced: forgets what was running on it. A new connection starts clean.</summary>
    private static void Forget(Slot s) {
        s.Link = null;
        s.Generation++;
        s.Busy = false;
        s.Dirty = false;
    }

    /// <summary>
    /// Forms and sends transactions until no connection is free or nothing is waiting. Sends happen outside the lock.
    /// <paramref name="mayWait"/> lets a lone write on an idle system wait for company.
    /// </summary>
    private void Pump(bool mayWait) {
        while (true) {
            IPgLink? link = null;
            bool schedule = false;
            WriteBatch? batch;
            List<WriteJob>? jobs;
            bool rollbackFirst;
            long wakeIn;
            lock (_gate) {
                batch = Form(mayWait, out jobs, out rollbackFirst, out wakeIn);
                if (batch is null) {
                    if (wakeIn > 0 && !_wakePending) {
                        _wakePending = schedule = true;
                    }
                } else {
                    link = _slots[batch.Slot].Link;
                }
            }
            if (batch is null) {
                if (schedule) {
                    _clock.CallAfterMicros(wakeIn, OnWake);
                }

                return;
            }

            try {
                batch.Build(jobs!, rollbackFirst);
            } catch (Exception ex) {
                _stats?.RecordWriteError($"write: cannot encode transaction: {ex.Message}");
                lock (_gate) {
                    Slot s = _slots[batch.Slot];
                    if (s.Generation == batch.Generation) {
                        s.Busy = false;
                    }
                }
                foreach (WriteJob job in jobs!) {
                    FailQuietly(job, "internal error");
                }
                continue;
            }
            _stats?.RecordPgExecutions(1);
            try {
                link!.Send(batch);
            } catch (Exception ex) {
                // Send throws only before anything was written, so these writes never reached Postgres: queue them again.
                // Not every failure comes from a broken connection; make sure the pool replaces this one.
                try {
                    link!.Abort(ex);
                } catch (Exception) {
                    // Aborting is best effort; the connection is being replaced either way.
                }
                bool disconnected = false;
                lock (_gate) {
                    Slot s = _slots[batch.Slot];
                    if (ReferenceEquals(s.Link, link)) {
                        Forget(s);
                        disconnected = true;
                    }
                    for (int i = jobs!.Count - 1; i >= 0; i--) {
                        jobs[i].ResetResult();
                        _queue.PushFront(jobs[i]);
                    }
                }
                if (disconnected) {
                    _stats?.RecordWriteError($"write connection {batch.Slot} cannot send: {ex.Message}");
                }
            }
        }
    }

    /// <summary>Runs when the wait for company ends: clears the pending flag and sends what is waiting.</summary>
    private void OnWake() {
        lock (_gate) {
            _wakePending = false;
        }

        Pump(mayWait: true);
    }

    /// <summary>
    /// Picks a free connection and takes the writes for it: one write of a failed group first, otherwise up to
    /// <see cref="MaxGroup"/> waiting writes. Returns null when nothing can go; <paramref name="wakeIn"/> &gt; 0 then asks
    /// for a call after that many microseconds. Caller holds the lock.
    /// </summary>
    private WriteBatch? Form(bool mayWait, out List<WriteJob>? jobs, out bool rollbackFirst, out long wakeIn) {
        jobs = null;
        rollbackFirst = false;
        wakeIn = 0;

        int free = -1;
        bool anyBusy = false;
        for (int i = 0; i < _slots.Length; i++) {
            Slot s = _slots[i];
            if (s.Link is null) {
                continue;
            }

            if (s.Busy) {
                anyBusy = true;
            } else if (free < 0) {
                free = i;
            }
        }
        if (free < 0) {
            return null;
        }

        DropClosed(_reruns);
        DropClosed(_queue);
        if (_reruns.Count > 0) {
            jobs = [_reruns.PopFront()];
        } else {
            if (_queue.Count == 0) {
                return null;
            }

            if (mayWait && _queue.Count == 1 && !anyBusy) {
                // Idle system, one write waiting: give a second write up to 1 ms to arrive.
                long age = _clock.NowMicros - _queue.Peek().EnqueuedMicros;
                if (age < WaitMicros) {
                    wakeIn = WaitMicros - age;
                    return null;
                }
            }
            jobs = new List<WriteJob>(Math.Min(_queue.Count, MaxGroup));
            while (_queue.Count > 0 && jobs.Count < MaxGroup) {
                WriteJob job = _queue.PopFront();
                if (!job.Client.IsClosed) {
                    jobs.Add(job);
                }
            }
            if (jobs.Count == 0) {
                return null;
            }
        }

        Slot slot = _slots[free];
        slot.Busy = true;
        rollbackFirst = slot.Dirty;
        return new WriteBatch(this) { Slot = free, Generation = slot.Generation };
    }

    /// <summary>
    /// Removes writes whose client has gone from the front of a queue. A write is applied only while someone waits for
    /// its answer; one whose client left before it was sent is dropped.
    /// </summary>
    private static void DropClosed(JobQueue<WriteJob> q) {
        while (q.Count > 0 && q.Peek().Client.IsClosed) {
            q.PopFront().ResetResult();
        }
    }
}
