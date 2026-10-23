using System;
using System.Buffers;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Unicode;

namespace CodeFusion.Security;

// The computation shared by every entry point. Blowfish is bound by load latency: every round waits for the previous
// round's four S-box loads. So up to MaxLanes independent hashes run interleaved on one thread (Run), each filling
// the others' stalls. Every hash is still a full bcrypt of its own cost. The state lives on the stack and is read
// through one base pointer with constant offsets, and the key and salt words that every expansion XORs into P are
// computed once. Nothing here allocates.
public static unsafe partial class Bcrypt
{
    internal const int SaltBytes = 16;
    internal const int HashBytes = 23; // OpenBSD encodes 23 of the 24 ciphertext bytes
    internal const int HashChars = 31;
    const int SaltChars = 22;

    // One lane's state: S-boxes at 0, P at 1024; lane k starts at k * Lane. Offsets are constants, so the JIT folds
    // them into the addressing and every lane shares one base register.
    const int S = 0, P = 1024, Lane = 1048;

    // "OrpheanBeholderScryDoubt" as big-endian words.
    static ReadOnlySpan<uint> Ctext => [0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274];

    const string Alphabet = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    static readonly sbyte[] AlphabetIndex = BuildIndex();

    /// <summary>One hash, prepared: the words its key schedule reads, and what its output needs.</summary>
    internal struct Input
    {
        public fixed uint Key[18];
        public fixed uint Salt[18];
        public fixed byte SaltBytes[16];
        public int Cost;
        /// <summary>'a', 'b' or 'y'; '\0' for the original "$2$", whose key has no terminating NUL.</summary>
        public char Revision;
    }

    /// <summary>Told as each hash of a run finishes, so a caller with a cheap hash needn't wait for a costlier one.</summary>
    internal interface IFinished
    {
        /// <summary>Hash <paramref name="index"/>'s ciphertext is in ct[6 * index..].</summary>
        void Finished(int index);
    }

    struct Ignore : IFinished
    {
        public readonly void Finished(int index) { }
    }

    /// <summary>
    /// Runs <paramref name="n"/> (1 to <see cref="MaxLanes"/>) prepared hashes interleaved on this thread and writes
    /// hash i's six ciphertext words to <paramref name="ct"/>[6i..]. Costs may differ: all lanes run the cheapest
    /// cost's rounds together, then the lanes that need more continue without the finished ones.
    /// </summary>
    internal static void Run(Input* inputs, int n, uint* ct)
    {
        var ignore = default(Ignore);
        Run(inputs, n, ct, ref ignore);
    }

    /// <summary><see cref="Run(Input*, int, uint*)"/>, telling <paramref name="finished"/> as each hash completes.</summary>
    internal static void Run<T>(Input* inputs, int n, uint* ct, ref T finished) where T : struct, IFinished
    {
        if (n is < 1 or > MaxLanes) throw new ArgumentOutOfRangeException(nameof(n));
        // Highest cost first, so the lanes still running after a cheaper one finishes are always lanes 0 to m - 1.
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
            Init(st + k * Lane);
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
                // The lanes that are done: the loop no longer touches them, so they finish now.
                while (active > 0 && 1L << inputs[order[active - 1]].Cost == done)
                {
                    active--;
                    uint* c = ct + 6 * order[active];
                    Ctext.CopyTo(new Span<uint>(c, 6));
                    for (int i = 0; i < 64; i++)
                        for (int j = 0; j < 6; j += 2)
                            Encipher(st + active * Lane, ref c[j], ref c[j + 1]);
                    finished.Finished(order[active]);
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

    static void Init(uint* st)
    {
        fixed (uint* s0 = BlowfishConstants.S) Unsafe.CopyBlockUnaligned(st + S, s0, 1024 * sizeof(uint));
        fixed (uint* p0 = BlowfishConstants.P) Unsafe.CopyBlockUnaligned(st + P, p0, 18 * sizeof(uint));
    }

    /// <summary>Blowfish_expandstate: key into P, then P and S re-derived while mixing in the salt. Once per hash.</summary>
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

    // Native-width indexes: with a 32-bit index the JIT must add each S-box's offset before the load (a 32-bit sum
    // could wrap); with nuint it folds the offset into the load's address, one instruction less per lookup.
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    static uint F(uint* st, uint x) =>
        ((st[S + (nuint)(x >> 24)] + st[S + 0x100 + (nuint)(byte)(x >> 16)]) ^ st[S + 0x200 + (nuint)(byte)(x >> 8)]) + st[S + 0x300 + (nuint)(byte)x];

    // Each round XORs its P word into the half first and F's result after: "r ^= F(l) ^ P[n]" would put that XOR
    // on the chain every round waits for, after the S-box loads. On x86 and arm64 that made a hash 6 to 10% faster.
    // The hot loop is Bcrypt.Lanes.g.cs, which LanesGenerator writes at compile time; this one runs the setup and the
    // final 64 encryptions.
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

    // ---------- preparing a hash ----------

    /// <summary>
    /// Parses "$2" + revision + "$" + two-digit cost + "$" + 22 salt characters, and returns where the salt ends
    /// (29, or 28 for "$2$"); -1 when malformed. "$2x$" (PHP's buggy hashes before 5.3.7) is refused.
    /// </summary>
    internal static int ParseSettings(ReadOnlySpan<char> s, out char revision, out int cost, Span<byte> salt)
    {
        revision = '\0';
        cost = 0;
        if (s.Length < 28 || s[0] != '$' || s[1] != '2') return -1;
        int at = 3;
        if (s[2] != '$')
        {
            revision = s[2];
            if (revision is not ('a' or 'b' or 'y') || s[3] != '$') return -1;
            at = 4;
        }
        if (s.Length < at + 3 + SaltChars || !char.IsAsciiDigit(s[at]) || !char.IsAsciiDigit(s[at + 1]) || s[at + 2] != '$') return -1;
        cost = (s[at] - '0') * 10 + (s[at + 1] - '0');
        if (cost is < MinCost or > MaxCost) return -1;
        at += 3;
        if (!Decode(s.Slice(at, SaltChars), salt)) return -1;
        return at + SaltChars;
    }

    /// <summary>
    /// Whether <paramref name="hash"/> (salt ending at <paramref name="end"/>) is a whole hash as bcrypt writes it:
    /// 31 hash characters, and no stray bits where the encoding has room to spare. The salt's last character carries
    /// 2 bits of the salt and 4 unused ones; the hash's last carries 4 bits and 2 unused. A hash with stray bits could
    /// never match (OpenBSD and BCrypt.Net-Next compare the whole re-encoded hash), so it's refused before hashing.
    /// </summary>
    static bool IsWholeHash(ReadOnlySpan<char> hash, int end)
    {
        if (end < 0 || hash.Length != end + HashChars || (Index(hash[end - 1]) & 0x0f) != 0 || (Index(hash[^1]) & 0x03) != 0)
            return false;
        for (int i = end; i < hash.Length; i++)
            if (Index(hash[i]) < 0) return false;
        return true;
    }

    /// <summary>Prepares a check of <paramref name="password"/> against <paramref name="hash"/>; false when the hash is
    /// malformed or the password can't be a bcrypt key (see <see cref="PrepareKey"/>).</summary>
    internal static bool PrepareVerify(ReadOnlySpan<char> password, ReadOnlySpan<char> hash, Input* input)
    {
        Span<byte> salt = stackalloc byte[SaltBytes];
        return ParseHash(hash, out char revision, out int cost, salt) && Prepare(password, salt, cost, revision, input);
    }

    /// <summary>The settings of a whole hash; false when it's malformed.</summary>
    static bool ParseHash(ReadOnlySpan<char> hash, out char revision, out int cost, Span<byte> salt) =>
        IsWholeHash(hash, ParseSettings(hash, out revision, out cost, salt));

    internal static bool Prepare(ReadOnlySpan<char> password, ReadOnlySpan<byte> salt, int cost, char revision, Input* input)
    {
        if (!PrepareKey(password, revision, input->Key)) return false;
        StreamWords(salt, input->Salt);
        salt.CopyTo(new Span<byte>(input->SaltBytes, SaltBytes));
        input->Cost = cost;
        input->Revision = revision;
        return true;
    }

    /// <summary>
    /// The key's words: the password's UTF-8 and, except for "$2$", a terminating NUL. False when the UTF-8 is over
    /// 72 bytes (bcrypt would ignore the rest) or the text isn't valid UTF-16.
    /// </summary>
    static bool PrepareKey(ReadOnlySpan<char> password, char revision, uint* words)
    {
        Span<byte> key = stackalloc byte[MaxPasswordBytes + 1];
        bool ok = Utf8.FromUtf16(password, key[..MaxPasswordBytes], out _, out int n, replaceInvalidSequences: false) == OperationStatus.Done;
        if (ok)
        {
            if (revision != '\0') key[n++] = 0;
            StreamWords(key[..n], words);
        }
        CryptographicOperations.ZeroMemory(key);
        return ok;
    }

    /// <summary>Why <see cref="Prepare(ReadOnlySpan{char}, ReadOnlySpan{byte}, int, char, Input*)"/> refused <paramref name="password"/>, for the exception.</summary>
    internal static string RefusalOf(ReadOnlySpan<char> password) => IsValidUtf16(password)
        ? "bcrypt reads at most 72 UTF-8 bytes of a password"
        : "the password isn't valid UTF-16: it has a lone surrogate";

    static bool IsValidUtf16(ReadOnlySpan<char> text)
    {
        for (int i = 0; i < text.Length; i++)
        {
            if (!char.IsSurrogate(text[i])) continue;
            if (!char.IsHighSurrogate(text[i]) || i + 1 == text.Length || !char.IsLowSurrogate(text[i + 1])) return false;
            i++;
        }
        return true;
    }

    /// <summary>
    /// The 18 words the key schedule reads from <paramref name="data"/>, taken cyclically as OpenBSD's
    /// Blowfish_stream2word does. Each expansion restarts the stream, so the same words recur every time. An empty
    /// key ("$2$" and no password) reads as zero bytes, as C reads the string's terminator.
    /// </summary>
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

    /// <summary>Clears prepared inputs: their words are derived from the password.</summary>
    internal static void Wipe(Input* inputs, int n) => CryptographicOperations.ZeroMemory(new Span<byte>(inputs, n * sizeof(Input)));

    // ---------- output ----------

    static void HashBytesOf(uint* c, Span<byte> hash)
    {
        for (int i = 0; i < HashBytes; i++) hash[i] = (byte)(c[i / 4] >> (24 - 8 * (i % 4)));
    }

    /// <summary>
    /// Whether the computed hash equals <paramref name="stored"/> (31 characters), compared in constant time as
    /// encoded text, as Go's bcrypt does: a stored hash with stray low bits in its last character does not match.
    /// </summary>
    internal static bool Matches(uint* c, ReadOnlySpan<char> stored)
    {
        Span<byte> hash = stackalloc byte[HashBytes];
        HashBytesOf(c, hash);
        Span<char> encoded = stackalloc char[HashChars];
        Encode(hash, encoded);
        return CryptographicOperations.FixedTimeEquals(MemoryMarshal.AsBytes(encoded), MemoryMarshal.AsBytes(stored));
    }

    /// <summary><see cref="Matches(uint*, ReadOnlySpan{char})"/> of a stored hash as ASCII bytes.</summary>
    internal static bool Matches(uint* c, ReadOnlySpan<byte> stored)
    {
        Span<byte> hash = stackalloc byte[HashBytes];
        HashBytesOf(c, hash);
        Span<char> encoded = stackalloc char[HashChars];
        Encode(hash, encoded);
        Span<byte> ascii = stackalloc byte[HashChars];
        for (int i = 0; i < HashChars; i++) ascii[i] = (byte)encoded[i];
        return CryptographicOperations.FixedTimeEquals(ascii, stored);
    }

    /// <summary>The finished hash: "$2b$10$" + salt + hash, or "$2$10$" + ... for the original revision.</summary>
    internal static string Format(Input* input, uint* c)
    {
        Span<char> s = stackalloc char[HashLength];
        return new string(s[..Format(input, c, s)]);
    }

    /// <summary>The finished hash as ASCII bytes; returns the length written.</summary>
    internal static int Format(Input* input, uint* c, Span<byte> destination)
    {
        Span<char> s = stackalloc char[HashLength];
        int n = Format(input, c, s);
        for (int i = 0; i < n; i++) destination[i] = (byte)s[i];
        return n;
    }

    static int Format(Input* input, uint* c, Span<char> s)
    {
        int at = WriteSettings(s, input->Revision, input->Cost, new ReadOnlySpan<byte>(input->SaltBytes, SaltBytes));
        Span<byte> hash = stackalloc byte[HashBytes];
        HashBytesOf(c, hash);
        Encode(hash, s.Slice(at, HashChars));
        return at + HashChars;
    }

    /// <summary>Writes "$2b$10$" + 22 salt characters; returns the length written.</summary>
    internal static int WriteSettings(Span<char> s, char revision, int cost, ReadOnlySpan<byte> salt)
    {
        s[0] = '$';
        s[1] = '2';
        int at = 2;
        if (revision != '\0') s[at++] = revision;
        s[at++] = '$';
        s[at++] = (char)('0' + cost / 10);
        s[at++] = (char)('0' + cost % 10);
        s[at++] = '$';
        Encode(salt, s.Slice(at, SaltChars));
        return at + SaltChars;
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
