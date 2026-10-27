using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;

namespace Conduit.Auth;

/// <summary>
/// bcrypt at cost 10 on dedicated threads, so hashing never blocks an HTTP loop. Jobs queue up; a batch of up to
/// <c>BcryptLanes</c> hashes runs interleaved when enough jobs wait or the oldest has waited <c>BcryptWaitMs</c>.
/// Interleaving lets one core work on several independent hashes at once. Nothing is cached between calls.
/// </summary>
public sealed class BcryptService : IDisposable {
    /// <summary>The bcrypt cost factor every new hash uses.</summary>
    public const int Cost = 10;

    /// <summary>The seed data's hash of <c>password123</c> at cost 10, used by the self-test.</summary>
    private const string SeedHash = "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq";

    /// <summary>Cost 5 vectors from the test table in crypt_blowfish's wrapper.c; they cover $2a, $2x, $2y, $2b and 8-bit keys.</summary>
    private static readonly (string Hash, byte[] Key)[] KnownAnswers =
    [
        ("$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW", "U*U"u8.ToArray()),
        ("$2a$05$CCCCCCCCCCCCCCCCCCCCC.VGOzA784oUp/Z0DY336zx7pLYAy0lwK", "U*U*"u8.ToArray()),
        ("$2a$05$XXXXXXXXXXXXXXXXXXXXXOAcXxm9kjPGEMsLznoKqmqw7tc8WCx4a", "U*U*U"u8.ToArray()),
        ("$2x$05$/OK.fbVrR/bpIqNJ5ianF.CE5elHaaO4EbggVDjb8P19RukzXSM3e", [0xff, 0xff, 0xa3]),
        ("$2y$05$/OK.fbVrR/bpIqNJ5ianF.CE5elHaaO4EbggVDjb8P19RukzXSM3e", [0xff, 0xff, 0xa3]),
        ("$2a$05$/OK.fbVrR/bpIqNJ5ianF.nqd1wy.pTMdcvrRWxyiGL2eMz.2a85.", [0xff, 0xff, 0xa3]),
        ("$2b$05$/OK.fbVrR/bpIqNJ5ianF.Sa7shbm4.OzKpvFnX1pQLmQW96oUlCq", [0xa3]),
        ("$2a$05$CCCCCCCCCCCCCCCCCCCCC.7uG0VCzI2bS7j6ymqJi9CdcdxiRTWNy", []),
    ];

    /// <summary>The bcrypt implementation: the native library, or a stand-in in tests.</summary>
    private readonly IBcryptNative _native;
    /// <summary>Millisecond clock for the batching rule.</summary>
    private readonly Func<long> _clockMs;
    /// <summary>Sink for warnings.</summary>
    private readonly Action<string> _log;
    /// <summary>Queue and batching rule. Guarded by <see cref="_lock"/>.</summary>
    private readonly BcryptBatcher _batcher;
    /// <summary>Guards the batcher and <see cref="_stopped"/>; the bcrypt threads wait on it.</summary>
    private readonly object _lock = new();
    /// <summary>The bcrypt worker threads.</summary>
    private readonly Thread[] _threads;
    /// <summary>Set by <see cref="Dispose"/> to end the worker threads.</summary>
    private bool _stopped;

    /// <summary>Creates the service over the native library with the real clock, runs the self-test and starts its threads.</summary>
    /// <exception cref="InvalidOperationException">bcrypt gives wrong answers even on one lane.</exception>
    public BcryptService(Settings settings)
        : this(settings, new NativeBcrypt(), null, null) {
    }

    /// <summary>
    /// Creates the service with an injected native layer, millisecond clock and log sink (the last two optional).
    /// Runs the self-test and starts the threads.
    /// </summary>
    internal BcryptService(Settings settings, IBcryptNative native, Func<long>? clockMs, Action<string>? log) {
        _native = native;
        _log = log ?? Console.Error.WriteLine;
        long start = Stopwatch.GetTimestamp();
        _clockMs = clockMs ?? (() => (long)Stopwatch.GetElapsedTime(start).TotalMilliseconds);

        Lanes = Math.Clamp(settings.BcryptLanes, 1, NativeBcrypt.MaxLanes);
        if (Lanes > 1 && !SelfTestPasses(Lanes)) {
            _log($"bcrypt: self-test failed with {Lanes} lanes, using 1 lane");
            Lanes = 1;
        }
        if (Lanes == 1 && !SelfTestPasses(1)) {
            throw new InvalidOperationException("bcrypt self-test failed with one lane.");
        }

        _batcher = new BcryptBatcher(Lanes, settings.BcryptWaitMs);
        _threads = new Thread[Math.Max(1, settings.BcryptThreads)];
        for (int i = 0; i < _threads.Length; i++) {
            _threads[i] = new Thread(Work) { IsBackground = true, Name = $"bcrypt-{i}" };
            _threads[i].Start();
        }
    }

    /// <summary>Lanes per batch after the self-test: the configured count (at most 8), or 1 if the interleaved path failed.</summary>
    public int Lanes { get; private set; }

    /// <summary>Number of jobs queued and not yet taken by a bcrypt thread.</summary>
    public int QueueLength {
        get {
            lock (_lock) {
                return _batcher.Count;
            }
        }
    }

    /// <summary>
    /// Hashes <paramref name="password"/> with a fresh random 16-byte salt at cost 10. <paramref name="done"/>
    /// receives the 60-character hash on a bcrypt thread. If the native call fails, it receives a text that starts with <c>*</c>.
    /// </summary>
    public void Hash(byte[] password, Action<string> done) {
        string setting = _native.Gensalt(Cost, RandomNumberGenerator.GetBytes(16));
        Enqueue(new BcryptJob { Key = password, Setting = setting, Complete = done });
    }

    /// <summary>
    /// Hashes <paramref name="password"/> with the salt and cost of <paramref name="storedHash"/> and compares it
    /// to the stored hash in constant time. <paramref name="done"/> receives the result on a bcrypt thread. A
    /// malformed stored hash calls it with false at once, on the calling thread.
    /// </summary>
    public void Verify(byte[] password, string storedHash, Action<bool> done) {
        if (storedHash.Length != 60 || !storedHash.StartsWith("$2", StringComparison.Ordinal)) {
            done(false);
            return;
        }
        byte[] stored = Encoding.UTF8.GetBytes(storedHash);
        Enqueue(new BcryptJob {
            Key = password,
            Setting = storedHash[..29],
            Complete = output => done(output.Length == 60
                && CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(output), stored)),
        });
    }

    /// <summary>Stops the threads. Jobs still queued are dropped.</summary>
    public void Dispose() {
        lock (_lock) {
            _stopped = true;
            Monitor.PulseAll(_lock);
        }
        foreach (Thread t in _threads) {
            t.Join();
        }
    }

    /// <summary>Adds a job under the lock and wakes a waiting bcrypt thread.</summary>
    private void Enqueue(BcryptJob job) {
        lock (_lock) {
            _batcher.Add(job, _clockMs());
            Monitor.Pulse(_lock);
        }
    }

    /// <summary>Checks the known answers through the interleaved path with the given lane count.</summary>
    private bool SelfTestPasses(int lanes) {
        try {
            byte[][] keys = new byte[lanes][];
            string[] settings = new string[lanes];
            string[] outputs = new string[lanes];
            string[] expected = new string[lanes];

            // Cost 5 vectors, rotated so every lane position sees different keys.
            for (int shift = 0; shift < KnownAnswers.Length; shift += 3) {
                for (int i = 0; i < lanes; i++) {
                    (string? hash, byte[]? key) = KnownAnswers[(i + shift) % KnownAnswers.Length];
                    keys[i] = key;
                    settings[i] = hash[..29];
                    expected[i] = hash;
                }
                if (!_native.Hash(keys, settings, outputs) || !outputs.AsSpan().SequenceEqual(expected)) {
                    return false;
                }
            }

            // The real cost: the seed's password123 in every lane.
            for (int i = 0; i < lanes; i++) {
                keys[i] = "password123"u8.ToArray();
                settings[i] = SeedHash[..29];
                expected[i] = SeedHash;
            }
            return _native.Hash(keys, settings, outputs) && outputs.AsSpan().SequenceEqual(expected);
        } catch (Exception) when (lanes > 1) {
            return false;
        }
    }

    /// <summary>Body of each bcrypt thread: takes batches and hashes them until disposed.</summary>
    private void Work() {
        List<BcryptJob> batch = new(Lanes);
        byte[][] keys = new byte[Lanes][];
        string[] settings = new string[Lanes];
        string[] outputs = new string[Lanes];

        while (true) {
            lock (_lock) {
                while (!_stopped && !_batcher.TryTake(_clockMs(), batch)) {
                    long wait = _batcher.MsUntilReady(_clockMs());
                    Monitor.Wait(_lock, wait < 0 ? Timeout.Infinite : (int)Math.Max(1, wait));
                }
                if (_stopped) {
                    return;
                }
            }

            int n = batch.Count;
            for (int i = 0; i < n; i++) {
                keys[i] = batch[i].Key;
                settings[i] = batch[i].Setting;
            }
            try {
                _native.Hash(keys.AsSpan(0, n), settings.AsSpan(0, n), outputs.AsSpan(0, n));
            } catch (Exception e) {
                _log($"bcrypt: native call failed: {e.Message}");
                outputs.AsSpan(0, n).Fill("*0");
            }
            for (int i = 0; i < n; i++) {
                try {
                    batch[i].Complete(outputs[i]);
                } catch (Exception e) {
                    _log($"bcrypt: completion callback threw: {e.Message}");
                }
            }
            batch.Clear();
        }
    }
}
