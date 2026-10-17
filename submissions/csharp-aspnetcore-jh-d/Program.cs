using System.Net;
using Conduit;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.AspNetCore.Server.Kestrel.Transport.Sockets;

static string Env(string name) =>
    Environment.GetEnvironmentVariable(name) is { Length: > 0 } v ? v : throw new InvalidOperationException(name + " is required");

string host = Environment.GetEnvironmentVariable("HOST") is { Length: > 0 } h ? h : "127.0.0.1";
int port = int.Parse(Environment.GetEnvironmentVariable("PORT") is { Length: > 0 } p ? p : "3000");
int poolSize = int.Parse(Environment.GetEnvironmentVariable("DB_POOL_SIZE") is { Length: > 0 } ps ? ps : (4 * Environment.ProcessorCount).ToString());
string databaseUrl = Env("DATABASE_URL");
Jwt.Init(Env("JWT_SECRET"));

var builder = WebApplication.CreateSlimBuilder(args);
builder.Logging.ClearProviders();
builder.Services.Configure<SocketTransportOptions>(o =>
{
    o.Backlog = 16384;
    if (Environment.GetEnvironmentVariable("CONDUIT_INLINE") == "1") o.UnsafePreferInlineScheduling = true;
});
builder.WebHost.ConfigureKestrel(o =>
{
    o.AddServerHeader = false;
    // Idle keep-alive connections stay open well past Nginx's 60 s, and a direct client (tens of thousands of them) is never dropped while thinking.
    o.Limits.KeepAliveTimeout = TimeSpan.FromMinutes(10);
    o.Limits.MaxRequestBodySize = 1 << 20;
    o.Limits.MinRequestBodyDataRate = null;
    o.Limits.MinResponseDataRate = null;
    var address = IPAddress.TryParse(host, out var ip) ? ip : IPAddress.Any;
    o.Listen(address, port, l => l.Protocols = HttpProtocols.Http1);
});

await Db.Init(databaseUrl, poolSize);
var app = builder.Build();
if (Environment.GetEnvironmentVariable("CONDUIT_STATS") == "1")
{
    // Diagnostics for tuning only (off by default): GC activity and thread-pool pressure, every 10 s on stderr.
    _ = Task.Run(async () =>
    {
        TimeSpan lastPause = default;
        while (true)
        {
            await Task.Delay(10_000);
            var pause = GC.GetTotalPauseDuration();
            Console.Error.WriteLine(
                $"stats gc0={GC.CollectionCount(0)} gc1={GC.CollectionCount(1)} gc2={GC.CollectionCount(2)} pause10s={(pause - lastPause).TotalMilliseconds:F0}ms " +
                $"heap={GC.GetTotalMemory(false) >> 20}MB threads={ThreadPool.ThreadCount} queue={ThreadPool.PendingWorkItemCount} conns={System.Diagnostics.Process.GetCurrentProcess().Threads.Count}t");
            lastPause = pause;
        }
    });
}
app.Run(Api.Handle);
await app.RunAsync();
