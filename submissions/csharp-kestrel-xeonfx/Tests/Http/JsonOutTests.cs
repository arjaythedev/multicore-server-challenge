using System;
using System.Linq;
using System.Text;
using Conduit.Http;
using FsCheck;
using FsCheck.Fluent;
using FsCheck.Xunit;
using Xunit;

namespace Conduit.Tests.Http;

[Collection(ServerState.Collection)]
public class JsonOutTests
{
    [Fact]
    public void ThePoolKeepsNoMoreThanItsBudgetAfterABurst()
    {
        var burst = new JsonOut[(int)(JsonOut.MaxPooledBytes / (16 * 1024)) + 500];
        for (int i = 0; i < burst.Length; i++) burst[i] = JsonOut.Rent();
        foreach (var j in burst) j.Dispose();

        Assert.InRange(JsonOut.PooledBytes, JsonOut.MaxPooledBytes - 16 * 1024, JsonOut.MaxPooledBytes);
        var again = JsonOut.Rent();
        Assert.Contains(again, burst); // what is kept is used again
        again.Dispose();
    }

    [Fact]
    public void AReturnedBufferComesBackEmpty()
    {
        var j = JsonOut.Rent();
        j.W.WriteStartObject();
        j.W.WriteEndObject();
        Assert.Equal("{}"u8, j.Written);
        j.Dispose();
        var next = JsonOut.Rent();
        Assert.True(next.Written.IsEmpty);
        next.Dispose();
    }

    /// <summary>Text from Postgres is written from its UTF-8 bytes; the JSON must be what the string would have given.</summary>
    [Property(MaxTest = 1000)]
    public Property TextWrittenFromItsUtf8BytesMatchesTheString() => Prop.ForAll(Texts(), s =>
    {
        using JsonOut fromString = JsonOut.Rent(), fromBytes = JsonOut.Rent();
        fromString.W.WriteStartObject();
        fromString.W.WriteString(Names.Body, s);
        fromString.W.WriteEndObject();
        fromBytes.W.WriteStartObject();
        fromBytes.W.WriteString(Names.Body, Encoding.UTF8.GetBytes(s));
        fromBytes.W.WriteEndObject();
        return fromString.Written.SequenceEqual(fromBytes.Written);
    });

    /// <summary>Any text a Postgres text column can hold: controls and JSON's escapes, the rest of the BMP, and
    /// characters outside it (surrogate pairs in UTF-16, four bytes in UTF-8).</summary>
    static Arbitrary<string> Texts() =>
        Gen.ArrayOf(Gen.OneOf(Gen.Choose(1, 0x7F), Gen.Choose(0x80, 0xD7FF), Gen.Choose(0xE000, 0xFFFF), Gen.Choose(0x10000, 0x10FFFF)))
            .Select(cps => string.Concat(cps.Select(char.ConvertFromUtf32)))
            .ToArbitrary();
}
