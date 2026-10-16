/**
 * Conduit (RealWorld) on vibe.d, for the multicore server challenge (SPEC.md).
 *
 * Process and thread model
 * ------------------------
 * Postgres is capped at `max_connections = 100`, runs on the same 8 cores, and every
 * request has to wait for it, so the interesting question is how much of the
 * database's work a core can keep flowing.
 *
 * One process with one vibe-core event loop thread per core. Each thread has:
 *   - its own listening socket on the same port (SO_REUSEPORT), so the kernel
 *     spreads connections over the threads and each one serves its own
 *     keep-alive connections for their whole life;
 *   - its own pool of long-lived, prepared Postgres connections (a vibe.d
 *     connection belongs to the thread that created it).
 *
 * A request is then parsed, queried, rendered and answered by a single core, with
 * no lock or channel between any two of them.
 */
module conduit.app;

import vibe.core.core;
import vibe.core.log;
import vibe.core.net;
import vibe.http.server;

import derelict.pq.dynload : DerelictPQ;

import conduit.api : handleRequest, sendError, setDb;
import conduit.db;
import conduit.jwt;

import core.time : seconds;
import std.algorithm.comparison : max;
import std.conv : to;
import std.exception : enforce;
import std.process : environment;

/// dpq2 reaches libpq through derelict, which fills in the function pointers when
/// the library is loaded. This has to happen before anything calls into libpq,
/// otherwise the first call dereferences a null pointer.
shared static this()
{
    DerelictPQ.load();
}

int main(string[] args)
{
    immutable dbURL = environment.get("DATABASE_URL", "");
    immutable secret = environment.get("JWT_SECRET", "");
    enforce(dbURL.length > 0, "DATABASE_URL is required");
    enforce(secret.length > 0, "JWT_SECRET is required");

    initJwt(secret);

    g_host = environment.get("HOST", "127.0.0.1");
    if (g_host.length == 0) g_host = "127.0.0.1";
    g_port = portFromEnv("PORT");
    g_settings = makeSettings();

    g_dbURL = dbURL;
    immutable threads = threadCountFromEnv("THREADS");
    // SPEC.md: keep the total, across every process, at 95 or fewer.
    immutable totalConns = uintFromEnv("CONNS", 95);
    immutable perThread = cast(uint) max(1, cast(int) totalConns / cast(int) threads);
    g_maxConns = perThread;

    // The main thread is never one of the worker threads.
    immutable workers = threads > 1 ? threads - 1 : 0;
    logInfo("conduit (D, vibe.d): %s:%s, %s event loop threads, up to %s connections each (%s total)",
            g_host, g_port, threads, perThread, perThread * threads);

    // Prepare the statements once on a first connection: a wrong SQL statement, or
    // a database that isn't there, must fail at startup and not on the first request.
    auto bootstrap = new Db(dbURL, 1);
    bootstrap.warmUp(1);

    // Start the worker threads, each with its own listener and its own pool, ...
    setupWorkerThreads(cast(uint) workers);
    if (workers) runWorkerTaskDist(&bindListener);

    // ... then the main thread listens too, and runApplication() runs its event loop.
    bindListener();
    logInfo("listening for HTTP on %s:%s", g_host, g_port);
    return runApplication();
}

/// Runs in every event loop thread: each worker thread once, plus the main one.
void bindListener() nothrow
{
    try {
        auto db = new Db(g_dbURL, g_maxConns);
        db.warmUp(g_maxConns);
        setDb(db);

        auto ctx = new HTTPServerContext(g_host, g_port);
        ctx.addVirtualHost(g_settings, (req, res) @safe { handleRequest(req, res); });

        NetworkAddress addr;
        try addr = resolveHost(g_host);
        catch (Exception e) {
            logError("cannot resolve %s: %s", g_host, e.msg);
            exitEventLoop(true);
            return;
        }
        addr.port = g_port;

        auto listener = listenTCP((TCPConnection conn) nothrow @safe {
            try handleHTTPConnection(conn, ctx);
            catch (Exception e) {
                logError("HTTP connection handler threw: %s", e.msg);
                try conn.close();
                catch (Exception) {
                }
            }
        }, addr, TCPListenOptions.reusePort);
        if (!listener) {
            logError("failed to listen on %s:%s", g_host, g_port);
            exitEventLoop(true);
            return;
        }
        logInfo("listening for requests on %s (event loop %s)", listener.bindAddress, threadName());
    } catch (Exception e) {
        logError("failed to start a listener: %s", e.msg);
        exitEventLoop(true);
    }
}

private HTTPServerSettings makeSettings()
{
    auto settings = new HTTPServerSettings;
    settings.port = g_port;
    settings.bindAddresses = [g_host];
    settings.options |= HTTPServerOption.reusePort;
    // Hold keep-alive connections for a long time: the load generator keeps one per
    // virtual user for the whole session.
    settings.keepAliveTimeout = 120.seconds;
    settings.maxRequestTime = 30.seconds;
    settings.serverString = "conduit-vibed";
    settings.errorPageHandler = (req, res, err) @trusted { errorPage(req, res, err); };
    return settings;
}

/// vibe.d's own error path (a malformed request line, say): JSON, in the shape
/// every other error uses.
private void errorPage(HTTPServerRequest req, HTTPServerResponse res, HTTPServerErrorInfo error)
@trusted
{
    if (res.headerWritten) return;
    sendError(res, error.code, error.message.length ? error.message : "bad request");
}

private ushort portFromEnv(string name) nothrow
{
    try return environment.get(name, "3000").to!ushort;
    catch (Exception) return 3000;
}

private uint uintFromEnv(string name, uint fallback) nothrow
{
    try {
        auto t = environment.get(name, "");
        if (!t.length) return fallback;
        return t.to!uint;
    } catch (Exception) {
        return fallback;
    }
}

/// Event loop threads: one per core, capped at the 8 vCPUs the box gives us.
private uint threadCountFromEnv(string name) nothrow
{
    uint fromEnv;
    try {
        auto t = environment.get(name, "");
        if (t.length) {
            immutable n = t.to!uint;
            if (n >= 1) fromEnv = n;
        }
    } catch (Exception) {
    }
    if (fromEnv == 0) {
        try fromEnv = cast(uint) logicalProcessorCount();
        catch (Exception) fromEnv = 4;
    }
    return fromEnv > 8 ? 8 : fromEnv;
}

private string threadName() nothrow @trusted
{
    import core.thread : Thread;

    try return Thread.getThis().name;
    catch (Exception) return "main";
}

/// Configuration shared by every thread (read-only after main() has set it).
__gshared {
    string g_host = "127.0.0.1";
    ushort g_port = 3000;
    string g_dbURL;
    uint g_maxConns = 8;
    HTTPServerSettings g_settings;
}
