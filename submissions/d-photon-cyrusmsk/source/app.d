/// Multicore Conduit server on photon + photon-http.
///
/// Photon schedules fibers across one OS thread per available CPU. Each
/// scheduler thread opens its own Postgres pool (a connection belongs to the
/// thread that opened it) and then parks in a long timer, keeping the
/// scheduler alive. A dedicated acceptor thread owns the listening socket and
/// hands each accepted connection to `go`, which spreads clients over the
/// schedulers.
module conduit.app;

import photon : Mutex, delay, go, goOnAllThreads, initPhoton, mutex,
    runScheduler, schedulerThreads;

import conduit.api : ConduitProcessor, setPool;
import conduit.auth : initAuth;
import conduit.db : Db;

import core.atomic : atomicLoad, atomicOp, atomicStore, cas;
import core.stdc.stdlib : abort;
import core.time : Duration, MonoTime, hours, msecs, seconds;

import std.conv : to;
import std.exception : enforce;
import std.process : environment;
import std.socket : InternetAddress, Socket, SocketOption, SocketOptionLevel,
    SocketShutdown, TcpSocket;

import std.stdio : stderr;

/// Configuration, read once in main() and never changed afterwards.
__gshared string g_dbUrl;
__gshared string g_host;
__gshared ushort g_port;
__gshared string g_secret;
__gshared size_t g_schedulers;
__gshared uint g_connections;

/// SPEC.md allows 95 connections across every process.
enum totalConnections = 95;

/// Keep the direct listener from exhausting the fd/memory budget.
enum maxClients = 100_000;

/// Close sockets that have not completed a request in this long.
enum idleTimeout = 120.seconds;

/// Number of scheduler threads whose database pool is ready.
private shared(int) g_ready;

/// Accepted sockets that are still open.
private shared(int) g_activeClients;

/// Intrusive registry of live clients, protected by `clientLock`.
private __gshared ClientTask clientHead;
private shared Mutex clientLock;

/// Next scheduler index handed out by `workerMain`.
private shared(int) g_workerIndex;

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

    initPhoton();
    clientLock = mutex();
    g_schedulers = schedulerThreads();
    enforce(g_schedulers > 0 && g_schedulers <= totalConnections,
        "photon scheduler count exceeds the 95-connection limit");

    g_connections = totalConnections;
    const connValue = environment.get("CONNS", "");
    if (connValue.length)
    {
        try
            g_connections = connValue.to!uint;
        catch (Exception)
            g_connections = totalConnections;
        if (g_connections == 0)
            g_connections = totalConnections;
        if (g_connections > totalConnections)
            g_connections = totalConnections;
    }
    enforce(g_connections >= g_schedulers,
        "CONNS must be at least the scheduler count");

    // One setup fiber per scheduler: its own database pool, then a timer that
    // keeps the scheduler (and the process) alive while clients are served.
    // The setup fiber is queued first, so a client can never run on a
    // scheduler before that scheduler's pool exists.
    goOnAllThreads({ workerMain(); });

    // Photon intercepts accept4() and parks only this fiber while the
    // listener is idle; the scheduler keeps running other connections.
    go({ acceptLoop(); });
    go({ clientReaper(); });

    runScheduler();
}

/// Runs once in every worker thread.
private void workerMain()
{
    const scheduler = cast(size_t) atomicOp!"+="(g_workerIndex, 1);
    const base = g_connections / g_schedulers;
    const extra = g_connections % g_schedulers;
    const count = base + (scheduler < extra ? 1 : 0);

    try
    {
        auto db = new Db(g_dbUrl, cast(uint) count);
        setPool(db);
        initAuth(g_secret);
        atomicOp!"+="(g_ready, 1);
        while (true)
            delay(1.hours);
    }
    catch (Exception e)
    {
        stderr.writeln("conduit: worker setup failed: ", e.msg);
        abort();
    }
}

/// The single listening socket. The kernel queues connections; this fiber
/// only accepts and schedules.
private void acceptLoop()
{
    // No client may run before every scheduler has its pool: a request that
    // arrives early would dereference a null TLS pool.
    while (atomicLoad(g_ready) < g_schedulers)
        delay(1.msecs);

    TcpSocket listener;
    try
    {
        listener = new TcpSocket;
        listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
        listener.bind(new InternetAddress(g_host, g_port));
        listener.listen(1024);
    }
    catch (Exception e)
    {
        stderr.writeln("conduit: listen failed: ", e.msg);
        abort();
    }

    while (true)
    {
        Socket client;
        try
        {
            client = listener.accept();
            client.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, 1);
        }
        catch (Exception e)
        {
            if (client !is null)
            {
                try
                    client.close();
                catch (Throwable)
                {
                }
            }
            stderr.writeln("conduit: accept failed: ", e.msg);
            delay(10.msecs);
            continue;
        }

        atomicOp!"+="(g_activeClients, 1);
        if (atomicLoad(g_activeClients) > maxClients)
        {
            atomicOp!"-="(g_activeClients, 1);
            try
                client.close();
            catch (Throwable)
            {
            }
            continue;
        }

        // Bind the socket to a heap object: a closure over the loop-local
        // `client` would keep reading the slot that the next accept reuses.
        auto task = new ClientTask(client);
        registerClient(task);
        try
            go(&task.run);
        catch (Throwable e)
        {
            finishClient(task);
            stderr.writeln("conduit: schedule failed: ", e);
        }
    }
}

/// Current monotonic time in milliseconds.
private long nowTicks() nothrow
{
    return MonoTime.currTime.ticks;
}

/// Carries one accepted socket into a fiber without a stack capture.
private final class ClientTask
{
    private Socket socket;
    private shared(long) lastActiveTicks;
    private shared(int) state;
    private shared(int) timedOut;
    private ClientTask prev;
    private ClientTask next;

    this(Socket socket)
    {
        this.socket = socket;
        atomicStore(this.lastActiveTicks, nowTicks());
    }

    void run()
    {
        serveClient(this);
    }
}

/// Removes `task` from the registry; caller holds `clientLock`.
private void unregisterLocked(ClientTask task) nothrow
{
    if (task.prev !is null)
        task.prev.next = task.next;
    else if (clientHead is task)
        clientHead = task.next;
    if (task.next !is null)
        task.next.prev = task.prev;
    task.prev = null;
    task.next = null;
}

/// Claims the one close/accounting transition for a client.
private bool claimClient(ClientTask task) nothrow
{
    return cas(&task.state, 0, 1);
}

private void registerClient(ClientTask task) nothrow
{
    clientLock.lock();
    task.next = clientHead;
    if (clientHead !is null)
        clientHead.prev = task;
    clientHead = task;
    clientLock.unlock();
}

/// Closes a client once, removing it from the registry and the active count.
private void finishClient(ClientTask task) nothrow
{
    if (!claimClient(task))
        return;
    clientLock.lock();
    unregisterLocked(task);
    clientLock.unlock();
    try
        task.socket.close();
    catch (Throwable)
    {
    }
    atomicOp!"-="(g_activeClients, 1);
}

/// Closes sockets that have not completed a request for `idleTimeout`.
private void clientReaper() nothrow
{
    while (true)
    {
        try
            delay(10.seconds);
        catch (Throwable)
            return;
        const now = nowTicks();
        clientLock.lock();
        try
        {
            auto task = clientHead;
            while (task !is null)
            {
                auto next = task.next;
                if (now - atomicLoad(task.lastActiveTicks) >= idleTimeout.total!"seconds" * MonoTime.ticksPerSecond
                        && cas(&task.timedOut, 0, 1))
                {
                    try
                        task.socket.shutdown(SocketShutdown.BOTH);
                    catch (Throwable)
                    {
                    }
                }
                task = next;
            }
        }
        finally
            clientLock.unlock();
    }
}

/// One fiber per connection. The processor loops until the client closes or
/// the connection is idle for too long.
private void serveClient(ClientTask task)
{
    scope (exit) finishClient(task);
    try
    {
        atomicStore(task.lastActiveTicks, nowTicks());
        auto processor = new ConduitProcessor(task.socket, &task.lastActiveTicks);
        processor.run();
    }
    catch (Throwable e)
    {
        // A keep-alive client closing its socket is normal, and photon-http
        // reports it as an incomplete parse. Only real failures are logged.
        import std.string : indexOf;
        const msg = e.msg;
        if (msg.indexOf("Failed during http parsing") < 0 &&
            msg.indexOf("I/O error") < 0)
            stderr.writeln("conduit: connection failed: ", e);
    }
}
