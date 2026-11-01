using System;
using System.Threading;

// A few epoll loops serve the clients; reads and writes from all of them run as batches on a shared set of Postgres
// connections; bcrypt runs on threads of its own.
Jwt.Init(Environment.GetEnvironmentVariable("JWT_SECRET") ?? "multicore-server-challenge");
Loop.Conns = new Conn[Native.MaxFiles()];
Passwords.Start();

var db = PgSettings.Parse(Environment.GetEnvironmentVariable("DATABASE_URL") ?? "postgres://conduit:conduit@127.0.0.1:5432/conduit");
string host = Environment.GetEnvironmentVariable("HOST") ?? "0.0.0.0";
int port = int.TryParse(Environment.GetEnvironmentVariable("PORT"), out int p) ? p : 80;

var hub = new Hub(host, port, db, Hub.LoopCount, Hub.Readers, Hub.Writers);
Thread[] threads = hub.Start();
Console.WriteLine($"listening on {host}:{port} with {Hub.LoopCount} loops, {Hub.Readers} readers and {Hub.Writers} writer");
foreach (Thread t in threads) t.Join();
return 0;
