using System.Diagnostics;
using System.Globalization;
using System.Text;

namespace ConduitChallenge;

static class ReadMetrics
{
    public enum Stage { Admission, Queue, Connection, Execute, ReadEncode, FinishEncode }

    static readonly Collector? Output = Create();

    public static bool Enabled => Output is not null;
    public static long Stamp() => Enabled ? Stopwatch.GetTimestamp() : 0;
    public static long Elapsed(long start) => start == 0 ? 0 : Stopwatch.GetTimestamp() - start;
    public static void Record(int shape, Stage stage, long ticks) => Output?.Record(shape, stage, ticks);
    public static void Batch(int shape, int size) => Output?.Batch(shape, size);
    public static ValueTask StopAsync() => Output is { } output ? output.StopAsync() : default;

    static Collector? Create()
    {
        var path = Environment.GetEnvironmentVariable("READ_METRICS_PATH");
        return string.IsNullOrWhiteSpace(path) ? null : new Collector(path);
    }

    sealed class Collector
    {
        const int ShapeCount = 10;
        const int StageCount = 6;
        const int BatchSlots = 65;
        static readonly string[] ShapeNames = ["tags", "profile", "article", "comments", "global", "tag", "author", "favorited", "feed", "article_id"];
        static readonly string[] StageNames = ["admission", "queue", "connection", "execute", "read_encode", "finish_encode"];
        readonly long[] _counts = new long[ShapeCount * StageCount];
        readonly long[] _totals = new long[ShapeCount * StageCount];
        readonly long[] _maxima = new long[ShapeCount * StageCount];
        readonly long[] _batches = new long[ShapeCount * BatchSlots];
        readonly CancellationTokenSource _stop = new();
        readonly StreamWriter _writer;
        readonly Task _loop;
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
                var header = new StringBuilder("epoch_ms,interval_ms,pid,shape,batches,batch_requests,batch_mean,batch_max,batch_size_counts");
                foreach (var name in StageNames)
                    header.Append(',').Append(name).Append("_count,").Append(name).Append("_mean_ms,").Append(name).Append("_max_ms");
                _writer.WriteLine(header);
                _writer.Flush();
            }
            _loop = RunAsync();
        }

        public void Record(int shape, Stage stage, long ticks)
        {
            if ((uint)shape >= ShapeCount || (uint)stage >= StageCount || ticks < 0)
                return;
            var index = shape * StageCount + (int)stage;
            Interlocked.Add(ref _totals[index], ticks);
            Interlocked.Increment(ref _counts[index]);
            var maximum = Volatile.Read(ref _maxima[index]);
            while (ticks > maximum)
            {
                var observed = Interlocked.CompareExchange(ref _maxima[index], ticks, maximum);
                if (observed == maximum)
                    break;
                maximum = observed;
            }
        }

        public void Batch(int shape, int size)
        {
            if ((uint)shape < ShapeCount && size is >= 1 and < BatchSlots)
                Interlocked.Increment(ref _batches[shape * BatchSlots + size]);
        }

        public ValueTask StopAsync()
        {
            if (Interlocked.Exchange(ref _stopped, 1) == 0)
                _stop.Cancel();
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
                Flush();
                _writer.Dispose();
                _stop.Dispose();
            }
        }

        void Flush()
        {
            var stamp = Stopwatch.GetTimestamp();
            var interval = Stopwatch.GetElapsedTime(_last, stamp).TotalMilliseconds;
            _last = stamp;
            var epoch = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            Span<long> counts = stackalloc long[StageCount];
            Span<long> totals = stackalloc long[StageCount];
            Span<long> maxima = stackalloc long[StageCount];
            Span<long> histogram = stackalloc long[BatchSlots];
            for (var shape = 0; shape < ShapeCount; shape++)
            {
                long samples = 0, batches = 0, requests = 0;
                var maximum = 0;
                for (var stage = 0; stage < StageCount; stage++)
                {
                    var index = shape * StageCount + stage;
                    counts[stage] = Interlocked.Exchange(ref _counts[index], 0);
                    totals[stage] = Interlocked.Exchange(ref _totals[index], 0);
                    maxima[stage] = Interlocked.Exchange(ref _maxima[index], 0);
                    samples += counts[stage];
                }
                for (var size = 1; size < BatchSlots; size++)
                {
                    var count = Interlocked.Exchange(ref _batches[shape * BatchSlots + size], 0);
                    histogram[size] = count;
                    batches += count;
                    requests += count * size;
                    if (count != 0)
                        maximum = size;
                }
                if (samples == 0 && batches == 0)
                    continue;
                var row = new StringBuilder(1024).Append(epoch);
                Value(row, interval);
                row.Append(',').Append(Environment.ProcessId).Append(',').Append(ShapeNames[shape]);
                row.Append(',').Append(batches).Append(',').Append(requests);
                Value(row, batches == 0 ? 0 : (double)requests / batches);
                row.Append(',').Append(maximum).Append(',');
                var separator = "";
                for (var size = 1; size < BatchSlots; size++)
                    if (histogram[size] != 0)
                    {
                        row.Append(separator).Append(size).Append(':').Append(histogram[size]);
                        separator = "|";
                    }
                for (var stage = 0; stage < StageCount; stage++)
                {
                    row.Append(',').Append(counts[stage]);
                    Value(row, counts[stage] == 0 ? 0 : totals[stage] * (1000.0 / Stopwatch.Frequency) / counts[stage]);
                    Value(row, maxima[stage] * (1000.0 / Stopwatch.Frequency));
                }
                _writer.WriteLine(row);
            }
            _writer.Flush();
        }

        static void Value(StringBuilder row, double value) => row.Append(',').Append(value.ToString("0.###", CultureInfo.InvariantCulture));
    }
}
