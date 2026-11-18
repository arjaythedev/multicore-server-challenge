using System.Security.Cryptography;
using System.Text;

namespace Conduit.Benchmarks;

/// <summary>
/// Checks the server's own bcrypt against two other implementations: hashes made by BcryptCore, in every grouping of 1 to
/// 8 at once (so every lane kernel runs), must verify under libcrypt and BCrypt.Net-Next, and hashes made by them must
/// verify under ours. Run it with: bash Benchmarks/run.sh --check
/// </summary>
internal static class BcryptCrossCheck
{
    internal static int Run()
    {
        var rng = new Random(2026);
        using var workspace = new BcryptCore.Workspace();
        int checkedCount = 0, failures = 0;

        // 1. our hashes, computed in groups of 1..8 at once, verified by the others
        for (var group = 1; group <= 8; group++)
        {
            var items = Enumerable.Range(0, group).Select(_ => new BcryptItem
            {
                Password = RandomPassword(rng),
                Salt = RandomNumberGenerator.GetBytes(16),
            }).ToArray();
            BcryptCore.Compute(workspace, 10, items);
            foreach (var item in items)
            {
                var hash = Bcrypt.Format('a', item.Salt, item.Output);
                var password = Encoding.UTF8.GetString(item.Password);
                var ok = LibcryptReference.Verify(password, hash) && BCrypt.Net.BCrypt.Verify(password, hash) && Bcrypt.Verify(password, hash);
                var wrong = LibcryptReference.Verify(password + "x", hash) || Bcrypt.Verify(password + "x", hash);
                checkedCount++;
                if (!ok || wrong)
                {
                    failures++;
                    Console.WriteLine($"MISMATCH group of {group}: password of {item.Password.Length} bytes, hash {hash}");
                }
            }
        }

        // 2. their hashes verified by ours
        for (var i = 0; i < 6; i++)
        {
            var password = Encoding.UTF8.GetString(RandomPassword(rng));
            foreach (var hash in new[] { BCrypt.Net.BCrypt.HashPassword(password, 10), LibcryptHash(password) })
            {
                checkedCount++;
                if (!Bcrypt.Verify(password, hash) || Bcrypt.Verify(password + "x", hash))
                {
                    failures++;
                    Console.WriteLine($"MISMATCH verifying someone else's hash {hash}");
                }
            }
        }

        // 3. the pool: many concurrent logins, batched, every result checked
        var pool = new (string Password, string Hash)[24];
        for (var i = 0; i < pool.Length; i++)
        {
            var password = Encoding.UTF8.GetString(RandomPassword(rng));
            pool[i] = (password, LibcryptHash(password));
        }
        var results = pool.Select(p => Bcrypt.VerifyAsync(p.Password, p.Hash).AsTask()).ToArray();
        Task.WaitAll(results);
        var hashed = pool.Select(p => Bcrypt.HashAsync(p.Password).AsTask()).ToArray();
        Task.WaitAll(hashed);
        for (var i = 0; i < pool.Length; i++)
        {
            checkedCount++;
            if (!results[i].Result || hashed[i].Result is not { } made || !LibcryptReference.Verify(pool[i].Password, made))
            {
                failures++;
                Console.WriteLine($"MISMATCH through the worker threads: password {i}");
            }
        }

        Console.WriteLine(failures == 0
            ? $"bcrypt cross-check: all {checkedCount} checks passed (libcrypt, BCrypt.Net-Next and our own agree)"
            : $"bcrypt cross-check: {failures} of {checkedCount} FAILED");
        return failures == 0 ? 0 : 1;
    }

    private static string LibcryptHash(string password)
    {
        LibcryptReference.TryHash(password, out var hash);
        return hash;
    }

    /// <summary>1 to 72 bytes of ASCII, Latin and CJK text (never cut in the middle of a character).</summary>
    private static byte[] RandomPassword(Random rng)
    {
        var target = rng.Next(1, 73);
        var sb = new StringBuilder();
        while (true)
        {
            var c = rng.Next(4) switch { 0 => (char)rng.Next(0x4E00, 0x9FFF), 1 => (char)rng.Next(0xC0, 0x17F), _ => (char)rng.Next(33, 126) };
            if (Encoding.UTF8.GetByteCount(sb.ToString()) + Encoding.UTF8.GetByteCount(c.ToString()) > target) break;
            sb.Append(c);
        }
        if (sb.Length == 0) sb.Append('a');
        return Encoding.UTF8.GetBytes(sb.ToString());
    }
}
