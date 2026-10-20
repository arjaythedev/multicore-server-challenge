using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using Conduit;

static string Env(string name, string def = null) => Environment.GetEnvironmentVariable(name) is { Length: > 0 } v ? v : def;

string url = Env("DATABASE_URL") ?? throw new InvalidOperationException("DATABASE_URL is not set");
// Session settings only. Generic plans: every statement here has a generic plan as good as its custom one, and
// custom planning costs as much as executing. No JIT, no parallel workers for these short OLTP queries. No Memoize:
// in a batched statement it could hand one request a row another request's lookup fetched; with it off every
// request's lookups are its own.
string options = Env("DB_OPTIONS",
    "-c plan_cache_mode=force_generic_plan -c jit=off -c max_parallel_workers_per_gather=0 -c enable_memoize=off");

// The collation decides whether tag lists are sorted by Postgres or by us (Sql.AppSortsTags), and so the SQL text.
var collation = new StartupQuery(Sql.Collation); // defines the statement before the connection prepares it
var boot = Pg.OpenOne(url, options);
boot.Submit(collation);
collation.Wait();
boot.Close();
static bool CodePoint(string c) => c is "C" or "POSIX" || c.StartsWith("C.", StringComparison.OrdinalIgnoreCase);
Sql.AppSortsTags = collation.Values[0] switch
{
    "c" => CodePoint(collation.Values[1]),   // libc
    "b" => CodePoint(collation.Values[2]),   // builtin C / C.UTF-8
    _ => false,                              // ICU: let Postgres sort
};
Kind.DefaultBatch = int.Parse(Env("BATCH_MAX", "64"));
Kind.DefaultInflight = int.Parse(Env("BATCH_INFLIGHT", "6"));
Sql.Define();
foreach (var k in Kind.All)
    if (Env("BATCH_" + k.Name.ToUpperInvariant()) is { } setting) k.Configure(setting);

if (args.Length > 0 && args[0] == "--print-sql")
{
    foreach (var s in Stmt.List) Console.WriteLine("s" + s.Id + "\t" + s.Sql.ReplaceLineEndings(" "));
    return;
}

int conns = int.Parse(Env("DB_CONNS", "12")), writeConns = int.Parse(Env("DB_WRITE_CONNS", "16"));
// writes: each commit waits for its WAL flush, so they get their own connections (reads never queue behind a
// commit), and enough of them that concurrent commits share flushes (Postgres's group commit)
Pg.Open(url, conns, writeConns, options);
Dispatch.ConnectionDriven = Env("DISPATCH", "conn") != "kind";
Dispatch.Depth = int.Parse(Env("DISPATCH_DEPTH", "1"));
foreach (var c in Pg.Reads.Conns) c.Freed = Dispatch.Pump;
Jwt.Init(Env("JWT_SECRET") ?? throw new InvalidOperationException("JWT_SECRET is not set"));
CpuWork.Init(int.Parse(Env("BCRYPT_THREADS", "2")), int.Parse(Env("BCRYPT_NICE", "0")), int.Parse(Env("BCRYPT_BATCH_WAIT_MS", "300")));

var host = Env("HOST", "127.0.0.1");
var port = int.Parse(Env("PORT", "3000"));
var ip = IPAddress.TryParse(host, out var parsed) ? parsed : host == "localhost" ? IPAddress.Loopback : IPAddress.IPv6Any;
new HttpServer(ip, port).Start();
Console.WriteLine($"conduit listening on {host}:{port} (postgres connections={conns} for reads + {writeConns} for writes, dispatch={(Dispatch.ConnectionDriven ? "conn depth " + Dispatch.Depth : "kind")}, batches " +
                  string.Join(" ", Kind.All.Select(k => $"{k.Name}={k.MaxBatch}:{k.MaxInflight}")) + $", tags sorted by {(Sql.AppSortsTags ? "app" : "Postgres")})");

var done = new ManualResetEventSlim();
using var sigterm = PosixSignalRegistration.Create(PosixSignal.SIGTERM, ctx => { ctx.Cancel = true; done.Set(); });
using var sigint = PosixSignalRegistration.Create(PosixSignal.SIGINT, ctx => { ctx.Cancel = true; done.Set(); });
done.Wait();

// a startup query on its own connection: the first row's columns as text
sealed class StartupQuery(Stmt stmt) : PgQuery
{
    readonly ManualResetEventSlim _done = new();
    public string[] Values = [];
    PgError _error;

    public override void Write(PgWriter w)
    {
        w.Bind(stmt);
        w.EndBind();
        w.Sync();
    }

    public override void Row(int result, ref PgRow row)
    {
        if (Values.Length > 0) return;
        Values = new string[row.Count];
        for (int i = 0; i < row.Count; i++) Values[i] = row.IsNull(i) ? null : Encoding.UTF8.GetString(row.Bytes(i));
    }

    public override void Done(PgError error)
    {
        _error = error;
        _done.Set();
    }

    public void Wait()
    {
        _done.Wait();
        if (_error != null) throw new InvalidOperationException("postgres: " + _error);
    }
}
