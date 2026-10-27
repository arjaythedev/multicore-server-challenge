using Conduit.Http;

namespace Conduit.Dispatch;

/// <summary>
/// One waiting read request: which family runs it, what kind of request it is, who asked, the parameters its family
/// needs, and the response being built from its result rows.
/// </summary>
public sealed class ReadJob {
    /// <summary>Creates a job for <paramref name="family"/> answering <paramref name="client"/>. Its kind is the family's position.</summary>
    public ReadJob(ReadFamily family, IClient client) {
        Family = family;
        Client = client;
        Kind = family.Index;
    }

    /// <summary>The family that runs and renders this job.</summary>
    public ReadFamily Family { get; }

    /// <summary>The request kind (see <see cref="ReadKinds"/>). The planner's jobs set it to say which read they are.</summary>
    public int Kind { get; init; }

    /// <summary>Where the response goes.</summary>
    public IClient Client { get; }

    /// <summary>The authenticated user id, or 0 when anonymous.</summary>
    public long Viewer { get; set; }

    /// <summary>A text parameter such as a username or slug; null when the family has none.</summary>
    public string? Key { get; set; }

    /// <summary>Page size of a list job (1 to 100).</summary>
    public int Limit { get; set; }

    /// <summary>Page offset of a list job.</summary>
    public long Offset { get; set; }

    /// <summary>The token the client presented (ASCII), for families that echo it.</summary>
    public byte[]? Token { get; set; }

    /// <summary>Per-request data a family keeps between its parameters and its answer, such as the login password. Null for most families.</summary>
    public object? State { get; set; }

    /// <summary>Arrival order, assigned by the dispatcher. Lower is older.</summary>
    public long Seq { get; internal set; }

    /// <summary>Dispatcher clock reading at arrival (Environment.TickCount64 by default), for the queue age in the stats line.</summary>
    public long EnqueuedMs { get; internal set; }

    /// <summary>Attempts started so far: 1 after the first batch it joined. A read lost with its connection runs once more.</summary>
    public int Attempts { get; internal set; }

    /// <summary>Result rows seen in the current attempt.</summary>
    public int Rows { get; set; }

    /// <summary>The rented response buffer, or null before first use and after it is returned.</summary>
    private ResponseWriter? _writer;

    /// <summary>The response being built. Rented on first use.</summary>
    public ResponseWriter Out => _writer ??= ResponseWriter.Rent();

    /// <summary>Forgets a partly built response so the job can run again.</summary>
    internal void ResetResult() {
        Rows = 0;
        if (_writer is not null) {
            ResponseWriter.Return(_writer);
            _writer = null;
        }
    }

    /// <summary>Sends the built response with <paramref name="status"/> unless the client is gone, then releases the buffer.</summary>
    public void Respond(int status) {
        ResponseWriter w = Out;
        if (!Client.IsClosed) {
            Client.Send(w.Finish(status));
        }

        _writer = null;
        ResponseWriter.Return(w);
    }

    /// <summary>Sends an error response with the given status.</summary>
    public void Fail(int status, string message) {
        Out.WriteError(message);
        Respond(status);
    }
}
