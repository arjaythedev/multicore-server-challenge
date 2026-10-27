using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace Conduit.Auth;

/// <summary>The native bcrypt calls the service needs, so tests can swap in a faulty one.</summary>
internal interface IBcryptNative {
    /// <summary>
    /// Hashes <c>keys.Length</c> (1 to 8) passwords, each with its own 29-character setting, and writes the
    /// 60-character hashes to <paramref name="outputs"/>. Returns false when any lane failed; that lane's output
    /// then starts with <c>*</c>.
    /// </summary>
    bool Hash(ReadOnlySpan<byte[]> keys, ReadOnlySpan<string> settings, Span<string> outputs);

    /// <summary>Builds a <c>$2a$&lt;cost&gt;$&lt;salt&gt;</c> setting from 16 raw salt bytes.</summary>
    string Gensalt(int cost, ReadOnlySpan<byte> salt16);
}

/// <summary>P/Invoke wrapper over <c>libconduit_bcrypt.so</c> (crypt_blowfish plus interleaved lanes).</summary>
internal sealed unsafe partial class NativeBcrypt : IBcryptNative {
    /// <summary>Most lanes the native code accepts in one call.</summary>
    public const int MaxLanes = 8;

    /// <summary>Bytes per key slot: up to 72 key bytes plus a NUL.</summary>
    private const int KeyStride = 73;
    /// <summary>Bytes per setting slot: 29 characters plus a NUL, with room to spare.</summary>
    private const int SettingStride = 32;
    /// <summary>Bytes per output slot; the native code needs at least 61.</summary>
    private const int OutputStride = 64;

    /// <summary><c>conduit_bcrypt_lanes</c> in bcrypt_lanes.c: hashes <paramref name="n"/> passwords. Returns 0 when every lane worked.</summary>
    [LibraryImport("conduit_bcrypt")]
    private static partial int conduit_bcrypt_lanes(int n, byte** keys, byte** settings, byte** outputs, int outputSize);

    /// <summary><c>conduit_bcrypt_gensalt</c> in bcrypt_lanes.c: writes a <c>$2a$</c> setting from 16 salt bytes. Returns 0, or -1 for a bad cost.</summary>
    [LibraryImport("conduit_bcrypt")]
    private static partial int conduit_bcrypt_gensalt(int cost, byte* salt16, byte* output, int outputSize);

    /// <inheritdoc />
    public bool Hash(ReadOnlySpan<byte[]> keys, ReadOnlySpan<string> settings, Span<string> outputs) {
        int n = keys.Length;
        if (n is < 1 or > MaxLanes || settings.Length != n || outputs.Length != n) {
            throw new ArgumentException("Lane count must be 1 to 8 and equal across arguments.");
        }

        byte* keyBuf = stackalloc byte[MaxLanes * KeyStride];
        byte* settingBuf = stackalloc byte[MaxLanes * SettingStride];
        byte* outputBuf = stackalloc byte[MaxLanes * OutputStride];
        byte** keyPtrs = stackalloc byte*[MaxLanes];
        byte** settingPtrs = stackalloc byte*[MaxLanes];
        byte** outputPtrs = stackalloc byte*[MaxLanes];

        for (int i = 0; i < n; i++) {
            // bcrypt reads at most 72 key bytes; the C side reads up to the first NUL.
            byte* k = keyBuf + i * KeyStride;
            int len = Math.Min(keys[i].Length, KeyStride - 1);
            keys[i].AsSpan(0, len).CopyTo(new Span<byte>(k, len));
            k[len] = 0;

            byte* s = settingBuf + i * SettingStride;
            if (settings[i].Length > SettingStride - 1) {
                throw new ArgumentException("Setting is too long.");
            }

            int sl = Encoding.ASCII.GetBytes(settings[i], new Span<byte>(s, SettingStride - 1));
            s[sl] = 0;

            keyPtrs[i] = k;
            settingPtrs[i] = s;
            outputPtrs[i] = outputBuf + i * OutputStride;
            outputPtrs[i][0] = 0;
        }

        int rc = conduit_bcrypt_lanes(n, keyPtrs, settingPtrs, outputPtrs, OutputStride);
        CryptographicOperations.ZeroMemory(new Span<byte>(keyBuf, MaxLanes * KeyStride));

        for (int i = 0; i < n; i++) {
            ReadOnlySpan<byte> o = new(outputPtrs[i], OutputStride);
            int end = o.IndexOf((byte)0);
            outputs[i] = Encoding.ASCII.GetString(o[..(end < 0 ? OutputStride : end)]);
        }
        return rc == 0;
    }

    /// <inheritdoc />
    public string Gensalt(int cost, ReadOnlySpan<byte> salt16) {
        if (salt16.Length != 16) {
            throw new ArgumentException("Salt must be 16 bytes.", nameof(salt16));
        }

        byte* output = stackalloc byte[SettingStride];
        fixed (byte* salt = salt16) {
            if (conduit_bcrypt_gensalt(cost, salt, output, SettingStride) != 0) {
                throw new ArgumentException("Bad bcrypt cost.", nameof(cost));
            }
        }
        return Encoding.ASCII.GetString(new ReadOnlySpan<byte>(output, 29));
    }
}
