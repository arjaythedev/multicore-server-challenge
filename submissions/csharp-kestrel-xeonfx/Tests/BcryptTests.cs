using System;
using System.Linq;
using System.Text;
using FsCheck;
using FsCheck.Fluent;
using FsCheck.Xunit;
using Xunit;

namespace Conduit.Tests;

public class BcryptTests
{
    // The seed's hash of "password123", made by Go's golang.org/x/crypto/bcrypt.
    const string SeedHash = "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq";

    [Fact]
    public void VerifiesGoHash() => Assert.True(Bcrypt.Verify("password123", SeedHash));

    [Theory]
    [InlineData("password12")]
    [InlineData("password1234")]
    [InlineData("Password123")]
    [InlineData("")]
    public void RejectsOtherPasswords(string password) => Assert.False(Bcrypt.Verify(password, SeedHash));

    [Fact]
    public void HashVerifiesAndDiffersEachTime()
    {
        string a = Bcrypt.Hash("hunter2", 4), b = Bcrypt.Hash("hunter2", 4);
        Assert.NotEqual(a, b); // random salts
        Assert.StartsWith("$2a$04$", a);
        Assert.Equal(60, a.Length);
        Assert.True(Bcrypt.Verify("hunter2", a));
        Assert.True(BCrypt.Net.BCrypt.Verify("hunter2", a));
        Assert.False(Bcrypt.Verify("hunter3", a));
    }

    /// <summary>Same password and salt give exactly BCrypt.Net-Next's hash, for any password up to 72 bytes.</summary>
    [Property(MaxTest = 60)]
    public Property MatchesBCryptNetNext() => Prop.ForAll(Passwords(), Salts(), (password, salt) =>
    {
        var job = BcryptJob.ForHash(password, 4, salt)!;
        Bcrypt.Run(job);
        string ours = job.Encoded();
        string theirs = BCrypt.Net.BCrypt.HashPassword(password, ours[..29]);
        return ours == theirs;
    });

    /// <summary>A batch of 1 to 4 jobs run interleaved gives each job the hash it gets alone.</summary>
    [Property(MaxTest = 30)]
    public Property BatchEqualsSingles() => Prop.ForAll(
        Gen.ArrayOf(Gen.Zip(Passwords().Generator, Salts().Generator), 4).ToArbitrary(), inputs =>
    {
        string[] alone = inputs.Select(i => { var j = BcryptJob.ForHash(i.Item1, 4, i.Item2)!; Bcrypt.Run(j); return j.Encoded(); }).ToArray();
        for (int n = 1; n <= Bcrypt.MaxLanes; n++)
        {
            BcryptJob[] batch = inputs[..n].Select(i => BcryptJob.ForHash(i.Item1, 4, i.Item2)!).ToArray();
            Bcrypt.Run(batch.AsSpan());
            if (!batch.Select(j => j.Encoded()).SequenceEqual(alone[..n])) return false;
        }
        return true;
    });

    [Fact]
    public void BatchOfNoneOrFiveIsRefused()
    {
        var job = BcryptJob.ForHash("x", 4)!;
        Assert.Throws<ArgumentOutOfRangeException>(() => Bcrypt.Run(ReadOnlySpan<BcryptJob>.Empty));
        Assert.Throws<ArgumentOutOfRangeException>(() => Bcrypt.Run(new[] { job, job, job, job, job }.AsSpan()));
    }

    [Fact]
    public void FourLanesFindTheMismatchInEachLane()
    {
        for (int bad = 0; bad < 4; bad++)
        {
            var jobs = Enumerable.Range(0, 4).Select(i => BcryptJob.ForVerify(i == bad ? "password124" : "password123", SeedHash)!).ToArray();
            Bcrypt.Run(jobs[0], jobs[1], jobs[2], jobs[3]);
            Assert.Equal(Enumerable.Range(0, 4).Select(i => i != bad), jobs.Select(j => j.Matches()));
        }
    }

    [Fact]
    public void ThreeAndFourWithAnotherCostRunEachAtItsOwnCost()
    {
        var salt = new byte[16];
        BcryptJob[] three = [BcryptJob.ForHash("x", 4, salt)!, BcryptJob.ForHash("y", 4, salt)!, BcryptJob.ForHash("z", 5, salt)!];
        BcryptJob[] four = [BcryptJob.ForHash("x", 5, salt)!, BcryptJob.ForHash("y", 4, salt)!, BcryptJob.ForHash("z", 4, salt)!, BcryptJob.ForHash("w", 4, salt)!];
        Bcrypt.Run(three[0], three[1], three[2]);
        Bcrypt.Run(four[0], four[1], four[2], four[3]);
        foreach (var (j, pw) in three.Zip(["x", "y", "z"]).Concat(four.Zip(["x", "y", "z", "w"])))
            Assert.Equal(BCrypt.Net.BCrypt.HashPassword(pw, j.Encoded()[..29]), j.Encoded());
    }

    [Fact]
    public void PairWithDifferentCostsRunsEachAtItsOwnCost()
    {
        var salt = new byte[16];
        BcryptJob a = BcryptJob.ForHash("x", 4, salt)!, b = BcryptJob.ForHash("x", 5, salt)!;
        Bcrypt.Run(a, b);
        Assert.Equal(BCrypt.Net.BCrypt.HashPassword("x", a.Encoded()[..29]), a.Encoded());
        Assert.Equal(BCrypt.Net.BCrypt.HashPassword("x", b.Encoded()[..29]), b.Encoded());
        Assert.NotEqual(a.Encoded()[29..], b.Encoded()[29..]);
    }

    [Fact]
    public void VerifiesAMatchAndAMismatchInOnePair()
    {
        var good = BcryptJob.ForVerify("password123", SeedHash)!;
        var bad = BcryptJob.ForVerify("password124", SeedHash)!;
        Bcrypt.Run(good, bad);
        Assert.True(good.Matches());
        Assert.False(bad.Matches());
    }

    [Theory]
    [InlineData("2a")]
    [InlineData("2b")]
    [InlineData("2y")]
    public void VerifiesEveryRevision(string revision)
    {
        string hash = BCrypt.Net.BCrypt.HashPassword("päss wörd", BCrypt.Net.BCrypt.GenerateSalt(4, revision[1]));
        Assert.True(Bcrypt.Verify("päss wörd", hash));
        Assert.False(Bcrypt.Verify("pass word", hash));
    }

    [Fact]
    public void SeventyTwoBytesIsTheLimit()
    {
        string ascii72 = new('a', 72), euro24 = string.Concat(Enumerable.Repeat("€", 24)); // 24 x 3 bytes
        Assert.True(Bcrypt.Verify(ascii72, Bcrypt.Hash(ascii72, 4)));
        Assert.True(Bcrypt.Verify(euro24, Bcrypt.Hash(euro24, 4)));
        Assert.Null(BcryptJob.ForHash(ascii72 + "a", 4));
        Assert.Null(BcryptJob.ForHash(euro24 + "€", 4));
        Assert.Throws<ArgumentException>(() => Bcrypt.Hash(ascii72 + "a", 4));
        // A longer password never matches, even one whose first 72 bytes do.
        Assert.False(Bcrypt.Verify(ascii72 + "a", Bcrypt.Hash(ascii72, 4)));
    }

    [Theory]
    [InlineData("")]
    [InlineData("$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899w")] // 59 chars
    [InlineData("$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wqq")] // 61 chars
    [InlineData("$2x$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq")] // unknown revision
    [InlineData("$3a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq")]
    [InlineData("$2a$03$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq")] // cost below 4
    [InlineData("$2a$32$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq")] // cost above 31
    [InlineData("$2a$1a$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq")]
    [InlineData("$2a$10#ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq")]
    [InlineData("$2a$10$ZSfEoPvlcsj2Xfvs!eK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq")] // '!' in the salt
    [InlineData("$2a$10$ZSfEoPvlcsj2XfvsSeK25ém4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq")] // non-ASCII in the salt
    public void MalformedHashesNeverMatch(string hash)
    {
        Assert.Null(BcryptJob.ForVerify("password123", hash));
        Assert.False(Bcrypt.Verify("password123", hash));
    }

    [Fact]
    public void StrayLowBitsInTheLastCharacterDoNotMatch()
    {
        // 'q' encodes 0b101010 + 2 unused bits; 'r' is the next value, which differs only in the unused bits.
        string altered = SeedHash[..^1] + "r";
        Assert.False(Bcrypt.Verify("password123", altered));
    }

    [Property(MaxTest = 200)]
    public Property VerifyNeverThrows() => Prop.ForAll(ArbMap.Default.ArbFor<string>().Filter(s => s is not null), hash =>
    {
        // Random strings, and random strings forced into the right shape.
        string shaped = "$2a$04$" + new string((hash + new string('.', 53)).Take(53).ToArray());
        Bcrypt.Verify("x", hash);
        Bcrypt.Verify("x", shaped);
        return true;
    });

    static Arbitrary<string> Passwords() =>
        ArbMap.Default.ArbFor<string>().Filter(s => s is not null && Encoding.UTF8.GetByteCount(s) <= 72 && !s.Contains('\0'));

    static Arbitrary<byte[]> Salts() =>
        Gen.ArrayOf(ArbMap.Default.GeneratorFor<byte>(), 16).ToArbitrary();
}
