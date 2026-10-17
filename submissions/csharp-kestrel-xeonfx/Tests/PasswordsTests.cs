using System.Linq;
using System.Threading.Tasks;
using Xunit;

namespace Conduit.Tests;

public class PasswordsTests
{
    const string SeedHash = "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq";

    static PasswordsTests() => Passwords.Init(1);

    /// <summary>With one worker, jobs submitted together queue up and run in batches of up to four; each caller
    /// still gets the answer for its own password, wherever it landed in a batch.</summary>
    [Fact]
    public async Task EachCallerGetsItsOwnAnswerFromABatch()
    {
        bool[] good = [true, false, true, true, false, false, true, false, true];
        var verifies = good.Select(g => Passwords.VerifyAsync(g ? "password123" : "password124", SeedHash)).ToArray();
        var hashes = new[] { "alpha", "beta", "gamma" }.Select(async p => (p, h: await Passwords.HashAsync(p))).ToArray();

        Assert.Equal(good, await Task.WhenAll(verifies));
        foreach (var (p, h) in await Task.WhenAll(hashes))
        {
            Assert.StartsWith("$2a$10$", h);
            Assert.True(BCrypt.Net.BCrypt.Verify(p, h));
            Assert.False(BCrypt.Net.BCrypt.Verify(p + "x", h));
        }
    }

    [Fact]
    public async Task UnknownUserHashIsACost10HashNoPasswordMatches()
    {
        Assert.StartsWith("$2a$10$", Passwords.UnknownUserHash);
        Assert.NotNull(BcryptJob.ForVerify("x", Passwords.UnknownUserHash));
        Assert.False(await Passwords.VerifyAsync("password123", Passwords.UnknownUserHash));
        Assert.False(await Passwords.VerifyAsync("", Passwords.UnknownUserHash));
    }

    [Fact]
    public async Task MalformedHashAndOverlongPasswordAreFalseWithoutQueueing()
    {
        Assert.False(await Passwords.VerifyAsync("password123", "not a hash"));
        Assert.False(await Passwords.VerifyAsync(new string('a', 73), SeedHash));
        Assert.True(Passwords.TooLong(new string('é', 37)));
        Assert.False(Passwords.TooLong(new string('é', 36)));
    }
}
