using System;
using System.Collections.Generic;

/// <summary>
/// Read batches on this loop's readers. An idle reader takes the reads waiting in the shared queue, from every loop,
/// and runs them in two exchanges. Phase A sends one statement per kind of read present, each with arrays of the
/// batch's distinct keys, so reads asking for the same thing share one row. Phase B enriches every article phase A
/// found once (tag list, favorites count, author) and answers the viewers' favorited and following flags; both phases
/// share one read-only snapshot. Each response is then written here and handed to the loop holding its client.
/// </summary>
sealed partial class Loop
{
    readonly List<Job> _taken = [], _again = [];

    /// <summary>Starts a batch on the idle reader <paramref name="pg"/> when reads are due; otherwise lowers
    /// <paramref name="due"/> to when they will be. False when the reader stays idle.</summary>
    bool StartBatch(Pg pg, long now, ref long due)
    {
        Batch b = pg.Batch!;
        b.Clear();
        while (b.Jobs.Count == 0)
        {
            _taken.Clear();
            if (!_hub.TakeReads(now, _hurry, _taken, out long when))
            {
                due = Math.Min(due, when);
                return false;
            }
            foreach (Job job in _taken)
            {
                if (job.Closed) Discard(job); // nobody would read its answer
                else
                {
                    b.Jobs.Add(job);
                    AddKeys(b, job);
                }
            }
            _taken.Clear();
        }
        b.InTransaction = NeedsPhaseB(b);
        Wire w = pg.Out;
        if (b.InTransaction) Plain(b, w, Statement.Begin);
        foreach (Part p in b.Parts)
            if (p.Wanted) SendPart(b, p, w);
        pg.Sync();
        b.Phase = BatchPhase.A;
        return true;
    }

    static void AddKeys(Batch b, Job job)
    {
        Part p = b.Parts[job.Kind - 1];
        switch (job.Kind)
        {
            case KTags:
                p.Asked = true;
                break;
            case KCurrentUser:
                job.Key = p.Keys.Add(job.Viewer);
                break;
            case KLogin:
            case KProfile:
            case KArticle:
            case KComments:
                job.Key = p.Keys.Add(job.NameSpan);
                break;
            case KGlobal:
                p.Asked = true; // the one count
                job.Key = p.Keys.Add(job.Limit, job.Offset, out _);
                break;
            case KTag:
            case KAuthor:
            case KFavorited:
                job.CountKey = p.Counts.Add(job.NameSpan);
                job.Key = p.Keys.Add(job.NameSpan, job.Limit, job.Offset);
                break;
            case KFeed:
                job.CountKey = p.Counts.Add(job.Viewer);
                job.Key = p.Keys.Add(job.Viewer, job.Limit, job.Offset);
                break;
        }
    }

    /// <summary>Articles need phase B for their enrichment, and a signed-in viewer for its flags.</summary>
    static bool NeedsPhaseB(Batch b)
    {
        foreach (Job job in b.Jobs)
            if (job.Kind >= KArticle && job.Kind != KComments || job.Viewer != 0 && job.Kind is KProfile or KComments) return true;
        return false;
    }

    static void Plain(Batch b, Wire w, byte statement)
    {
        w.Bind(statement);
        w.Execute();
        b.Send(statement);
    }

    /// <summary>The part's statement with its keys as arrays.</summary>
    static void SendPart(Batch b, Part p, Wire w)
    {
        KeySet k = p.Keys, c = p.Counts;
        w.Bind(p.Statement);
        switch (p.Statement)
        {
            case Statement.Tags:
                break;
            case Statement.Users:
                w.BeginArray(Statement.Int8);
                for (int o = 1; o <= k.Count; o++) w.Element(k.Number(o, 0));
                w.EndArray();
                break;
            case Statement.Login:
            case Statement.Profile:
            case Statement.Article:
            case Statement.Comments:
                w.BeginArray();
                for (int o = 1; o <= k.Count; o++) w.Element(k[o]);
                w.EndArray();
                break;
            case Statement.Global:
                Numbers(w, k, 0, 2);
                Numbers(w, k, 1, 2);
                break;
            case Statement.Tag:
            case Statement.Author:
            case Statement.Favorited:
                w.BeginArray();
                for (int o = 1; o <= c.Count; o++) w.Element(c[o]);
                w.EndArray();
                w.BeginArray();
                for (int o = 1; o <= k.Count; o++) w.Element(k.Name(o, 2));
                w.EndArray();
                TailNumbers(w, k, 0);
                TailNumbers(w, k, 1);
                break;
            case Statement.Feed:
                Numbers(w, c, 0, 1);
                Numbers(w, k, 0, 3);
                Numbers(w, k, 1, 3);
                Numbers(w, k, 2, 3);
                w.BeginArray(Statement.Int8);
                for (int o = 1; o <= k.Count; o++)
                {
                    // per followee, the newest limit + offset articles are enough
                    long limit = k.Number(o, 1), offset = k.Number(o, 2);
                    w.Element(offset > long.MaxValue - limit ? long.MaxValue : offset + limit);
                }
                w.EndArray();
                break;
        }
        w.Execute();
        p.Sent = true;
        b.Send(p.Statement);
    }

    /// <summary>An int8[] of each key's <paramref name="i"/>th number (keys of <paramref name="of"/> numbers).</summary>
    static void Numbers(Wire w, KeySet k, int i, int of)
    {
        w.BeginArray(Statement.Int8);
        for (int o = 1; o <= k.Count; o++) w.Element(k.Number(o, i));
        w.EndArray();
    }

    /// <summary>An int8[] of the <paramref name="i"/>th of the two numbers after each key's name.</summary>
    static void TailNumbers(Wire w, KeySet k, int i)
    {
        w.BeginArray(Statement.Int8);
        for (int o = 1; o <= k.Count; o++) w.Element(k.Tail(o, 2, i));
        w.EndArray();
    }

    /// <summary>A reader's reply: the next phase, or the answers.</summary>
    void OnBatchReply(Pg pg, ReadOnlySpan<byte> reply)
    {
        Batch b = pg.Batch!;
        switch (b.Phase)
        {
            case BatchPhase.A:
                if (!Keep(b, reply, phaseA: true))
                {
                    Failed(pg, b);
                    return;
                }
                if (!b.InTransaction)
                {
                    Render(b);
                    return;
                }
                SendPhaseB(pg, b);
                break;
            case BatchPhase.B:
                if (!Keep(b, reply, phaseA: false))
                {
                    Failed(pg, b);
                    return;
                }
                Render(b);
                break;
            case BatchPhase.Rollback:
                Retry(b);
                break;
        }
    }

    /// <summary>
    /// Copies a phase's reply and indexes its rows: phase A's by kind and key, sorted by key and then in the order
    /// the response lists them; phase B's enrichment by article and its flags as hits. False when a statement failed.
    /// </summary>
    bool Keep(Batch b, ReadOnlySpan<byte> reply, bool phaseA)
    {
        ref byte[] buf = ref phaseA ? ref b.A : ref b.B;
        if (buf.Length < reply.Length) buf = new byte[Math.Max(reply.Length, buf.Length * 2)];
        reply.CopyTo(buf);
        ReadOnlySpan<byte> rest = buf.AsSpan(0, reply.Length);
        ReadOnlySpan<byte> all = rest;
        Span<int> starts = stackalloc int[Row.MaxColumns];
        int s = -1;
        Part? part = null;
        while (Pg.NextMessage(ref rest, out byte type, out ReadOnlySpan<byte> m))
        {
            switch (type)
            {
                case (byte)'2': // BindComplete: the next statement's result starts
                    s++;
                    part = phaseA && s < b.SentCount ? b.PartOf(b.Sent[s]) : null;
                    if (part != null) part.RowStart = part.RowEnd = b.RowCount;
                    break;
                case (byte)'D':
                {
                    int at = all.Length - rest.Length - m.Length;
                    var r = new Row(m, starts);
                    if (phaseA)
                    {
                        if (part == null) break;
                        ref RowRef x = ref Batch.Grow(ref b.Rows, b.RowCount++);
                        x.At = at;
                        x.Length = m.Length;
                        x.K = part.Statement == Statement.Tags ? 1 : r.Int64(0);
                        x.Order1 = x.Order2 = 0;
                        if (part.Statement == Statement.Comments)
                        {
                            if (!r.IsNull(1))
                            {
                                x.Order1 = -r.Int64(2); // newest first, then highest id
                                x.Order2 = -r.Int64(1);
                            }
                        }
                        else if (part.Statement >= Statement.Global && x.K > 0) x.Order1 = -r.Int64(1); // highest id first
                        part.RowEnd = b.RowCount;
                    }
                    else if (s < b.SentCount)
                    {
                        if (b.Sent[s] == Statement.Enrich)
                        {
                            int o = b.Articles.Find(r.Int64(0));
                            if (o > 0)
                            {
                                ref RowRef x = ref Batch.Grow(ref b.BRows, b.BRowCount);
                                x.At = at;
                                x.Length = m.Length;
                                b.EnrichRow[o] = b.BRowCount++;
                            }
                        }
                        else if (b.Sent[s] == Statement.Flags)
                        {
                            long viewer = r.Int64(1), id = r.Int64(2);
                            bool fav = r.Int64(0) == 0;
                            int o = fav ? b.Favs.Find(viewer, id) : b.Follows.Find(viewer, id);
                            if (o > 0) (fav ? b.FavHit : b.FollowHit)[o] = true;
                        }
                    }
                    break;
                }
                case (byte)'E':
                    b.Error = Pg.ErrorText(m);
                    b.Busy503 = Pg.ErrorField(m, (byte)'C').SequenceEqual("57014"u8);
                    return false;
            }
        }
        if (phaseA) Index(b);
        return true;
    }

    /// <summary>Sorts each kind's rows and finds each key's rows and counts.</summary>
    static void Index(Batch b)
    {
        Span<int> starts = stackalloc int[Row.MaxColumns];
        foreach (Part p in b.Parts)
        {
            if (!p.Sent) continue;
            p.PrepareIndex();
            Span<RowRef> rows = b.Rows.AsSpan(p.RowStart, p.RowEnd - p.RowStart);
            rows.Sort(new RowOrder());
            for (int i = p.RowStart; i < p.RowEnd; i++)
            {
                long k = b.Rows[i].K;
                if (k <= 0)
                {
                    // a list's count: -k is its count key, 0 the global count
                    if (-k < p.CountOf.Length) p.CountOf[-k] = new Row(b.A.AsSpan(b.Rows[i].At, b.Rows[i].Length), starts).Int64(1);
                    continue;
                }
                if (k >= p.First.Length) continue;
                if (p.Number[k]++ == 0) p.First[k] = i;
            }
        }
    }

    /// <summary>Phase B: every article phase A found, once, and the pairs the signed-in viewers ask flags about.</summary>
    void SendPhaseB(Pg pg, Batch b)
    {
        Span<int> starts = stackalloc int[Row.MaxColumns];
        b.Articles.Clear();
        b.Favs.Clear();
        b.Follows.Clear();
        foreach (int part in (ReadOnlySpan<int>)[Batch.Article, Batch.Global, Batch.Tag, Batch.Author, Batch.Favorited, Batch.Feed])
        {
            Part p = b.Parts[part];
            if (!p.Sent) continue;
            for (int i = p.RowStart; i < p.RowEnd; i++)
            {
                if (b.Rows[i].K <= 0) continue;
                var r = new Row(b.A.AsSpan(b.Rows[i].At, b.Rows[i].Length), starts);
                int o = b.Articles.Add(r.Int64(1));
                if (o >= b.Authors.Length) Array.Resize(ref b.Authors, b.Authors.Length * 2);
                b.Authors[o] = r.Int64(2);
            }
        }
        foreach (Job job in b.Jobs)
        {
            if (job.Viewer == 0 || job.Kind is KTags or KCurrentUser or KLogin) continue;
            Part p = b.Parts[job.Kind - 1];
            if (job.Key >= p.Number.Length) continue;
            for (int i = p.First[job.Key], end = i + p.Number[job.Key]; i < end; i++)
            {
                var r = new Row(b.A.AsSpan(b.Rows[i].At, b.Rows[i].Length), starts);
                switch (job.Kind)
                {
                    case KProfile:
                        b.Follows.Add(job.Viewer, r.Int64(1), out _);
                        break;
                    case KComments:
                        if (!r.IsNull(1)) b.Follows.Add(job.Viewer, r.Int64(5), out _);
                        break;
                    default:
                        b.Favs.Add(job.Viewer, r.Int64(1), out _);
                        b.Follows.Add(job.Viewer, r.Int64(2), out _);
                        break;
                }
            }
        }
        b.PrepareFlags();
        b.SentCount = 0;
        Wire w = pg.Out;
        if (b.Articles.Count > 0)
        {
            w.Bind(Statement.Enrich);
            Numbers(w, b.Articles, 0, 1);
            w.BeginArray(Statement.Int8);
            for (int o = 1; o <= b.Articles.Count; o++) w.Element(b.Authors[o]);
            w.EndArray();
            w.Execute();
            b.Send(Statement.Enrich);
        }
        if (b.Favs.Count + b.Follows.Count > 0)
        {
            w.Bind(Statement.Flags);
            Numbers(w, b.Favs, 0, 2);
            Numbers(w, b.Favs, 1, 2);
            Numbers(w, b.Follows, 0, 2);
            Numbers(w, b.Follows, 1, 2);
            w.Execute();
            b.Send(Statement.Flags);
        }
        Plain(b, w, Statement.Commit);
        pg.Sync();
        b.Phase = BatchPhase.B;
    }

    /// <summary>A statement failed: inside the transaction the rollback goes first, then the reads go again.</summary>
    void Failed(Pg pg, Batch b)
    {
        if (b.InTransaction)
        {
            b.SentCount = 0;
            Plain(b, pg.Out, Statement.Rollback);
            pg.Sync();
            b.Phase = BatchPhase.Rollback;
            return;
        }
        Retry(b);
    }

    /// <summary>After a failed batch: each read runs again in a batch of its own, so one read's failure fails it
    /// alone; a read that already ran alone (or was the batch) gets the error.</summary>
    void Retry(Batch b)
    {
        bool logged = false;
        _again.Clear();
        foreach (Job job in b.Jobs)
        {
            if (job.Alone || b.Jobs.Count == 1)
            {
                if (b.Busy503) AnswerError(job, 503, Errors.DatabaseBusy);
                else
                {
                    if (!logged) Console.Error.WriteLine("postgres: " + b.Error);
                    logged = true;
                    AnswerError(job, 500, Errors.Internal);
                }
            }
            else
            {
                job.Alone = true;
                _again.Add(job);
            }
        }
        if (_again.Count > 0)
        {
            _hub.RequeueReads(_again);
            _hurry = true;
        }
        _again.Clear();
        b.Jobs.Clear();
        b.Phase = BatchPhase.Idle;
    }

    /// <summary>The reader dropped with a batch out: its reads go again once, on whichever reader is up, then 503.</summary>
    void BatchLost(Batch b)
    {
        if (b.Phase == BatchPhase.Idle) return;
        _again.Clear();
        foreach (Job job in b.Jobs)
        {
            if (++job.Tries > 1) AnswerError(job, 503, Errors.DatabaseBusy);
            else _again.Add(job);
        }
        if (_again.Count > 0) _hub.RequeueReads(_again);
        _again.Clear();
        b.Jobs.Clear();
        b.Phase = BatchPhase.Idle;
    }

    // ---- the answers

    void Render(Batch b)
    {
        b.Phase = BatchPhase.Idle;
        foreach (Job job in b.Jobs) RenderOne(b, job);
        b.Jobs.Clear();
    }

    void RenderOne(Batch b, Job job)
    {
        Span<int> starts = stackalloc int[Row.MaxColumns];
        Part p = b.Parts[job.Kind - 1];
        int first = 0, rows = 0;
        if (job.Kind == KTags)
        {
            rows = p.RowEnd - p.RowStart;
            first = p.RowStart;
        }
        else if (job.Key < p.Number.Length)
        {
            first = p.First[job.Key];
            rows = p.Number[job.Key];
        }
        int at = HeadRoom;
        int status = 200;
        switch (job.Kind)
        {
            case KTags:
            {
                // the aggregate always returns its one row; without it the answer is still an empty list
                var r = rows > 0 ? RowAt(b, first, starts) : default;
                ReadOnlySpan<byte> json = rows > 0 && !r.IsNull(0) ? r.Bytes(0) : "[]"u8;
                byte[] o = Room(at, json.Length + 64);
                Json.Raw(o, ref at, "{\"tags\":"u8);
                Json.Raw(o, ref at, json);
                o[at++] = (byte)'}';
                break;
            }
            case KCurrentUser:
                if (rows == 0)
                {
                    AnswerError(job, 401, Errors.Unauthorized); // the token's user is gone
                    return;
                }
                User(Room(at, 6 * b.Rows[first].Length + job.KeepLength + 256), ref at, RowAt(b, first, starts), 1, job.Keep.AsSpan(0, job.KeepLength));
                break;
            case KLogin:
                Login(b, job, first, rows, starts);
                return;
            case KProfile:
                if (rows == 0)
                {
                    AnswerError(job, 404, Errors.ProfileNotFound);
                    return;
                }
                {
                    var r = RowAt(b, first, starts);
                    Profile(Room(at, 6 * b.Rows[first].Length + 256), ref at, r, 2, Follows(b, job.Viewer, r.Int64(1)));
                }
                break;
            case KArticle:
            {
                if (rows == 0)
                {
                    AnswerError(job, 404, Errors.ArticleNotFound);
                    return;
                }
                Json.Raw(Room(at, 16), ref at, "{\"article\":"u8);
                if (!BatchArticle(b, ref at, first, job.Viewer, body: true))
                {
                    AnswerError(job, 500, Errors.Internal);
                    return;
                }
                _response[at++] = (byte)'}';
                break;
            }
            case KComments:
            {
                if (rows == 0)
                {
                    AnswerError(job, 404, Errors.ArticleNotFound);
                    return;
                }
                Json.Raw(Room(at, 16), ref at, "{\"comments\":["u8);
                for (int i = first; i < first + rows; i++)
                {
                    var r = RowAt(b, i, starts);
                    if (r.IsNull(1)) continue; // the article has no comments
                    byte[] o = Room(at, 6 * b.Rows[i].Length + 256);
                    if (i > first) o[at++] = (byte)',';
                    Json.Raw(o, ref at, "{\"id\":"u8);
                    Json.Long(o, ref at, r.Int64(1));
                    Json.Raw(o, ref at, ",\"createdAt\":"u8);
                    Json.Timestamp(o, ref at, r.Int64(2));
                    Json.Raw(o, ref at, ",\"updatedAt\":"u8);
                    Json.Timestamp(o, ref at, r.Int64(3));
                    Json.Raw(o, ref at, ",\"body\":"u8);
                    Json.String(o, ref at, r.Bytes(4));
                    Json.Raw(o, ref at, ",\"author\":"u8);
                    Person(o, ref at, r, 6, Follows(b, job.Viewer, r.Int64(5)));
                    o[at++] = (byte)'}';
                }
                Json.Raw(Room(at, 8), ref at, "]}"u8);
                break;
            }
            default: // the lists
            {
                long count = job.Kind == KGlobal ? p.CountOf[0] : job.CountKey < p.CountOf.Length ? p.CountOf[job.CountKey] : 0;
                Json.Raw(Room(at, 16), ref at, "{\"articles\":["u8);
                for (int i = first; i < first + rows; i++)
                {
                    if (i > first) Room(at, 1)[at++] = (byte)',';
                    if (!BatchArticle(b, ref at, i, job.Viewer, body: false))
                    {
                        AnswerError(job, 500, Errors.Internal);
                        return;
                    }
                }
                Json.Raw(Room(at, 64), ref at, "],\"articlesCount\":"u8);
                Json.Long(_response, ref at, count);
                _response[at++] = (byte)'}';
                break;
            }
        }
        Answer(job, status, at);
    }

    Row RowAt(Batch b, int i, Span<int> starts) => new(b.A.AsSpan(b.Rows[i].At, b.Rows[i].Length), starts);

    static bool Follows(Batch b, long viewer, long user)
    {
        int o = viewer != 0 ? b.Follows.Find(viewer, user) : 0;
        return o > 0 && b.FollowHit[o];
    }

    static bool Favorited(Batch b, long viewer, long article)
    {
        int o = viewer != 0 ? b.Favs.Find(viewer, article) : 0;
        return o > 0 && b.FavHit[o];
    }

    /// <summary>
    /// An article from phase A's row <paramref name="i"/> (k, id, author_id, slug, title, description, created_at,
    /// updated_at, body) and its enrichment (id, tag list, favorites count, username, bio, image). False when the
    /// enrichment is missing, which one snapshot rules out.
    /// </summary>
    bool BatchArticle(Batch b, ref int at, int i, long viewer, bool body)
    {
        Span<int> starts = stackalloc int[Row.MaxColumns], estarts = stackalloc int[Row.MaxColumns];
        var a = RowAt(b, i, starts);
        long id = a.Int64(1), author = a.Int64(2);
        int o = b.Articles.Find(id);
        int e = o > 0 ? b.EnrichRow[o] : -1;
        if (e < 0) return false;
        var x = new Row(b.B.AsSpan(b.BRows[e].At, b.BRows[e].Length), estarts);
        byte[] r = Room(at, 6 * (b.Rows[i].Length + b.BRows[e].Length) + 1024);
        Json.Raw(r, ref at, "{\"slug\":"u8);
        Json.String(r, ref at, a.Bytes(3));
        Json.Raw(r, ref at, ",\"title\":"u8);
        Json.String(r, ref at, a.Bytes(4));
        Json.Raw(r, ref at, ",\"description\":"u8);
        Json.String(r, ref at, a.Bytes(5));
        if (body)
        {
            Json.Raw(r, ref at, ",\"body\":"u8);
            Json.String(r, ref at, a.Bytes(8));
        }
        Json.Raw(r, ref at, ",\"createdAt\":"u8);
        Json.Timestamp(r, ref at, a.Int64(6));
        Json.Raw(r, ref at, ",\"updatedAt\":"u8);
        Json.Timestamp(r, ref at, a.Int64(7));
        Json.Raw(r, ref at, ",\"tagList\":"u8);
        Json.Raw(r, ref at, x.Bytes(1));
        Json.Raw(r, ref at, ",\"favoritesCount\":"u8);
        Json.Long(r, ref at, x.Int64(2));
        bool favorited = Favorited(b, viewer, id);
        Json.Raw(r, ref at, favorited ? ",\"favorited\":true,\"author\":"u8 : ",\"favorited\":false,\"author\":"u8);
        Person(r, ref at, x, 3, Follows(b, viewer, author));
        r[at++] = (byte)'}';
        return true;
    }

    /// <summary>A login's row: the response is built while the row is at hand and sent only if the password matches.</summary>
    void Login(Batch b, Job job, int first, int rows, Span<int> starts)
    {
        if (rows > 0)
        {
            var r = RowAt(b, first, starts);
            int at = HeadRoom;
            UserWithNewToken(ref at, r, 1);
            job.SetKeep(_response.AsSpan(HeadRoom, at - HeadRoom));
            // a value too long to be a bcrypt hash is left out: the check then matches nothing
            ReadOnlySpan<byte> stored = r.Bytes(6);
            job.HashLength = stored.Length <= job.Hash.Length ? stored.Length : 0;
            stored[..job.HashLength].CopyTo(job.Hash);
            job.Known = true;
        }
        else
        {
            // an unknown email checks against a hash of nothing, so it costs a wrong password's bcrypt
            Passwords.UnknownUserHash.CopyTo(job.Hash, 0);
            job.HashLength = Passwords.UnknownUserHash.Length;
        }
        if (!Passwords.TrySubmit(job)) Refused(job);
    }
}
