using System;
using System.Security.Cryptography;

namespace CodeFusion.Security;

/// <summary>
/// bcrypt (Provos and Mazières; OpenBSD's bcrypt.c): makes "$2b$" hashes and checks "$2a$", "$2b$", "$2y$" and
/// "$2$" ones. Hashing allocates only the returned string, checking allocates nothing.
/// <para>
/// bcrypt reads at most 72 bytes of a password. Longer passwords are refused rather than silently cut:
/// <see cref="Hash(string, int)"/> throws and <see cref="Verify(string, string)"/> returns false.
/// </para>
/// <para>
/// To hash many passwords at once, for example on a server's sign-in path, use <see cref="BcryptQueue"/>: it runs up
/// to five hashes interleaved on one thread, each for about a quarter of the CPU time of one hash alone.
/// </para>
/// </summary>
public static unsafe partial class Bcrypt
{
    /// <summary>The lowest cost (log2 of the rounds) accepted.</summary>
    public const int MinCost = 4;

    /// <summary>The highest cost accepted.</summary>
    public const int MaxCost = 31;

    /// <summary>The longest password, in UTF-8 bytes, that bcrypt reads in full.</summary>
    public const int MaxPasswordBytes = 72;

    /// <summary>The length of a hash this library makes, in characters or ASCII bytes: "$2b$", the cost, "$", 22 salt
    /// characters and 31 hash characters.</summary>
    public const int HashLength = 60;

    /// <summary>A new "$2b$" hash of <paramref name="password"/> with a random salt.</summary>
    /// <exception cref="ArgumentException">The password is over 72 UTF-8 bytes or isn't valid UTF-16.</exception>
    /// <exception cref="ArgumentOutOfRangeException"><paramref name="cost"/> is outside 4 to 31.</exception>
    public static string Hash(string password, int cost)
    {
        ArgumentNullException.ThrowIfNull(password);
        CheckCost(cost);
        Span<byte> salt = stackalloc byte[SaltBytes];
        RandomNumberGenerator.Fill(salt);
        Input input;
        if (!Prepare(password, salt, cost, 'b', &input)) throw new ArgumentException(RefusalOf(password), nameof(password));
        uint* ct = stackalloc uint[6];
        Run(&input, 1, ct);
        string hash = Format(&input, ct);
        Wipe(&input, 1);
        return hash;
    }

    /// <summary>Whether <paramref name="password"/> matches <paramref name="hash"/>. A malformed hash, or a password
    /// over 72 UTF-8 bytes or not valid UTF-16, never matches. Never throws for any non-null input.</summary>
    public static bool Verify(string password, string hash)
    {
        ArgumentNullException.ThrowIfNull(password);
        ArgumentNullException.ThrowIfNull(hash);
        Input input;
        if (!PrepareVerify(password, hash, &input)) return false;
        uint* ct = stackalloc uint[6];
        Run(&input, 1, ct);
        Wipe(&input, 1);
        return Matches(ct, hash.AsSpan(hash.Length - HashChars));
    }

    /// <summary>
    /// Checks <c>passwords[i]</c> against <c>hashes[i]</c> into <c>results[i]</c>, up to five at a time interleaved on
    /// this thread: five checks take 1.3 to 2 times as long as one, depending on the CPU.
    /// </summary>
    /// <exception cref="ArgumentException">The spans' lengths differ.</exception>
    public static void Verify(ReadOnlySpan<string> passwords, ReadOnlySpan<string> hashes, Span<bool> results)
    {
        if (hashes.Length != passwords.Length || results.Length != passwords.Length)
            throw new ArgumentException("passwords, hashes and results must have the same length", nameof(results));
        for (int i = 0; i < passwords.Length; i++)
        {
            ArgumentNullException.ThrowIfNull(passwords[i], nameof(passwords));
            ArgumentNullException.ThrowIfNull(hashes[i], nameof(hashes));
        }
        Input* inputs = stackalloc Input[MaxLanes];
        int* index = stackalloc int[MaxLanes];
        uint* ct = stackalloc uint[6 * MaxLanes];
        int n = 0;
        for (int i = 0; i < passwords.Length; i++)
        {
            results[i] = false;
            if (PrepareVerify(passwords[i], hashes[i], inputs + n)) index[n++] = i;
            if (n == MaxLanes || (i == passwords.Length - 1 && n > 0))
            {
                Run(inputs, n, ct);
                for (int k = 0; k < n; k++)
                {
                    string hash = hashes[index[k]];
                    results[index[k]] = Matches(ct + 6 * k, hash.AsSpan(hash.Length - HashChars));
                }
                n = 0;
            }
        }
        Wipe(inputs, MaxLanes);
    }

    /// <summary>The parts of <paramref name="hash"/>.</summary>
    /// <exception cref="FormatException">The hash is malformed.</exception>
    public static BcryptHashInfo InterrogateHash(string hash)
    {
        ArgumentNullException.ThrowIfNull(hash);
        Span<byte> salt = stackalloc byte[SaltBytes];
        int end = ParseSettings(hash, out char revision, out int cost, salt);
        if (!IsWholeHash(hash, end)) throw new FormatException("not a bcrypt hash");
        return new BcryptHashInfo(revision == '\0' ? "2" : "2" + revision, cost, hash.Substring(end - SaltChars, SaltChars), hash[end..]);
    }

    internal static void CheckCost(int cost)
    {
        if (cost is < MinCost or > MaxCost) throw new ArgumentOutOfRangeException(nameof(cost), cost, "the cost must be 4 to 31");
    }
}
