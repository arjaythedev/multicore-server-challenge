using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace Conduit;

/// <summary>
/// bcrypt (Provos and Mazières; OpenBSD's bcrypt.c) producing and checking "$2a$", "$2b$" and "$2y$" hashes.
/// <para>
/// Logins and sign-ups spend most of the app's own CPU here. Blowfish is bound by load latency: every round waits
/// for the previous round's four S-box loads. So up to four independent hashes can run interleaved on one thread
/// (<see cref="Run(ReadOnlySpan{BcryptJob})"/>), each filling the others' stalls: two give nearly twice the hashes
/// per core, four about two and a half to three times.
/// Every hash is still a full bcrypt of its own cost. The state lives on the stack and is read through one base
/// pointer with constant offsets, the 16 Feistel rounds are unrolled, and the key and salt words that every
/// expansion XORs into P are computed once.
/// </para>
/// </summary>
public static unsafe partial class Bcrypt
{
    internal const int SaltBytes = 16;
    internal const int HashBytes = 23; // OpenBSD encodes 23 of the 24 ciphertext bytes
    internal const int MaxKeyBytes = 72;

    // One lane's state: S-boxes at 0, P at 1024; the second lane starts at Lane. Offsets are constants, so the JIT
    // folds them into the addressing and both lanes share one base register.
    const int S = 0, P = 1024, Lane = 1048;

    // "OrpheanBeholderScryDoubt" as big-endian words.
    static ReadOnlySpan<uint> Ctext => [0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274];

    const string Alphabet = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    static readonly sbyte[] AlphabetIndex = BuildIndex();

    /// <summary>A new "$2a$" hash of <paramref name="password"/> (at most 72 UTF-8 bytes) with a random salt.</summary>
    public static string Hash(string password, int cost)
    {
        var job = BcryptJob.ForHash(password, cost) ?? throw new ArgumentException("bcrypt passwords are limited to 72 bytes", nameof(password));
        Run(job);
        return job.Encoded();
    }

    /// <summary>Whether <paramref name="password"/> matches <paramref name="hash"/>; malformed hashes and passwords over 72 bytes never match.</summary>
    public static bool Verify(string password, string hash)
    {
        var job = BcryptJob.ForVerify(password, hash);
        if (job is null) return false;
        Run(job);
        return job.Matches();
    }

    public static void Run(BcryptJob a)
    {
        uint* st = stackalloc uint[Lane];
        Init(st);
        fixed (uint* ka = a.KeyWords, sa = a.SaltWords)
        {
            ExpandState(st, ka, sa);
            for (long n = 1L << a.Cost; n > 0; n--)
            {
                Expand0State(st, ka);
                Expand0State(st, sa);
            }
        }
        uint* c = stackalloc uint[6];
        Ctext.CopyTo(new Span<uint>(c, 6));
        for (int i = 0; i < 64; i++)
            for (int k = 0; k < 6; k += 2)
                Encipher(st, ref c[k], ref c[k + 1]);
        Output(c, a.Hash);
    }

    /// <summary>Two hashes interleaved on this thread. Both finish together, in a little more than one hash's time.</summary>
    public static void Run(BcryptJob a, BcryptJob b)
    {
        if (a.Cost != b.Cost) { Run(a); Run(b); return; }
        uint* st = stackalloc uint[2 * Lane];
        Init(st);
        Init(st + Lane);
        fixed (uint* ka = a.KeyWords, sa = a.SaltWords, kb = b.KeyWords, sb = b.SaltWords)
        {
            ExpandState2(st, ka, sa, kb, sb);
            for (long n = 1L << a.Cost; n > 0; n--)
            {
                Expand0State2(st, ka, kb);
                Expand0State2(st, sa, sb);
            }
        }
        uint* c = stackalloc uint[12];
        Ctext.CopyTo(new Span<uint>(c, 6));
        Ctext.CopyTo(new Span<uint>(c + 6, 6));
        for (int i = 0; i < 64; i++)
            for (int k = 0; k < 6; k += 2)
                Encipher2(st, ref c[k], ref c[k + 1], ref c[6 + k], ref c[7 + k]);
        Output(c, a.Hash);
        Output(c + 6, b.Hash);
    }

    static void Init(uint* st)
    {
        fixed (uint* s0 = BlowfishConstants.S) Unsafe.CopyBlockUnaligned(st + S, s0, 1024 * sizeof(uint));
        fixed (uint* p0 = BlowfishConstants.P) Unsafe.CopyBlockUnaligned(st + P, p0, 18 * sizeof(uint));
    }

    static void Output(uint* c, byte[] hash)
    {
        Span<byte> full = stackalloc byte[24];
        for (int i = 0; i < 6; i++)
        {
            full[4 * i] = (byte)(c[i] >> 24);
            full[4 * i + 1] = (byte)(c[i] >> 16);
            full[4 * i + 2] = (byte)(c[i] >> 8);
            full[4 * i + 3] = (byte)c[i];
        }
        full[..HashBytes].CopyTo(hash);
    }

    // ---------- one lane ----------

    /// <summary>Blowfish_expandstate: key into P, then P and S re-derived while mixing in the salt.</summary>
    static void ExpandState(uint* st, uint* keyWords, uint* saltWords)
    {
        for (int i = 0; i < 18; i++) st[P + i] ^= keyWords[i];
        uint l = 0, r = 0;
        int j = 0; // the 16-byte salt repeats every 4 words
        for (int i = 0; i < 18; i += 2)
        {
            l ^= saltWords[j]; r ^= saltWords[j + 1]; j = (j + 2) & 3;
            Encipher(st, ref l, ref r);
            st[P + i] = l; st[P + i + 1] = r;
        }
        for (int i = 0; i < 1024; i += 2)
        {
            l ^= saltWords[j]; r ^= saltWords[j + 1]; j = (j + 2) & 3;
            Encipher(st, ref l, ref r);
            st[S + i] = l; st[S + i + 1] = r;
        }
    }

    /// <summary>Blowfish_expand0state: the hot loop, 2^cost times for the key and again for the salt.</summary>
    [MethodImpl(MethodImplOptions.AggressiveOptimization)]
    static void Expand0State(uint* st, uint* words)
    {
        for (int i = 0; i < 18; i++) st[P + i] ^= words[i];
        uint l = 0, r = 0;
        for (int i = 0; i < 18; i += 2)
        {
            Encipher(st, ref l, ref r);
            st[P + i] = l; st[P + i + 1] = r;
        }
        for (int i = 0; i < 1024; i += 2)
        {
            Encipher(st, ref l, ref r);
            st[S + i] = l; st[S + i + 1] = r;
        }
    }

    // Native-width indexes: with a 32-bit index the JIT must add each S-box's offset before the load (a 32-bit sum
    // could wrap); with nuint it folds the offset into the load's address, one instruction less per lookup.
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    static uint F(uint* st, uint x) =>
        ((st[S + (nuint)(x >> 24)] + st[S + 0x100 + (nuint)(byte)(x >> 16)]) ^ st[S + 0x200 + (nuint)(byte)(x >> 8)]) + st[S + 0x300 + (nuint)(byte)x];

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    static void Encipher(uint* st, ref uint xl, ref uint xr)
    {
        uint l = xl ^ st[P], r = xr;
        r ^= F(st, l) ^ st[P + 1]; l ^= F(st, r) ^ st[P + 2];
        r ^= F(st, l) ^ st[P + 3]; l ^= F(st, r) ^ st[P + 4];
        r ^= F(st, l) ^ st[P + 5]; l ^= F(st, r) ^ st[P + 6];
        r ^= F(st, l) ^ st[P + 7]; l ^= F(st, r) ^ st[P + 8];
        r ^= F(st, l) ^ st[P + 9]; l ^= F(st, r) ^ st[P + 10];
        r ^= F(st, l) ^ st[P + 11]; l ^= F(st, r) ^ st[P + 12];
        r ^= F(st, l) ^ st[P + 13]; l ^= F(st, r) ^ st[P + 14];
        r ^= F(st, l) ^ st[P + 15]; l ^= F(st, r) ^ st[P + 16];
        xl = r ^ st[P + 17];
        xr = l;
    }

    // ---------- two lanes, interleaved round by round ----------

    static void ExpandState2(uint* st, uint* ka, uint* sa, uint* kb, uint* sb)
    {
        for (int i = 0; i < 18; i++) { st[P + i] ^= ka[i]; st[Lane + P + i] ^= kb[i]; }
        uint l1 = 0, r1 = 0, l2 = 0, r2 = 0;
        int j = 0;
        for (int i = 0; i < 18; i += 2)
        {
            l1 ^= sa[j]; r1 ^= sa[j + 1]; l2 ^= sb[j]; r2 ^= sb[j + 1]; j = (j + 2) & 3;
            Encipher2(st, ref l1, ref r1, ref l2, ref r2);
            st[P + i] = l1; st[P + i + 1] = r1; st[Lane + P + i] = l2; st[Lane + P + i + 1] = r2;
        }
        for (int i = 0; i < 1024; i += 2)
        {
            l1 ^= sa[j]; r1 ^= sa[j + 1]; l2 ^= sb[j]; r2 ^= sb[j + 1]; j = (j + 2) & 3;
            Encipher2(st, ref l1, ref r1, ref l2, ref r2);
            st[S + i] = l1; st[S + i + 1] = r1; st[Lane + S + i] = l2; st[Lane + S + i + 1] = r2;
        }
    }

    [MethodImpl(MethodImplOptions.AggressiveOptimization)]
    static void Expand0State2(uint* st, uint* wa, uint* wb)
    {
        for (int i = 0; i < 18; i++) { st[P + i] ^= wa[i]; st[Lane + P + i] ^= wb[i]; }
        uint l1 = 0, r1 = 0, l2 = 0, r2 = 0;
        for (int i = 0; i < 18; i += 2)
        {
            Encipher2(st, ref l1, ref r1, ref l2, ref r2);
            st[P + i] = l1; st[P + i + 1] = r1; st[Lane + P + i] = l2; st[Lane + P + i + 1] = r2;
        }
        for (int i = 0; i < 1024; i += 2)
        {
            Encipher2(st, ref l1, ref r1, ref l2, ref r2);
            st[S + i] = l1; st[S + i + 1] = r1; st[Lane + S + i] = l2; st[Lane + S + i + 1] = r2;
        }
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    static uint F2(uint* st, uint x) =>
        ((st[Lane + S + (nuint)(x >> 24)] + st[Lane + S + 0x100 + (nuint)(byte)(x >> 16)]) ^ st[Lane + S + 0x200 + (nuint)(byte)(x >> 8)])
        + st[Lane + S + 0x300 + (nuint)(byte)x];

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    static void Encipher2(uint* st, ref uint xl1, ref uint xr1, ref uint xl2, ref uint xr2)
    {
        const int Q = Lane + P;
        uint l1 = xl1 ^ st[P], r1 = xr1, l2 = xl2 ^ st[Q], r2 = xr2;
        r1 ^= F(st, l1) ^ st[P + 1]; r2 ^= F2(st, l2) ^ st[Q + 1]; l1 ^= F(st, r1) ^ st[P + 2]; l2 ^= F2(st, r2) ^ st[Q + 2];
        r1 ^= F(st, l1) ^ st[P + 3]; r2 ^= F2(st, l2) ^ st[Q + 3]; l1 ^= F(st, r1) ^ st[P + 4]; l2 ^= F2(st, r2) ^ st[Q + 4];
        r1 ^= F(st, l1) ^ st[P + 5]; r2 ^= F2(st, l2) ^ st[Q + 5]; l1 ^= F(st, r1) ^ st[P + 6]; l2 ^= F2(st, r2) ^ st[Q + 6];
        r1 ^= F(st, l1) ^ st[P + 7]; r2 ^= F2(st, l2) ^ st[Q + 7]; l1 ^= F(st, r1) ^ st[P + 8]; l2 ^= F2(st, r2) ^ st[Q + 8];
        r1 ^= F(st, l1) ^ st[P + 9]; r2 ^= F2(st, l2) ^ st[Q + 9]; l1 ^= F(st, r1) ^ st[P + 10]; l2 ^= F2(st, r2) ^ st[Q + 10];
        r1 ^= F(st, l1) ^ st[P + 11]; r2 ^= F2(st, l2) ^ st[Q + 11]; l1 ^= F(st, r1) ^ st[P + 12]; l2 ^= F2(st, r2) ^ st[Q + 12];
        r1 ^= F(st, l1) ^ st[P + 13]; r2 ^= F2(st, l2) ^ st[Q + 13]; l1 ^= F(st, r1) ^ st[P + 14]; l2 ^= F2(st, r2) ^ st[Q + 14];
        r1 ^= F(st, l1) ^ st[P + 15]; r2 ^= F2(st, l2) ^ st[Q + 15]; l1 ^= F(st, r1) ^ st[P + 16]; l2 ^= F2(st, r2) ^ st[Q + 16];
        xl1 = r1 ^ st[P + 17]; xr1 = l1;
        xl2 = r2 ^ st[Q + 17]; xr2 = l2;
    }

    // ---------- bcrypt's base64: its own alphabet, no padding ----------

    internal static void Encode(ReadOnlySpan<byte> data, Span<char> output)
    {
        int o = 0, i = 0;
        while (i < data.Length)
        {
            int c1 = data[i++];
            output[o++] = Alphabet[c1 >> 2];
            c1 = (c1 & 0x03) << 4;
            if (i >= data.Length) { output[o++] = Alphabet[c1]; break; }
            int c2 = data[i++];
            output[o++] = Alphabet[c1 | c2 >> 4];
            c1 = (c2 & 0x0f) << 2;
            if (i >= data.Length) { output[o++] = Alphabet[c1]; break; }
            c2 = data[i++];
            output[o++] = Alphabet[c1 | c2 >> 6];
            output[o++] = Alphabet[c2 & 0x3f];
        }
    }

    /// <summary>Decodes exactly output.Length bytes; false on a character outside the alphabet.</summary>
    internal static bool Decode(ReadOnlySpan<char> text, Span<byte> output)
    {
        int o = 0, i = 0;
        while (o < output.Length)
        {
            if (i + 1 >= text.Length) return false;
            int c1 = Index(text[i++]), c2 = Index(text[i++]);
            if ((c1 | c2) < 0) return false;
            output[o++] = (byte)(c1 << 2 | (c2 & 0x30) >> 4);
            if (o == output.Length) break;
            if (i >= text.Length) return false;
            int c3 = Index(text[i++]);
            if (c3 < 0) return false;
            output[o++] = (byte)((c2 & 0x0f) << 4 | (c3 & 0x3c) >> 2);
            if (o == output.Length) break;
            if (i >= text.Length) return false;
            int c4 = Index(text[i++]);
            if (c4 < 0) return false;
            output[o++] = (byte)((c3 & 0x03) << 6 | c4);
        }
        return true;
    }

    static int Index(char c) => c < 128 ? AlphabetIndex[c] : -1;

    static sbyte[] BuildIndex()
    {
        var index = new sbyte[128];
        index.AsSpan().Fill(-1);
        for (int i = 0; i < Alphabet.Length; i++) index[Alphabet[i]] = (sbyte)i;
        return index;
    }
}

/// <summary>One bcrypt computation: a new hash (random salt) or a check against a stored hash.</summary>
public sealed class BcryptJob
{
    internal readonly uint[] KeyWords = new uint[18];
    internal readonly uint[] SaltWords = new uint[18];
    internal readonly byte[] Hash = new byte[Bcrypt.HashBytes];
    internal readonly int Cost;
    readonly byte[] _salt;
    readonly string? _stored; // Verify: the stored hash

    BcryptJob(ReadOnlySpan<byte> key, byte[] salt, int cost, string? stored)
    {
        _salt = salt;
        Cost = cost;
        _stored = stored;
        StreamWords(key, KeyWords);
        StreamWords(salt, SaltWords);
    }

    /// <summary>A job hashing <paramref name="password"/> with a random salt; null when the password exceeds 72 bytes.</summary>
    public static BcryptJob? ForHash(string password, int cost, byte[]? salt = null)
    {
        if (cost is < 4 or > 31) throw new ArgumentOutOfRangeException(nameof(cost));
        Span<byte> key = stackalloc byte[Bcrypt.MaxKeyBytes + 1];
        int keyLen = Key(password, key);
        if (keyLen < 0) return null;
        if (salt is null) RandomNumberGenerator.Fill(salt = new byte[Bcrypt.SaltBytes]);
        else if (salt.Length != Bcrypt.SaltBytes) throw new ArgumentException("bcrypt salts are 16 bytes", nameof(salt));
        return new BcryptJob(key[..keyLen], salt, cost, null);
    }

    /// <summary>A job checking <paramref name="password"/> against <paramref name="hash"/>; null when the hash is malformed or the password exceeds 72 bytes.</summary>
    public static BcryptJob? ForVerify(string password, string hash)
    {
        // $2a$10$ + 22 salt chars + 31 hash chars
        if (hash.Length != 60 || hash[0] != '$' || hash[1] != '2' || hash[2] is not ('a' or 'b' or 'y') || hash[3] != '$'
            || hash[6] != '$' || !char.IsAsciiDigit(hash[4]) || !char.IsAsciiDigit(hash[5]))
            return null;
        int cost = (hash[4] - '0') * 10 + (hash[5] - '0');
        if (cost is < 4 or > 31) return null;
        var salt = new byte[Bcrypt.SaltBytes];
        if (!Bcrypt.Decode(hash.AsSpan(7, 22), salt)) return null;
        Span<byte> key = stackalloc byte[Bcrypt.MaxKeyBytes + 1];
        int keyLen = Key(password, key);
        if (keyLen < 0) return null;
        return new BcryptJob(key[..keyLen], salt, cost, hash);
    }

    /// <summary>The computed hash as "$2a$NN$" + salt + hash.</summary>
    public string Encoded() => string.Create(60, this, static (s, job) =>
    {
        "$2a$".CopyTo(s);
        s[4] = (char)('0' + job.Cost / 10);
        s[5] = (char)('0' + job.Cost % 10);
        s[6] = '$';
        Bcrypt.Encode(job._salt, s.Slice(7, 22));
        Bcrypt.Encode(job.Hash, s.Slice(29, 31));
    });

    /// <summary>
    /// Whether the computed hash equals the stored one, compared in constant time as encoded text (as Go's bcrypt
    /// does: a stored hash with stray low bits in its last character does not match).
    /// </summary>
    public bool Matches()
    {
        if (_stored is null) return false;
        Span<char> encoded = stackalloc char[31];
        Bcrypt.Encode(Hash, encoded);
        return CryptographicOperations.FixedTimeEquals(MemoryMarshal.AsBytes(encoded), MemoryMarshal.AsBytes(_stored.AsSpan(29, 31)));
    }

    /// <summary>The key bytes: the UTF-8 password and its terminating NUL. -1 when the password exceeds 72 bytes.</summary>
    static int Key(string password, Span<byte> key)
    {
        if (Encoding.UTF8.GetByteCount(password) > Bcrypt.MaxKeyBytes) return -1;
        int n = Encoding.UTF8.GetBytes(password, key);
        key[n] = 0;
        return n + 1;
    }

    /// <summary>
    /// The 18 words the key schedule reads from <paramref name="data"/>, taken cyclically as OpenBSD's
    /// Blowfish_stream2word does. Each expansion restarts the stream, so the same words recur every time.
    /// </summary>
    static void StreamWords(ReadOnlySpan<byte> data, uint[] words)
    {
        int j = 0;
        for (int i = 0; i < 18; i++)
        {
            uint w = 0;
            for (int k = 0; k < 4; k++)
            {
                w = w << 8 | data[j];
                if (++j == data.Length) j = 0;
            }
            words[i] = w;
        }
    }
}
