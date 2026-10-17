using System.Numerics;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;

namespace Conduit;

/// <summary>
/// bcrypt ($2a$/$2b$/$2y$) written for throughput. Blowfish is a chain of dependent table lookups, so one hash leaves most of the CPU's
/// execution units idle; <see cref="Run"/> works on up to four hashes at once on one thread and the independent chains fill those units.
/// The Blowfish tables are the hex digits of pi, computed once at startup.
/// </summary>
static unsafe class Bcrypt
{
    public const int MaxLanes = 4, MaxKeyBytes = 72, MaxCost = 12;
    const int P = 1024, StateWords = 1042; // a lane's state: four 256-word S-boxes, then the 18-word P array
    const string Alphabet = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    static readonly uint[] Init = PiWords();
    static readonly uint[] Magic = [0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274]; // "OrpheanBeholderScryDoubt"

    /// <summary>One hash in flight: the password's key words and the salt in, the 23 hash bytes out.</summary>
    public sealed class Job
    {
        public readonly uint[] Key = new uint[18], SaltWords = new uint[4];
        public readonly byte[] Salt = new byte[16], Hash = new byte[23];
        public int Cost;

        /// <summary>A hash of the password under a random salt; false if the password is over 72 bytes.</summary>
        public static Job? ForHash(string password, int cost)
        {
            var salt = RandomNumberGenerator.GetBytes(16);
            return Make(password, salt, cost);
        }

        /// <summary>The check of a password against a stored hash; null if the hash is malformed or the password is over 72 bytes.</summary>
        public static Job? ForVerify(string password, string stored)
        {
            if (stored.Length != 60 || stored[0] != '$' || stored[1] != '2' || stored[2] is not ('a' or 'b' or 'y') || stored[3] != '$' || stored[6] != '$') return null;
            if (!char.IsAsciiDigit(stored[4]) || !char.IsAsciiDigit(stored[5])) return null;
            int cost = (stored[4] - '0') * 10 + stored[5] - '0';
            if (cost is < 4 or > MaxCost) return null; // a stored cost of 31 would keep a worker busy for days
            var salt = Decode(stored.AsSpan(7, 22), 16);
            return salt is null ? null : Make(password, salt, cost);
        }

        static Job? Make(string password, byte[] salt, int cost)
        {
            var key = new byte[System.Text.Encoding.UTF8.GetByteCount(password) + 1]; // the key includes the terminating NUL
            if (key.Length > MaxKeyBytes + 1) return null;
            System.Text.Encoding.UTF8.GetBytes(password, key);
            var job = new Job { Cost = cost };
            salt.CopyTo(job.Salt, 0);
            for (int i = 0, j = 0; i < 18; i++)
                for (int b = 0; b < 4; b++, j++) job.Key[i] = job.Key[i] << 8 | key[j % key.Length];
            for (int i = 0; i < 4; i++) job.SaltWords[i] = (uint)(salt[4 * i] << 24 | salt[4 * i + 1] << 16 | salt[4 * i + 2] << 8 | salt[4 * i + 3]);
            return job;
        }

        /// <summary>The stored form: $2a$10$ + 22 salt characters + 31 hash characters.</summary>
        public string Encoded() => $"$2a${Cost:00}${Encode(Salt)}{Encode(Hash)}";

        public bool Matches(string stored) => CryptographicOperations.FixedTimeEquals(Hash, Decode(stored.AsSpan(29, 31), 23) ?? new byte[23]);
    }

    /// <summary>Computes 1 to <see cref="MaxLanes"/> hashes; with two or more, all four lanes run (the spare ones compute a throwaway).</summary>
    public static void Run(ReadOnlySpan<Job> jobs)
    {
        if (jobs.Length == 1 || !SameCost(jobs)) { foreach (var job in jobs) Run1(job); return; }
        uint* st = stackalloc uint[MaxLanes * StateWords];
        var lanes = new Job[MaxLanes];
        for (int i = 0; i < MaxLanes; i++) lanes[i] = i < jobs.Length ? jobs[i] : jobs[0];
        for (int i = 0; i < MaxLanes; i++)
        {
            Init.AsSpan().CopyTo(new Span<uint>(st + i * StateWords, StateWords));
            ExpandWithSalt(st + i * StateWords, lanes[i]);
        }
        uint* s0 = st, s1 = st + StateWords, s2 = st + 2 * StateWords, s3 = st + 3 * StateWords;
        fixed (uint* k0 = lanes[0].Key, k1 = lanes[1].Key, k2 = lanes[2].Key, k3 = lanes[3].Key)
        {
            uint* a = stackalloc uint[MaxLanes * 18];
            for (int i = 0; i < 18; i++)
                for (int l = 0; l < MaxLanes; l++) a[l * 18 + i] = lanes[l].SaltWords[i & 3];
            for (long n = 1L << jobs[0].Cost; n > 0; n--)
            {
                Expand4(s0, s1, s2, s3, k0, k1, k2, k3);
                Expand4(s0, s1, s2, s3, a, a + 18, a + 36, a + 54);
            }
        }
        for (int i = 0; i < jobs.Length; i++) Finish(st + i * StateWords, jobs[i]);
    }

    static bool SameCost(ReadOnlySpan<Job> jobs)
    {
        foreach (var j in jobs) if (j.Cost != jobs[0].Cost) return false;
        return true;
    }

    static void Run1(Job job)
    {
        uint* st = stackalloc uint[StateWords];
        Init.AsSpan().CopyTo(new Span<uint>(st, StateWords));
        ExpandWithSalt(st, job);
        uint* salt = stackalloc uint[18];
        for (int i = 0; i < 18; i++) salt[i] = job.SaltWords[i & 3];
        fixed (uint* key = job.Key)
            for (long n = 1L << job.Cost; n > 0; n--)
            {
                Expand1(st, key);
                Expand1(st, salt);
            }
        Finish(st, job);
    }

    /// <summary>The first key expansion, which mixes the salt in as well.</summary>
    static void ExpandWithSalt(uint* st, Job job)
    {
        for (int i = 0; i < 18; i++) st[P + i] ^= job.Key[i];
        uint l = 0, r = 0;
        int j = 0;
        for (int i = 0; i < StateWords; i += 2)
        {
            int at = i < 18 ? P + i : i - 18;
            l ^= job.SaltWords[j]; r ^= job.SaltWords[j + 1]; j = (j + 2) & 3;
            Encipher(st, ref l, ref r);
            st[at] = l; st[at + 1] = r;
        }
    }

    /// <summary>A key expansion without salt: the P array is xored with the 18 key words, then P and the S-boxes are rewritten by enciphering a running block.</summary>
    [MethodImpl(MethodImplOptions.AggressiveOptimization)]
    static void Expand1(uint* st, uint* key)
    {
        for (int i = 0; i < 18; i++) st[P + i] ^= key[i];
        uint l = 0, r = 0;
        for (int i = 0; i < 18; i += 2) { Encipher(st, ref l, ref r); st[P + i] = l; st[P + i + 1] = r; }
        for (int i = 0; i < 1024; i += 2) { Encipher(st, ref l, ref r); st[i] = l; st[i + 1] = r; }
    }

    [MethodImpl(MethodImplOptions.AggressiveOptimization)]
    static void Expand4(uint* s0, uint* s1, uint* s2, uint* s3, uint* w0, uint* w1, uint* w2, uint* w3)
    {
        for (int i = 0; i < 18; i++) { s0[P + i] ^= w0[i]; s1[P + i] ^= w1[i]; s2[P + i] ^= w2[i]; s3[P + i] ^= w3[i]; }
        uint l0 = 0, r0 = 0, l1 = 0, r1 = 0, l2 = 0, r2 = 0, l3 = 0, r3 = 0;
        for (int i = 0; i < 18; i += 2)
        {
            Encipher4(s0, s1, s2, s3, ref l0, ref r0, ref l1, ref r1, ref l2, ref r2, ref l3, ref r3);
            s0[P + i] = l0; s0[P + i + 1] = r0; s1[P + i] = l1; s1[P + i + 1] = r1; s2[P + i] = l2; s2[P + i + 1] = r2; s3[P + i] = l3; s3[P + i + 1] = r3;
        }
        for (int i = 0; i < 1024; i += 2)
        {
            Encipher4(s0, s1, s2, s3, ref l0, ref r0, ref l1, ref r1, ref l2, ref r2, ref l3, ref r3);
            s0[i] = l0; s0[i + 1] = r0; s1[i] = l1; s1[i + 1] = r1; s2[i] = l2; s2[i + 1] = r2; s3[i] = l3; s3[i + 1] = r3;
        }
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    static uint F(uint* s, uint x) => ((s[x >> 24] + s[256 + ((x >> 16) & 0xff)]) ^ s[512 + ((x >> 8) & 0xff)]) + s[768 + (x & 0xff)];

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    static void Encipher(uint* s, ref uint xl, ref uint xr)
    {
        uint l = xl ^ s[P], r = xr;
        for (int i = 1; i <= 16; i += 2)
        {
            r ^= F(s, l) ^ s[P + i];
            l ^= F(s, r) ^ s[P + i + 1];
        }
        xl = r ^ s[P + 17];
        xr = l;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    static void Encipher4(uint* s0, uint* s1, uint* s2, uint* s3, ref uint xl0, ref uint xr0, ref uint xl1, ref uint xr1, ref uint xl2, ref uint xr2, ref uint xl3, ref uint xr3)
    {
        uint l0 = xl0 ^ s0[P], r0 = xr0, l1 = xl1 ^ s1[P], r1 = xr1, l2 = xl2 ^ s2[P], r2 = xr2, l3 = xl3 ^ s3[P], r3 = xr3;
        for (int i = 1; i <= 16; i += 2)
        {
            r0 ^= F(s0, l0) ^ s0[P + i]; r1 ^= F(s1, l1) ^ s1[P + i]; r2 ^= F(s2, l2) ^ s2[P + i]; r3 ^= F(s3, l3) ^ s3[P + i];
            l0 ^= F(s0, r0) ^ s0[P + i + 1]; l1 ^= F(s1, r1) ^ s1[P + i + 1]; l2 ^= F(s2, r2) ^ s2[P + i + 1]; l3 ^= F(s3, r3) ^ s3[P + i + 1];
        }
        xl0 = r0 ^ s0[P + 17]; xr0 = l0; xl1 = r1 ^ s1[P + 17]; xr1 = l1; xl2 = r2 ^ s2[P + 17]; xr2 = l2; xl3 = r3 ^ s3[P + 17]; xr3 = l3;
    }

    /// <summary>Enciphers "OrpheanBeholderScryDoubt" 64 times under the finished key schedule.</summary>
    static void Finish(uint* st, Job job)
    {
        uint* c = stackalloc uint[6];
        for (int i = 0; i < 6; i++) c[i] = Magic[i];
        for (int n = 0; n < 64; n++)
            for (int i = 0; i < 6; i += 2) Encipher(st, ref c[i], ref c[i + 1]);
        for (int i = 0; i < 23; i++) job.Hash[i] = (byte)(c[i / 4] >> (24 - 8 * (i % 4)));
    }

    // ---- the digits of pi ----

    /// <summary>The first 1042 32-bit words of pi's fractional part, in hex: the P array, then the four S-boxes.</summary>
    static uint[] PiWords()
    {
        int bits = StateWords * 32 + 128; // fractional bits, with guard bits for the truncation in the series
        var one = BigInteger.One << bits;
        BigInteger Arctan(int x) // arctan(1/x) = sum (-1)^k / ((2k + 1) x^(2k + 1))
        {
            var x2 = (BigInteger)x * x;
            var power = one / x;
            var sum = power;
            for (int k = 1; !power.IsZero; k++)
            {
                power /= x2;
                sum += (k % 2 == 0 ? 1 : -1) * (power / (2 * k + 1));
            }
            return sum;
        }
        var pi = 16 * Arctan(5) - 4 * Arctan(239); // Machin's formula
        var fraction = pi - 3 * one;
        var words = new uint[StateWords];
        for (int w = 0; w < words.Length; w++) words[w] = (uint)((fraction >> (bits - 32 * (w + 1))) & uint.MaxValue);
        if (words[0] != 0x243F6A88 || words[StateWords - 1] != 0x3AC372E6) throw new InvalidOperationException("pi digits are wrong");
        // The words are P[0..17] then S[0..1023]; the lane state keeps S first.
        var state = new uint[StateWords];
        Array.Copy(words, 18, state, 0, 1024);
        Array.Copy(words, 0, state, P, 18);
        return state;
    }

    // ---- bcrypt's base64: the standard bit packing with its own alphabet and no padding ----

    static string Encode(byte[] data)
    {
        var sb = new System.Text.StringBuilder();
        for (int i = 0; i < data.Length; i += 3)
        {
            int b0 = data[i], b1 = i + 1 < data.Length ? data[i + 1] : 0, b2 = i + 2 < data.Length ? data[i + 2] : 0;
            int n = Math.Min(3, data.Length - i) + 1;
            int v = b0 << 16 | b1 << 8 | b2;
            for (int k = 0; k < n; k++) sb.Append(Alphabet[(v >> (18 - 6 * k)) & 63]);
        }
        return sb.ToString();
    }

    static byte[]? Decode(ReadOnlySpan<char> text, int bytes)
    {
        var data = new byte[bytes];
        int bit = 0;
        foreach (char ch in text)
        {
            int v = Alphabet.IndexOf(ch);
            if (v < 0) return null;
            for (int k = 5; k >= 0; k--, bit++)
                if (bit / 8 < bytes && (v >> k & 1) != 0) data[bit / 8] |= (byte)(0x80 >> (bit % 8));
        }
        return data;
    }
}
