using System.IO.Pipelines;
using Microsoft.AspNetCore.Http.Features;

namespace Conduit.Benchmarks;

/// <summary>Request and response plumbing so the app's Http helpers can run without a Kestrel server.</summary>
internal static class Fixtures
{
    /// <summary>A context whose response goes to a writer that copies and forgets, like Kestrel's pipe without the socket.</summary>
    internal static DefaultHttpContext NewContext()
    {
        var ctx = new DefaultHttpContext();
        ctx.Features.Set<IHttpResponseBodyFeature>(new DiscardingBodyFeature());
        return ctx;
    }

    internal static DefaultHttpContext NewContext(byte[] requestBody)
    {
        var ctx = NewContext();
        ctx.Request.Body = new MemoryStream(requestBody, writable: false);
        return ctx;
    }

    /// <summary>Lets the same context serve its request body again.</summary>
    internal static void Rewind(DefaultHttpContext ctx) => ctx.Request.Body.Position = 0;
}

internal sealed class DiscardingBodyFeature : IHttpResponseBodyFeature
{
    public Stream Stream => Stream.Null;
    public PipeWriter Writer { get; } = new DiscardingPipeWriter();
    public Task StartAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
    public Task SendFileAsync(string path, long offset, long? count, CancellationToken cancellationToken = default) => Task.CompletedTask;
    public Task CompleteAsync() => Task.CompletedTask;
    public void DisableBuffering() { }
}

/// <summary>A PipeWriter over one reused 1 MB buffer: it takes the bytes (the copy is the cost) and starts over when full.</summary>
internal sealed class DiscardingPipeWriter : PipeWriter
{
    private readonly byte[] _buffer = new byte[1 << 20];
    private int _pos;

    public override void Advance(int bytes) => _pos += bytes;

    public override Memory<byte> GetMemory(int sizeHint = 0)
    {
        Ensure(sizeHint);
        return _buffer.AsMemory(_pos);
    }

    public override Span<byte> GetSpan(int sizeHint = 0)
    {
        Ensure(sizeHint);
        return _buffer.AsSpan(_pos);
    }

    private void Ensure(int sizeHint)
    {
        if (_pos + Math.Max(sizeHint, 1) > _buffer.Length) _pos = 0;
    }

    public override void CancelPendingFlush() { }
    public override void Complete(Exception? exception = null) { }

    public override ValueTask<FlushResult> FlushAsync(CancellationToken cancellationToken = default)
    {
        _pos = 0;
        return default;
    }
}
