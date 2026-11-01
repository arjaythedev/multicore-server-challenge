using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace Conduit.Benchmarks;

/// <summary>
/// The reference the server's own bcrypt (Bcrypt.cs, BcryptCore.cs) is checked and timed against: bcrypt at cost 10 through the system's libcrypt (libxcrypt, which ships Solar Designer's crypt_blowfish): the same
/// algorithm and hash format as any other bcrypt, about a quarter faster per hash than BCrypt.Net-Next on the dev box.
/// Hashes are "$2a$10$..." like the seed's. libcrypt treats the password as a C string, so a NUL byte would silently
/// cut it short: such passwords, and passwords over bcrypt's 72 bytes, are refused instead.
/// </summary>
public static unsafe class LibcryptReference
{
    private const int Cost = 10;
    private const int MaxPasswordBytes = 72;
    private const int HashLength = 60;
    private const int CryptDataSize = 32768;   // sizeof(struct crypt_data), which crypt_r wants zeroed before first use
    private const int GensaltOutputSize = 192; // CRYPT_GENSALT_OUTPUT_SIZE

    [DllImport("libcrypt.so.1")]
    private static extern byte* crypt_r(byte* phrase, byte* setting, byte* data);

    [DllImport("libcrypt.so.1")]
    private static extern byte* crypt_gensalt_rn(byte* prefix, nuint count, byte* randomBytes, int randomByteCount, byte* output, int outputSize);

    // crypt_r keeps its state in a caller-supplied buffer. One pinned buffer per thread: no locking, no allocation per hash.
    [ThreadStatic] private static byte[]? t_data;

    private static byte[] Data() => t_data ??= GC.AllocateArray<byte>(CryptDataSize, pinned: true);

    /// <summary>The password as UTF-8 plus a terminating NUL. False if it is over 72 bytes or contains a NUL.</summary>
    private static bool TryEncode(string password, Span<byte> buffer)
    {
        if (Encoding.UTF8.GetByteCount(password) > MaxPasswordBytes || password.Contains('\0')) return false;
        buffer.Clear();
        Encoding.UTF8.GetBytes(password, buffer);
        return true;
    }

    /// <summary>Hashes a password with a fresh random salt. False for a password bcrypt cannot take (see the class summary).</summary>
    public static bool TryHash(string password, out string hash)
    {
        hash = "";
        Span<byte> pw = stackalloc byte[MaxPasswordBytes + 1];
        try
        {
            if (!TryEncode(password, pw)) return false;

            Span<byte> random = stackalloc byte[16];
            RandomNumberGenerator.Fill(random);
            byte* setting = stackalloc byte[GensaltOutputSize];

            fixed (byte* p = pw)
            fixed (byte* r = random)
            fixed (byte* prefix = "$2a$"u8)
            fixed (byte* data = Data())
            {
                if (crypt_gensalt_rn(prefix, Cost, r, random.Length, setting, GensaltOutputSize) == null)
                    throw new InvalidOperationException("libcrypt could not make a bcrypt salt");
                var result = crypt_r(p, setting, data);
                var text = result == null ? "" : Marshal.PtrToStringUTF8((nint)result) ?? "";
                if (!IsAcceptableHash(text))
                    throw new InvalidOperationException("libcrypt did not return a bcrypt hash");
                hash = text;
                return true;
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(pw);
        }
    }

    /// <summary>
    /// A stored hash we will verify against: 60 characters, "$2a$", "$2b$" or "$2y$" (the versions crypt_blowfish computes
    /// correctly) and our cost, 10. Anything else cannot be one of ours, and a hash with a high cost would make crypt_r
    /// spend seconds or minutes of CPU.
    /// </summary>
    private static bool IsAcceptableHash(string hash) =>
        hash.Length == HashLength
        && hash[0] == '$' && hash[1] == '2' && hash[2] is 'a' or 'b' or 'y' && hash[3] == '$'
        && hash[4] == '1' && hash[5] == '0' && hash[6] == '$'
        && Encoding.UTF8.GetByteCount(hash) == HashLength; // ASCII only

    /// <summary>True if the password matches the stored bcrypt hash.</summary>
    public static bool Verify(string password, string hash)
    {
        if (!IsAcceptableHash(hash)) return false;
        Span<byte> pw = stackalloc byte[MaxPasswordBytes + 1];
        try
        {
            if (!TryEncode(password, pw)) return false;
            // The stored hash is also the setting: crypt_r reads the cost and salt from its first 29 characters.
            Span<byte> stored = stackalloc byte[HashLength + 1];
            stored.Clear();
            Encoding.UTF8.GetBytes(hash, stored);

            fixed (byte* p = pw)
            fixed (byte* s = stored)
            fixed (byte* data = Data())
            {
                var result = crypt_r(p, s, data);
                if (result == null) return false;
                var computed = MemoryMarshal.CreateReadOnlySpanFromNullTerminated(result);
                // An unsupported or malformed setting comes back as a short failure token, never as a 60-character hash.
                return computed.Length == HashLength && CryptographicOperations.FixedTimeEquals(computed, stored[..HashLength]);
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(pw);
        }
    }

    /// <summary>Fails fast at startup, with a clear message, if libcrypt is missing or does not compute real bcrypt.</summary>
    public static void SelfTest()
    {
        // A known answer from the crypt_blowfish test suite (cost 5, so it takes a millisecond): this libcrypt computes
        // bcrypt, not just something that looks like it.
        const string knownHash = "$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW";
        if (Crypt("U*U", knownHash) != knownHash)
            throw new InvalidOperationException("libcrypt does not reproduce the bcrypt known-answer test");

        if (!TryHash("self-test", out var hash) || !Verify("self-test", hash) || Verify("self-tesT", hash))
            throw new InvalidOperationException("libcrypt bcrypt hash/verify round trip failed");
    }

    /// <summary>crypt_r as is, for the self-test: any setting, no checks. Returns null on failure.</summary>
    private static string? Crypt(string password, string setting)
    {
        Span<byte> pw = stackalloc byte[MaxPasswordBytes + 1];
        Span<byte> set = stackalloc byte[HashLength + 1];
        try
        {
            if (!TryEncode(password, pw) || Encoding.UTF8.GetByteCount(setting) > HashLength) return null;
            set.Clear();
            Encoding.UTF8.GetBytes(setting, set);
            fixed (byte* p = pw)
            fixed (byte* s = set)
            fixed (byte* data = Data())
            {
                var result = crypt_r(p, s, data);
                return result == null ? null : Marshal.PtrToStringUTF8((nint)result);
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(pw);
        }
    }
}
