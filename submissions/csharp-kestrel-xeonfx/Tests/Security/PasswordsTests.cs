using System;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using CodeFusion.Security;
using Conduit.Security;
using Xunit;

namespace Conduit.Tests.Security;

/// <summary>
/// The server's passwords on CodeFusion.Security.Bcrypt, held against BCrypt.Net-Next: answers through the
/// queue, calls whose request was aborted, stored hashes of every revision, the unknown-user hash and the 72-byte
/// limit. Each test swaps in a queue of its own, as the endpoint tests swap Db's writer.
/// </summary>
[Collection(ServerState.Collection)]
public sealed class PasswordsTests : IDisposable
{
    const string SeedHash = "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq";

    readonly BcryptQueue _running = Passwords.Queue;
    readonly BcryptQueue _queue = new(new BcryptQueueOptions { Threads = 1 });

    public PasswordsTests() => Passwords.Queue = _queue;

    public void Dispose()
    {
        Passwords.Queue = _running;
        _queue.Dispose();
    }

    static CancellationToken Running => TestContext.Current.CancellationToken;

    /// <summary>With one worker, calls made together queue up and run in batches of up to five; each caller still
    /// gets the answer for its own password, wherever it landed in a batch. New hashes are $2b$.</summary>
    [Fact]
    public async Task EachCallerGetsItsOwnAnswerFromABatch()
    {
        bool[] good = [true, false, true, true, false, false, true, false, true];
        var verifies = good.Select(g => Passwords.VerifyAsync(g ? "password123" : "password124", SeedHash, Running).AsTask()).ToArray();
        var hashes = new[] { "alpha", "beta", "gamma" }.Select(async p => (p, h: await Passwords.HashAsync(p, Running))).ToArray();

        Assert.Equal(good, await Task.WhenAll(verifies));
        foreach (var (p, h) in await Task.WhenAll(hashes))
        {
            Assert.StartsWith("$2b$10$", h);
            Assert.True(BCrypt.Net.BCrypt.Verify(p, h));
            Assert.False(BCrypt.Net.BCrypt.Verify(p + "x", h));
        }
        Assert.True(_queue.Batches < _queue.HashesRun, $"{_queue.HashesRun} hashes in {_queue.Batches} runs");
    }

    /// <summary>A call whose request was aborted is cancelled, not hashed, and the live calls around it still get
    /// their answers.</summary>
    [Fact]
    public async Task ACallAbortedBeforeItRunsIsCancelledAndTheOthersStillRun()
    {
        var aborted = new CancellationToken(canceled: true);
        bool[] live = [true, false, true, false, true, true];
        var tasks = live.Select((g, i) => Passwords.VerifyAsync(g ? "password123" : "password124", SeedHash, i % 2 == 0 ? aborted : Running).AsTask()).ToArray();
        var hash = Passwords.HashAsync("alpha", aborted).AsTask();

        for (int i = 0; i < tasks.Length; i++)
        {
            if (i % 2 == 0) await Assert.ThrowsAnyAsync<OperationCanceledException>(() => tasks[i]);
            else Assert.Equal(live[i], await tasks[i]);
        }
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => hash);
        Assert.Equal(3, _queue.HashesRun);
    }

    /// <summary>A request aborted while its check waits behind a busy worker leaves the queue at once, before the
    /// worker comes to it, and is never run.</summary>
    [Fact]
    public async Task ACallAbortedWhileItWaitsLeavesTheQueueAtOnce()
    {
        using var queue = new BcryptQueue(new BcryptQueueOptions { Threads = 1, Lanes = 1 });
        Passwords.Queue = queue;
        var slow = queue.HashAsync("slow", 14, Running).AsTask(); // about a second
        while (queue.QueueLength > 0) await Task.Delay(5, Running);

        using var request = new CancellationTokenSource();
        var check = Passwords.VerifyAsync("password123", SeedHash, request.Token).AsTask();
        Assert.Equal(1, queue.QueueLength);
        await request.CancelAsync();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => check);
        Assert.Equal(0, queue.QueueLength);
        Assert.False(slow.IsCompleted);

        await slow;
        Assert.Equal(1, queue.HashesRun);
        Assert.Equal(1, queue.Cancelled);
    }

    /// <summary>Stored hashes the server didn't make: the seed's $2a$, and $2b$ and $2y$ from BCrypt.Net-Next.</summary>
    [Theory]
    [InlineData('a')]
    [InlineData('b')]
    [InlineData('y')]
    public async Task AStoredHashOfEachRevisionMatchesItsPasswordOnly(char revision)
    {
        string hash = BCrypt.Net.BCrypt.HashPassword("s3cret é", BCrypt.Net.BCrypt.GenerateSalt(4, revision));
        Assert.StartsWith($"$2{revision}$04$", hash);
        Assert.True(await Passwords.VerifyAsync("s3cret é", hash, Running));
        Assert.False(await Passwords.VerifyAsync("s3cret e", hash, Running));
    }

    [Fact]
    public async Task UnknownUserHashIsACost10HashNoPasswordMatches()
    {
        Assert.StartsWith("$2b$10$", Passwords.UnknownUserHash);
        Assert.Equal(10, Bcrypt.InterrogateHash(Passwords.UnknownUserHash).Cost); // well formed: a check of it runs bcrypt
        Assert.False(await Passwords.VerifyAsync("password123", Passwords.UnknownUserHash, Running));
        Assert.False(await Passwords.VerifyAsync("", Passwords.UnknownUserHash, Running));
        Assert.Equal(2, _queue.HashesRun);
    }

    /// <summary>bcrypt reads 72 bytes, so a longer password would match the hash of its first 72: it is refused
    /// instead, as a malformed stored hash is, both at once without queueing.</summary>
    [Fact]
    public async Task MalformedHashAndOverlongPasswordAreFalseWithoutQueueing()
    {
        string first72 = new('a', 72);
        string hashOfFirst72 = BCrypt.Net.BCrypt.HashPassword(first72, BCrypt.Net.BCrypt.GenerateSalt(4));
        foreach (var check in new[]
        {
            Passwords.VerifyAsync("password123", "not a hash", Running),
            Passwords.VerifyAsync("password123", SeedHash + "x", Running),
            Passwords.VerifyAsync(first72 + "a", hashOfFirst72, Running),
        })
        {
            Assert.True(check.IsCompletedSuccessfully);
            Assert.False(await check);
        }
        Assert.Equal(0, _queue.HashesRun);
        Assert.True(await Passwords.VerifyAsync(first72, hashOfFirst72, Running));

        Assert.True(Passwords.TooLong(new string('é', 37)));  // 74 bytes
        Assert.False(Passwords.TooLong(new string('é', 36))); // 72
        Assert.True(Passwords.TooLong(first72 + "a"));
        Assert.False(Passwords.TooLong(first72));
    }
}
