using System;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;

/// <summary>
/// bcrypt (Provos and Mazières; OpenBSD's bcrypt.c) over UTF-8 and ASCII bytes: makes "$2b$" hashes and checks
/// "$2a$", "$2b$", "$2y$" and "$2$" ones. Blowfish is bound by load latency (every round waits for the last round's
/// four S-box loads), so up to <see cref="MaxLanes"/> independent hashes run interleaved on one thread, each filling
/// the others' stalls; every one is still a full bcrypt of its own cost. Nothing here allocates.
/// Taken from codefusion-dotnet's CodeFusion.Security.Bcrypt, cut to bytes in and out.
/// </summary>
static unsafe partial class Bcrypt
{
    public const int MinCost = 4, MaxCost = 31;

    /// <summary>The longest password, in UTF-8 bytes, that bcrypt reads in full. Longer ones are refused, not cut.</summary>
    public const int MaxPasswordBytes = 72;

    /// <summary>"$2b$", the cost, "$", 22 salt characters and 31 hash characters.</summary>
    public const int HashLength = 60;

    const int SaltBytes = 16, HashBytes = 23, HashChars = 31, SaltChars = 22;

    // One lane's state: S-boxes at 0, P at 1024; lane k starts at k * Lane. The offsets are constants, so the JIT
    // folds them into the addressing and every lane shares one base register.
    const int S = 0, P = 1024, Lane = 1048;

    /// <summary>"OrpheanBeholderScryDoubt" as big-endian words.</summary>
    static ReadOnlySpan<uint> Ctext => [0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274];

    static ReadOnlySpan<byte> Alphabet => "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"u8;

    /// <summary>One hash, prepared: the words its key schedule reads, and what its output needs.</summary>
    public struct Input
    {
        public fixed uint Key[18];
        public fixed uint Salt[18];
        public fixed byte SaltBytes[16];
        public int Cost;
        /// <summary>'a', 'b' or 'y'; 0 for the original "$2$", whose key has no terminating NUL.</summary>
        public byte Revision;
    }

    /// <summary>A new "$2b$" hash of <paramref name="password"/> into <paramref name="dest"/> (60 bytes); false when
    /// the password is over 72 bytes.</summary>
    public static bool Hash(ReadOnlySpan<byte> password, int cost, Span<byte> dest)
    {
        Input input;
        if (!PrepareHash(password, cost, &input)) return false;
        uint* ct = stackalloc uint[6];
        Run(&input, 1, ct);
        Format(&input, ct, dest);
        Wipe(&input, 1);
        return true;
    }

    /// <summary>Whether <paramref name="password"/> matches <paramref name="hash"/>. A malformed hash or a password
    /// over 72 bytes never matches.</summary>
    public static bool Verify(ReadOnlySpan<byte> password, ReadOnlySpan<byte> hash)
    {
        Input input;
        if (!PrepareVerify(password, hash, &input)) return false;
        uint* ct = stackalloc uint[6];
        Run(&input, 1, ct);
        Wipe(&input, 1);
        return Matches(ct, hash[^HashChars..]);
    }

    /// <summary>Prepares a new hash with a random salt; false when the password is too long.</summary>
    public static bool PrepareHash(ReadOnlySpan<byte> password, int cost, Input* input)
    {
        if (cost is < MinCost or > MaxCost) throw new ArgumentOutOfRangeException(nameof(cost));
        Span<byte> salt = stackalloc byte[SaltBytes];
        RandomNumberGenerator.Fill(salt);
        return Prepare(password, salt, cost, (byte)'b', input);
    }

    /// <summary>Prepares a check of <paramref name="password"/> against <paramref name="hash"/>; false when the hash
    /// is malformed or the password is too long.</summary>
    public static bool PrepareVerify(ReadOnlySpan<byte> password, ReadOnlySpan<byte> hash, Input* input)
    {
        Span<byte> salt = stackalloc byte[SaltBytes];
        int end = ParseSettings(hash, out byte revision, out int cost, salt);
        return IsWholeHash(hash, end) && Prepare(password, salt, cost, revision, input);
    }

    /// <summary>
    /// Runs <paramref name="n"/> (1 to <see cref="MaxLanes"/>) prepared hashes interleaved on this thread and writes
    /// hash i's six ciphertext words to <paramref name="ct"/>[6i..]. Costs may differ: all lanes run the cheapest
    /// cost's rounds together, then the lanes that need more go on without the finished ones.
    /// </summary>
    public static void Run(Input* inputs, int n, uint* ct)
    {
        if (n is < 1 or > MaxLanes) throw new ArgumentOutOfRangeException(nameof(n));
        // highest cost first, so the lanes still running after a cheaper one finishes are always lanes 0 to m - 1
        int* order = stackalloc int[MaxLanes];
        for (int i = 0; i < n; i++)
        {
            int j = i;
            for (; j > 0 && inputs[order[j - 1]].Cost < inputs[i].Cost; j--) order[j] = order[j - 1];
            order[j] = i;
        }

        uint* st = stackalloc uint[n * Lane];
        uint* wk = stackalloc uint[n * 18];
        uint* ws = stackalloc uint[n * 18];
        for (int k = 0; k < n; k++)
        {
            Input* input = inputs + order[k];
            Unsafe.CopyBlockUnaligned(wk + 18 * k, input->Key, 18 * sizeof(uint));
            Unsafe.CopyBlockUnaligned(ws + 18 * k, input->Salt, 18 * sizeof(uint));
            fixed (uint* s0 = BlowfishConstants.S) Unsafe.CopyBlockUnaligned(st + k * Lane + S, s0, 1024 * sizeof(uint));
            fixed (uint* p0 = BlowfishConstants.P) Unsafe.CopyBlockUnaligned(st + k * Lane + P, p0, 18 * sizeof(uint));
            ExpandState(st + k * Lane, wk + 18 * k, ws + 18 * k);
        }

        try
        {
            long done = 0;
            for (int active = n; active > 0;)
            {
                long target = 1L << inputs[order[active - 1]].Cost;
                ExpandRounds(active, st, wk, ws, target - done);
                done = target;
                while (active > 0 && 1L << inputs[order[active - 1]].Cost == done)
                {
                    active--;
                    uint* c = ct + 6 * order[active];
                    Ctext.CopyTo(new Span<uint>(c, 6));
                    for (int i = 0; i < 64; i++)
                        for (int j = 0; j < 6; j += 2)
                            Encipher(st + active * Lane, ref c[j], ref c[j + 1]);
                }
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(new Span<byte>(st, n * Lane * sizeof(uint)));
            CryptographicOperations.ZeroMemory(new Span<byte>(wk, n * 18 * sizeof(uint)));
            CryptographicOperations.ZeroMemory(new Span<byte>(ws, n * 18 * sizeof(uint)));
        }
    }

    /// <summary>Blowfish_expandstate: the key into P, then P and S derived again while mixing in the salt.</summary>
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

    // native-width indexes let the JIT fold each S-box's offset into the load's address
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    static uint F(uint* st, uint x) =>
        ((st[S + (nuint)(x >> 24)] + st[S + 0x100 + (nuint)(byte)(x >> 16)]) ^ st[S + 0x200 + (nuint)(byte)(x >> 8)]) + st[S + 0x300 + (nuint)(byte)x];

    // each round XORs its P word in first and F's result after, keeping that XOR off the chain every round waits on
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    static void Encipher(uint* st, ref uint xl, ref uint xr)
    {
        uint l = xl ^ st[P], r = xr;
        r ^= st[P + 1]; r ^= F(st, l); l ^= st[P + 2]; l ^= F(st, r);
        r ^= st[P + 3]; r ^= F(st, l); l ^= st[P + 4]; l ^= F(st, r);
        r ^= st[P + 5]; r ^= F(st, l); l ^= st[P + 6]; l ^= F(st, r);
        r ^= st[P + 7]; r ^= F(st, l); l ^= st[P + 8]; l ^= F(st, r);
        r ^= st[P + 9]; r ^= F(st, l); l ^= st[P + 10]; l ^= F(st, r);
        r ^= st[P + 11]; r ^= F(st, l); l ^= st[P + 12]; l ^= F(st, r);
        r ^= st[P + 13]; r ^= F(st, l); l ^= st[P + 14]; l ^= F(st, r);
        r ^= st[P + 15]; r ^= F(st, l); l ^= st[P + 16]; l ^= F(st, r);
        xl = r ^ st[P + 17];
        xr = l;
    }

    /// <summary>
    /// Parses "$2" + revision + "$" + two-digit cost + "$" + 22 salt characters and returns where the salt ends (29,
    /// or 28 for "$2$"); -1 when malformed. "$2x$" (PHP's buggy hashes before 5.3.7) is refused.
    /// </summary>
    public static int ParseSettings(ReadOnlySpan<byte> s, out byte revision, out int cost, Span<byte> salt)
    {
        revision = 0;
        cost = 0;
        if (s.Length < 28 || s[0] != '$' || s[1] != '2') return -1;
        int at = 3;
        if (s[2] != '$')
        {
            revision = s[2];
            if (revision is not ((byte)'a' or (byte)'b' or (byte)'y') || s[3] != '$') return -1;
            at = 4;
        }
        if (s.Length < at + 3 + SaltChars || !char.IsAsciiDigit((char)s[at]) || !char.IsAsciiDigit((char)s[at + 1]) || s[at + 2] != '$') return -1;
        cost = (s[at] - '0') * 10 + (s[at + 1] - '0');
        if (cost is < MinCost or > MaxCost) return -1;
        at += 3;
        if (!Decode(s.Slice(at, SaltChars), salt)) return -1;
        return at + SaltChars;
    }

    /// <summary>
    /// Whether <paramref name="hash"/> (its salt ending at <paramref name="end"/>) is whole as bcrypt writes it: 31
    /// hash characters and no stray bits where the encoding has room to spare. Such a hash could never match, so it
    /// is refused before any hashing.
    /// </summary>
    static bool IsWholeHash(ReadOnlySpan<byte> hash, int end)
    {
        if (end < 0 || hash.Length != end + HashChars || (Index(hash[end - 1]) & 0x0f) != 0 || (Index(hash[^1]) & 0x03) != 0)
            return false;
        for (int i = end; i < hash.Length; i++)
            if (Index(hash[i]) < 0) return false;
        return true;
    }

    static bool Prepare(ReadOnlySpan<byte> password, ReadOnlySpan<byte> salt, int cost, byte revision, Input* input)
    {
        if (password.Length > MaxPasswordBytes) return false;
        // the key: the password's UTF-8 and, except for "$2$", a terminating NUL
        Span<byte> key = stackalloc byte[MaxPasswordBytes + 1];
        password.CopyTo(key);
        int n = password.Length;
        if (revision != 0) key[n++] = 0;
        StreamWords(key[..n], input->Key);
        CryptographicOperations.ZeroMemory(key);
        StreamWords(salt, input->Salt);
        salt.CopyTo(new Span<byte>(input->SaltBytes, SaltBytes));
        input->Cost = cost;
        input->Revision = revision;
        return true;
    }

    /// <summary>The 18 words the key schedule reads, taken cyclically as OpenBSD's Blowfish_stream2word does. An empty
    /// key reads as zero bytes, as C reads the string's terminator.</summary>
    static void StreamWords(ReadOnlySpan<byte> data, uint* words)
    {
        if (data.IsEmpty)
        {
            new Span<uint>(words, 18).Clear();
            return;
        }
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

    /// <summary>Clears prepared inputs: their words come from the password.</summary>
    public static void Wipe(Input* inputs, int n) => CryptographicOperations.ZeroMemory(new Span<byte>(inputs, n * sizeof(Input)));

    static void HashBytesOf(uint* c, Span<byte> hash)
    {
        for (int i = 0; i < HashBytes; i++) hash[i] = (byte)(c[i / 4] >> (24 - 8 * (i % 4)));
    }

    /// <summary>Whether the computed hash equals the stored one's 31 characters, compared in constant time as
    /// encoded text: a stored hash with stray low bits in its last character does not match.</summary>
    public static bool Matches(uint* c, ReadOnlySpan<byte> stored)
    {
        Span<byte> hash = stackalloc byte[HashBytes];
        HashBytesOf(c, hash);
        Span<byte> encoded = stackalloc byte[HashChars];
        Encode(hash, encoded);
        return CryptographicOperations.FixedTimeEquals(encoded, stored);
    }

    /// <summary>The finished hash, "$2b$10$" + salt + hash, as ASCII; returns its length.</summary>
    public static int Format(Input* input, uint* c, Span<byte> s)
    {
        s[0] = (byte)'$';
        s[1] = (byte)'2';
        int at = 2;
        if (input->Revision != 0) s[at++] = input->Revision;
        s[at++] = (byte)'$';
        s[at++] = (byte)('0' + input->Cost / 10);
        s[at++] = (byte)('0' + input->Cost % 10);
        s[at++] = (byte)'$';
        Encode(new ReadOnlySpan<byte>(input->SaltBytes, SaltBytes), s.Slice(at, SaltChars));
        at += SaltChars;
        Span<byte> hash = stackalloc byte[HashBytes];
        HashBytesOf(c, hash);
        Encode(hash, s.Slice(at, HashChars));
        return at + HashChars;
    }

    // ---- bcrypt's base64: its own alphabet, no padding

    static void Encode(ReadOnlySpan<byte> data, Span<byte> output)
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
    static bool Decode(ReadOnlySpan<byte> text, Span<byte> output)
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

    static int Index(byte c) => c switch
    {
        (byte)'.' => 0,
        (byte)'/' => 1,
        >= (byte)'A' and <= (byte)'Z' => c - 'A' + 2,
        >= (byte)'a' and <= (byte)'z' => c - 'a' + 28,
        >= (byte)'0' and <= (byte)'9' => c - '0' + 54,
        _ => -1,
    };
}
