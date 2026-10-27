using System.Globalization;
using System.Text;
using Conduit.Pg;

namespace Conduit;

/// <summary>
/// Thread-safe counters and the periodic stats line on stderr, which the service journal keeps. Other components call
/// the Record methods; <see cref="Report"/> turns the change since the last report into one line.
/// </summary>
public sealed class Stats {
    /// <summary>Family names, in report order.</summary>
    private readonly string[] _families;
    /// <summary>Requests counted per family since start.</summary>
    private readonly long[] _requests;
    /// <summary>Per-family request counts at the last report, so a report can give the interval's rate.</summary>
    private readonly long[] _lastRequests;
    /// <summary>Totals since start: batches, requests in them, Postgres executions, connections refused for lack of descriptors, read errors, write errors and accept errors.</summary>
    private long _batches, _batchItems, _pgExecutions, _emfile, _readErrors, _writeErrors, _acceptErrors;
    /// <summary>Text of the latest read or write error not yet reported, or null.</summary>
    private string? _lastError;
    /// <summary>Batch and execution totals at the last report.</summary>
    private long _lastBatches, _lastBatchItems, _lastPgExecutions;

    /// <summary>Creates counters for the named request families, in the order they are reported.</summary>
    public Stats(string[] families) {
        _families = families;
        _requests = new long[families.Length];
        _lastRequests = new long[families.Length];
    }

    /// <summary>Returns the age in milliseconds of the oldest waiting read request; set by the read dispatcher.</summary>
    public Func<long>? OldestQueueAgeMs { get; set; }

    /// <summary>Returns the number of bcrypt jobs waiting; set by the bcrypt service.</summary>
    public Func<int>? BcryptQueueLength { get; set; }

    /// <summary>Connections refused for lack of descriptors since start: EMFILE or ENFILE from accept, or past the reserve.</summary>
    public long Emfile => Interlocked.Read(ref _emfile);

    /// <summary>Total read connection and batch failures since start.</summary>
    public long ReadErrors => Interlocked.Read(ref _readErrors);

    /// <summary>Total write connection and transaction failures since start.</summary>
    public long WriteErrors => Interlocked.Read(ref _writeErrors);

    /// <summary>Total accept-path failures that were survived since start, such as a failed socket option, a connection that could not be registered or an exception caught in a loop handler.</summary>
    public long AcceptErrors => Interlocked.Read(ref _acceptErrors);

    /// <summary>Counts one read request of family index <paramref name="family"/>.</summary>
    public void RecordRequest(int family) => Interlocked.Increment(ref _requests[family]);

    /// <summary>Counts one read batch of <paramref name="size"/> requests.</summary>
    public void RecordBatch(int size) {
        Interlocked.Increment(ref _batches);
        Interlocked.Add(ref _batchItems, size);
    }

    /// <summary>Counts Postgres statement executions.</summary>
    public void RecordPgExecutions(int count) => Interlocked.Add(ref _pgExecutions, count);

    /// <summary>Counts one connection refused for lack of descriptors.</summary>
    public void RecordEmfile() => Interlocked.Increment(ref _emfile);

    /// <summary>Counts one Postgres error on a read batch of family <paramref name="family"/> and keeps its text as the latest error.</summary>
    public void RecordReadError(string family, PgError error) {
        Interlocked.Increment(ref _readErrors);
        Volatile.Write(ref _lastError, $"read {family}: {error.SqlState} {error.Message}");
    }

    /// <summary>Counts one Postgres error on a write transaction and keeps its text as the latest error.</summary>
    public void RecordWriteError(PgError error) {
        Interlocked.Increment(ref _writeErrors);
        Volatile.Write(ref _lastError, $"write: {error.SqlState} {error.Message}");
    }

    /// <summary>Counts one read failure and keeps its context as the latest error.</summary>
    public void RecordReadError(string message) {
        Interlocked.Increment(ref _readErrors);
        Volatile.Write(ref _lastError, message);
    }

    /// <summary>Counts one write failure and keeps its context as the latest error.</summary>
    public void RecordWriteError(string message) {
        Interlocked.Increment(ref _writeErrors);
        Volatile.Write(ref _lastError, message);
    }

    /// <summary>Counts one accept-path failure that was survived.</summary>
    public void RecordAcceptError() => Interlocked.Increment(ref _acceptErrors);

    /// <summary>Returns the latest read or write error text since the last call, or null when there was none.</summary>
    public string? TakeLastError() => Interlocked.Exchange(ref _lastError, null);

    /// <summary>
    /// Builds the stats line for the last <paramref name="elapsedSeconds"/> seconds and starts the
    /// next interval. Rates are per second; the EMFILE and error figures are totals since start.
    /// Call it from one thread: the interval figures are not locked.
    /// </summary>
    public string Report(double elapsedSeconds) {
        CultureInfo inv = CultureInfo.InvariantCulture;
        StringBuilder sb = new("stats rps");
        for (int i = 0; i < _families.Length; i++) {
            long now = Interlocked.Read(ref _requests[i]);
            sb.Append(' ').Append(_families[i]).Append('=').Append(Rate(now - _lastRequests[i], elapsedSeconds).ToString(inv));
            _lastRequests[i] = now;
        }

        long batches = Interlocked.Read(ref _batches);
        long items = Interlocked.Read(ref _batchItems);
        long pg = Interlocked.Read(ref _pgExecutions);
        long dBatches = batches - _lastBatches;
        double mean = dBatches == 0 ? 0.0 : (double)(items - _lastBatchItems) / dBatches;
        long pgRate = Rate(pg - _lastPgExecutions, elapsedSeconds);
        _lastBatches = batches;
        _lastBatchItems = items;
        _lastPgExecutions = pg;

        sb.Append(" oldest_ms=").Append((OldestQueueAgeMs?.Invoke() ?? 0).ToString(inv));
        sb.Append(" batch_mean=").Append(mean.ToString("0.0", inv));
        sb.Append(" pg_per_s=").Append(pgRate.ToString(inv));
        sb.Append(" bcrypt_q=").Append((BcryptQueueLength?.Invoke() ?? 0).ToString(inv));
        sb.Append(" emfile=").Append(Emfile.ToString(inv));
        sb.Append(" read_err=").Append(ReadErrors.ToString(inv));
        sb.Append(" write_err=").Append(WriteErrors.ToString(inv));
        sb.Append(" accept_err=").Append(AcceptErrors.ToString(inv));
        return sb.ToString();
    }

    /// <summary>Starts a background thread that writes <see cref="Report"/> to stderr every <paramref name="seconds"/> seconds.</summary>
    public void StartReporter(int seconds) {
        Thread thread = new(() => {
            long last = Environment.TickCount64;
            while (true) {
                Thread.Sleep(seconds * 1000);
                long now = Environment.TickCount64;
                WriteReport((now - last) / 1000.0, Console.Error.WriteLine);
                last = now;
            }
        }) { IsBackground = true, Name = "stats" };
        thread.Start();
    }

    /// <summary>
    /// Writes one report line over <paramref name="seconds"/>, then the latest error if there is one. Never throws: on
    /// the reporter thread an exception would end the process. A failed write loses that error's text, not its count.
    /// </summary>
    internal void WriteReport(double seconds, Action<string> write) {
        string line = Report(seconds);
        string? lastError = TakeLastError();
        try {
            write(line);
            if (lastError is not null) {
                write("last error: " + lastError);
            }
        } catch (Exception) {
            // stderr is unusable for now; the counters keep counting and the next interval tries again.
        }
    }

    /// <summary>Turns a count over <paramref name="seconds"/> into whole units per second, rounding halves up.</summary>
    private static long Rate(long delta, double seconds) => (long)Math.Round(delta / seconds, MidpointRounding.AwayFromZero);
}
