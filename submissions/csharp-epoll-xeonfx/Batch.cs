using System;
using System.Collections.Generic;

enum BatchPhase : byte
{
    Idle,
    /// <summary>Phase A is out: one statement per kind of read in the batch.</summary>
    A,
    /// <summary>Phase B is out: the enrichment of the articles phase A found, the viewers' flags, the commit.</summary>
    B,
    /// <summary>A statement failed inside the batch's transaction: its rollback is out.</summary>
    Rollback,
}

/// <summary>A row of a reply, where it lies in the batch's copy of it, and what it is sorted by: its key's ordinal,
/// then the order the response lists it in.</summary>
struct RowRef
{
    public int At, Length;
    public long K, Order1, Order2;
}

struct RowOrder : IComparer<RowRef>
{
    public readonly int Compare(RowRef x, RowRef y) =>
        x.K != y.K ? x.K.CompareTo(y.K) : x.Order1 != y.Order1 ? x.Order1.CompareTo(y.Order1) : x.Order2.CompareTo(y.Order2);
}

/// <summary>One kind of read in a batch: its distinct keys (and a list's count keys), and where its rows are.</summary>
sealed class Part(byte statement)
{
    public readonly byte Statement = statement;
    /// <summary>The page, slug, username, email or user id of each distinct read.</summary>
    public readonly KeySet Keys = new();
    /// <summary>A list's filters (tag, username, viewer), counted once each.</summary>
    public readonly KeySet Counts = new();
    /// <summary>Some read needs it (the tag list, the global count: they have no keys).</summary>
    public bool Asked;
    public bool Sent;
    /// <summary>Its rows in <see cref="Batch.Rows"/>, sorted by key.</summary>
    public int RowStart, RowEnd;
    /// <summary>By key ordinal: its first row and how many.</summary>
    public int[] First = new int[64], Number = new int[64];
    /// <summary>By count ordinal (the global count at 0): the capped count.</summary>
    public long[] CountOf = new long[64];

    public bool Wanted => Asked || Keys.Count > 0;

    public void Clear()
    {
        Keys.Clear();
        Counts.Clear();
        Asked = Sent = false;
        RowStart = RowEnd = 0;
    }

    /// <summary>Sizes and zeroes the per-key tables once the keys are known.</summary>
    public void PrepareIndex()
    {
        int keys = Keys.Count + 1, counts = Counts.Count + 1;
        if (First.Length < keys)
        {
            First = new int[keys * 2];
            Number = new int[keys * 2];
        }
        if (CountOf.Length < counts) CountOf = new long[counts * 2];
        Array.Clear(Number, 0, keys);
        Array.Clear(CountOf, 0, counts);
    }
}

/// <summary>
/// A reader's batch: the reads it took from the shared queue, their distinct keys by kind, and the replies of its two
/// phases, copied out of the connection's buffer so the rows stay put while every response is written from them.
/// Everything here is reused from batch to batch.
/// </summary>
sealed class Batch
{
    // parts by read kind - 1 (Loop.KTags ... Loop.KFeed)
    public const int Tags = 0, Users = 1, Login = 2, Profile = 3, Article = 4, Comments = 5, Global = 6, Tag = 7, Author = 8,
        Favorited = 9, Feed = 10, PartCount = 11;

    public BatchPhase Phase;
    /// <summary>Both phases run in one read-only REPEATABLE READ transaction, so they see one snapshot.</summary>
    public bool InTransaction;
    public readonly List<Job> Jobs = [];
    public readonly Part[] Parts =
    [
        new(global::Statement.Tags), new(global::Statement.Users), new(global::Statement.Login),
        new(global::Statement.Profile), new(global::Statement.Article), new(global::Statement.Comments),
        new(global::Statement.Global), new(global::Statement.Tag), new(global::Statement.Author),
        new(global::Statement.Favorited), new(global::Statement.Feed),
    ];

    /// <summary>The statements of the phase out, in order: their results come back in this order.</summary>
    public readonly byte[] Sent = new byte[16];
    public int SentCount;

    /// <summary>The phase replies' bytes.</summary>
    public byte[] A = new byte[64 << 10], B = new byte[64 << 10];
    public RowRef[] Rows = new RowRef[256], BRows = new RowRef[256];
    public int RowCount, BRowCount;

    // phase B
    /// <summary>Every article phase A found, once: its author by ordinal, and its enrichment row (-1: none).</summary>
    public readonly KeySet Articles = new();
    public long[] Authors = new long[256];
    public int[] EnrichRow = new int[256];
    /// <summary>(viewer, article) pairs asked about favorites and (viewer, user) pairs asked about follows, and
    /// which of them exist.</summary>
    public readonly KeySet Favs = new(), Follows = new();
    public bool[] FavHit = new bool[256], FollowHit = new bool[256];

    /// <summary>The SQLSTATE and message of the error that failed the batch.</summary>
    public string Error = "";
    public bool Busy503;

    public void Clear()
    {
        Phase = BatchPhase.Idle;
        InTransaction = false;
        Jobs.Clear();
        foreach (Part p in Parts) p.Clear();
        SentCount = RowCount = BRowCount = 0;
        Articles.Clear();
        Favs.Clear();
        Follows.Clear();
        Error = "";
        Busy503 = false;
    }

    public void Send(byte statement) => Sent[SentCount++] = statement;

    /// <summary>The part whose statement is <paramref name="statement"/>, or null (BEGIN, COMMIT, phase B).</summary>
    public Part? PartOf(byte statement)
    {
        foreach (Part p in Parts)
            if (p.Statement == statement) return p;
        return null;
    }

    public static ref RowRef Grow(ref RowRef[] rows, int count)
    {
        if (count == rows.Length) Array.Resize(ref rows, rows.Length * 2);
        return ref rows[count];
    }

    /// <summary>Sizes the phase B tables once its keys are known.</summary>
    public void PrepareFlags()
    {
        int a = Articles.Count + 1, f = Favs.Count + 1, g = Follows.Count + 1;
        if (EnrichRow.Length < a) EnrichRow = new int[a * 2];
        if (Authors.Length < a) Array.Resize(ref Authors, a * 2);
        if (FavHit.Length < f) FavHit = new bool[f * 2];
        if (FollowHit.Length < g) FollowHit = new bool[g * 2];
        Array.Fill(EnrichRow, -1, 0, a);
        Array.Clear(FavHit, 0, f);
        Array.Clear(FollowHit, 0, g);
    }
}
