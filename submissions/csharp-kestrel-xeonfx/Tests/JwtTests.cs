using System;
using System.Security.Cryptography;
using System.Text;
using FsCheck;
using FsCheck.Fluent;
using FsCheck.Xunit;
using Xunit;

namespace Conduit.Tests;

public class JwtTests
{
    const string Secret = "multicore-server-challenge";
    const string Hs256 = """{"alg":"HS256","typ":"JWT"}""";
    static readonly long Now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();

    public JwtTests() => Jwt.Init(Secret);

    static string B64(string s) => B64(Encoding.UTF8.GetBytes(s));
    static string B64(byte[] b) => Convert.ToBase64String(b).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    static string Sign(string header, string payload, string secret = Secret)
    {
        string input = B64(header) + "." + B64(payload);
        byte[] mac = HMACSHA256.HashData(Encoding.UTF8.GetBytes(secret), Encoding.ASCII.GetBytes(input));
        return input + "." + B64(mac);
    }

    static string Claims(string sub, long? exp = null, long? nbf = null) =>
        $"{{\"sub\":{sub},\"iat\":{Now}" + (exp is null ? "" : $",\"exp\":{exp}") + (nbf is null ? "" : $",\"nbf\":{nbf}") + "}";

    [Theory]
    [InlineData(1L)]
    [InlineData(12345L)]
    [InlineData(long.MaxValue)]
    public void IssuedTokensVerify(long id) => Assert.Equal(id, Jwt.Verify(Jwt.Issue(id)));

    /// <summary>The keyed HMAC kept per thread must follow a new secret: a token signed with the old one fails.</summary>
    [Fact]
    public void NewSecretRejectsTokensOfTheOldOne()
    {
        string old = Jwt.Issue(7);
        Assert.Equal(7, Jwt.Verify(old));
        Jwt.Init("another-secret");
        Assert.Equal(0, Jwt.Verify(old));
        Assert.Equal(0, Jwt.Verify(Sign(Hs256, Claims("\"7\"", Now + 60))));
        Assert.Equal(7, Jwt.Verify(Sign(Hs256, Claims("\"7\"", Now + 60), "another-secret")));
        Jwt.Init(Secret);
        Assert.Equal(7, Jwt.Verify(old));
    }

    [Fact]
    public void AcceptsTokensFromOtherLibraries()
    {
        // Another header field order and extra claims are fine.
        Assert.Equal(7, Jwt.Verify(Sign("""{"typ":"JWT","alg":"HS256","kid":"k1"}""", Claims("\"7\"", Now + 60) )));
        Assert.Equal(7, Jwt.Verify(Sign(Hs256, """{"exp":""" + (Now + 60) + ""","sub":"7","roles":["a",{"b":1}],"x":null}""")));
        Assert.Equal(7, Jwt.Verify(Sign(Hs256, Claims("\"7\"", Now + 60, Now - 5))));
    }

    [Theory]
    [InlineData("\"7\"", -10L, null)]          // expired
    [InlineData("\"7\"", 0L, null)]            // exp == now: expired (now < exp is required)
    [InlineData("\"7\"", null, null)]          // no exp
    [InlineData("\"7\"", 60L, 30L)]            // not valid before 30 s from now
    [InlineData("7", 60L, null)]               // numeric sub
    [InlineData("\"abc\"", 60L, null)]
    [InlineData("\"0\"", 60L, null)]
    [InlineData("\"-1\"", 60L, null)]
    [InlineData("\"+7\"", 60L, null)]
    [InlineData("\" 7\"", 60L, null)]
    [InlineData("\"\"", 60L, null)]
    [InlineData("\"9223372036854775808\"", 60L, null)] // long.MaxValue + 1
    [InlineData("\"\\u0037\"", 60L, null)]    // escaped digits are not taken
    [InlineData("null", 60L, null)]
    public void RejectsBadClaims(string sub, long? expIn, long? nbfIn) =>
        Assert.Equal(0, Jwt.Verify(Sign(Hs256, Claims(sub, expIn is null ? null : Now + expIn, nbfIn is null ? null : Now + nbfIn))));

    [Fact]
    public void RejectsMissingSub() => Assert.Equal(0, Jwt.Verify(Sign(Hs256, $"{{\"exp\":{Now + 60}}}")));

    [Theory]
    [InlineData("""{"alg":"none","typ":"JWT"}""")]
    [InlineData("""{"alg":"HS512","typ":"JWT"}""")]
    [InlineData("""{"alg":"hs256"}""")]
    [InlineData("""{"typ":"JWT"}""")]
    [InlineData("""{"alg":{"alg":"HS256"}}""")]
    [InlineData("""{"x":{"alg":"HS256"}}""")]
    [InlineData("""["HS256"]""")]
    [InlineData("not json")]
    public void RejectsOtherAlgorithmsAndBadHeaders(string header) => Assert.Equal(0, Jwt.Verify(Sign(header, Claims("\"7\"", Now + 60))));

    [Fact]
    public void RejectsWrongSecretAndTampering()
    {
        Assert.Equal(0, Jwt.Verify(Sign(Hs256, Claims("\"7\"", Now + 60), Secret + "-wrong")));
        string token = Jwt.Issue(7);
        string[] parts = token.Split('.');
        Assert.Equal(0, Jwt.Verify(parts[0] + "." + B64(Claims("\"8\"", Now + 60)) + "." + parts[2]));
        char last = parts[2][^1];
        Assert.Equal(0, Jwt.Verify(parts[0] + "." + parts[1] + "." + parts[2][..^1] + (last == 'A' ? 'B' : 'A')));
    }

    [Theory]
    [InlineData("")]
    [InlineData("not.a.jwt")]
    [InlineData("..")]
    [InlineData("a.b")]
    [InlineData("a.b.c.d")]
    public void RejectsGarbage(string token) => Assert.Equal(0, Jwt.Verify(token));

    [Fact]
    public void RejectsPaddingWhitespaceAndOversizedTokens()
    {
        string token = Jwt.Issue(7);
        Assert.Equal(0, Jwt.Verify(token + "="));
        Assert.Equal(0, Jwt.Verify(token.Insert(token.LastIndexOf('.') + 3, " ")));
        Assert.Equal(0, Jwt.Verify(token.Insert(10, "\n")));
        Assert.Equal(0, Jwt.Verify(new string('a', 5000)));
    }

    [Property(MaxTest = 500)]
    public Property NeverThrows() => Prop.ForAll(ArbMap.Default.ArbFor<string>().Filter(s => s is not null), s =>
    {
        Jwt.Verify(s);
        Jwt.Verify(s.Replace(' ', '.'));
        return true;
    });
}
