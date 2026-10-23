using System;
using Conduit.Http;
using FsCheck;
using FsCheck.Fluent;
using FsCheck.Xunit;
using Microsoft.AspNetCore.Http;
using Xunit;

namespace Conduit.Tests.Http;

/// <summary>Query parsing follows Go's url.Values (the reference server) and the challenge's page rules.</summary>
public class QueryTests
{
    static string? Get(string qs, string key) => Query.Get(new QueryString(qs), key);

    [Theory]
    [InlineData("?tag=a&tag=b", "a")]                 // the first value wins
    [InlineData("?tag=a+b", "a b")]
    [InlineData("?tag=a%20b%2Bc", "a b+c")]
    [InlineData("?tag=%E2%82%AC", "€")]
    [InlineData("?tag=", "")]
    [InlineData("?tag", "")]
    [InlineData("?tag=%zz&tag=b", "b")]              // a bad escape drops that pair only
    [InlineData("?tag=%2", null)]
    [InlineData("?tag=a;b&tag=c", "c")]              // pairs with ';' are skipped, as in Go
    [InlineData("?x=1&&tag=a", "a")]
    [InlineData("?t%61g=a", "a")]                    // keys are decoded too
    [InlineData("?TAG=a", null)]                     // keys are case-sensitive
    [InlineData("", null)]
    [InlineData("?", null)]
    public void GetsTheFirstDecodedValue(string qs, string? expected) => Assert.Equal(expected, Get(qs, "tag"));

    [Theory]
    [InlineData("", 20, 0)]
    [InlineData("?limit=1", 1, 0)]
    [InlineData("?limit=100&offset=0", 100, 0)]
    [InlineData("?offset=9223372036854775807", 20, long.MaxValue)]
    [InlineData("?limit=005", 5, 0)]
    [InlineData("?limit=10&limit=500", 10, 0)]
    public void AcceptsValidPages(string qs, long limit, long offset)
    {
        Assert.True(Query.TryPage(new QueryString(qs), out long l, out long o));
        Assert.Equal((limit, offset), (l, o));
    }

    [Theory]
    [InlineData("?limit=0")]
    [InlineData("?limit=101")]
    [InlineData("?limit=")]
    [InlineData("?limit=-1")]
    [InlineData("?limit=+5")]        // '+' is a space
    [InlineData("?limit=%2B5")]
    [InlineData("?limit=5.0")]
    [InlineData("?limit=1e1")]
    [InlineData("?limit=%D9%A1")]    // Arabic-Indic digit one
    [InlineData("?offset=-1")]
    [InlineData("?offset=")]
    [InlineData("?offset=9223372036854775808")]
    [InlineData("?offset=99999999999999999999999")]
    public void RejectsInvalidPages(string qs) => Assert.False(Query.TryPage(new QueryString(qs), out _, out _));

    [Property(MaxTest = 300)]
    public Property EscapedValuesRoundTrip() => Prop.ForAll(ArbMap.Default.ArbFor<string>().Filter(s => s is not null && !s.Contains('\uFFFD') && IsWellFormed(s)), v =>
        Get("?a=1&tag=" + Uri.EscapeDataString(v) + "&tag=zzz", "tag") == v);

    [Property(MaxTest = 300)]
    public Property NeverThrows() => Prop.ForAll(ArbMap.Default.ArbFor<string>().Filter(s => s is not null), s =>
    {
        Get("?" + s, "tag");
        Query.TryPage(new QueryString("?" + s.Replace(' ', '&')), out _, out _);
        return true;
    });

    static bool IsWellFormed(string s)
    {
        for (int i = 0; i < s.Length; i++)
        {
            if (char.IsHighSurrogate(s[i])) { if (i + 1 >= s.Length || !char.IsLowSurrogate(s[++i])) return false; }
            else if (char.IsLowSurrogate(s[i])) return false;
        }
        return true;
    }
}
