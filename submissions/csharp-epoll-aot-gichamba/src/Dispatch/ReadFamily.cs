using Conduit.Pg;

namespace Conduit.Dispatch;

/// <summary>
/// The kinds of read request, by position; the stats line counts requests per kind. Tags, profile, user and login each
/// have a family at their own position. The planner, at <see cref="Plan"/>, serves the other seven kinds.
/// </summary>
public static class ReadKinds {
    /// <summary>The kind positions, in the order of <see cref="All"/>.</summary>
    public const int Tags = 0, List = 1, ListTag = 2, ListAuthor = 3, ListFav = 4, Feed = 5,
        Article = 6, Comments = 7, Profile = 8, User = 9, Login = 10;

    /// <summary>Names by position, as the stats line prints them.</summary>
    public static readonly string[] All =
        ["tags", "list", "list_tag", "list_author", "list_fav", "feed", "article", "comments", "profile", "user", "login"];

    /// <summary>The planner's family position. It is not a request kind: its jobs keep their own kinds.</summary>
    public const int Plan = 11;

    /// <summary>Family positions the dispatcher needs queues for: every kind position and the planner.</summary>
    public const int Slots = 12;
}

/// <summary>
/// A batched read: its prepared statement, how a batch's parameters are encoded and how a request's rows become a
/// response. To add a family, subclass this (see TagsFamily, UserFamily, ProfileFamily in Conduit.Api) and register it
/// in ReadFamilies.
///
/// The statement's first parameters are arrays with one element per request in the batch, and it has the shape:
/// <code>
/// SELECT r.i, x.* FROM unnest($1::int8[], $2::int8[]) AS r(i, v) CROSS JOIN LATERAL (per-request query using r.v) x
/// </code>
/// Every result row starts with r.i, the request's position in the batch, so the row finds its request.
/// A subquery that uses no request value is tied to the row (<c>WHERE r.i &gt;= 0</c>) so it runs once per request.
/// </summary>
public abstract class ReadFamily {
    /// <summary>Per-thread scratch array that <see cref="AddIndexes"/> and <see cref="AddViewers"/> fill before encoding.</summary>
    [ThreadStatic] private static long[]? s_longs;
    /// <summary>Per-thread scratch array that <see cref="AddKeys"/> fills before encoding.</summary>
    [ThreadStatic] private static string[]? s_strings;

    /// <summary>
    /// Returned by <see cref="Complete"/> when the family answers later, from another thread (for example after a bcrypt
    /// check). The batch then does not respond; the family must call <see cref="ReadJob.Respond"/> or <see cref="ReadJob.Fail"/> itself.
    /// </summary>
    public const int Deferred = 0;

    /// <summary>Creates a family at position <paramref name="index"/> (see <see cref="ReadKinds"/>).</summary>
    protected ReadFamily(int index, string name) {
        Index = index;
        Name = name;
    }

    /// <summary>Position of the family's queue, and the request kind of its jobs unless they set their own.</summary>
    public int Index { get; }

    /// <summary>Family name, used in error reports and in the prepared statement's name.</summary>
    public string Name { get; }

    /// <summary>Name of the prepared statement.</summary>
    public string StatementName => "r_" + Name;

    /// <summary>The statement text.</summary>
    public abstract string Sql { get; }

    /// <summary>Parameter type OIDs of <see cref="Sql"/>.</summary>
    public abstract uint[] ParamOids { get; }

    /// <summary>
    /// True when one execution answers every request in the batch, because the answer does not depend on the request.
    /// Its rows then carry no r.i column, and each row is given to every job in the batch.
    /// </summary>
    public virtual bool Broadcast => false;

    /// <summary>True when the family may run on every read connection at once. Other families get at most half of them.</summary>
    public virtual bool UsesEveryConnection => false;

    /// <summary>
    /// True when the family runs its batches itself, over several statements and round trips. <see cref="PrepareBatch"/>,
    /// <see cref="OnBatchRow"/>, <see cref="ContinueBatch"/> and <see cref="FinishBatch"/> then replace Encode, OnRow and Complete.
    /// </summary>
    public virtual bool OwnsBatch => false;

    /// <summary>Adds the statements of a newly formed batch. The default adds <see cref="Sql"/> and encodes the jobs into it.</summary>
    protected internal virtual void PrepareBatch(ReadBatch batch) {
        ReadOnlySpan<ReadJob> jobs = batch.Jobs.AsSpan(0, batch.Count);
        Encode(batch.Statement(StatementName), jobs);
    }

    /// <summary>A result row of statement <paramref name="statementIndex"/> of a batch this family owns.</summary>
    protected internal virtual void OnBatchRow(ReadBatch batch, int statementIndex, in PgRow row) {
    }

    /// <summary>
    /// A round trip of an owned batch finished without error. Return true after adding the statements of the next round
    /// trip, which goes out on the same connection; false when the batch is complete.
    /// </summary>
    protected internal virtual bool ContinueBatch(ReadBatch batch) => false;

    /// <summary>Answers every job of an owned batch: from its rows, or with a 500 when <paramref name="failed"/>.</summary>
    protected internal virtual void FinishBatch(ReadBatch batch, bool failed) {
    }

    /// <summary>The statements a read connection prepares for this family, with their parameter types.</summary>
    public virtual IEnumerable<(string Name, string Sql, uint[] Oids)> Statements => [(StatementName, Sql, ParamOids)];

    /// <summary>Index of the first payload column: 1 after r.i, 0 for a broadcast statement.</summary>
    protected int First => Broadcast ? 0 : 1;

    /// <summary>Adds the batch's parameters, in the order of <see cref="ParamOids"/>. Element i belongs to jobs[i].</summary>
    public abstract void Encode(PgParams p, ReadOnlySpan<ReadJob> jobs);

    /// <summary>Handles one result row of <paramref name="job"/>. Count it in <see cref="ReadJob.Rows"/> and write its part of the response.</summary>
    public abstract void OnRow(ReadJob job, in PgRow row);

    /// <summary>Called when the batch is done: finish the body in <see cref="ReadJob.Out"/> (or write an error) and return the status, or <see cref="Deferred"/>.</summary>
    public abstract int Complete(ReadJob job);

    /// <summary>Writes an error body for <paramref name="job"/> and returns <paramref name="status"/>.</summary>
    protected static int Error(ReadJob job, int status, string message) {
        job.Out.WriteError(message);
        return status;
    }

    /// <summary>Adds an int8[] holding 0, 1, 2 ... for the batch, the r.i column.</summary>
    protected static void AddIndexes(PgParams p, int count) {
        long[] a = Longs(count);
        for (int i = 0; i < count; i++) {
            a[i] = i;
        }

        p.AddInt8Array(a.AsSpan(0, count));
    }

    /// <summary>Adds an int8[] of the jobs' viewers.</summary>
    protected static void AddViewers(PgParams p, ReadOnlySpan<ReadJob> jobs) {
        long[] a = Longs(jobs.Length);
        for (int i = 0; i < jobs.Length; i++) {
            a[i] = jobs[i].Viewer;
        }

        p.AddInt8Array(a.AsSpan(0, jobs.Length));
    }

    /// <summary>Adds a text[] of the jobs' keys.</summary>
    protected static void AddKeys(PgParams p, ReadOnlySpan<ReadJob> jobs) {
        string[]? a = s_strings;
        if (a is null || a.Length < jobs.Length) {
            a = s_strings = new string[Math.Max(jobs.Length, 64)];
        }

        for (int i = 0; i < jobs.Length; i++) {
            a[i] = jobs[i].Key ?? "";
        }

        p.AddTextArray(a.AsSpan(0, jobs.Length));
    }

    /// <summary>Returns the thread's long scratch array, grown to at least <paramref name="n"/> elements.</summary>
    private static long[] Longs(int n) {
        long[]? a = s_longs;
        if (a is null || a.Length < n) {
            a = s_longs = new long[Math.Max(n, 64)];
        }

        return a;
    }
}
