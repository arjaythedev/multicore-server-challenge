using System;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using CodeFusion.Security;

namespace Conduit;

/// <summary>
/// Counters of the reader, the writer and the bcrypt queue, and the runtime's GC and thread pool, printed as one line
/// per interval. Only the reader and writer loops update theirs, once per group (a few thousand times a second at
/// most), never per request; the bcrypt queue keeps its own.
/// </summary>
public static class Stats
{
    // writer
    public static long WriteGroups, WritesGrouped, WriteGroupMax, CommitTicks, CommitTicksMax, WriteWaitTicksMax, WriteRetries, WritesRefused;
    // reader
    public static long ReadGroups, ReadsGrouped, ReadGroupMax, ReadReruns, ReadsRefused;

    public static void Max(ref long field, long value)
    {
        for (long seen = Volatile.Read(ref field); value > seen; seen = Volatile.Read(ref field))
            if (Interlocked.CompareExchange(ref field, value, seen) == seen) return;
    }

    /// <summary>Prints a line every <paramref name="interval"/> on stdout until the process exits; the queues' depths
    /// come from <paramref name="readsQueued"/>, <paramref name="writesQueued"/> and <paramref name="bcrypt"/>.</summary>
    public static void Start(TimeSpan interval, Func<int> readsQueued, Func<int> writesQueued, BcryptQueue bcrypt)
    {
        if (interval <= TimeSpan.Zero) return;
        _ = Task.Run(async () =>
        {
            using var timer = new PeriodicTimer(interval);
            var last = Snapshot.Take(bcrypt);
            while (await timer.WaitForNextTickAsync())
            {
                var now = Snapshot.Take(bcrypt);
                Console.Out.WriteLine(Line(last, now, readsQueued(), writesQueued(), bcrypt.QueueLength));
                last = now;
            }
        });
    }

    readonly record struct Snapshot(long At, long Reads, long ReadJobs, long ReadRerunCount, long ReadRefusals, long Groups, long Grouped, long Commit, long Reruns, long WriteRefusals,
        long Batches, long Jobs, long BcryptCancelled, long BcryptRefusals, int Gen0, int Gen1, int Gen2, TimeSpan Pause, long Allocated, TimeSpan Cpu)
    {
        public static Snapshot Take(BcryptQueue q) => new(Stopwatch.GetTimestamp(),
            Interlocked.Read(ref ReadGroups), Interlocked.Read(ref ReadsGrouped), Interlocked.Read(ref ReadReruns), Interlocked.Read(ref ReadsRefused),
            Interlocked.Read(ref WriteGroups), Interlocked.Read(ref WritesGrouped), Interlocked.Read(ref CommitTicks),
            Interlocked.Read(ref WriteRetries), Interlocked.Read(ref WritesRefused),
            q.Batches, q.HashesRun, q.Cancelled, q.Refused,
            GC.CollectionCount(0), GC.CollectionCount(1), GC.CollectionCount(2), GC.GetTotalPauseDuration(),
            GC.GetTotalAllocatedBytes(), Environment.CpuUsage.TotalTime);
    }

    static double Ms(long ticks) => ticks * 1000.0 / Stopwatch.Frequency;

    static string Line(Snapshot a, Snapshot b, int readsQueued, int writesQueued, int bcryptQueued)
    {
        double seconds = (b.At - a.At) / (double)Stopwatch.Frequency;
        long readGroups = b.Reads - a.Reads, groups = b.Groups - a.Groups, batches = b.Batches - a.Batches;
        return
            $"stats {seconds:0}s: reads queued {readsQueued}, groups {readGroups} (avg {(readGroups > 0 ? (b.ReadJobs - a.ReadJobs) / (double)readGroups : 0):0.0}, " +
            $"max {Interlocked.Exchange(ref ReadGroupMax, 0)}), reruns {b.ReadRerunCount - a.ReadRerunCount}, refused {b.ReadRefusals - a.ReadRefusals}; " +
            $"writes queued {writesQueued}, max wait {Ms(Interlocked.Exchange(ref WriteWaitTicksMax, 0)):0} ms, " +
            $"groups {groups} (avg {(groups > 0 ? (b.Grouped - a.Grouped) / (double)groups : 0):0.0}, max {Interlocked.Exchange(ref WriteGroupMax, 0)}), " +
            $"commit avg {(groups > 0 ? Ms(b.Commit - a.Commit) / groups : 0):0.0} ms max {Ms(Interlocked.Exchange(ref CommitTicksMax, 0)):0} ms, " +
            $"reruns {b.Reruns - a.Reruns}, refused {b.WriteRefusals - a.WriteRefusals}; " +
            $"bcrypt queued {bcryptQueued}, " +
            $"batches {batches} (avg {(batches > 0 ? (b.Jobs - a.Jobs) / (double)batches : 0):0.0} lanes), cancelled {b.BcryptCancelled - a.BcryptCancelled}, refused {b.BcryptRefusals - a.BcryptRefusals}; " +
            $"gc {b.Gen0 - a.Gen0}/{b.Gen1 - a.Gen1}/{b.Gen2 - a.Gen2} pause {(b.Pause - a.Pause).TotalMilliseconds:0} ms, " +
            $"alloc {(b.Allocated - a.Allocated) / seconds / (1 << 20):0} MB/s, heap {GC.GetGCMemoryInfo().HeapSizeBytes >> 20} MB; " +
            $"cpu {(b.Cpu - a.Cpu).TotalSeconds / seconds:0.00} cores, pool threads {ThreadPool.ThreadCount}, pending {ThreadPool.PendingWorkItemCount}";
    }
}
