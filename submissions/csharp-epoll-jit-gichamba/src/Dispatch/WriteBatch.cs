using Conduit.Pg;

namespace Conduit.Dispatch;

/// <summary>
/// One transaction of waiting writes sent as a single pipeline: [ROLLBACK], BEGIN, [one shared tag insert], each write's
/// statements, COMMIT, Sync. A write also runs alone this way after its group failed. Callbacks run on the connection's
/// reader thread. Responses are sent only after COMMIT succeeded.
/// </summary>
public sealed class WriteBatch : PgRequest, IStatementSink {
    /// <summary>Prepared name of BEGIN.</summary>
    public const string BeginName = "w_begin";

    /// <summary>Prepared name of COMMIT.</summary>
    public const string CommitName = "w_commit";

    /// <summary>Prepared name of ROLLBACK, which clears an aborted transaction left by a failed request.</summary>
    public const string RollbackName = "w_rollback";

    /// <summary>Prepared name of the shared tag insert: one text[] parameter, sorted and distinct.</summary>
    public const string TagsName = "w_tags";

    /// <summary>The statements every write connection prepares for the transaction frame.</summary>
    public static readonly IReadOnlyList<WriteStatement> FrameStatements =
    [
        new(BeginName, "BEGIN", []),
        new(CommitName, "COMMIT", []),
        new(RollbackName, "ROLLBACK", []),
        new(TagsName, "INSERT INTO tags (name) SELECT unnest($1::text[]) ON CONFLICT (name) DO NOTHING", [PgOid.TextArray]),
    ];

    /// <summary>The dispatcher that frees the connection and receives stats.</summary>
    private readonly WriteDispatcher _owner;

    /// <summary>Creates an empty write transaction for <paramref name="owner"/>.</summary>
    internal WriteBatch(WriteDispatcher owner) => _owner = owner;

    /// <summary>Guards row routing, the error and the flags below against an abandon from another thread.</summary>
    private readonly object _gate = new();
    /// <summary>Statement index to index in Jobs, or -1 for a frame statement.</summary>
    private int[] _jobAt = new int[16];
    /// <summary>Statement index to the write's own statement number.</summary>
    private int[] _localAt = new int[16];
    /// <summary>Index in Jobs of the write being encoded.</summary>
    private int _current;
    /// <summary>Number of statements the current write has added so far.</summary>
    private int _local;
    /// <summary>Statement index of COMMIT.</summary>
    private int _commitIndex;
    /// <summary>True when COMMIT completed with the tag COMMIT.</summary>
    private bool _committed;
    /// <summary>The first server error of the transaction, or null.</summary>
    private PgError? _error;
    /// <summary>The connection broke and the dispatcher took the batch back. Later callbacks are ignored.</summary>
    private bool _abandoned;
    /// <summary>OnDone has run, so a broken connection can no longer take this batch back.</summary>
    private bool _finished;

    /// <summary>The writes in this transaction, in the order of their statements.</summary>
    public List<WriteJob> Jobs { get; } = [];

    /// <summary>Index of the write connection slot this batch was sent on.</summary>
    internal int Slot { get; set; }

    /// <summary>The connection generation this batch was sent on; a stale one is ignored when it finishes.</summary>
    internal int Generation { get; set; }

    /// <summary>Builds the pipeline for <paramref name="jobs"/>; <paramref name="rollbackFirst"/> prepends ROLLBACK.</summary>
    internal void Build(IReadOnlyList<WriteJob> jobs, bool rollbackFirst) {
        ResetStatements();
        Jobs.Clear();
        Jobs.AddRange(jobs);
        _committed = false;
        _error = null;
        _abandoned = _finished = false;

        if (rollbackFirst) {
            Frame(RollbackName);
        }

        Frame(BeginName);

        // One tag insert for the whole transaction, in ordinal order, so two concurrent groups lock tag rows in the same order.
        List<string>? tags = null;
        foreach (WriteJob job in jobs) {
            if (job.Tags.Length > 0) {
                (tags ??= []).AddRange(job.Tags);
            }
        }

        if (tags is not null) {
            tags.Sort(StringComparer.Ordinal);
            for (int i = tags.Count - 1; i > 0; i--) {
                if (tags[i] == tags[i - 1]) {
                    tags.RemoveAt(i);
                }
            }

            Frame(TagsName).AddTextArray(System.Runtime.InteropServices.CollectionsMarshal.AsSpan(tags));
        }

        for (int i = 0; i < Jobs.Count; i++) {
            _current = i;
            _local = 0;
            Jobs[i].Op.Encode(Jobs[i], this);
        }

        _commitIndex = StatementCount;
        AddStatement(CommitName);
        Track(-1, 0);
    }

    /// <inheritdoc />
    public PgParams Add(string preparedName) {
        PgParams p = AddStatement(preparedName);
        Track(_current, _local++);
        return p;
    }

    /// <summary>Adds a frame statement (not part of any write) and returns its parameter list.</summary>
    private PgParams Frame(string name) {
        PgParams p = AddStatement(name);
        Track(-1, 0);
        return p;
    }

    /// <summary>Records which job and which of its statements the statement just added belongs to. Frame statements use job -1.</summary>
    private void Track(int job, int local) {
        int at = StatementCount - 1;
        if (at == _jobAt.Length) {
            Array.Resize(ref _jobAt, at * 2);
            Array.Resize(ref _localAt, at * 2);
        }
        _jobAt[at] = job;
        _localAt[at] = local;
    }

    /// <summary>
    /// Takes the batch away from a broken connection. Returns false when it already finished, in which case
    /// its writes are answered and must not be touched.
    /// </summary>
    internal bool TryAbandon() {
        lock (_gate) {
            if (_finished) {
                return false;
            }

            _abandoned = true;
            return true;
        }
    }

    /// <inheritdoc />
    public override void OnRow(int statementIndex, in PgRow row) {
        lock (_gate) {
            if (_abandoned || _error is not null || (uint)statementIndex >= (uint)StatementCount) {
                return;
            }

            int at = _jobAt[statementIndex];
            if (at < 0) {
                return;
            }

            WriteJob job = Jobs[at];
            try {
                job.Op.OnRow(job, _localAt[statementIndex], row);
            } catch (Exception) {
                job.RenderFailed = true;
            }
        }
    }

    /// <inheritdoc />
    public override void OnCommandComplete(int statementIndex, ReadOnlySpan<byte> tag) {
        // COMMIT of an aborted transaction answers with the tag ROLLBACK and no error, so the tag decides.
        if (statementIndex == _commitIndex) {
            _committed = tag.SequenceEqual("COMMIT"u8);
        }
    }

    /// <inheritdoc />
    public override void OnError(PgError error) {
        lock (_gate) {
            _error ??= error;
        }

        _owner.Stats?.RecordWriteError(error);
    }

    /// <inheritdoc />
    public override void OnDone() {
        lock (_gate) {
            if (_abandoned) {
                return;
            }

            _finished = true;
        }
        bool ok = _error is null && _committed;
        if (!ok && Jobs.Count > 1) {
            // The group is rolled back (or never committed). Nothing was answered; each write runs again alone.
            foreach (WriteJob job in Jobs) {
                job.ResetResult();
            }

            _owner.GroupFailed(this);
            return;
        }
        if (!ok) {
            WriteJob job = Jobs[0];
            try {
                int status = 500;
                string message = "internal error";
                if (_error is { } e) {
                    status = job.Op.MapError(e, out message);
                }

                job.ResetResult();
                job.Fail(status, message);
            } catch (Exception) {
                // The client is gone or the buffer failed; nothing more to do.
            }
        } else {
            foreach (WriteJob job in Jobs) {
                try {
                    if (job.RenderFailed) {
                        throw new InvalidOperationException("render failed");
                    }

                    job.Respond(job.Op.Complete(job));
                } catch (Exception) {
                    try {
                        job.ResetResult();
                        job.Fail(500, "internal error");
                    } catch (Exception) {
                        // The client is gone; there is no one left to answer.
                    }
                }
            }
        }
        _owner.BatchDone(this, failed: !ok);
    }
}
