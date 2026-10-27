using Conduit.Pg;

namespace Conduit.Dispatch;

/// <summary>Where the API hands a read request. <see cref="ReadDispatcher"/> is the real one.</summary>
public interface IReadQueue {
    /// <summary>Queues a job. It is sent when a read connection has room and its family's gather window has ended.</summary>
    void Enqueue(ReadJob job);
}

/// <summary>What the dispatchers need from a Postgres connection: send one request. Throws when the connection is broken.</summary>
public interface IPgLink {
    /// <summary>Sends the request without waiting. Throws <see cref="InvalidOperationException"/> if the connection is broken.</summary>
    void Send(PgRequest request);

    /// <summary>
    /// Breaks the connection after a failure that left it unusable, so the pool thread notices and replaces it.
    /// The default does nothing.
    /// </summary>
    void Abort(Exception reason) {
    }
}

/// <summary>
/// Per-family FIFO queues feeding the read connections. Whenever a request arrives, a batch finishes or the gather timer
/// ticks, while some connection has fewer than PG_DEPTH batches in flight, the family whose oldest request has waited
/// longest sends up to BATCH_MAX of its waiting requests as one batch. A family waits until its batch is full or its
/// oldest request has waited GATHER_MS, so that more requests share one execution. A request that arrives after a batch
/// formed waits for the next one.
/// </summary>
public sealed class ReadDispatcher : IReadQueue {
    /// <summary>The state of one read connection.</summary>
    private sealed class Slot {
        /// <summary>The attached connection, or null while it is down.</summary>
        public IPgLink? Link;
        /// <summary>Batches sent and not finished on the current link.</summary>
        public int InFlight;
        /// <summary>Changes with every new link or loss. A batch keeps the value it was sent on, so a stale batch is recognised.</summary>
        public int Generation;
        /// <summary>Batches in flight per family position.</summary>
        public readonly int[] PerFamily = new int[ReadKinds.Slots];
    }

    /// <summary>Guards the queues, slots, spare batches and the arrival counter.</summary>
    private readonly object _gate = new();
    /// <summary>The switches the dispatcher reads: GatherMs, BatchMax and PgDepth.</summary>
    private readonly Settings _settings;
    /// <summary>Counters to report to, or null.</summary>
    private readonly Stats? _stats;
    /// <summary>The registered families.</summary>
    private readonly ReadFamily[] _families;
    /// <summary>Waiting jobs by family position, null for an unregistered position.</summary>
    private readonly JobQueue<ReadJob>?[] _queues = new JobQueue<ReadJob>?[ReadKinds.Slots];
    /// <summary>One slot per read connection.</summary>
    private readonly Slot[] _slots;
    /// <summary>Finished batches kept for reuse.</summary>
    private readonly Stack<ReadBatch> _spare = new();
    /// <summary>Time source in milliseconds.</summary>
    private readonly Func<long> _clockMs;
    /// <summary>The last arrival number handed out.</summary>
    private long _seq;

    /// <summary>
    /// Creates a dispatcher with <c>settings.PgRead</c> connection slots. Connections are attached later with
    /// <see cref="SetLink"/>. <paramref name="clockMs"/> gives the time in milliseconds (default <see cref="Environment.TickCount64"/>).
    /// </summary>
    public ReadDispatcher(Settings settings, IReadOnlyList<ReadFamily> families, Stats? stats, Func<long>? clockMs = null) {
        _settings = settings;
        _stats = stats;
        _clockMs = clockMs ?? (() => Environment.TickCount64);
        _families = [.. families];
        foreach (ReadFamily f in _families) {
            _queues[f.Index] = new JobQueue<ReadJob>();
        }

        _slots = [.. Enumerable.Range(0, settings.PgRead).Select(_ => new Slot())];
        if (stats is not null) {
            stats.OldestQueueAgeMs = OldestAgeMs;
        }
    }

    /// <summary>The counters this dispatcher reports to, or null.</summary>
    internal Stats? Stats => _stats;

    /// <summary>Queues <paramref name="job"/> and sends what can go now.</summary>
    /// <exception cref="ArgumentException">The job's family is not registered.</exception>
    public void Enqueue(ReadJob job) {
        JobQueue<ReadJob> queue = _queues[job.Family.Index] ?? throw new ArgumentException("family is not registered: " + job.Family.Name);
        lock (_gate) {
            job.Seq = ++_seq;
            job.EnqueuedMs = _clockMs();
            queue.PushBack(job);
        }
        _stats?.RecordRequest(job.Kind);
        Pump();
    }

    /// <summary>Sends the batches whose gather window has ended. A timer calls this every millisecond.</summary>
    public void Tick() => Pump();

    /// <summary>Milliseconds the oldest waiting request has waited, or 0 when nothing waits.</summary>
    public long OldestAgeMs() {
        long oldest = long.MaxValue;
        lock (_gate) {
            foreach (ReadFamily f in _families) {
                JobQueue<ReadJob> q = _queues[f.Index]!;
                if (q.Count > 0) {
                    oldest = Math.Min(oldest, q.Peek().EnqueuedMs);
                }
            }
        }
        return oldest == long.MaxValue ? 0 : _clockMs() - oldest;
    }

    /// <summary>Attaches a working connection to slot <paramref name="slot"/> (also after a reconnect) and sends what is waiting.</summary>
    public void SetLink(int slot, IPgLink link) {
        lock (_gate) {
            Slot s = _slots[slot];
            Forget(s);
            s.Link = link;
        }
        Pump();
    }

    /// <summary>
    /// A connection broke with <paramref name="lost"/> requests in flight. Each lost read runs again once on another
    /// connection; one that was already tried twice gets a 500. Never throws.
    /// </summary>
    public void LinkBroken(int slot, IPgLink link, IReadOnlyList<PgRequest> lost, Exception error) {
        List<ReadJob>? failed = null;
        bool disconnected = false;
        lock (_gate) {
            Slot s = _slots[slot];
            if (ReferenceEquals(s.Link, link)) {
                Forget(s);
                disconnected = true;
            }
            foreach (PgRequest request in lost) {
                if (request is not ReadBatch batch || !batch.TryAbandon()) {
                    continue;
                }

                for (int i = batch.Count - 1; i >= 0; i--) {
                    ReadJob job = batch.Jobs[i];
                    if (job.Attempts < 2) {
                        job.ResetResult();
                        _queues[job.Family.Index]!.PushFront(job);
                    } else {
                        (failed ??= []).Add(job);
                    }
                }
            }
        }
        if (disconnected) {
            _stats?.RecordReadError($"read connection {slot} lost: {error.Message}");
        }

        if (failed is not null) {
            foreach (ReadJob job in failed) {
                try {
                    job.ResetResult();
                    job.Fail(500, "database unavailable");
                } catch (Exception) {
                    // The client is gone; there is no one left to answer.
                }
            }
        }
        Pump();
    }

    /// <summary>A batch finished: free its place and send what is waiting.</summary>
    internal void BatchDone(ReadBatch batch) {
        Release(batch);
        Pump();
    }

    /// <summary>
    /// Sends the next round trip of a batch whose family owns its batches, on the connection it is running on. When that
    /// connection is gone or the send fails, the batch's requests are handled like those of a broken connection.
    /// </summary>
    internal void SendNext(ReadBatch batch) {
        IPgLink? link;
        lock (_gate) {
            Slot s = _slots[batch.Slot];
            link = s.Generation == batch.Generation ? s.Link : null;
        }
        if (link is null) {
            LinkBroken(batch.Slot, NoLink.Instance, [batch], new InvalidOperationException("the connection was replaced"));
            return;
        }

        try {
            link.Send(batch);
        } catch (Exception ex) {
            AbortQuietly(link, ex);
            LinkBroken(batch.Slot, link, [batch], ex);
        }
    }

    /// <summary>Stands for a connection that is already gone, so <see cref="LinkBroken"/> only re-queues the requests.</summary>
    private sealed class NoLink : IPgLink {
        /// <summary>The single instance.</summary>
        public static readonly NoLink Instance = new();

        /// <summary>Always throws, as a connection that is gone would.</summary>
        public void Send(PgRequest request) => throw new InvalidOperationException("no connection");
    }

    /// <summary>Breaks <paramref name="link"/> after a failed send, so its pool replaces it even when the failure was not the socket's.</summary>
    private static void AbortQuietly(IPgLink link, Exception reason) {
        try {
            link.Abort(reason);
        } catch (Exception) {
            // Aborting is best effort; the connection is being replaced either way.
        }
    }

    /// <summary>Frees a finished batch's place on its connection (unless the connection was replaced meanwhile) and recycles it.</summary>
    private void Release(ReadBatch batch) {
        lock (_gate) {
            Slot s = _slots[batch.Slot];
            if (s.Generation == batch.Generation) {
                s.InFlight--;
                s.PerFamily[batch.Family.Index]--;
            }
            batch.Clear();
            _spare.Push(batch);
        }
    }

    /// <summary>The link of a slot is gone or replaced: forgets what was running on it.</summary>
    private static void Forget(Slot s) {
        s.Link = null;
        s.Generation++;
        s.InFlight = 0;
        Array.Clear(s.PerFamily);
    }

    /// <summary>Forms and sends batches until no connection has room or nothing is due. Sends happen outside the lock.</summary>
    private void Pump() {
        while (true) {
            ReadBatch? batch;
            IPgLink link;
            lock (_gate) {
                batch = Form(out int slot);
                if (batch is null) {
                    return;
                }

                link = _slots[slot].Link!;
            }
            _stats?.RecordBatch(batch.Count);
            _stats?.RecordPgExecutions(1);
            try {
                batch.Prepare();
            } catch (Exception ex) {
                _stats?.RecordReadError($"read {batch.Family.Name}: cannot encode batch: {ex.Message}");
                for (int i = 0; i < batch.Count; i++) {
                    try {
                        batch.Jobs[i].ResetResult();
                        batch.Jobs[i].Fail(500, "internal error");
                    } catch (Exception) {
                        // The client is gone; there is no one left to answer.
                    }
                }
                Release(batch);
                continue;
            }
            try {
                link.Send(batch);
            } catch (Exception ex) {
                AbortQuietly(link, ex);
                LinkBroken(batch.Slot, link, [batch], ex);
            }
        }
    }

    /// <summary>Picks the family with the oldest due request that has a usable connection, and takes its jobs. Caller holds the lock.</summary>
    private ReadBatch? Form(out int slotIndex) {
        slotIndex = -1;
        int rejected = 0;  // bit per family position: has due work but no usable connection right now
        long now = _clockMs();
        while (true) {
            ReadFamily? best = null;
            long oldest = long.MaxValue;
            foreach (ReadFamily f in _families) {
                if ((rejected & (1 << f.Index)) != 0) {
                    continue;
                }

                JobQueue<ReadJob> q = _queues[f.Index]!;
                DropClosed(q);
                if (q.Count > 0 && q.Peek().Seq < oldest && Due(q, now)) {
                    oldest = q.Peek().Seq;
                    best = f;
                }
            }
            if (best is null) {
                return null;
            }

            int s = PickSlot(best);
            if (s < 0) {
                rejected |= 1 << best.Index;
                continue;
            }

            Slot slot = _slots[s];
            ReadBatch batch = _spare.Count > 0 ? _spare.Pop() : new ReadBatch(this, _settings.BatchMax);
            batch.Begin(best);
            JobQueue<ReadJob> queue = _queues[best.Index]!;
            while (queue.Count > 0 && batch.Count < _settings.BatchMax) {
                ReadJob job = queue.PopFront();
                if (job.Client.IsClosed) {
                    job.ResetResult();
                    continue;
                }

                job.Attempts++;
                batch.Add(job);
            }
            batch.Slot = s;
            batch.Generation = slot.Generation;
            slot.InFlight++;
            slot.PerFamily[best.Index]++;
            slotIndex = s;
            return batch;
        }
    }

    /// <summary>Drops requests at the front of <paramref name="queue"/> whose client has gone: nobody would read the answer.</summary>
    private static void DropClosed(JobQueue<ReadJob> queue) {
        while (queue.Count > 0 && queue.Peek().Client.IsClosed) {
            queue.PopFront().ResetResult();
        }
    }

    /// <summary>True when a family's batch should go now: it is full, or its oldest request has waited the gather window. Caller holds the lock.</summary>
    private bool Due(JobQueue<ReadJob> queue, long now) =>
        queue.Count >= _settings.BatchMax || now - queue.Peek().EnqueuedMs >= _settings.GatherMs;

    /// <summary>
    /// The connection with the fewest batches in flight that has room, keeping at most half the connections (at least one)
    /// on one family unless it may use every connection. -1 when there is none. Caller holds the lock.
    /// </summary>
    private int PickSlot(ReadFamily family) {
        int cap = family.UsesEveryConnection ? _slots.Length : Math.Max(1, _slots.Length / 2);
        int running = 0;
        foreach (Slot s in _slots) {
            if (s.PerFamily[family.Index] > 0) {
                running++;
            }
        }

        int best = -1;
        for (int i = 0; i < _slots.Length; i++) {
            Slot s = _slots[i];
            if (s.Link is null || s.InFlight >= _settings.PgDepth) {
                continue;
            }

            if (s.PerFamily[family.Index] == 0 && running >= cap) {
                continue;
            }
            if (best < 0 || s.InFlight < _slots[best].InFlight) {
                best = i;
            }
        }
        return best;
    }
}
