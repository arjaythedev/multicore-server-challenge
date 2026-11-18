using Conduit.Api;
using Conduit.Auth;
using Conduit.Dispatch;
using Conduit.Http;
using Conduit.Pg;

namespace Conduit;

/// <summary>Process entry point: reads the settings, opens the read and write connections, serves HTTP.</summary>
public static class Program {
    /// <summary>
    /// Starts the server and serves until the process is stopped. A startup failure, such as a bad setting, a missing
    /// bcrypt library or a port in use, prints one line and returns 1.
    /// </summary>
    public static int Main() {
        // The first console write duplicates fds 1 and 2, which needs free descriptors. Write now: under load every
        // descriptor can be a client connection, and a first write then throws "Too many open files".
        Console.Error.WriteLine("conduit: starting");

        Settings settings;
        PgConnectionString connection;
        BcryptService bcrypt;
        try {
            settings = Config.Load(Environment.GetEnvironmentVariable);
            connection = PgConnectionString.Parse(settings.DatabaseUrl);
            bcrypt = new BcryptService(settings);
        } catch (Exception ex) {
            Console.Error.WriteLine("startup failed: " + ex.Message);
            return 1;
        }

        Stats stats = new(ReadKinds.All) { BcryptQueueLength = () => bcrypt.QueueLength };
        BcryptPasswords passwords = new(bcrypt);
        ReadFamilies families = ReadFamilies.Create(settings, passwords);
        ReadDispatcher reads = new(settings, families.All, stats);
        new ReadPool(connection, reads, settings.PgRead, families.All).Start();
        StartGatherTimer(reads, stats);

        WriteDispatcher writes = new(settings, new StopwatchClock(), stats);
        new WritePool(connection, writes, settings.PgWrite, WriteOps.All.SelectMany(o => o.Statements)).Start();

        // Postgres may still be starting: requests wait in the queues until the pools connect.
        try {
            HttpServer.Start(settings, new ApiHandler(settings, reads, families, null, writes, passwords), stats);
        } catch (Exception ex) {
            Console.Error.WriteLine("startup failed: " + ex.Message);
            return 1;
        }

        stats.StartReporter(settings.StatsSeconds);
        Thread.Sleep(Timeout.Infinite);
        return 0;
    }

    /// <summary>
    /// Ticks the read dispatcher every millisecond, so a batch whose gather window ended goes out even when no request
    /// arrives and no batch finishes to trigger it.
    /// </summary>
    private static void StartGatherTimer(ReadDispatcher reads, Stats stats) {
        new Thread(() => {
            while (true) {
                Thread.Sleep(1);
                try {
                    reads.Tick();
                } catch (Exception ex) {
                    stats.RecordReadError("read gather timer: " + ex.Message);
                }
            }
        }) { IsBackground = true, Name = "read-gather" }.Start();
    }
}
