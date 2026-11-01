using System;
using System.Collections.Generic;
using System.Threading;

/// <summary>The loop's Postgres side: write groups on its writers, replies handed on, and connections that drop or
/// reconnect. Read batches are in Loop.Batch.cs.</summary>
sealed partial class Loop
{
    /// <summary>How often a write that lost a deadlock or serialization check runs again.</summary>
    const int MaxTries = 3;

    // ---- writes

    /// <summary>Sends the writes waiting in the hub as the idle writer's next group (one transaction, one commit) once
    /// the oldest has waited Hub.GroupWindow or Hub.MaxGroup wait; otherwise lowers <paramref name="due"/> to when they
    /// will. A write runs even when its client has gone: it asked for it.</summary>
    bool StartGroup(Pg pg, long now, ref long due)
    {
        if (!_hub.TakeWrites(now, _hurry, pg.Group, out long when))
        {
            due = Math.Min(due, when);
            return false;
        }
        pg.SendGroup();
        return true;
    }

    /// <summary>
    /// The group's reply: every write's outcome in the order sent, or the error that rolled them all back. The
    /// writes before the failing one ran without error and go again. The failing one is answered with its error only
    /// when it ran first, on committed data alone; otherwise it goes again first, so an error never comes from a
    /// write that then didn't commit.
    /// </summary>
    void OnWriteGroupReply(Pg pg, ReadOnlySpan<byte> reply)
    {
        List<Job> group = pg.Group;
        ReadOnlySpan<byte> all = reply;
        int k = 0, left = group.Count > 0 ? group[0].Statements : 0, failedAt = -1, statementStart = 0;
        scoped ReadOnlySpan<byte> error = default;
        while (Pg.NextMessage(ref reply, out byte type, out ReadOnlySpan<byte> m))
        {
            int at = all.Length - reply.Length; // the offset after this message
            if (type == 'C' && k < group.Count)
            {
                if (--left == 0)
                {
                    group[k].ReplyStart = statementStart;
                    group[k].ReplyEnd = at;
                    if (++k < group.Count) left = group[k].Statements;
                }
                statementStart = at;
            }
            else if (type == 'E')
            {
                failedAt = k;
                error = m;
                break;
            }
        }

        if (failedAt < 0)
        {
            foreach (Job job in group) AnswerWrite(job, all[job.ReplyStart..job.ReplyEnd]);
        }
        else if (failedAt >= group.Count)
        {
            // the commit failed after every statement succeeded: no write to blame
            foreach (Job job in group) FailWrite(job, 500, Errors.Internal);
        }
        else
        {
            Job bad = group[failedAt];
            ReadOnlySpan<byte> code = Pg.ErrorField(error, (byte)'C');
            bool transient = code.SequenceEqual("40P01"u8) || code.SequenceEqual("40001"u8);
            group.RemoveAt(failedAt);
            if (transient && ++bad.Tries > MaxTries) FailWrite(bad, 503, Errors.DatabaseBusy);
            else if (transient || failedAt > 0) group.Insert(0, bad);
            else if (code.SequenceEqual("23505"u8) && bad.Kind is WRegister or WUpdateUser) FailWrite(bad, 422, Errors.Taken);
            else if (code.SequenceEqual("55P03"u8) || code.SequenceEqual("57014"u8)) FailWrite(bad, 503, Errors.DatabaseBusy);
            else
            {
                Console.Error.WriteLine("postgres: " + Pg.ErrorText(error));
                FailWrite(bad, 500, Errors.Internal);
            }
            _hub.RequeueWrites(group);
            _hurry = true;
        }
        group.Clear();
    }

    /// <summary>Answers a write that can't be done, and spares its job.</summary>
    void FailWrite(Job job, int status, ReadOnlySpan<byte> body) => AnswerError(job, status, body);

    // ---- connections

    void OnPg(int i, uint events)
    {
        Pg pg = _pgs[i];
        if (pg.Connecting)
        {
            OnPgConnected(i);
            return;
        }
        if (pg.Broken) return;
        if ((events & (Native.EpollErr | Native.EpollHup)) != 0 || ((events & Native.EpollIn) != 0 && !pg.Receive()))
        {
            OnPgLost(i);
            return;
        }
        if ((events & Native.EpollOut) != 0) FlushPg(i);
        if (pg.IsWriter)
            while (!pg.Broken && pg.NextReply(out ReadOnlySpan<byte> reply)) OnWriteGroupReply(pg, reply);
        else
            while (!pg.Broken && pg.NextReply(out ReadOnlySpan<byte> reply)) OnBatchReply(pg, reply);
    }

    /// <summary>Sends what the connection has queued, and watches it for writable only while some is left.</summary>
    void FlushPg(int i)
    {
        Pg pg = _pgs[i];
        if (pg.Broken) return;
        if (!pg.Flush())
        {
            OnPgLost(i);
            return;
        }
        bool wantOut = pg.WantsWrite;
        if (wantOut != _pgWatchingOut[i])
        {
            Native.Watch(_epfd, Native.EpollCtlMod, pg.Fd, Native.EpollIn | (wantOut ? Native.EpollOut : 0), PgTag | (uint)i);
            _pgWatchingOut[i] = wantOut;
        }
    }

    /// <summary>A Postgres connection dropped, and reconnects within a second. A read batch out goes again once, on
    /// whichever reader is up. A write group in flight may or may not have committed, so its writes fail with 503 and
    /// are never sent again.</summary>
    void OnPgLost(int i)
    {
        Pg pg = _pgs[i];
        Console.Error.WriteLine("postgres: connection lost");
        pg.Close();
        Interlocked.Decrement(ref pg.IsWriter ? ref _hub.LiveWriters : ref _hub.LiveReaders);
        if (pg.IsWriter)
        {
            foreach (Job job in pg.Group) FailWrite(job, 503, Errors.DatabaseBusy);
            pg.Group.Clear();
        }
        else BatchLost(pg.Batch!);
    }

    /// <summary>Starts connecting; the connection's first writable event finishes the login in <see cref="OnPgConnected"/>.</summary>
    void Reconnect(int i)
    {
        Pg pg = _pgs[i];
        try
        {
            pg.BeginOpen();
            Native.Watch(_epfd, Native.EpollCtlAdd, pg.Fd, Native.EpollOut, PgTag | (uint)i);
        }
        catch (Exception e)
        {
            Console.Error.WriteLine("postgres: " + e.Message);
            pg.Close();
        }
    }

    void OnPgConnected(int i)
    {
        Pg pg = _pgs[i];
        try
        {
            Native.Watch(_epfd, Native.EpollCtlMod, pg.Fd, Native.EpollIn, PgTag | (uint)i);
            _pgWatchingOut[i] = false;
            pg.FinishOpen();
            Interlocked.Increment(ref pg.IsWriter ? ref _hub.LiveWriters : ref _hub.LiveReaders);
        }
        catch (Exception e)
        {
            Console.Error.WriteLine("postgres: " + e.Message);
            pg.Close();
        }
    }

    bool AnyBroken()
    {
        foreach (Pg pg in _pgs)
            if (pg.Broken) return true;
        return false;
    }
}
