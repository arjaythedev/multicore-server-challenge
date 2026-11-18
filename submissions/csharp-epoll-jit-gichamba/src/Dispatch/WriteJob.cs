using Conduit.Http;
using Conduit.Pg;

namespace Conduit.Dispatch;

/// <summary>Where a <see cref="WriteOp"/> adds the prepared statements of one write.</summary>
public interface IStatementSink {
    /// <summary>Adds a statement run by prepared name and returns its parameter list to fill.</summary>
    PgParams Add(string preparedName);
}

/// <summary>A prepared statement a write connection must have: name, text and parameter type OIDs.</summary>
public readonly record struct WriteStatement(string Name, string Sql, uint[] ParamOids);

/// <summary>
/// One kind of write request: its statements, how its result rows become a response, and how a server error maps to a
/// status. To add a kind, subclass this (see Conduit.Api.WriteOps). It is the write-side twin of <see cref="ReadFamily"/>.
/// A write runs inside a transaction shared with other writes, so its statements must report expected outcomes
/// (not found, not the author, already exists) as rows or as no row, never as errors.
/// </summary>
public abstract class WriteOp {
    /// <summary>Every statement this kind uses, prepared once per write connection.</summary>
    public abstract IReadOnlyList<WriteStatement> Statements { get; }

    /// <summary>Adds the statements of <paramref name="job"/>, in order, to <paramref name="sink"/>.</summary>
    public abstract void Encode(WriteJob job, IStatementSink sink);

    /// <summary>Handles a result row of the job's statement number <paramref name="statement"/> (0 for its first).</summary>
    public abstract void OnRow(WriteJob job, int statement, in PgRow row);

    /// <summary>Called after COMMIT succeeded: finishes the body in <see cref="WriteJob.Out"/> and returns the status.</summary>
    public abstract int Complete(WriteJob job);

    /// <summary>
    /// Maps a server error raised while the write ran alone to a status and message: a unique violation (23505) is 422,
    /// a foreign key violation (23503) is 404, anything else is 500.
    /// </summary>
    public virtual int MapError(PgError error, out string message) {
        switch (error.SqlState) {
            case "23505":
                message = "already exists";
                return 422;
            case "23503":
                message = "not found";
                return 404;
            default:
                message = "internal error";
                return 500;
        }
    }

    /// <summary>Writes an error body for <paramref name="job"/> and returns <paramref name="status"/>.</summary>
    protected static int Error(WriteJob job, int status, string message) {
        job.Out.WriteError(message);
        return status;
    }
}

/// <summary>
/// One waiting write request: its kind, who asked, the values its statements need and the response being built.
/// The Api layer fills the fields its kind uses.
/// </summary>
public sealed class WriteJob {
    /// <summary>Creates a job of kind <paramref name="op"/> answering <paramref name="client"/>.</summary>
    public WriteJob(WriteOp op, IClient client) {
        Op = op;
        Client = client;
    }

    /// <summary>The kind that runs and renders this job.</summary>
    public WriteOp Op { get; }

    /// <summary>Where the response goes.</summary>
    public IClient Client { get; }

    /// <summary>The authenticated user id; 0 for a registration.</summary>
    public long Viewer { get; set; }

    /// <summary>Article slug.</summary>
    public string? Slug { get; set; }

    /// <summary>Profile username to follow or unfollow, or the new user's name.</summary>
    public string? Username { get; set; }

    /// <summary>User email.</summary>
    public string? Email { get; set; }

    /// <summary>bcrypt hash of a new password; null leaves the password unchanged.</summary>
    public string? PasswordHash { get; set; }

    /// <summary>User bio; null leaves it unchanged.</summary>
    public string? Bio { get; set; }

    /// <summary>User image; null leaves it unchanged.</summary>
    public string? Image { get; set; }

    /// <summary>Article title; null leaves it unchanged on update.</summary>
    public string? Title { get; set; }

    /// <summary>Article description; null leaves it unchanged on update.</summary>
    public string? Description { get; set; }

    /// <summary>Article or comment body; null leaves an article body unchanged on update.</summary>
    public string? Body { get; set; }

    /// <summary>Distinct tag names of a new article, sorted by ordinal comparison; empty when none.</summary>
    public string[] Tags { get; set; } = [];

    /// <summary>Comment id to delete.</summary>
    public long CommentId { get; set; }

    /// <summary>The token the client presented (ASCII), echoed by the user update.</summary>
    public byte[]? Token { get; set; }

    /// <summary>Makes a fresh token for a user id; used by registration.</summary>
    public Func<long, byte[]>? Signer { get; set; }

    /// <summary>Arrival order, assigned by the dispatcher.</summary>
    public long Seq { get; internal set; }

    /// <summary>Arrival time on the dispatcher's clock, in microseconds.</summary>
    public long EnqueuedMicros { get; internal set; }

    /// <summary>Result rows seen in the current attempt.</summary>
    public int Rows { get; set; }

    /// <summary>A status the kind read from a result row; 0 until it does.</summary>
    public int Status { get; set; }

    /// <summary>True when rendering this job's rows threw, so it must answer 500 even though the transaction committed.</summary>
    internal bool RenderFailed { get; set; }

    /// <summary>The rented response buffer, or null before first use and after it is returned.</summary>
    private ResponseWriter? _writer;

    /// <summary>The response being built. Rented on first use.</summary>
    public ResponseWriter Out => _writer ??= ResponseWriter.Rent();

    /// <summary>Forgets a partly built response so the job can run again.</summary>
    internal void ResetResult() {
        Rows = 0;
        Status = 0;
        RenderFailed = false;
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
