using System.Diagnostics;
using System.Globalization;
using System.Text;

namespace ConduitChallenge;

static class WriteMetrics
{
    static readonly Collector? Output = Create();

    public static bool Enabled => Output is not null;
    public static long Stamp() => Enabled ? Stopwatch.GetTimestamp() : 0;
    public static long Elapsed(long start) => start == 0 ? 0 : Stopwatch.GetTimestamp() - start;
    public static void Waiting(int delta) => Output?.ChangeWaiting(delta);
    public static void Active(int delta) => Output?.ChangeActive(delta);
    public static void RecordWait(long ticks) => Output?.Record(0, ticks);
    public static void RecordHold(long ticks) => Output?.Record(1, ticks);
    public static void RecordCommit(long ticks) => Output?.Record(2, ticks);
    public static ValueTask StopAsync() => Output is { } output ? output.StopAsync() : default;

    static Collector? Create()
    {
        var path = Environment.GetEnvironmentVariable("WRITE_METRICS_PATH");
        return string.IsNullOrWhiteSpace(path) ? null : new Collector(path);
    }

    sealed class Collector
    {
        static readonly string[] StageNames = ["wait", "hold", "commit"];
        readonly long[] _counts = new long[3];
        readonly long[] _totals = new long[3];
        readonly long[] _maxima = new long[3];
        readonly CancellationTokenSource _stop = new();
        readonly StreamWriter _writer;
        readonly Task _loop;
        long _waiting;
        long _active;
        long _waitingPeak;
        long _activePeak;
        long _last = Stopwatch.GetTimestamp();
        int _stopped;

        public Collector(string path)
        {
            if (Path.GetDirectoryName(path) is { Length: > 0 } directory)
                Directory.CreateDirectory(directory);
            var file = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.Read, 65536);
            var empty = file.Length == 0;
            _writer = new StreamWriter(file, new UTF8Encoding(false), 65536);
            if (empty)
            {
                var header = new StringBuilder("epoch_ms,interval_ms,pid,waiting,waiting_peak,active,active_peak");
                foreach (var stage in StageNames)
                    header.Append(',').Append(stage).Append("_count,").Append(stage).Append("_mean_ms,").Append(stage).Append("_max_ms");
                _writer.WriteLine(header);
                _writer.Flush();
            }
            _loop = RunAsync();
        }

        public void ChangeWaiting(int delta)
        {
            var value = Interlocked.Add(ref _waiting, delta);
            Maximum(ref _waitingPeak, value);
        }

        public void ChangeActive(int delta)
        {
            var value = Interlocked.Add(ref _active, delta);
            Maximum(ref _activePeak, value);
        }

        public void Record(int stage, long ticks)
        {
            if (ticks < 0) return;
            Interlocked.Add(ref _totals[stage], ticks);
            Interlocked.Increment(ref _counts[stage]);
            Maximum(ref _maxima[stage], ticks);
        }

        static void Maximum(ref long location, long value)
        {
            var maximum = Volatile.Read(ref location);
            while (value > maximum)
            {
                var observed = Interlocked.CompareExchange(ref location, value, maximum);
                if (observed == maximum) break;
                maximum = observed;
            }
        }

        public ValueTask StopAsync()
        {
            if (Interlocked.Exchange(ref _stopped, 1) == 0)
            {
                try { _stop.Cancel(); }
                catch (ObjectDisposedException) { }
            }
            return new ValueTask(_loop);
        }

        async Task RunAsync()
        {
            using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1));
            try
            {
                while (await timer.WaitForNextTickAsync(_stop.Token))
                    Flush();
            }
            catch (OperationCanceledException) when (_stop.IsCancellationRequested) { }
            finally
            {
                try { Flush(); }
                finally
                {
                    _writer.Dispose();
                    _stop.Dispose();
                }
            }
        }

        void Flush()
        {
            var stamp = Stopwatch.GetTimestamp();
            var interval = Stopwatch.GetElapsedTime(_last, stamp).TotalMilliseconds;
            _last = stamp;
            var waiting = Volatile.Read(ref _waiting);
            var active = Volatile.Read(ref _active);
            var waitingPeak = Math.Max(waiting, Interlocked.Exchange(ref _waitingPeak, 0));
            var activePeak = Math.Max(active, Interlocked.Exchange(ref _activePeak, 0));
            var row = new StringBuilder(512).Append(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
            Value(row, interval);
            row.Append(',').Append(Environment.ProcessId).Append(',').Append(waiting).Append(',').Append(waitingPeak);
            row.Append(',').Append(active).Append(',').Append(activePeak);
            for (var stage = 0; stage < StageNames.Length; stage++)
            {
                var count = Interlocked.Exchange(ref _counts[stage], 0);
                var total = Interlocked.Exchange(ref _totals[stage], 0);
                var maximum = Interlocked.Exchange(ref _maxima[stage], 0);
                row.Append(',').Append(count);
                Value(row, count == 0 ? 0 : total * (1000.0 / Stopwatch.Frequency) / count);
                Value(row, maximum * (1000.0 / Stopwatch.Frequency));
            }
            _writer.WriteLine(row);
            _writer.Flush();
        }

        static void Value(StringBuilder row, double value) => row.Append(',').Append(value.ToString("0.###", CultureInfo.InvariantCulture));
    }
}
