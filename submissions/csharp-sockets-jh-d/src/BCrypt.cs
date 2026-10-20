using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;

namespace Conduit;

// bcrypt ($2a$/$2b$/$2y$), written from the Provos-Mazieres paper: EksBlowfishSetup, then 64 encryptions of
// "OrpheanBeholderScryDoubt". Nearly all the work is the 2^cost key schedule (about a million Blowfish block
// encryptions at cost 10). One Blowfish round is a chain of dependent table loads, which leaves most of a core's
// execution units idle, so ComputeBatch runs up to four independent hashes interleaved in one thread (as John the
// Ripper does).
static unsafe class BCrypt
{
    const string Alphabet = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    static readonly sbyte[] Index = BuildIndex();
    const int StateWords = 18 + 1024;

    static sbyte[] BuildIndex()
    {
        var t = new sbyte[128];
        Array.Fill(t, (sbyte)-1);
        for (int i = 0; i < Alphabet.Length; i++) t[Alphabet[i]] = (sbyte)i;
        return t;
    }

    // OrpheanBeholderScryDoubt as six big-endian words
    static readonly uint[] Magic = [0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274];

    // One hash to compute: key words, salt words and cost in; the 23 raw output bytes out.
    public sealed class Job
    {
        internal readonly uint[] KeyWords = new uint[18];
        internal readonly uint[] SaltWords = new uint[4];
        internal int Cost;
        public readonly byte[] Output = new byte[23];

        public Job(string password, ReadOnlySpan<byte> salt, int cost)
        {
            // key = UTF-8 password + NUL, at most 72 bytes, cycled into 18 big-endian words
            byte[] pw = Encoding.UTF8.GetBytes(password);
            int n = Math.Min(pw.Length, 72);
            Span<byte> key = stackalloc byte[73];
            pw.AsSpan(0, n).CopyTo(key);
            key[n] = 0;
            int keyLen = Math.Min(n + 1, 72);
            int kp = 0;
            for (int i = 0; i < 18; i++)
            {
                uint w = 0;
                for (int j = 0; j < 4; j++)
                {
                    w = (w << 8) | key[kp];
                    kp = kp + 1 == keyLen ? 0 : kp + 1;
                }
                KeyWords[i] = w;
            }
            for (int i = 0; i < 4; i++)
                SaltWords[i] = (uint)(salt[4 * i] << 24 | salt[4 * i + 1] << 16 | salt[4 * i + 2] << 8 | salt[4 * i + 3]);
            Cost = cost;
        }

        public bool CanPairWith(Job other) => other.Cost == Cost;
    }

    public static Job HashJob(string password, out byte[] salt)
    {
        salt = new byte[16];
        RandomNumberGenerator.Fill(salt);
        return new Job(password, salt, 10);
    }

    public static string FormatHash(byte[] salt, Job done)
    {
        var sb = new StringBuilder(60);
        sb.Append("$2b$").Append(done.Cost.ToString("00")).Append('$');
        Encode(salt, sb);
        Encode(done.Output, sb);
        return sb.ToString();
    }

    // null if the stored hash isn't a bcrypt hash we understand (the login then fails)
    public static Job VerifyJob(string password, string hash, out byte[] expected)
    {
        expected = null;
        if (hash.Length != 60 || hash[0] != '$' || hash[1] != '2' || hash[3] != '$' || hash[6] != '$') return null;
        char v = hash[2];
        if (v != 'a' && v != 'b' && v != 'y') return null;
        int cost = (hash[4] - '0') * 10 + (hash[5] - '0');
        if (cost < 4 || cost > 31) return null;
        Span<byte> salt = stackalloc byte[16];
        if (!Decode(hash.AsSpan(7, 22), salt)) return null;
        var want = new byte[23];
        if (!Decode(hash.AsSpan(29, 31), want)) return null;
        expected = want;
        return new Job(password, salt, cost);
    }

    public static bool Matches(Job done, byte[] expected) => CryptographicOperations.FixedTimeEquals(done.Output, expected);

    public static string Hash(string password)
    {
        var job = HashJob(password, out var salt);
        Compute(job);
        return FormatHash(salt, job);
    }

    public static bool Verify(string password, string hash)
    {
        var job = VerifyJob(password, hash, out var expected);
        if (job == null) return false;
        Compute(job);
        return Matches(job, expected);
    }

    public const int MaxBatch = 4;

    public static void Compute(Job a) => ComputeBatch([a], 1);

    // 1 to 4 hashes of the same cost, interleaved in this thread
    public static void ComputeBatch(Job[] jobs, int n)
    {
        uint* st = stackalloc uint[StateWords * MaxBatch];
        var keys = stackalloc uint[18 * MaxBatch];
        var salts = stackalloc uint[4 * MaxBatch];
        for (int j = 0; j < n; j++)
        {
            for (int i = 0; i < 18; i++) keys[18 * j + i] = jobs[j].KeyWords[i];
            for (int i = 0; i < 4; i++) salts[4 * j + i] = jobs[j].SaltWords[i];
            Setup(st + StateWords * j, keys + 18 * j, salts + 4 * j);
        }
        uint* s0 = st, s1 = st + StateWords, s2 = st + 2 * StateWords, s3 = st + 3 * StateWords;
        for (long r = 1L << jobs[0].Cost; r > 0; r--)
        {
            for (int j = 0; j < n; j++) XorKey(st + StateWords * j, keys + 18 * j);
            Rekey(n, s0, s1, s2, s3);
            for (int j = 0; j < n; j++) XorSalt(st + StateWords * j, salts + 4 * j);
            Rekey(n, s0, s1, s2, s3);
        }
        for (int j = 0; j < n; j++) Finish(st + StateWords * j, jobs[j].Output);
    }

    static void Rekey(int n, uint* s0, uint* s1, uint* s2, uint* s3)
    {
        switch (n)
        {
            case 1: Rekey1(s0); break;
            case 2: Rekey2(s0, s1); break;
            case 3: Rekey3(s0, s1, s2); break;
            default: Rekey4(s0, s1, s2, s3); break;
        }
    }

    // initial state from pi, then ExpandKey(state, salt, key): the data stream is the salt, cycled
    static void Setup(uint* st, uint* key, uint* salt)
    {
        fixed (uint* p0 = BlowfishInit.P) Unsafe.CopyBlock(st, p0, 18 * 4);
        fixed (uint* s0 = BlowfishInit.S) Unsafe.CopyBlock(st + 18, s0, 1024 * 4);
        XorKey(st, key);
        uint l = 0, r = 0;
        int sp = 0;
        for (int i = 0; i < StateWords; i += 2)
        {
            l ^= salt[sp]; r ^= salt[sp + 1]; sp ^= 2;
            Encrypt(st, ref l, ref r);
            st[i] = l; st[i + 1] = r;
        }
    }

    static void XorKey(uint* st, uint* key)
    {
        for (int i = 0; i < 18; i++) st[i] ^= key[i];
    }

    // ExpandKey(state, 0, salt): the 16-byte salt, cycled, is the key
    static void XorSalt(uint* st, uint* salt)
    {
        for (int i = 0; i < 18; i++) st[i] ^= salt[i & 3];
    }

    static void Finish(uint* st, byte[] output)
    {
        uint* c = stackalloc uint[6];
        for (int i = 0; i < 6; i++) c[i] = Magic[i];
        for (int k = 0; k < 64; k++)
        {
            for (int j = 0; j < 6; j += 2) Encrypt(st, ref c[j], ref c[j + 1]);
        }
        for (int i = 0; i < 23; i++) output[i] = (byte)(c[i >> 2] >> (24 - 8 * (i & 3)));
    }

    static void Encrypt(uint* st, ref uint xl, ref uint xr)
    {
        uint l = xl ^ st[0], r = xr;
        for (int i = 1; i <= 16; i += 2)
        {
            r ^= (((st[(nuint)(l >> 24) + 18] + st[(nuint)(byte)(l >> 16) + 274]) ^ st[(nuint)(byte)(l >> 8) + 530]) + st[(nuint)(byte)l + 786]) ^ st[i];
            l ^= (((st[(nuint)(r >> 24) + 18] + st[(nuint)(byte)(r >> 16) + 274]) ^ st[(nuint)(byte)(r >> 8) + 530]) + st[(nuint)(byte)r + 786]) ^ st[i + 1];
        }
        xl = r ^ st[17];
        xr = l;
    }

    // Re-key P (words 0..17) and S (words 18..1041) of n states from a zero data stream: the hot loop. Block
    // halves stay in locals, the 16 rounds are unrolled and interleaved across the states, and each state is
    // addressed from one pointer with constant displacements (nuint index math, so the JIT folds them).
    [MethodImpl(MethodImplOptions.AggressiveOptimization)]
    static void Rekey1(uint* a)
    {
        uint xl0 = 0, xr0 = 0;
        for (nint i = 0; i < StateWords; i += 2)
        {
            uint l0 = xl0 ^ a[0], r0 = xr0;
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[1];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[2];
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[3];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[4];
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[5];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[6];
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[7];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[8];
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[9];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[10];
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[11];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[12];
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[13];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[14];
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[15];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[16];
            xl0 = r0 ^ a[17]; xr0 = l0;
            a[i] = xl0; a[i + 1] = xr0;
        }
    }

    [MethodImpl(MethodImplOptions.AggressiveOptimization)]
    static void Rekey2(uint* a, uint* b)
    {
        uint xl0 = 0, xr0 = 0; uint xl1 = 0, xr1 = 0;
        for (nint i = 0; i < StateWords; i += 2)
        {
            uint l0 = xl0 ^ a[0], r0 = xr0;
            uint l1 = xl1 ^ b[0], r1 = xr1;
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[1];
            r1 ^= (((b[(nuint)(l1 >> 24) + 18] + b[(nuint)(byte)(l1 >> 16) + 274]) ^ b[(nuint)(byte)(l1 >> 8) + 530]) + b[(nuint)(byte)l1 + 786]) ^ b[1];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[2];
            l1 ^= (((b[(nuint)(r1 >> 24) + 18] + b[(nuint)(byte)(r1 >> 16) + 274]) ^ b[(nuint)(byte)(r1 >> 8) + 530]) + b[(nuint)(byte)r1 + 786]) ^ b[2];
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[3];
            r1 ^= (((b[(nuint)(l1 >> 24) + 18] + b[(nuint)(byte)(l1 >> 16) + 274]) ^ b[(nuint)(byte)(l1 >> 8) + 530]) + b[(nuint)(byte)l1 + 786]) ^ b[3];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[4];
            l1 ^= (((b[(nuint)(r1 >> 24) + 18] + b[(nuint)(byte)(r1 >> 16) + 274]) ^ b[(nuint)(byte)(r1 >> 8) + 530]) + b[(nuint)(byte)r1 + 786]) ^ b[4];
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[5];
            r1 ^= (((b[(nuint)(l1 >> 24) + 18] + b[(nuint)(byte)(l1 >> 16) + 274]) ^ b[(nuint)(byte)(l1 >> 8) + 530]) + b[(nuint)(byte)l1 + 786]) ^ b[5];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[6];
            l1 ^= (((b[(nuint)(r1 >> 24) + 18] + b[(nuint)(byte)(r1 >> 16) + 274]) ^ b[(nuint)(byte)(r1 >> 8) + 530]) + b[(nuint)(byte)r1 + 786]) ^ b[6];
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[7];
            r1 ^= (((b[(nuint)(l1 >> 24) + 18] + b[(nuint)(byte)(l1 >> 16) + 274]) ^ b[(nuint)(byte)(l1 >> 8) + 530]) + b[(nuint)(byte)l1 + 786]) ^ b[7];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[8];
            l1 ^= (((b[(nuint)(r1 >> 24) + 18] + b[(nuint)(byte)(r1 >> 16) + 274]) ^ b[(nuint)(byte)(r1 >> 8) + 530]) + b[(nuint)(byte)r1 + 786]) ^ b[8];
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[9];
            r1 ^= (((b[(nuint)(l1 >> 24) + 18] + b[(nuint)(byte)(l1 >> 16) + 274]) ^ b[(nuint)(byte)(l1 >> 8) + 530]) + b[(nuint)(byte)l1 + 786]) ^ b[9];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[10];
            l1 ^= (((b[(nuint)(r1 >> 24) + 18] + b[(nuint)(byte)(r1 >> 16) + 274]) ^ b[(nuint)(byte)(r1 >> 8) + 530]) + b[(nuint)(byte)r1 + 786]) ^ b[10];
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[11];
            r1 ^= (((b[(nuint)(l1 >> 24) + 18] + b[(nuint)(byte)(l1 >> 16) + 274]) ^ b[(nuint)(byte)(l1 >> 8) + 530]) + b[(nuint)(byte)l1 + 786]) ^ b[11];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[12];
            l1 ^= (((b[(nuint)(r1 >> 24) + 18] + b[(nuint)(byte)(r1 >> 16) + 274]) ^ b[(nuint)(byte)(r1 >> 8) + 530]) + b[(nuint)(byte)r1 + 786]) ^ b[12];
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[13];
            r1 ^= (((b[(nuint)(l1 >> 24) + 18] + b[(nuint)(byte)(l1 >> 16) + 274]) ^ b[(nuint)(byte)(l1 >> 8) + 530]) + b[(nuint)(byte)l1 + 786]) ^ b[13];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[14];
            l1 ^= (((b[(nuint)(r1 >> 24) + 18] + b[(nuint)(byte)(r1 >> 16) + 274]) ^ b[(nuint)(byte)(r1 >> 8) + 530]) + b[(nuint)(byte)r1 + 786]) ^ b[14];
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[15];
            r1 ^= (((b[(nuint)(l1 >> 24) + 18] + b[(nuint)(byte)(l1 >> 16) + 274]) ^ b[(nuint)(byte)(l1 >> 8) + 530]) + b[(nuint)(byte)l1 + 786]) ^ b[15];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[16];
            l1 ^= (((b[(nuint)(r1 >> 24) + 18] + b[(nuint)(byte)(r1 >> 16) + 274]) ^ b[(nuint)(byte)(r1 >> 8) + 530]) + b[(nuint)(byte)r1 + 786]) ^ b[16];
            xl0 = r0 ^ a[17]; xr0 = l0;
            a[i] = xl0; a[i + 1] = xr0;
            xl1 = r1 ^ b[17]; xr1 = l1;
            b[i] = xl1; b[i + 1] = xr1;
        }
    }

    [MethodImpl(MethodImplOptions.AggressiveOptimization)]
    static void Rekey3(uint* a, uint* b, uint* c)
    {
        uint xl0 = 0, xr0 = 0; uint xl1 = 0, xr1 = 0; uint xl2 = 0, xr2 = 0;
        for (nint i = 0; i < StateWords; i += 2)
        {
            uint l0 = xl0 ^ a[0], r0 = xr0;
            uint l1 = xl1 ^ b[0], r1 = xr1;
            uint l2 = xl2 ^ c[0], r2 = xr2;
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[1];
            r1 ^= (((b[(nuint)(l1 >> 24) + 18] + b[(nuint)(byte)(l1 >> 16) + 274]) ^ b[(nuint)(byte)(l1 >> 8) + 530]) + b[(nuint)(byte)l1 + 786]) ^ b[1];
            r2 ^= (((c[(nuint)(l2 >> 24) + 18] + c[(nuint)(byte)(l2 >> 16) + 274]) ^ c[(nuint)(byte)(l2 >> 8) + 530]) + c[(nuint)(byte)l2 + 786]) ^ c[1];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[2];
            l1 ^= (((b[(nuint)(r1 >> 24) + 18] + b[(nuint)(byte)(r1 >> 16) + 274]) ^ b[(nuint)(byte)(r1 >> 8) + 530]) + b[(nuint)(byte)r1 + 786]) ^ b[2];
            l2 ^= (((c[(nuint)(r2 >> 24) + 18] + c[(nuint)(byte)(r2 >> 16) + 274]) ^ c[(nuint)(byte)(r2 >> 8) + 530]) + c[(nuint)(byte)r2 + 786]) ^ c[2];
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[3];
            r1 ^= (((b[(nuint)(l1 >> 24) + 18] + b[(nuint)(byte)(l1 >> 16) + 274]) ^ b[(nuint)(byte)(l1 >> 8) + 530]) + b[(nuint)(byte)l1 + 786]) ^ b[3];
            r2 ^= (((c[(nuint)(l2 >> 24) + 18] + c[(nuint)(byte)(l2 >> 16) + 274]) ^ c[(nuint)(byte)(l2 >> 8) + 530]) + c[(nuint)(byte)l2 + 786]) ^ c[3];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[4];
            l1 ^= (((b[(nuint)(r1 >> 24) + 18] + b[(nuint)(byte)(r1 >> 16) + 274]) ^ b[(nuint)(byte)(r1 >> 8) + 530]) + b[(nuint)(byte)r1 + 786]) ^ b[4];
            l2 ^= (((c[(nuint)(r2 >> 24) + 18] + c[(nuint)(byte)(r2 >> 16) + 274]) ^ c[(nuint)(byte)(r2 >> 8) + 530]) + c[(nuint)(byte)r2 + 786]) ^ c[4];
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[5];
            r1 ^= (((b[(nuint)(l1 >> 24) + 18] + b[(nuint)(byte)(l1 >> 16) + 274]) ^ b[(nuint)(byte)(l1 >> 8) + 530]) + b[(nuint)(byte)l1 + 786]) ^ b[5];
            r2 ^= (((c[(nuint)(l2 >> 24) + 18] + c[(nuint)(byte)(l2 >> 16) + 274]) ^ c[(nuint)(byte)(l2 >> 8) + 530]) + c[(nuint)(byte)l2 + 786]) ^ c[5];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[6];
            l1 ^= (((b[(nuint)(r1 >> 24) + 18] + b[(nuint)(byte)(r1 >> 16) + 274]) ^ b[(nuint)(byte)(r1 >> 8) + 530]) + b[(nuint)(byte)r1 + 786]) ^ b[6];
            l2 ^= (((c[(nuint)(r2 >> 24) + 18] + c[(nuint)(byte)(r2 >> 16) + 274]) ^ c[(nuint)(byte)(r2 >> 8) + 530]) + c[(nuint)(byte)r2 + 786]) ^ c[6];
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[7];
            r1 ^= (((b[(nuint)(l1 >> 24) + 18] + b[(nuint)(byte)(l1 >> 16) + 274]) ^ b[(nuint)(byte)(l1 >> 8) + 530]) + b[(nuint)(byte)l1 + 786]) ^ b[7];
            r2 ^= (((c[(nuint)(l2 >> 24) + 18] + c[(nuint)(byte)(l2 >> 16) + 274]) ^ c[(nuint)(byte)(l2 >> 8) + 530]) + c[(nuint)(byte)l2 + 786]) ^ c[7];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[8];
            l1 ^= (((b[(nuint)(r1 >> 24) + 18] + b[(nuint)(byte)(r1 >> 16) + 274]) ^ b[(nuint)(byte)(r1 >> 8) + 530]) + b[(nuint)(byte)r1 + 786]) ^ b[8];
            l2 ^= (((c[(nuint)(r2 >> 24) + 18] + c[(nuint)(byte)(r2 >> 16) + 274]) ^ c[(nuint)(byte)(r2 >> 8) + 530]) + c[(nuint)(byte)r2 + 786]) ^ c[8];
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[9];
            r1 ^= (((b[(nuint)(l1 >> 24) + 18] + b[(nuint)(byte)(l1 >> 16) + 274]) ^ b[(nuint)(byte)(l1 >> 8) + 530]) + b[(nuint)(byte)l1 + 786]) ^ b[9];
            r2 ^= (((c[(nuint)(l2 >> 24) + 18] + c[(nuint)(byte)(l2 >> 16) + 274]) ^ c[(nuint)(byte)(l2 >> 8) + 530]) + c[(nuint)(byte)l2 + 786]) ^ c[9];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[10];
            l1 ^= (((b[(nuint)(r1 >> 24) + 18] + b[(nuint)(byte)(r1 >> 16) + 274]) ^ b[(nuint)(byte)(r1 >> 8) + 530]) + b[(nuint)(byte)r1 + 786]) ^ b[10];
            l2 ^= (((c[(nuint)(r2 >> 24) + 18] + c[(nuint)(byte)(r2 >> 16) + 274]) ^ c[(nuint)(byte)(r2 >> 8) + 530]) + c[(nuint)(byte)r2 + 786]) ^ c[10];
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[11];
            r1 ^= (((b[(nuint)(l1 >> 24) + 18] + b[(nuint)(byte)(l1 >> 16) + 274]) ^ b[(nuint)(byte)(l1 >> 8) + 530]) + b[(nuint)(byte)l1 + 786]) ^ b[11];
            r2 ^= (((c[(nuint)(l2 >> 24) + 18] + c[(nuint)(byte)(l2 >> 16) + 274]) ^ c[(nuint)(byte)(l2 >> 8) + 530]) + c[(nuint)(byte)l2 + 786]) ^ c[11];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[12];
            l1 ^= (((b[(nuint)(r1 >> 24) + 18] + b[(nuint)(byte)(r1 >> 16) + 274]) ^ b[(nuint)(byte)(r1 >> 8) + 530]) + b[(nuint)(byte)r1 + 786]) ^ b[12];
            l2 ^= (((c[(nuint)(r2 >> 24) + 18] + c[(nuint)(byte)(r2 >> 16) + 274]) ^ c[(nuint)(byte)(r2 >> 8) + 530]) + c[(nuint)(byte)r2 + 786]) ^ c[12];
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[13];
            r1 ^= (((b[(nuint)(l1 >> 24) + 18] + b[(nuint)(byte)(l1 >> 16) + 274]) ^ b[(nuint)(byte)(l1 >> 8) + 530]) + b[(nuint)(byte)l1 + 786]) ^ b[13];
            r2 ^= (((c[(nuint)(l2 >> 24) + 18] + c[(nuint)(byte)(l2 >> 16) + 274]) ^ c[(nuint)(byte)(l2 >> 8) + 530]) + c[(nuint)(byte)l2 + 786]) ^ c[13];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[14];
            l1 ^= (((b[(nuint)(r1 >> 24) + 18] + b[(nuint)(byte)(r1 >> 16) + 274]) ^ b[(nuint)(byte)(r1 >> 8) + 530]) + b[(nuint)(byte)r1 + 786]) ^ b[14];
            l2 ^= (((c[(nuint)(r2 >> 24) + 18] + c[(nuint)(byte)(r2 >> 16) + 274]) ^ c[(nuint)(byte)(r2 >> 8) + 530]) + c[(nuint)(byte)r2 + 786]) ^ c[14];
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[15];
            r1 ^= (((b[(nuint)(l1 >> 24) + 18] + b[(nuint)(byte)(l1 >> 16) + 274]) ^ b[(nuint)(byte)(l1 >> 8) + 530]) + b[(nuint)(byte)l1 + 786]) ^ b[15];
            r2 ^= (((c[(nuint)(l2 >> 24) + 18] + c[(nuint)(byte)(l2 >> 16) + 274]) ^ c[(nuint)(byte)(l2 >> 8) + 530]) + c[(nuint)(byte)l2 + 786]) ^ c[15];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[16];
            l1 ^= (((b[(nuint)(r1 >> 24) + 18] + b[(nuint)(byte)(r1 >> 16) + 274]) ^ b[(nuint)(byte)(r1 >> 8) + 530]) + b[(nuint)(byte)r1 + 786]) ^ b[16];
            l2 ^= (((c[(nuint)(r2 >> 24) + 18] + c[(nuint)(byte)(r2 >> 16) + 274]) ^ c[(nuint)(byte)(r2 >> 8) + 530]) + c[(nuint)(byte)r2 + 786]) ^ c[16];
            xl0 = r0 ^ a[17]; xr0 = l0;
            a[i] = xl0; a[i + 1] = xr0;
            xl1 = r1 ^ b[17]; xr1 = l1;
            b[i] = xl1; b[i + 1] = xr1;
            xl2 = r2 ^ c[17]; xr2 = l2;
            c[i] = xl2; c[i + 1] = xr2;
        }
    }

    [MethodImpl(MethodImplOptions.AggressiveOptimization)]
    static void Rekey4(uint* a, uint* b, uint* c, uint* d)
    {
        uint xl0 = 0, xr0 = 0; uint xl1 = 0, xr1 = 0; uint xl2 = 0, xr2 = 0; uint xl3 = 0, xr3 = 0;
        for (nint i = 0; i < StateWords; i += 2)
        {
            uint l0 = xl0 ^ a[0], r0 = xr0;
            uint l1 = xl1 ^ b[0], r1 = xr1;
            uint l2 = xl2 ^ c[0], r2 = xr2;
            uint l3 = xl3 ^ d[0], r3 = xr3;
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[1];
            r1 ^= (((b[(nuint)(l1 >> 24) + 18] + b[(nuint)(byte)(l1 >> 16) + 274]) ^ b[(nuint)(byte)(l1 >> 8) + 530]) + b[(nuint)(byte)l1 + 786]) ^ b[1];
            r2 ^= (((c[(nuint)(l2 >> 24) + 18] + c[(nuint)(byte)(l2 >> 16) + 274]) ^ c[(nuint)(byte)(l2 >> 8) + 530]) + c[(nuint)(byte)l2 + 786]) ^ c[1];
            r3 ^= (((d[(nuint)(l3 >> 24) + 18] + d[(nuint)(byte)(l3 >> 16) + 274]) ^ d[(nuint)(byte)(l3 >> 8) + 530]) + d[(nuint)(byte)l3 + 786]) ^ d[1];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[2];
            l1 ^= (((b[(nuint)(r1 >> 24) + 18] + b[(nuint)(byte)(r1 >> 16) + 274]) ^ b[(nuint)(byte)(r1 >> 8) + 530]) + b[(nuint)(byte)r1 + 786]) ^ b[2];
            l2 ^= (((c[(nuint)(r2 >> 24) + 18] + c[(nuint)(byte)(r2 >> 16) + 274]) ^ c[(nuint)(byte)(r2 >> 8) + 530]) + c[(nuint)(byte)r2 + 786]) ^ c[2];
            l3 ^= (((d[(nuint)(r3 >> 24) + 18] + d[(nuint)(byte)(r3 >> 16) + 274]) ^ d[(nuint)(byte)(r3 >> 8) + 530]) + d[(nuint)(byte)r3 + 786]) ^ d[2];
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[3];
            r1 ^= (((b[(nuint)(l1 >> 24) + 18] + b[(nuint)(byte)(l1 >> 16) + 274]) ^ b[(nuint)(byte)(l1 >> 8) + 530]) + b[(nuint)(byte)l1 + 786]) ^ b[3];
            r2 ^= (((c[(nuint)(l2 >> 24) + 18] + c[(nuint)(byte)(l2 >> 16) + 274]) ^ c[(nuint)(byte)(l2 >> 8) + 530]) + c[(nuint)(byte)l2 + 786]) ^ c[3];
            r3 ^= (((d[(nuint)(l3 >> 24) + 18] + d[(nuint)(byte)(l3 >> 16) + 274]) ^ d[(nuint)(byte)(l3 >> 8) + 530]) + d[(nuint)(byte)l3 + 786]) ^ d[3];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[4];
            l1 ^= (((b[(nuint)(r1 >> 24) + 18] + b[(nuint)(byte)(r1 >> 16) + 274]) ^ b[(nuint)(byte)(r1 >> 8) + 530]) + b[(nuint)(byte)r1 + 786]) ^ b[4];
            l2 ^= (((c[(nuint)(r2 >> 24) + 18] + c[(nuint)(byte)(r2 >> 16) + 274]) ^ c[(nuint)(byte)(r2 >> 8) + 530]) + c[(nuint)(byte)r2 + 786]) ^ c[4];
            l3 ^= (((d[(nuint)(r3 >> 24) + 18] + d[(nuint)(byte)(r3 >> 16) + 274]) ^ d[(nuint)(byte)(r3 >> 8) + 530]) + d[(nuint)(byte)r3 + 786]) ^ d[4];
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[5];
            r1 ^= (((b[(nuint)(l1 >> 24) + 18] + b[(nuint)(byte)(l1 >> 16) + 274]) ^ b[(nuint)(byte)(l1 >> 8) + 530]) + b[(nuint)(byte)l1 + 786]) ^ b[5];
            r2 ^= (((c[(nuint)(l2 >> 24) + 18] + c[(nuint)(byte)(l2 >> 16) + 274]) ^ c[(nuint)(byte)(l2 >> 8) + 530]) + c[(nuint)(byte)l2 + 786]) ^ c[5];
            r3 ^= (((d[(nuint)(l3 >> 24) + 18] + d[(nuint)(byte)(l3 >> 16) + 274]) ^ d[(nuint)(byte)(l3 >> 8) + 530]) + d[(nuint)(byte)l3 + 786]) ^ d[5];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[6];
            l1 ^= (((b[(nuint)(r1 >> 24) + 18] + b[(nuint)(byte)(r1 >> 16) + 274]) ^ b[(nuint)(byte)(r1 >> 8) + 530]) + b[(nuint)(byte)r1 + 786]) ^ b[6];
            l2 ^= (((c[(nuint)(r2 >> 24) + 18] + c[(nuint)(byte)(r2 >> 16) + 274]) ^ c[(nuint)(byte)(r2 >> 8) + 530]) + c[(nuint)(byte)r2 + 786]) ^ c[6];
            l3 ^= (((d[(nuint)(r3 >> 24) + 18] + d[(nuint)(byte)(r3 >> 16) + 274]) ^ d[(nuint)(byte)(r3 >> 8) + 530]) + d[(nuint)(byte)r3 + 786]) ^ d[6];
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[7];
            r1 ^= (((b[(nuint)(l1 >> 24) + 18] + b[(nuint)(byte)(l1 >> 16) + 274]) ^ b[(nuint)(byte)(l1 >> 8) + 530]) + b[(nuint)(byte)l1 + 786]) ^ b[7];
            r2 ^= (((c[(nuint)(l2 >> 24) + 18] + c[(nuint)(byte)(l2 >> 16) + 274]) ^ c[(nuint)(byte)(l2 >> 8) + 530]) + c[(nuint)(byte)l2 + 786]) ^ c[7];
            r3 ^= (((d[(nuint)(l3 >> 24) + 18] + d[(nuint)(byte)(l3 >> 16) + 274]) ^ d[(nuint)(byte)(l3 >> 8) + 530]) + d[(nuint)(byte)l3 + 786]) ^ d[7];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[8];
            l1 ^= (((b[(nuint)(r1 >> 24) + 18] + b[(nuint)(byte)(r1 >> 16) + 274]) ^ b[(nuint)(byte)(r1 >> 8) + 530]) + b[(nuint)(byte)r1 + 786]) ^ b[8];
            l2 ^= (((c[(nuint)(r2 >> 24) + 18] + c[(nuint)(byte)(r2 >> 16) + 274]) ^ c[(nuint)(byte)(r2 >> 8) + 530]) + c[(nuint)(byte)r2 + 786]) ^ c[8];
            l3 ^= (((d[(nuint)(r3 >> 24) + 18] + d[(nuint)(byte)(r3 >> 16) + 274]) ^ d[(nuint)(byte)(r3 >> 8) + 530]) + d[(nuint)(byte)r3 + 786]) ^ d[8];
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[9];
            r1 ^= (((b[(nuint)(l1 >> 24) + 18] + b[(nuint)(byte)(l1 >> 16) + 274]) ^ b[(nuint)(byte)(l1 >> 8) + 530]) + b[(nuint)(byte)l1 + 786]) ^ b[9];
            r2 ^= (((c[(nuint)(l2 >> 24) + 18] + c[(nuint)(byte)(l2 >> 16) + 274]) ^ c[(nuint)(byte)(l2 >> 8) + 530]) + c[(nuint)(byte)l2 + 786]) ^ c[9];
            r3 ^= (((d[(nuint)(l3 >> 24) + 18] + d[(nuint)(byte)(l3 >> 16) + 274]) ^ d[(nuint)(byte)(l3 >> 8) + 530]) + d[(nuint)(byte)l3 + 786]) ^ d[9];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[10];
            l1 ^= (((b[(nuint)(r1 >> 24) + 18] + b[(nuint)(byte)(r1 >> 16) + 274]) ^ b[(nuint)(byte)(r1 >> 8) + 530]) + b[(nuint)(byte)r1 + 786]) ^ b[10];
            l2 ^= (((c[(nuint)(r2 >> 24) + 18] + c[(nuint)(byte)(r2 >> 16) + 274]) ^ c[(nuint)(byte)(r2 >> 8) + 530]) + c[(nuint)(byte)r2 + 786]) ^ c[10];
            l3 ^= (((d[(nuint)(r3 >> 24) + 18] + d[(nuint)(byte)(r3 >> 16) + 274]) ^ d[(nuint)(byte)(r3 >> 8) + 530]) + d[(nuint)(byte)r3 + 786]) ^ d[10];
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[11];
            r1 ^= (((b[(nuint)(l1 >> 24) + 18] + b[(nuint)(byte)(l1 >> 16) + 274]) ^ b[(nuint)(byte)(l1 >> 8) + 530]) + b[(nuint)(byte)l1 + 786]) ^ b[11];
            r2 ^= (((c[(nuint)(l2 >> 24) + 18] + c[(nuint)(byte)(l2 >> 16) + 274]) ^ c[(nuint)(byte)(l2 >> 8) + 530]) + c[(nuint)(byte)l2 + 786]) ^ c[11];
            r3 ^= (((d[(nuint)(l3 >> 24) + 18] + d[(nuint)(byte)(l3 >> 16) + 274]) ^ d[(nuint)(byte)(l3 >> 8) + 530]) + d[(nuint)(byte)l3 + 786]) ^ d[11];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[12];
            l1 ^= (((b[(nuint)(r1 >> 24) + 18] + b[(nuint)(byte)(r1 >> 16) + 274]) ^ b[(nuint)(byte)(r1 >> 8) + 530]) + b[(nuint)(byte)r1 + 786]) ^ b[12];
            l2 ^= (((c[(nuint)(r2 >> 24) + 18] + c[(nuint)(byte)(r2 >> 16) + 274]) ^ c[(nuint)(byte)(r2 >> 8) + 530]) + c[(nuint)(byte)r2 + 786]) ^ c[12];
            l3 ^= (((d[(nuint)(r3 >> 24) + 18] + d[(nuint)(byte)(r3 >> 16) + 274]) ^ d[(nuint)(byte)(r3 >> 8) + 530]) + d[(nuint)(byte)r3 + 786]) ^ d[12];
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[13];
            r1 ^= (((b[(nuint)(l1 >> 24) + 18] + b[(nuint)(byte)(l1 >> 16) + 274]) ^ b[(nuint)(byte)(l1 >> 8) + 530]) + b[(nuint)(byte)l1 + 786]) ^ b[13];
            r2 ^= (((c[(nuint)(l2 >> 24) + 18] + c[(nuint)(byte)(l2 >> 16) + 274]) ^ c[(nuint)(byte)(l2 >> 8) + 530]) + c[(nuint)(byte)l2 + 786]) ^ c[13];
            r3 ^= (((d[(nuint)(l3 >> 24) + 18] + d[(nuint)(byte)(l3 >> 16) + 274]) ^ d[(nuint)(byte)(l3 >> 8) + 530]) + d[(nuint)(byte)l3 + 786]) ^ d[13];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[14];
            l1 ^= (((b[(nuint)(r1 >> 24) + 18] + b[(nuint)(byte)(r1 >> 16) + 274]) ^ b[(nuint)(byte)(r1 >> 8) + 530]) + b[(nuint)(byte)r1 + 786]) ^ b[14];
            l2 ^= (((c[(nuint)(r2 >> 24) + 18] + c[(nuint)(byte)(r2 >> 16) + 274]) ^ c[(nuint)(byte)(r2 >> 8) + 530]) + c[(nuint)(byte)r2 + 786]) ^ c[14];
            l3 ^= (((d[(nuint)(r3 >> 24) + 18] + d[(nuint)(byte)(r3 >> 16) + 274]) ^ d[(nuint)(byte)(r3 >> 8) + 530]) + d[(nuint)(byte)r3 + 786]) ^ d[14];
            r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[15];
            r1 ^= (((b[(nuint)(l1 >> 24) + 18] + b[(nuint)(byte)(l1 >> 16) + 274]) ^ b[(nuint)(byte)(l1 >> 8) + 530]) + b[(nuint)(byte)l1 + 786]) ^ b[15];
            r2 ^= (((c[(nuint)(l2 >> 24) + 18] + c[(nuint)(byte)(l2 >> 16) + 274]) ^ c[(nuint)(byte)(l2 >> 8) + 530]) + c[(nuint)(byte)l2 + 786]) ^ c[15];
            r3 ^= (((d[(nuint)(l3 >> 24) + 18] + d[(nuint)(byte)(l3 >> 16) + 274]) ^ d[(nuint)(byte)(l3 >> 8) + 530]) + d[(nuint)(byte)l3 + 786]) ^ d[15];
            l0 ^= (((a[(nuint)(r0 >> 24) + 18] + a[(nuint)(byte)(r0 >> 16) + 274]) ^ a[(nuint)(byte)(r0 >> 8) + 530]) + a[(nuint)(byte)r0 + 786]) ^ a[16];
            l1 ^= (((b[(nuint)(r1 >> 24) + 18] + b[(nuint)(byte)(r1 >> 16) + 274]) ^ b[(nuint)(byte)(r1 >> 8) + 530]) + b[(nuint)(byte)r1 + 786]) ^ b[16];
            l2 ^= (((c[(nuint)(r2 >> 24) + 18] + c[(nuint)(byte)(r2 >> 16) + 274]) ^ c[(nuint)(byte)(r2 >> 8) + 530]) + c[(nuint)(byte)r2 + 786]) ^ c[16];
            l3 ^= (((d[(nuint)(r3 >> 24) + 18] + d[(nuint)(byte)(r3 >> 16) + 274]) ^ d[(nuint)(byte)(r3 >> 8) + 530]) + d[(nuint)(byte)r3 + 786]) ^ d[16];
            xl0 = r0 ^ a[17]; xr0 = l0;
            a[i] = xl0; a[i + 1] = xr0;
            xl1 = r1 ^ b[17]; xr1 = l1;
            b[i] = xl1; b[i + 1] = xr1;
            xl2 = r2 ^ c[17]; xr2 = l2;
            c[i] = xl2; c[i + 1] = xr2;
            xl3 = r3 ^ d[17]; xr3 = l3;
            d[i] = xl3; d[i + 1] = xr3;
        }
    }

    static void Encode(ReadOnlySpan<byte> d, StringBuilder sb)
    {
        int i = 0;
        while (i < d.Length)
        {
            int c1 = d[i++];
            sb.Append(Alphabet[c1 >> 2]);
            c1 = (c1 & 0x03) << 4;
            if (i >= d.Length) { sb.Append(Alphabet[c1]); break; }
            int c2 = d[i++];
            c1 |= c2 >> 4;
            sb.Append(Alphabet[c1]);
            c1 = (c2 & 0x0f) << 2;
            if (i >= d.Length) { sb.Append(Alphabet[c1]); break; }
            c2 = d[i++];
            c1 |= c2 >> 6;
            sb.Append(Alphabet[c1]);
            sb.Append(Alphabet[c2 & 0x3f]);
        }
    }

    static bool Decode(ReadOnlySpan<char> s, Span<byte> outp)
    {
        int o = 0, i = 0;
        while (o < outp.Length && i < s.Length)
        {
            int c1 = Val(s, i++), c2 = Val(s, i++);
            if (c1 < 0 || c2 < 0) return false;
            outp[o++] = (byte)((c1 << 2) | ((c2 & 0x30) >> 4));
            if (o >= outp.Length || i >= s.Length) break;
            int c3 = Val(s, i++);
            if (c3 < 0) return false;
            outp[o++] = (byte)(((c2 & 0x0f) << 4) | ((c3 & 0x3c) >> 2));
            if (o >= outp.Length || i >= s.Length) break;
            int c4 = Val(s, i++);
            if (c4 < 0) return false;
            outp[o++] = (byte)(((c3 & 0x03) << 6) | c4);
        }
        return o == outp.Length;
    }

    static int Val(ReadOnlySpan<char> s, int i) => i < s.Length && s[i] < 128 ? Index[s[i]] : -1;
}
