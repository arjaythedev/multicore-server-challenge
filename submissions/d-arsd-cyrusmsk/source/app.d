/// Process entry point.
///
/// Reads the SPEC.md configuration from the environment, records the JWT
/// secret, then runs arsd.cgi's embedded HTTP server in fiber (`hybrid`) mode.
/// Each worker thread accepts connections itself and serves them on fibers, so
/// there is nothing shared between threads except immutable configuration.
module conduit.app;

import arsd.cgi : RequestServer;

import conduit.api : handle;
import conduit.auth : initAuth;
import conduit.db : g_dbUrl;

import std.conv : to;
import std.exception : enforce;
import std.parallelism : totalCPUs;
import std.process : environment;

version(cgi_use_fiber)
{
    import arsd.cgi : fiberStackSize;
}

/// SPEC.md allows at most 95 Postgres connections across every process, and
/// each worker thread holds exactly one connection, so that is also the thread
/// cap.
private enum maxThreads = 90;

void main()
{
    g_dbUrl = environment.get("DATABASE_URL", "");
    immutable secret = environment.get("JWT_SECRET", "");
    enforce(g_dbUrl.length > 0, "DATABASE_URL is required");
    enforce(secret.length > 0, "JWT_SECRET is required");

    auto host = environment.get("HOST", "127.0.0.1");
    if (!host.length)
        host = "127.0.0.1";
    ushort port;
    try
        port = environment.get("PORT", "3000").to!ushort;
    catch (Exception)
        port = 3000;

    // Loads the HMAC key in this thread; every worker thread loads its own on
    // first use.
    initAuth(secret);

    version(cgi_use_fiber)
    {
        // Tens of thousands of idle keep-alive connections are expected, and a
        // fiber is parked on each one; the 400 KB default stack per fiber is
        // far more than these shallow handlers need.
        fiberStackSize = 64 * 1024;
    }

    auto threads = defaultThreads();
    auto requested = environment.get("ARSD_THREADS", "");
    long parsed;
    if (requested.length && parsePositive(requested, parsed) && parsed >= 1 && parsed <= maxThreads)
        threads = cast(int) parsed;

    auto server = RequestServer(["http://" ~ host ~ ":" ~ to!string(port)]);
    // Required, not just arsd's default: in fiber (`hybrid`) mode arsd only
    // makes the listening socket non-blocking when useFork is set (cgi.d), and
    // a blocking listener lets the EPOLLEXCLUSIVE accept wake-up park worker
    // threads in accept() until the pool collapses under a few thousand
    // keep-alive connections.
    server.useFork = true;
    server.numberOfThreads = threads;

    server.serve!handle();
}

/// `2 * cores + 1` (the arsd default for fiber servers), clamped to the
/// connection budget.
private int defaultThreads()
{
    auto threads = cast(int)(totalCPUs * 2 + 1);
    if (threads > maxThreads)
        threads = maxThreads;
    if (threads < 1)
        threads = 1;
    return threads;
}

/// ASCII digits only, non-empty, fitting in a long.
private bool parsePositive(const(char)[] s, out long value) pure nothrow @safe
{
    value = 0;
    if (s.length == 0 || s.length > 9)
        return false;
    long parsed;
    foreach (c; s)
    {
        if (c < '0' || c > '9')
            return false;
        parsed = parsed * 10 + (c - '0');
    }
    value = parsed;
    return true;
}
