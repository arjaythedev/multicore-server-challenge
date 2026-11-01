using System.Security.Cryptography;
using System.Text;

namespace Conduit;

/// <summary>
/// bcrypt at cost 10: the "$2a$10$..." hash format, and passwords in and out. The algorithm is BcryptCore (our own
/// EksBlowfish, which runs several hashes at once); BcryptPool runs it on dedicated threads and batches waiting hashes.
/// A password over bcrypt's 72 bytes, or with a NUL character in it, is refused rather than silently cut short.
/// The hashes are the same as any bcrypt library makes (checked against libcrypt, BCrypt.Net and Go: see Benchmarks/).
/// Settings (environment): BCRYPT_THREADS (default: half the cores, at least 1) and BCRYPT_BATCH_MS (default 100).
/// </summary>
internal static class Bcrypt
{
    private const int Cost = 10;
    private const int MaxPasswordBytes = 72;
    private const int HashLength = 60;
    private const string Alphabet = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

    private static readonly BcryptPool Pool = new(
        Cost,
        EnvInt("BCRYPT_THREADS", Math.Max(1, Environment.ProcessorCount / 2)),
        EnvInt("BCRYPT_BATCH_MS", 100));

    private static int EnvInt(string name, int fallback) =>
        int.TryParse(Environment.GetEnvironmentVariable(name), out var v) && v >= 0 ? v : fallback;

    /// <summary>Hashes a password with a fresh random salt. Null for a password bcrypt cannot take (see the class summary).</summary>
    internal static async ValueTask<string?> HashAsync(string password)
    {
        if (!TryEncode(password, out var bytes)) return null;
        var job = new BcryptPool.Job(bytes, RandomNumberGenerator.GetBytes(16));
        await Pool.Run(job);
        return Format('a', job.Salt, job.Output);
    }

    /// <summary>True if the password matches the stored bcrypt hash.</summary>
    internal static async ValueTask<bool> VerifyAsync(string password, string hash)
    {
        if (!IsAcceptableHash(hash) || !TryEncode(password, out var bytes) || !TryDecodeSalt(hash.AsSpan(7, 22), out var salt))
            return false;
        var job = new BcryptPool.Job(bytes, salt);
        await Pool.Run(job);
        return Matches(hash, job);
    }

    /// <summary>The same, on the calling thread, one hash at a time: for the start-up self-test, tests and benchmarks.</summary>
    internal static bool TryHash(string password, out string hash)
    {
        hash = "";
        if (!TryEncode(password, out var bytes)) return false;
        var item = new BcryptItem { Password = bytes, Salt = RandomNumberGenerator.GetBytes(16) };
        using var workspace = new BcryptCore.Workspace();
        BcryptCore.Compute(workspace, Cost, [item]);
        hash = Format('a', item.Salt, item.Output);
        return true;
    }

    internal static bool Verify(string password, string hash)
    {
        if (!IsAcceptableHash(hash) || !TryEncode(password, out var bytes) || !TryDecodeSalt(hash.AsSpan(7, 22), out var salt))
            return false;
        var item = new BcryptItem { Password = bytes, Salt = salt };
        using var workspace = new BcryptCore.Workspace();
        BcryptCore.Compute(workspace, Cost, [item]);
        return Matches(hash, item);
    }

    // ---------- validation ----------

    /// <summary>The password as UTF-8 bytes. False if it is over 72 bytes or contains a NUL character.</summary>
    private static bool TryEncode(string password, out byte[] bytes)
    {
        bytes = [];
        if (Encoding.UTF8.GetByteCount(password) > MaxPasswordBytes || password.Contains('\0')) return false;
        bytes = Encoding.UTF8.GetBytes(password);
        return true;
    }

    /// <summary>
    /// A stored hash we will verify against: 60 characters, "$2a$", "$2b$" or "$2y$" (identical for valid UTF-8 passwords)
    /// and our cost, 10. Anything else cannot be one of ours, and a hash with a high cost would make us spend seconds
    /// or minutes of CPU on one login.
    /// </summary>
    private static bool IsAcceptableHash(string hash) =>
        hash.Length == HashLength
        && hash[0] == '$' && hash[1] == '2' && hash[2] is 'a' or 'b' or 'y' && hash[3] == '$'
        && hash[4] == '1' && hash[5] == '0' && hash[6] == '$'
        && Encoding.UTF8.GetByteCount(hash) == HashLength; // ASCII only

    // ---------- the hash string ----------

    /// <summary>"$2a$10$" + the salt in 22 characters + the first 23 bytes of the result in 31.</summary>
    internal static string Format(char version, byte[] salt, byte[] output) =>
        string.Create(HashLength, (version, salt, output), static (span, s) =>
        {
            "$2".CopyTo(span);
            span[2] = s.version;
            "$10$".CopyTo(span[3..]);
            Encode(s.salt, 16, span.Slice(7, 22));
            Encode(s.output, 23, span.Slice(29, 31));
        });

    /// <summary>The stored hash, recomputed with its own version, cost and salt, must equal it character for character.</summary>
    private static bool Matches(string stored, BcryptItem item)
    {
        Span<char> expected = stackalloc char[HashLength];
        Span<byte> a = stackalloc byte[HashLength];
        Span<byte> b = stackalloc byte[HashLength];
        stored.AsSpan(0, 7).CopyTo(expected); // "$2a$10$": the version and cost are the stored hash's own
        expected[2] = stored[2];
        Encode(item.Salt, 16, expected.Slice(7, 22));
        Encode(item.Output, 23, expected.Slice(29, 31));
        Encoding.ASCII.GetBytes(expected, a);
        Encoding.ASCII.GetBytes(stored, b);
        return CryptographicOperations.FixedTimeEquals(a, b);
    }

    /// <summary>bcrypt's base 64 (its own alphabet, no padding).</summary>
    private static void Encode(ReadOnlySpan<byte> data, int length, Span<char> dest)
    {
        int p = 0, o = 0;
        while (p < length)
        {
            int c1 = data[p++];
            dest[o++] = Alphabet[c1 >> 2];
            c1 = (c1 & 3) << 4;
            if (p >= length) { dest[o++] = Alphabet[c1]; break; }
            int c2 = data[p++];
            c1 |= c2 >> 4;
            dest[o++] = Alphabet[c1];
            c1 = (c2 & 0x0F) << 2;
            if (p >= length) { dest[o++] = Alphabet[c1]; break; }
            c2 = data[p++];
            c1 |= c2 >> 6;
            dest[o++] = Alphabet[c1];
            dest[o++] = Alphabet[c2 & 0x3F];
        }
    }

    /// <summary>The 16 salt bytes from the 22 characters of a stored hash; false if a character is not in the alphabet.</summary>
    private static bool TryDecodeSalt(ReadOnlySpan<char> chars, out byte[] salt)
    {
        salt = new byte[16];
        Span<int> v = stackalloc int[22];
        for (var i = 0; i < 22; i++)
            if ((v[i] = Alphabet.IndexOf(chars[i])) < 0) return false;
        int p = 0, c = 0;
        while (p < 16)
        {
            salt[p++] = (byte)((v[c] << 2) | ((v[c + 1] & 0x30) >> 4));
            if (p >= 16) break;
            salt[p++] = (byte)(((v[c + 1] & 0x0F) << 4) | ((v[c + 2] & 0x3C) >> 2));
            if (p >= 16) break;
            salt[p++] = (byte)(((v[c + 2] & 0x03) << 6) | v[c + 3]);
            c += 4;
        }
        return true;
    }

    // ---------- start-up check ----------

    // Known answers: the first four are from the crypt_blowfish test suite, the last is the seed's hash of "password123".
    // Go's bcrypt and libcrypt both accept every one of them.
    private static readonly (string Password, string Hash)[] KnownAnswers =
    [
        ("U*U", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW"),
        ("U*U*", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.VGOzA784oUp/Z0DY336zx7pLYAy0lwK"),
        ("U*U*U", "$2a$05$XXXXXXXXXXXXXXXXXXXXXOAcXxm9kjPGEMsLznoKqmqw7tc8WCx4a"),
        ("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", "$2a$05$abcdefghijklmnopqrstuu5s2v8.iXieOjg/.AySBTTZIIVFJeBui"),
        ("pässword-ü-日本", "$2a$05$kP4qMEv9Q0pIRN6Fh7xRZ.kyXMmjpfZI61Phl0h89bLIQBMddUJqq"),
        ("a", "$2a$05$kP4qMEv9Q0pIRN6Fh7xRZ.EeeqOJRhZpx6Nhhl6hr/ify5B6mcJva"),
        ("password123", "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq"),
    ];

    /// <summary>
    /// Runs the known answers through every lane count (1 to MaxLanes hashes at once), then the seed's hash on all lanes
    /// at cost 10 and through the worker threads. Throws if anything is off, so a wrong build fails at launch, not on a login.
    /// </summary>
    internal static void SelfTest()
    {
        using var workspace = new BcryptCore.Workspace();
        var cost5 = KnownAnswers[..^1]; // the quick ones (cost 5)
        for (var lanes = 1; lanes <= BcryptCore.MaxLanes; lanes++)
        {
            var items = new BcryptItem[lanes];
            var expected = new string[lanes];
            for (var k = 0; k < lanes; k++)
            {
                (var password, expected[k]) = cost5[(k + lanes) % cost5.Length];
                items[k] = ItemFor(password, expected[k]);
            }
            BcryptCore.Compute(workspace, 5, items);
            for (var k = 0; k < lanes; k++)
                if (!Matches(expected[k], items[k]))
                    throw new InvalidOperationException($"bcrypt self-test failed: {lanes} hashes at once, lane {k}");
        }

        // The seed's own hash, at cost 10, on every lane at once.
        var (seedPassword, seedHash) = KnownAnswers[^1];
        var seeds = Enumerable.Range(0, BcryptCore.MaxLanes).Select(_ => ItemFor(seedPassword, seedHash)).ToArray();
        BcryptCore.Compute(workspace, Cost, seeds);
        if (!seeds.All(item => Matches(seedHash, item)))
            throw new InvalidOperationException("bcrypt self-test failed: the seed's hash, all lanes at cost 10");

        if (!TryHash("self-test", out var round) || !Verify("self-test", round) || Verify("self-tesT", round))
            throw new InvalidOperationException("bcrypt self-test failed: hash/verify round trip");
        if (!VerifyAsync(seedPassword, seedHash).AsTask().GetAwaiter().GetResult())
            throw new InvalidOperationException("bcrypt self-test failed: the worker threads do not verify the seed's hash");
    }

    private static BcryptItem ItemFor(string password, string hash)
    {
        if (!TryEncode(password, out var bytes) || !TryDecodeSalt(hash.AsSpan(7, 22), out var salt))
            throw new InvalidOperationException("bcrypt self-test: bad known answer");
        return new BcryptItem { Password = bytes, Salt = salt };
    }
}
