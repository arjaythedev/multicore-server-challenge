using System;
using System.Threading;

/// <summary>
/// A request that waits: a read in the shared queue and then its batch, a write in a group commit, a login's bcrypt
/// check, a sign-up's hash then insert. A job belongs to the loop that holds its client (<see cref="Owner"/>); another
/// loop's Postgres connection may run it, and hands it back through the owner's inbox with its answer in
/// <see cref="Out"/>. Each loop keeps its own spare jobs, so none is allocated per request once warm.
/// </summary>
sealed class Job
{
    public Loop Owner = null!;
    public int Fd, Gen;
    public byte Kind;
    public long Viewer;

    // ---- a read

    /// <summary>The slug, username, tag or email the read is about.</summary>
    public byte[] Name = new byte[64];
    public int NameLength;
    public long Limit, Offset;
    /// <summary>When it was queued (a Stopwatch timestamp).</summary>
    public long QueuedAt;
    /// <summary>Its batch failed: it runs again in a batch of its own, where a failure is its own.</summary>
    public bool Alone;
    /// <summary>The ordinals of its keys in its batch.</summary>
    public int Key, CountKey;

    // ---- a write

    /// <summary>The write's Binds and Executes, encoded when the request came: a group just copies them, and a write
    /// that goes again (its group rolled back) is sent as it was.</summary>
    public readonly Wire Bind = new(512);
    /// <summary>The write's Executes; its answer is read from the last one's rows.</summary>
    public int Statements;
    /// <summary>Where the last statement's messages lie in the group's reply.</summary>
    public int ReplyStart, ReplyEnd;
    /// <summary>The runs that lost a deadlock or serialization check, or the connections lost under a read.</summary>
    public int Tries;
    /// <summary>What the answer needs that the request held: the presented token, or a login's response.</summary>
    public byte[] Keep = new byte[512];
    public int KeepLength;

    // ---- bcrypt

    public readonly byte[] Password = new byte[Bcrypt.MaxPasswordBytes];
    public int PasswordLength;
    /// <summary>A login's stored hash; a sign-up's new hash is written into <see cref="Bind"/> at <see cref="HashAt"/>.</summary>
    public readonly byte[] Hash = new byte[Bcrypt.HashLength];
    public int HashLength, HashAt;
    public bool Hashing, Known, Match;
    /// <summary>Dropped unrun because <see cref="Gone"/>: its loop closes the connection rather than answer.</summary>
    public bool Dropped;

    // ---- going between threads

    /// <summary>The next job in the shared queue it waits in.</summary>
    public Job? QueueNext;
    /// <summary>The next job in its owner's inbox.</summary>
    public Job? InboxNext;
    /// <summary>Why it is in its owner's inbox: <see cref="Hashed"/> or <see cref="Answered"/>.</summary>
    public byte Mail;
    public const byte Hashed = 1, Answered = 2;
    /// <summary>The answer another loop wrote: the status (0: nothing to send) and the body at [Loop.HeadRoom,
    /// <see cref="OutEnd"/>), with room for the head before it.</summary>
    public int Status, OutEnd;
    public byte[] Out = [];

    /// <summary>The client hung up (its fd closed, or it sent FIN while waiting): nobody reads the answer, so its bcrypt
    /// needn't run. Read from a bcrypt thread; a stale read only runs a hash that wasn't needed.</summary>
    public bool Gone => (uint)Fd < (uint)Loop.Conns.Length
        && (Volatile.Read(ref Loop.Conns[Fd].Gen) != Gen || Volatile.Read(ref Loop.Conns[Fd].PeerDone));

    /// <summary>The client's fd closed since the request came: its answer would be dropped. Read from any loop.</summary>
    public bool Closed => (uint)Fd < (uint)Loop.Conns.Length && Volatile.Read(ref Loop.Conns[Fd].Gen) != Gen;

    public ReadOnlySpan<byte> NameSpan => Name.AsSpan(0, NameLength);

    public void SetName(ReadOnlySpan<byte> name)
    {
        if (Name.Length < name.Length) Name = new byte[Math.Max(name.Length, Name.Length * 2)];
        name.CopyTo(Name);
        NameLength = name.Length;
    }

    public void SetKeep(ReadOnlySpan<byte> bytes)
    {
        if (Keep.Length < bytes.Length) Keep = new byte[Math.Max(bytes.Length, Keep.Length * 2)];
        bytes.CopyTo(Keep);
        KeepLength = bytes.Length;
    }

    /// <summary>Keeps the body at [<paramref name="from"/>, <paramref name="end"/>) of a loop's response buffer, at the
    /// same offsets, for the owner to send.</summary>
    public void SetOut(byte[] response, int from, int end)
    {
        if (Out.Length < end) Out = new byte[Math.Max(end, 1024)];
        response.AsSpan(from, end - from).CopyTo(Out.AsSpan(from));
        OutEnd = end;
    }

    /// <summary>Clears what one request left, and drops a buffer a large request grew, before the job goes spare.</summary>
    public void Reset()
    {
        Bind.Length = Statements = Tries = KeepLength = PasswordLength = HashLength = NameLength = Status = OutEnd = 0;
        Limit = Offset = QueuedAt = 0;
        HashAt = -1;
        Hashing = Known = Match = Dropped = Alone = false;
        QueueNext = InboxNext = null;
        Mail = 0;
        if (Bind.Buf.Length > 64 << 10) Bind.Buf = new byte[512];
        if (Keep.Length > 64 << 10) Keep = new byte[512];
        if (Name.Length > 64 << 10) Name = new byte[64];
        if (Out.Length > 256 << 10) Out = [];
        Password.AsSpan().Clear();
    }
}
