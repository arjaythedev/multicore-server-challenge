using System;
using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Conduit;

/// <summary>
/// bcrypt (cost 10) on a few dedicated threads. A hash takes tens of milliseconds of CPU; running it on the thread
/// pool would let a burst of logins occupy every pool thread and stall all other requests until the pool grows.
/// A worker that finds more jobs waiting runs up to four interleaved (<see cref="Bcrypt.Run(ReadOnlySpan{BcryptJob})"/>),
/// so under load each hash costs well under half the CPU.
/// </summary>
public static class Passwords
{
    const int Cost = 10;

    /// <summary>A queued job; it completes with the job once the worker has run it.</summary>
    sealed class Pending(BcryptJob job) : TaskCompletionSource<BcryptJob>(TaskCreationOptions.RunContinuationsAsynchronously)
    {
        public readonly BcryptJob Job = job;
    }

    static readonly BlockingCollection<Pending> Jobs = new();

    /// <summary>A hash of a random password, checked when a login names an unknown email so that it costs the same
    /// bcrypt as a wrong password: response times don't tell which emails have accounts.</summary>
    public static readonly string UnknownUserHash = Bcrypt.Hash(Convert.ToHexString(RandomNumberGenerator.GetBytes(16)), Cost);

    public static void Init(int threads)
    {
        for (int i = 0; i < threads; i++)
            new Thread(Work) { IsBackground = true, Name = $"bcrypt-{i}" }.Start();
    }

    static void Work()
    {
        var batch = new Pending[Bcrypt.MaxLanes];
        var jobs = new BcryptJob[Bcrypt.MaxLanes];
        foreach (var first in Jobs.GetConsumingEnumerable())
        {
            batch[0] = first;
            int n = 1;
            while (n < batch.Length && Jobs.TryTake(out var next)) batch[n++] = next;
            for (int i = 0; i < n; i++) jobs[i] = batch[i].Job;
            try
            {
                Bcrypt.Run(jobs.AsSpan(0, n));
            }
            catch (Exception e)
            {
                for (int i = 0; i < n; i++) batch[i].SetException(e);
                n = 0;
            }
            for (int i = 0; i < n; i++) batch[i].SetResult(batch[i].Job);
            Array.Clear(batch);
            Array.Clear(jobs);
        }
    }

    /// <summary>bcrypt ignores everything after 72 bytes; such passwords are refused, not truncated.</summary>
    public static bool TooLong(string password) => Encoding.UTF8.GetByteCount(password) > Bcrypt.MaxKeyBytes;

    static Task<BcryptJob> RunAsync(BcryptJob job)
    {
        var p = new Pending(job);
        Jobs.Add(p);
        return p.Task;
    }

    /// <summary>A new hash; the caller has checked <see cref="TooLong"/>.</summary>
    public static async Task<string> HashAsync(string password) =>
        (await RunAsync(BcryptJob.ForHash(password, Cost) ?? throw new ArgumentException("password is too long", nameof(password)))).Encoded();

    /// <summary>False for a wrong password, a password over 72 bytes, or a malformed stored hash.</summary>
    public static async Task<bool> VerifyAsync(string password, string hash) =>
        BcryptJob.ForVerify(password, hash) is { } job && (await RunAsync(job)).Matches();
}
