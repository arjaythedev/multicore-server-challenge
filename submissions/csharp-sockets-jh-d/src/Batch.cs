namespace Conduit;

// Read requests of the same kind that arrive while earlier ones are still in Postgres are sent together as ONE
// statement: the kind's query runs once per request inside a LATERAL join over arrays of the requests' parameters
// (unnest), and every row comes back tagged with its request's index. Each request's data is still read by its own
// execution of the query, in the statement's snapshot, while the request is being served; the batch only shares
// the per-statement costs (protocol messages, executor startup and shutdown, snapshot, socket round trip).
//
// No timer. Requests wait in their kind's queue until a read connection has room (fewer than Dispatch.Depth
// statements in Postgres); then the kind whose oldest request has waited longest sends everything it has queued
// (up to MaxBatch) as one statement. At low load every batch has one request and nothing waits; under load requests
// stay queued until a backend is actually free, so batches grow and nothing queues behind a long statement on a
// connection. MaxInflight caps how many connections one kind can hold at once.
enum Layout : byte
{
    None,           // tags: index only
    ViewerKey,      // (viewer bigint, key text)
    Viewer,         // (viewer bigint)
    List,           // (viewer bigint, limit int, offset bigint)
    ListKey,        // (viewer bigint, limit int, offset bigint, key text)
}

static class Dispatch
{
    // DISPATCH=kind: the earlier policy (each kind sends at once while it has fewer than MaxInflight batches out)
    public static bool ConnectionDriven = true;
    public static int Depth = 1;
    public static readonly object Lock = new();

    // fill free connection slots, oldest waiting request first
    public static void Pump()
    {
        if (!ConnectionDriven) return;
        while (true)
        {
            BatchQuery b;
            PgConn conn;
            lock (Lock)
            {
                Kind best = null;
                long oldest = long.MaxValue;
                foreach (var k in Kind.All)
                {
                    if (!k.Ready) continue;
                    long t = k.HeadQueued;
                    if (t < oldest) { oldest = t; best = k; }
                }
                if (best == null) return;
                conn = Pg.Reads.PickBelow(Depth);
                if (conn == null) return;
                conn.Reserve();
                b = best.TakeLocked();
            }
            conn.Submit(b, reserved: true);
        }
    }
}

sealed class Kind
{
    // defaults; per kind: BATCH_<NAME>=<max batch>:<max in flight> (e.g. BATCH_COMMENTS=8:6)
    public static int DefaultBatch = 32, DefaultInflight = 6;
    public static readonly List<Kind> All = new();

    public readonly string Name;
    public readonly Stmt Stmt;
    public readonly Layout Layout;
    public int MaxBatch = DefaultBatch, MaxInflight = DefaultInflight;
    readonly Queue<Ctx> _pending = new();
    readonly Stack<BatchQuery> _free = new();
    int _inflight;

    public Kind(string name, Stmt stmt, Layout layout, int maxBatch = 0, int maxInflight = 0)
    {
        Name = name;
        Stmt = stmt;
        Layout = layout;
        if (maxBatch > 0) MaxBatch = maxBatch;
        if (maxInflight > 0) MaxInflight = maxInflight;
        All.Add(this);
    }

    public void Configure(string setting)
    {
        var p = setting.Split(':');
        MaxBatch = int.Parse(p[0]);
        if (p.Length > 1) MaxInflight = int.Parse(p[1]);
    }

    // under Dispatch.Lock
    public bool Ready => _pending.Count > 0 && _inflight < MaxInflight;
    public long HeadQueued => _pending.Peek().Queued;

    public void Enqueue(Ctx c)
    {
        c.Queued = System.Diagnostics.Stopwatch.GetTimestamp();
        BatchQuery b = null;
        lock (Dispatch.Lock)
        {
            _pending.Enqueue(c);
            if (!Dispatch.ConnectionDriven && _inflight < MaxInflight) b = TakeLocked();
        }
        if (Dispatch.ConnectionDriven) Dispatch.Pump();
        else if (b != null) Pg.Read(b);
    }

    // a batch completed: let the next one go
    public void Release()
    {
        BatchQuery b = null;
        lock (Dispatch.Lock)
        {
            _inflight--;
            if (!Dispatch.ConnectionDriven && _pending.Count > 0) b = TakeLocked();
        }
        if (Dispatch.ConnectionDriven) Dispatch.Pump();
        else if (b != null) Pg.Read(b);
    }

    // a batch's responses are all written: it can be reused
    public void Recycle(BatchQuery done)
    {
        lock (Dispatch.Lock) _free.Push(done);
    }

    // under Dispatch.Lock
    public BatchQuery TakeLocked()
    {
        var b = _free.Count > 0 ? _free.Pop() : new BatchQuery(this);
        int n = Math.Min(_pending.Count, MaxBatch);
        for (int i = 0; i < n; i++) b.Items[i] = _pending.Dequeue();
        b.N = n;
        _inflight++;
        return b;
    }
}

sealed class BatchQuery : PgQuery
{
    readonly Kind _k;
    public readonly Ctx[] Items;
    public int N;
    readonly Ctx[] _done;

    public BatchQuery(Kind k)
    {
        _k = k;
        Items = new Ctx[k.MaxBatch];
        _done = new Ctx[k.MaxBatch];
    }

    public override void Write(PgWriter w)
    {
        int n = N;
        var it = Items;
        w.Bind(_k.Stmt);
        w.BeginArray(Oid.Int4);
        for (int i = 0; i < n; i++) w.Int4(i);
        w.EndArray(n);
        var l = _k.Layout;
        if (l != Layout.None)
        {
            w.BeginArray(Oid.Int8);
            for (int i = 0; i < n; i++) w.Int8(it[i].Viewer);
            w.EndArray(n);
        }
        if (l is Layout.List or Layout.ListKey)
        {
            w.BeginArray(Oid.Int4);
            for (int i = 0; i < n; i++) w.Int4(it[i].Limit);
            w.EndArray(n);
            w.BeginArray(Oid.Int8);
            for (int i = 0; i < n; i++) w.Int8(it[i].Offset);
            w.EndArray(n);
        }
        if (l is Layout.ViewerKey or Layout.ListKey)
        {
            w.BeginArray(Oid.Text);
            for (int i = 0; i < n; i++) w.Text(it[i].Key);
            w.EndArray(n);
        }
        w.EndBind();
        w.Sync();
    }

    public override void Row(int result, ref PgRow row)
    {
        int i = row.Int4(0);
        if ((uint)i < (uint)N) Handlers.BatchRow(Items[i], ref row);
    }

    public override void Done(PgError error)
    {
        int n = N;
        Array.Copy(Items, _done, n);
        Array.Clear(Items, 0, n);
        N = 0;
        _k.Release(); // the next batch of this kind goes out before these responses are written
        for (int i = 0; i < n; i++)
        {
            var c = _done[i];
            _done[i] = null;
            try { Handlers.BatchDone(c, error); }
            catch (Exception e)
            {
                Console.Error.WriteLine(e);
                c.Error(500, "internal error");
                c.Finish();
            }
        }
        _k.Recycle(this);
    }
}

// A request's own statement(s) (writes, logins): one Sync group, written by the handler for the request's step.
sealed class SingleQuery : PgQuery
{
    readonly Ctx _c;
    public SingleQuery(Ctx c) => _c = c;
    public override void Write(PgWriter w) => Handlers.WriteSingle(_c, w);
    public override void Row(int result, ref PgRow row) => Handlers.SingleRow(_c, result, ref row);
    public override void Complete(int result, ReadOnlySpan<byte> tag) => Handlers.SingleComplete(_c, result, tag);

    public override void Done(PgError error)
    {
        try { Handlers.SingleDone(_c, error); }
        catch (Exception e)
        {
            Console.Error.WriteLine(e);
            _c.Error(500, "internal error");
            _c.Finish();
        }
    }
}
