using System.Collections.Concurrent;
using System.Runtime.InteropServices;

namespace Conduit;

// bcrypt runs on a few dedicated threads, not the thread pool (whose threads here are the socket threads).
// A worker collects up to four jobs and computes them interleaved (BCrypt.ComputeBatch), which costs less CPU per
// hash than computing them one by one. Like group commit, the worker holding one job waits up to BatchWait for
// others before it starts (logins are rare). One worker collects at a time (so two workers never split
// what would have been one batch); the others compute meanwhile.
static partial class CpuWork
{
    static readonly BlockingCollection<Ctx> Queue = new(new ConcurrentQueue<Ctx>());
    static readonly Lock Collecting = new();
    static TimeSpan _batchWait;

    public static void Init(int threads, int nice, int batchWaitMs)
    {
        _batchWait = TimeSpan.FromMilliseconds(batchWaitMs);
        for (int i = 0; i < Math.Max(1, threads); i++)
        {
            var t = new Thread(() => Loop(nice)) { IsBackground = true, Name = "bcrypt-" + i };
            t.Start();
        }
    }

    [LibraryImport("libc", SetLastError = true)]
    private static partial int setpriority(int which, int who, int prio);

    [LibraryImport("libc")]
    private static partial int gettid();

    static void Loop(int nice)
    {
        if (nice != 0 && OperatingSystem.IsLinux() && setpriority(0 /* PRIO_PROCESS */, gettid(), nice) != 0)
            Console.Error.WriteLine($"setpriority({nice}) failed: errno {Marshal.GetLastPInvokeError()}");
        var batch = new Ctx[BCrypt.MaxBatch];
        var jobs = new BCrypt.Job[BCrypt.MaxBatch];
        while (true)
        {
            int n = 0;
            lock (Collecting)
            {
                Take(Queue.Take(), batch, ref n);
                long deadline = Environment.TickCount64 + (long)_batchWait.TotalMilliseconds;
                while (n < BCrypt.MaxBatch && Queue.TryTake(out var more, (int)Math.Max(0, deadline - Environment.TickCount64)))
                {
                    if (n > 0 && !more.Job.CanPairWith(batch[0].Job))
                    {
                        Queue.Add(more); // a different cost: leave it for another round
                        break;
                    }
                    Take(more, batch, ref n);
                }
            }
            if (n == 0) continue;
            for (int i = 0; i < n; i++) jobs[i] = batch[i].Job;
            bool computed;
            try
            {
                BCrypt.ComputeBatch(jobs, n);
                computed = true;
            }
            catch (Exception e)
            {
                Console.Error.WriteLine(e);
                computed = false;
            }
            for (int i = 0; i < n; i++)
            {
                var c = batch[i];
                try
                {
                    if (computed) Handlers.AfterBcrypt(c);
                    else { c.Error(500, "internal error"); c.Finish(); }
                }
                catch (Exception e)
                {
                    Console.Error.WriteLine(e);
                    c.Error(500, "internal error");
                    c.Finish();
                }
            }
            Array.Clear(batch);
            Array.Clear(jobs);
        }
    }

    // A job whose client has gone away by the time a thread is free is dropped, not hashed: under overload,
    // timed-out logins would otherwise keep the workers busy with work nobody waits for.
    static void Take(Ctx it, Ctx[] batch, ref int n)
    {
        if (it.Conn.Closed) Ctx.Return(it);
        else batch[n++] = it;
    }

    // queues the request's bcrypt job (c.Job); Handlers.AfterBcrypt continues the request on a bcrypt thread
    public static void Run(Ctx c) => Queue.Add(c);
}
