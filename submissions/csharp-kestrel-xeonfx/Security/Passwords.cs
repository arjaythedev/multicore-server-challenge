using System;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using CodeFusion.Security;

namespace Conduit.Security;

/// <summary>
/// bcrypt (cost 10) on a <see cref="BcryptQueue"/> of CodeFusion.Security.Bcrypt (Bcrypt/): its own threads, up to
/// five hashes interleaved per thread. A hash takes tens of milliseconds of CPU; running it on the thread pool would
/// let a burst of logins occupy every pool thread and stall all other requests until the pool grows.
/// </summary>
public static class Passwords
{
    const int Cost = 10;

    /// <summary>The queue; the tests swap in one of their own, as they do Db's writer.</summary>
    public static BcryptQueue Queue = null!;

    /// <summary>A hash of a random password, checked when a login names an unknown email so that it costs the same
    /// bcrypt as a wrong password: response times don't tell which emails have accounts.</summary>
    public static readonly string UnknownUserHash = Bcrypt.Hash(Convert.ToHexString(RandomNumberGenerator.GetBytes(16)), Cost);

    public static void Init(int threads, TimeSpan batchWindow = default) =>
        Queue = new BcryptQueue(new BcryptQueueOptions { Threads = threads, BatchWindow = batchWindow });

    /// <summary>bcrypt ignores everything after 72 bytes; such passwords are refused, not truncated.</summary>
    public static bool TooLong(string password) => Encoding.UTF8.GetByteCount(password) > Bcrypt.MaxPasswordBytes;

    /// <summary>A new hash; the caller has checked <see cref="TooLong"/>. Cancelled, unhashed, if
    /// <paramref name="aborted"/> fires before a worker takes it; fails at once with
    /// <see cref="BcryptQueueFullException"/> (a 503) when too many are waiting.</summary>
    public static ValueTask<string> HashAsync(string password, CancellationToken aborted) => Queue.HashAsync(password, Cost, aborted);

    /// <summary>False for a wrong password, a password over 72 bytes, or a malformed stored hash, the last two at once;
    /// cancelled and refused as <see cref="HashAsync"/> is.</summary>
    public static ValueTask<bool> VerifyAsync(string password, string hash, CancellationToken aborted) => Queue.VerifyAsync(password, hash, aborted);
}
