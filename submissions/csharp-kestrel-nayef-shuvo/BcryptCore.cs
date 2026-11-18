using System.Buffers.Binary;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Conduit;

/// <summary>One bcrypt computation: the password bytes (at most 72, no NUL) and the 16-byte salt in, 24 bytes of ciphertext out.</summary>
internal class BcryptItem
{
    internal byte[] Password = [];
    internal byte[] Salt = new byte[16];
    internal byte[] Output = new byte[24];
}

/// <summary>
/// bcrypt's EksBlowfish, computing several hashes at once. One Blowfish hash is a long chain of dependent steps, so a
/// core spends most of its time waiting on its own previous result; running two to four independent hashes in lockstep
/// (BcryptLanes.g.cs, written by Tools/gen_bcrypt.py) fills that waiting time with the other hashes' work.
/// This class is the algorithm: key and salt setup, the 2^cost loop (in the lanes), and the final encryption.
/// Everything outside it (hash string format, salts, batching, threads) is in Bcrypt.cs and BcryptPool.cs.
/// </summary>
internal static unsafe partial class BcryptCore
{
    internal const int StateWords = 18 + 4 * 256; // P-array, then four S-boxes
    private const int KeyWords = 18;

    /// <summary>The memory one thread needs to hash <see cref="MaxLanes"/> passwords at once. One per worker thread.</summary>
    internal sealed class Workspace : IDisposable
    {
        internal readonly uint* State = (uint*)NativeMemory.AlignedAlloc((nuint)(MaxLanes * StateWords * sizeof(uint)), 64);
        internal readonly uint* Keys = (uint*)NativeMemory.AlignedAlloc((nuint)(MaxLanes * KeyWords * sizeof(uint)), 64);
        internal readonly uint* SaltKeys = (uint*)NativeMemory.AlignedAlloc((nuint)(MaxLanes * KeyWords * sizeof(uint)), 64);

        private int _freed;

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _freed, 1) != 0) return; // the finalizer calls this too: free only once
            NativeMemory.AlignedFree(State);
            NativeMemory.AlignedFree(Keys);
            NativeMemory.AlignedFree(SaltKeys);
            GC.SuppressFinalize(this);
        }

        ~Workspace() => Dispose();
    }

    // "OrpheanBeholderScryDoubt": the 24 bytes bcrypt encrypts 64 times.
    private static ReadOnlySpan<byte> Magic => "OrpheanBeholderScryDoubt"u8;

    /// <summary>Hashes every item with the given cost, <see cref="MaxLanes"/> at a time, and fills in each item's Output.</summary>
    internal static void Compute(Workspace ws, int cost, ReadOnlySpan<BcryptItem> items)
    {
        for (var done = 0; done < items.Length;)
        {
            var n = Math.Min(MaxLanes, items.Length - done);
            Run(ws, cost, items.Slice(done, n));
            done += n;
        }
    }

    private static void Run(Workspace ws, int cost, ReadOnlySpan<BcryptItem> group)
    {
        var n = group.Length;
        uint* salt = stackalloc uint[4];
        for (var k = 0; k < n; k++)
        {
            var item = group[k];
            uint* state = ws.State + k * StateWords;
            BlowfishConstants.Initial.CopyTo(new Span<uint>(state, StateWords));
            CyclicWords(item.Password, includeNul: true, ws.Keys + k * KeyWords);
            CyclicWords(item.Salt, includeNul: false, ws.SaltKeys + k * KeyWords);
            for (var i = 0; i < 4; i++) salt[i] = BinaryPrimitives.ReadUInt32BigEndian(item.Salt.AsSpan(i * 4, 4));
            ExpandSalted(state, ws.Keys + k * KeyWords, salt);
        }

        var iterations = 1 << cost;
        RunLoop(n, ws.State, ws.Keys, ws.SaltKeys, iterations);

        for (var k = 0; k < n; k++) Finish(ws.State + k * StateWords + 18, group[k].Output);
    }

    /// <summary>72 bytes of the data repeated (and, for a password, its terminating NUL) as 18 big-endian words.</summary>
    private static void CyclicWords(ReadOnlySpan<byte> data, bool includeNul, uint* words)
    {
        Span<byte> cycle = stackalloc byte[73];
        data.CopyTo(cycle);
        var length = data.Length;
        if (includeNul) cycle[length++] = 0;
        length = Math.Min(length, 72); // bcrypt only uses the first 72 bytes of the password and its NUL
        for (var w = 0; w < KeyWords; w++)
        {
            uint word = 0;
            for (var b = 0; b < 4; b++) word = (word << 8) | cycle[(w * 4 + b) % length];
            words[w] = word;
        }
    }

    /// <summary>The first key expansion: like the loop's steps, but each block is also XORed with the salt.</summary>
    private static void ExpandSalted(uint* state, uint* key, uint* salt)
    {
        uint* s = state + 18;
        for (var i = 0; i < 18; i++) state[i] ^= key[i];
        uint l = 0, r = 0;
        var sw = 0;
        for (var i = 0; i < StateWords; i += 2)
        {
            l ^= salt[sw];
            r ^= salt[sw + 1];
            sw ^= 2;
            Encrypt(s, ref l, ref r);
            state[i] = l;
            state[i + 1] = r;
        }
    }

    /// <summary>Encrypts "OrpheanBeholderScryDoubt" 64 times (three blocks, each on its own) with the finished state.</summary>
    private static void Finish(uint* s, byte[] output)
    {
        uint* c = stackalloc uint[6];
        for (var i = 0; i < 6; i++) c[i] = BinaryPrimitives.ReadUInt32BigEndian(Magic.Slice(i * 4, 4));
        for (var round = 0; round < 64; round++)
            for (var b = 0; b < 3; b++) Encrypt(s, ref c[b * 2], ref c[b * 2 + 1]);
        for (var i = 0; i < 6; i++) BinaryPrimitives.WriteUInt32BigEndian(output.AsSpan(i * 4, 4), c[i]);
    }

    /// <summary>One Blowfish block, one hash: used for the one-off steps; the hot loop is in the lanes.</summary>
    private static void Encrypt(uint* s, ref uint l, ref uint r)
    {
        var a = l ^ s[-18];
        var b = r;
        for (var n = 1; n <= 16; n += 2)
        {
            b ^= F(s, a) ^ s[n - 18];
            a ^= F(s, b) ^ s[n + 1 - 18];
        }
        l = b ^ s[-1];
        r = a;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static uint F(uint* s, uint x) =>
        ((s[x >> 24] + s[256 + ((x >> 16) & 0xFF)]) ^ s[512 + ((x >> 8) & 0xFF)]) + s[768 + (x & 0xFF)];
}
