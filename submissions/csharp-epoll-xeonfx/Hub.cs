using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;

/// <summary>
/// What the loops share: one queue of reads and one of writes, filled by every loop and emptied by whichever loop has
/// an idle Postgres connection, and the loops themselves, to wake one that has. A lock guards each queue and is held
/// only to link or unlink jobs.
/// </summary>
sealed class Hub
{
    // Measured on the contest box shape (8 vCPUs, Postgres on the same box) at 160,000 users; see the README.
    /// <summary>Epoll loops: a quarter of the cores, so Postgres keeps the rest (3 and 4 on 8 cores cost more CPU
    /// per request than 2).</summary>
    public static readonly int LoopCount = Math.Max(1, Environment.ProcessorCount / 4);
    /// <summary>Read connections in all, about one per core (6 and 12 on 8 cores held fewer users than 8), well
    /// under Postgres's 100 connections; one group-commit writer.</summary>
    public static readonly int Readers = Math.Clamp(Environment.ProcessorCount, 2, 64);
    public const int Writers = 1;
    public const int MaxBatch = 512, MaxGroup = 512;
    /// <summary>With no connection up, reads fail at once and writes after this long.</summary>
    public const int DownWaitMs = 2000;

    /// <summary>An idle reader takes the queue once its oldest read has waited this long, or at once when
    /// <see cref="MaxBatch"/> wait: the reads of a short wait share one batch's statements instead of each paying
    /// them. 5 ms beat 1 and 2 ms.</summary>
    public const int BatchWindowMicros = 5000;
    public static readonly long BatchWindow = BatchWindowMicros * Stopwatch.Frequency / 1_000_000;
    public static readonly long GroupWindow = 1000 * Stopwatch.Frequency / 1_000_000;

    public Loop[] Loops = [];
    /// <summary>Connected readers and writers in all, kept by the loops that own them.</summary>
    public int LiveReaders, LiveWriters;

    readonly JobQueue _reads = new(), _writes = new();

    /// <summary>The loops for <paramref name="loops"/> threads, with the readers spread from the first loop and the
    /// writers from the last, so that with two loops each side's jobs also run on the other's connections.</summary>
    public Hub(string host, int port, PgSettings db, int loops, int readers, int writers)
    {
        Loops = new Loop[loops];
        for (int i = 0; i < loops; i++)
        {
            int r = readers / loops + (i < readers % loops ? 1 : 0);
            int w = writers / loops + (loops - 1 - i < writers % loops ? 1 : 0);
            Loops[i] = new Loop(this, i, host, port, db, r, w);
        }
    }

    /// <summary>Starts every loop on its own thread.</summary>
    public Thread[] Start(bool background = false)
    {
        var threads = new Thread[Loops.Length];
        for (int i = 0; i < Loops.Length; i++)
        {
            threads[i] = new Thread(Loops[i].Run) { Name = "loop " + i, IsBackground = background };
            threads[i].Start();
        }
        return threads;
    }

    // ---- reads

    /// <summary>Queues a read; wakes a loop with an idle reader when <paramref name="from"/> has none.</summary>
    public void EnqueueRead(Job job, Loop from)
    {
        job.QueuedAt = Stopwatch.GetTimestamp();
        _reads.Add(job);
        Interlocked.MemoryBarrier(); // pairs with Loop.Publish: one of us sees the other
        if (Volatile.Read(ref from.IdleReaders) == 0) WakeOne(from, reader: true);
    }

    /// <summary>Puts reads back at the front, in their order: they have waited already.</summary>
    public void RequeueReads(List<Job> jobs) => _reads.AddFront(jobs);

    /// <summary>Takes the reads for the next batch when they are due: a job to run alone by itself, else up to
    /// <see cref="MaxBatch"/>. Otherwise <paramref name="due"/> is when they will be (long.MaxValue: none wait).</summary>
    public bool TakeReads(long now, bool hurry, List<Job> into, out long due) =>
        _reads.Take(now, hurry ? 0 : BatchWindow, MaxBatch, into, out due);

    /// <summary>Takes every read (to fail them: no reader is up).</summary>
    public void TakeAllReads(List<Job> into) => _reads.Take(long.MaxValue, 0, int.MaxValue, into, out _);

    public int ReadsWaiting => _reads.Count;

    // ---- writes

    public void EnqueueWrite(Job job, Loop from)
    {
        job.QueuedAt = Stopwatch.GetTimestamp();
        _writes.Add(job);
        Interlocked.MemoryBarrier();
        if (Volatile.Read(ref from.IdleWriters) == 0) WakeOne(from, reader: false);
    }

    public void RequeueWrites(List<Job> jobs) => _writes.AddFront(jobs);

    public bool TakeWrites(long now, bool hurry, List<Job> into, out long due) =>
        _writes.Take(now, hurry ? 0 : GroupWindow, MaxGroup, into, out due);

    /// <summary>Takes the writes that have waited since before <paramref name="before"/>.</summary>
    public void TakeWritesQueuedBefore(long before, List<Job> into) => _writes.TakeOlderThan(before, into);

    public int WritesWaiting => _writes.Count;

    void WakeOne(Loop from, bool reader)
    {
        foreach (Loop loop in Loops)
            if (loop != from && Volatile.Read(ref reader ? ref loop.IdleReaders : ref loop.IdleWriters) > 0)
            {
                loop.Wake();
                return;
            }
    }
}

/// <summary>A FIFO of jobs linked through <see cref="Job.QueueNext"/>, under one lock.</summary>
sealed class JobQueue
{
    readonly object _lock = new();
    Job? _head, _tail;
    int _count;

    public int Count => Volatile.Read(ref _count);

    public void Add(Job job)
    {
        job.QueueNext = null;
        lock (_lock)
        {
            if (_tail == null) _head = job;
            else _tail.QueueNext = job;
            _tail = job;
            _count++;
        }
    }

    public void AddFront(List<Job> jobs)
    {
        if (jobs.Count == 0) return;
        for (int i = 0; i < jobs.Count - 1; i++) jobs[i].QueueNext = jobs[i + 1];
        lock (_lock)
        {
            jobs[^1].QueueNext = _head;
            if (_head == null) _tail = jobs[^1];
            _head = jobs[0];
            _count += jobs.Count;
        }
    }

    /// <summary>When the oldest has waited <paramref name="window"/> by <paramref name="now"/>, or <paramref name="max"/>
    /// wait: takes up to <paramref name="max"/>, or the oldest alone when it is to run alone (and stops before one that
    /// is).</summary>
    public bool Take(long now, long window, int max, List<Job> into, out long due)
    {
        lock (_lock)
        {
            due = long.MaxValue;
            if (_head == null) return false;
            if (_count < max && now - _head.QueuedAt < window)
            {
                due = _head.QueuedAt + window;
                return false;
            }
            int n = 0;
            if (_head.Alone) n = Unlink(into, 1);
            else
            {
                Job? j = _head;
                while (j != null && n < max && !j.Alone)
                {
                    n++;
                    j = j.QueueNext;
                }
                Unlink(into, n);
            }
            return true;
        }
    }

    public void TakeOlderThan(long before, List<Job> into)
    {
        lock (_lock)
        {
            int n = 0;
            for (Job? j = _head; j != null && j.QueuedAt < before; j = j.QueueNext) n++;
            Unlink(into, n);
        }
    }

    int Unlink(List<Job> into, int n)
    {
        for (int i = 0; i < n; i++)
        {
            Job j = _head!;
            _head = j.QueueNext;
            j.QueueNext = null;
            into.Add(j);
        }
        if (_head == null) _tail = null;
        _count -= n;
        return n;
    }
}
