import vibe.core.core : runApplication, runWorkerTaskDist, setupWorkerThreads;
import vibe.core.log;
import vibe.http.router;
import vibe.http.server;

import conduit.api;
import conduit.auth;
import conduit.db;

import std.conv : to;
import std.exception : enforce;
import std.parallelism : totalCPUs;
import std.process : environment;

import core.time : seconds;

/// Configuration, read once in main() and never changed afterwards.
__gshared string g_dbUrl;
__gshared string g_host;
__gshared ushort g_port;
__gshared string g_secret;
__gshared uint g_perThread;

/// SPEC.md allows 95 connections across every process.
enum totalConnections = 95;

void main()
{
    g_dbUrl = environment.get("DATABASE_URL", "");
    g_secret = environment.get("JWT_SECRET", "");
    enforce(g_dbUrl.length > 0, "DATABASE_URL is required");
    enforce(g_secret.length > 0, "JWT_SECRET is required");
    g_host = environment.get("HOST", "127.0.0.1");
    if (!g_host.length)
        g_host = "127.0.0.1";
    try
        g_port = environment.get("PORT", "3000").to!ushort;
    catch (Exception)
        g_port = 3000;

    // One event loop thread per core; each serves its own connections and
    // holds its own database pool.
    immutable threads = totalCPUs > 8 ? 8 : totalCPUs;
    g_perThread = totalConnections / threads;
    if (g_perThread < 1)
        g_perThread = 1;

    setupWorkerThreads(threads);
    runWorkerTaskDist(&workerMain, g_dbUrl, g_host, g_port, g_secret);
    runApplication();
}

/// Runs once in every worker thread: its own database pool, its own JSON
/// error page, its own router, and its own listening socket on the same port
/// (SO_REUSEPORT spreads the connections over the threads).
void workerMain(string dbUrl, string host, ushort port, string secret) nothrow
{
    try
    {
        auto db = new Db(dbUrl, g_perThread);
        db.warmUp(g_perThread);
        setPool(db);
        initAuth(secret);

        auto settings = new HTTPServerSettings;
        settings.port = port;
        settings.bindAddresses = [host];
        settings.options |= HTTPServerOption.reusePort;
        // The load generator holds one keep-alive connection per virtual user
        // for the whole session; never close one from under it.
        settings.keepAliveTimeout = 120.seconds;
        settings.maxRequestTime = 30.seconds;
        settings.errorPageHandler = (req, res, err) => errorPage(req, res, err);

        auto router = new URLRouter;
        registerRoutes(router);

        router.rebuild();
        listenHTTP(settings, router);
        logInfo("listening for requests on %s:%s", host, port);
    }
    catch (Exception e)
        assert(false, e.msg);
}
