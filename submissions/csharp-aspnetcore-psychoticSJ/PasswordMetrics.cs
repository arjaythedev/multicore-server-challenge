using System.Diagnostics;
using System.Globalization;
using System.Text;

namespace ConduitChallenge;

sealed class PasswordMetrics : IDisposable
{
    readonly object _gate = new();
    readonly Stats[] _stats = new Stats[2];
    readonly CancellationTokenSource _stop = new();
    readonly StreamWriter _writer;
    readonly Task _loop;
    long _last = Stopwatch.GetTimestamp();
    int _admissions;
    bool _stopping;
    int _disposed;

    public static PasswordMetrics? Create()
    {
        var path = Environment.GetEnvironmentVariable("BCRYPT_METRICS_PATH");
        return string.IsNullOrWhiteSpace(path) ? null : new PasswordMetrics(path);
    }

    PasswordMetrics(string path)
    {
        if (Path.GetDirectoryName(path) is { Length: > 0 } directory)
            Directory.CreateDirectory(directory);
        var file = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.Read, 16384);
        var empty = file.Length == 0;
        _writer = new StreamWriter(file, new UTF8Encoding(false), 16384);
        if (empty)
        {
            _writer.WriteLine("epoch_ms,interval_ms,pid,operation,waiting,waiting_peak,active,active_peak,queue_count,queue_mean_ms,queue_max_ms,work_count,work_mean_ms,work_max_ms,canceled_count,failed_count");
            _writer.Flush();
        }
        _loop = RunAsync();
    }

    public long Enqueue(int operation)
    {
        lock (_gate)
        {
            if (_stopping) return 0;
            var now = Stopwatch.GetTimestamp();
            _admissions++;
            ref var value = ref _stats[operation];
            value.Waiting++;
            value.WaitingPeak = Math.Max(value.WaitingPeak, value.Waiting);
            return now;
        }
    }

    public void AdmissionCompleted(long queuedAt)
    {
        if (queuedAt == 0) return;
        lock (_gate) CompleteAdmission();
    }

    public long Start(int operation, long queuedAt)
    {
        if (queuedAt == 0) return 0;
        var now = Stopwatch.GetTimestamp();
        lock (_gate)
        {
            ref var value = ref _stats[operation];
            value.Waiting--;
            Queue(ref value, now - queuedAt);
            value.Active++;
            value.ActivePeak = Math.Max(value.ActivePeak, value.Active);
        }
        return now;
    }

    public void Finish(int operation, long started, bool failed)
    {
        if (started == 0) return;
        var elapsed = Stopwatch.GetTimestamp() - started;
        lock (_gate)
        {
            ref var value = ref _stats[operation];
            value.Active--;
            value.WorkCount++;
            value.WorkTicks += elapsed;
            value.WorkMaximum = Math.Max(value.WorkMaximum, elapsed);
            if (failed) value.Failed++;
        }
    }

    public void Abandon(int operation, long queuedAt, bool canceled, bool admissionPending = false)
    {
        if (queuedAt == 0) return;
        var elapsed = Stopwatch.GetTimestamp() - queuedAt;
        lock (_gate)
        {
            ref var value = ref _stats[operation];
            value.Waiting--;
            Queue(ref value, elapsed);
            if (canceled) value.Canceled++;
            else value.Failed++;
            if (admissionPending) CompleteAdmission();
        }
    }

    void CompleteAdmission()
    {
        if (--_admissions == 0) Monitor.PulseAll(_gate);
    }

    static void Queue(ref Stats value, long ticks)
    {
        value.QueueCount++;
        value.QueueTicks += ticks;
        value.QueueMaximum = Math.Max(value.QueueMaximum, ticks);
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        lock (_gate)
        {
            _stopping = true;
            // Rejected channel writers must finish their metrics before the final snapshot.
            while (_admissions != 0) Monitor.Wait(_gate);
        }
        try { _stop.Cancel(); }
        catch (ObjectDisposedException) { }
        _loop.GetAwaiter().GetResult();
    }

    async Task RunAsync()
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1));
        try
        {
            while (await timer.WaitForNextTickAsync(_stop.Token)) Flush();
        }
        catch (OperationCanceledException) when (_stop.IsCancellationRequested) { }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            Console.Error.WriteLine($"Bcrypt metrics output stopped: {error.Message}");
        }
        finally
        {
            try { Flush(); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                Console.Error.WriteLine($"Bcrypt metrics flush failed: {error.Message}");
            }
            finally
            {
                try { _writer.Dispose(); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
                _stop.Dispose();
            }
        }
    }

    void Flush()
    {
        var now = Stopwatch.GetTimestamp();
        var interval = Stopwatch.GetElapsedTime(_last, now).TotalMilliseconds;
        _last = now;
        var epoch = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        for (var operation = 0; operation < _stats.Length; operation++)
        {
            Stats snapshot;
            lock (_gate)
            {
                snapshot = _stats[operation];
                _stats[operation] = new Stats
                {
                    Waiting = snapshot.Waiting, WaitingPeak = snapshot.Waiting,
                    Active = snapshot.Active, ActivePeak = snapshot.Active
                };
            }
            var row = new StringBuilder(320).Append(epoch);
            Value(row, interval);
            row.Append(',').Append(Environment.ProcessId).Append(',').Append(operation == 0 ? "hash" : "verify");
            row.Append(',').Append(snapshot.Waiting).Append(',').Append(snapshot.WaitingPeak);
            row.Append(',').Append(snapshot.Active).Append(',').Append(snapshot.ActivePeak);
            row.Append(',').Append(snapshot.QueueCount);
            Value(row, Mean(snapshot.QueueTicks, snapshot.QueueCount));
            Value(row, Milliseconds(snapshot.QueueMaximum));
            row.Append(',').Append(snapshot.WorkCount);
            Value(row, Mean(snapshot.WorkTicks, snapshot.WorkCount));
            Value(row, Milliseconds(snapshot.WorkMaximum));
            row.Append(',').Append(snapshot.Canceled).Append(',').Append(snapshot.Failed);
            _writer.WriteLine(row);
        }
        _writer.Flush();
    }

    static double Mean(long ticks, long count) => count == 0 ? 0 : Milliseconds(ticks) / count;
    static double Milliseconds(long ticks) => ticks * (1000.0 / Stopwatch.Frequency);
    static void Value(StringBuilder row, double value) => row.Append(',').Append(value.ToString("0.###", CultureInfo.InvariantCulture));

    struct Stats
    {
        public long Waiting, WaitingPeak, Active, ActivePeak;
        public long QueueCount, QueueTicks, QueueMaximum;
        public long WorkCount, WorkTicks, WorkMaximum;
        public long Canceled, Failed;
    }
}
