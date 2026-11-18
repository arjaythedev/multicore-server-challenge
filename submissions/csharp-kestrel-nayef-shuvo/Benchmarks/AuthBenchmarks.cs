using BenchmarkDotNet.Attributes;

namespace Conduit.Benchmarks;

/// <summary>Auth.cs: the JWT work done on nearly every request (a signature and expiry check on each Authorization header).</summary>
[MemoryDiagnoser]
public class AuthBenchmarks
{
    private Auth _auth = null!;
    private DefaultHttpContext _valid = null!;
    private DefaultHttpContext _noHeader = null!;
    private DefaultHttpContext _badSignature = null!;

    [GlobalSetup]
    public void Setup()
    {
        _auth = new Auth("multicore-server-challenge");
        var token = _auth.IssueToken(12345);
        _valid = Fixtures.NewContext();
        _valid.Request.Headers.Authorization = "Token " + token;
        _noHeader = Fixtures.NewContext();
        _badSignature = Fixtures.NewContext();
        _badSignature.Request.Headers.Authorization = "Token " + token[..^2] + (token[^2] == 'A' ? "B" : "A") + token[^1];
    }

    [Benchmark]
    public string IssueToken() => _auth.IssueToken(12345);

    [Benchmark]
    public long Authenticate_ValidToken() => _auth.Authenticate(_valid.Request).GetAwaiter().GetResult().Id;

    [Benchmark]
    public long Authenticate_NoHeader() => _auth.Authenticate(_noHeader.Request).GetAwaiter().GetResult().Id;

    [Benchmark]
    public long Authenticate_BadSignature() => _auth.Authenticate(_badSignature.Request).GetAwaiter().GetResult().Id;
}
