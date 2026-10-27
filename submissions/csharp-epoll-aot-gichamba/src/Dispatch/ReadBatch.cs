using Conduit.Pg;

namespace Conduit.Dispatch;

/// <summary>
/// One batch of waiting requests of one family, sent to Postgres as a single pipelined statement.
/// Result rows are routed to their request by the r.i column. Callbacks run on the connection's reader thread.
/// A family that owns its batches (the planner) adds several statements instead, reads the rows itself and may send
/// the same batch again for a second round trip on the same connection.
/// </summary>
public sealed class ReadBatch : PgRequest {
    /// <summary>The dispatcher that recycles this batch and receives its stats.</summary>
    private readonly ReadDispatcher _owner;
    /// <summary>Guards the flags below and row routing, which run on the reader thread, against an abandon from another thread.</summary>
    private readonly object _gate = new();
    /// <summary>The connection broke and the dispatcher took the jobs back. Later callbacks are ignored.</summary>
    private bool _abandoned;
    /// <summary>OnDone has run, so a broken connection can no longer take this batch back.</summary>
    private bool _finished;
    /// <summary>A server error, a bad row or a row that matched no job happened. The jobs get a 500.</summary>
    private bool _failed;

    /// <summary>Creates an empty batch for <paramref name="owner"/> with room for <paramref name="capacity"/> jobs.</summary>
    internal ReadBatch(ReadDispatcher owner, int capacity) {
        _owner = owner;
        Jobs = new ReadJob[capacity];
    }

    /// <summary>The family every job in this batch belongs to.</summary>
    public ReadFamily Family { get; private set; } = null!;

    /// <summary>The jobs; only the first <see cref="Count"/> are in use.</summary>
    public ReadJob[] Jobs { get; }

    /// <summary>Number of jobs in the batch.</summary>
    public int Count { get; private set; }

    /// <summary>Index of the read connection slot this batch was sent on.</summary>
    internal int Slot { get; set; }

    /// <summary>The connection generation this batch was sent on; a stale one is ignored when it finishes.</summary>
    internal int Generation { get; set; }

    /// <summary>What a family that owns its batches keeps for this batch between round trips. Null for other families.</summary>
    public object? State { get; set; }

    /// <summary>Starts a new batch of <paramref name="family"/> and clears the state of the previous use.</summary>
    internal void Begin(ReadFamily family) {
        Family = family;
        Count = 0;
        State = null;
        _abandoned = _finished = _failed = false;
    }

    /// <summary>Adds a job. The caller keeps <see cref="Count"/> below the capacity.</summary>
    internal void Add(ReadJob job) => Jobs[Count++] = job;

    /// <summary>Adds prepared statement <paramref name="preparedName"/> and returns its parameter list to fill.</summary>
    internal PgParams Statement(string preparedName) => AddStatement(preparedName);

    /// <summary>Removes the statements of the last round trip, before an owned batch adds the next one.</summary>
    internal void ClearStatements() => ResetStatements();

    /// <summary>Builds the statements and their parameters. Call after the batch is formed and before it is sent.</summary>
    internal void Prepare() {
        ResetStatements();
        Family.PrepareBatch(this);
    }

    /// <summary>
    /// Takes the batch away from a broken connection. Returns false when it already finished, in which case
    /// its jobs are answered and must not be retried.
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
            if (_abandoned || _failed) {
                return;
            }

            try {
                if (Family.OwnsBatch) {
                    Family.OnBatchRow(this, statementIndex, row);
                    return;
                }
                if (Family.Broadcast) {
                    for (int i = 0; i < Count; i++) {
                        Family.OnRow(Jobs[i], row);
                    }

                    return;
                }
                long at = PgBinary.ReadInt8(row[0]);
                if ((ulong)at >= (ulong)Count) {
                    _failed = true;
                } else {
                    Family.OnRow(Jobs[(int)at], row);
                }
            } catch (Exception) {
                _failed = true;
            }
        }
    }

    /// <inheritdoc />
    public override void OnCommandComplete(int statementIndex, ReadOnlySpan<byte> tag) {
    }

    /// <inheritdoc />
    public override void OnError(PgError error) {
        lock (_gate) {
            _failed = true;
        }

        _owner.Stats?.RecordReadError(Family.Name, error);
    }

    /// <inheritdoc />
    public override void OnDone() {
        if (Family.OwnsBatch) {
            OwnedDone();
            return;
        }
        lock (_gate) {
            if (_abandoned) {
                return;
            }

            _finished = true;
        }
        for (int i = 0; i < Count; i++) {
            ReadJob job = Jobs[i];
            try {
                if (_failed) {
                    job.Fail(500, "internal error");
                } else {
                    int status = Family.Complete(job);
                    if (status != ReadFamily.Deferred) {
                        job.Respond(status);
                    }
                }
            } catch (Exception) {
                try {
                    job.ResetResult();
                    job.Fail(500, "internal error");
                } catch (Exception) {
                    // The client is gone; there is no one left to answer.
                }
            }
        }
        _owner.BatchDone(this);
    }

    /// <summary>
    /// A round trip of an owned batch ended. The batch is not in the connection's queue now, so a broken connection cannot
    /// abandon it until it is sent again: either the next round trip goes out, or the family answers every job.
    /// </summary>
    private void OwnedDone() {
        bool failed;
        lock (_gate) {
            if (_abandoned) {
                return;
            }

            failed = _failed;
        }
        bool next = false;
        if (!failed) {
            try {
                next = Family.ContinueBatch(this);
            } catch (Exception) {
                failed = true;
            }
        }
        if (next) {
            _owner.SendNext(this);
            return;
        }

        lock (_gate) {
            _finished = true;
        }
        try {
            Family.FinishBatch(this, failed);
        } catch (Exception) {
            // FinishBatch answers each job on its own; nothing is left to answer here.
        }
        _owner.BatchDone(this);
    }

    /// <summary>Drops the job references so the batch can be reused.</summary>
    internal void Clear() {
        Array.Clear(Jobs, 0, Count);
        Count = 0;
        State = null;
    }
}
