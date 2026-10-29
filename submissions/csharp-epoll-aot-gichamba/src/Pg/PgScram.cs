using System.Security.Cryptography;
using System.Text;

namespace Conduit.Pg;

/// <summary>Client side of SCRAM-SHA-256 (RFC 5802, RFC 7677) without channel binding.</summary>
/// <remarks>The password is used as UTF-8 bytes. SASLprep is not applied; that is only different for non-ASCII passwords.</remarks>
internal sealed class PgScram {
    /// <summary>The password as UTF-8 bytes.</summary>
    private readonly byte[] _password;
    /// <summary>The client nonce.</summary>
    private readonly string _nonce;
    /// <summary>The client-first-message without the GS2 header.</summary>
    private readonly string _firstBare;
    /// <summary>The AuthMessage of the exchange, set by <see cref="ClientFinal"/>.</summary>
    private string _authMessage = "";
    /// <summary>The server key, set by <see cref="ClientFinal"/> and used to check the server signature.</summary>
    private byte[]? _serverKey;

    /// <summary>Starts an exchange with the given client nonce.</summary>
    public PgScram(string user, string password, string clientNonce) {
        _password = Encoding.UTF8.GetBytes(password);
        _nonce = clientNonce;
        _firstBare = "n=" + user.Replace("=", "=3D").Replace(",", "=2C") + ",r=" + clientNonce;
    }

    /// <summary>The client-first-message, sent in SASLInitialResponse.</summary>
    public string ClientFirst => "n,," + _firstBare;

    /// <summary>Builds the client-final-message from the server-first-message.</summary>
    public string ClientFinal(string serverFirst) {
        string? r = null, s = null, i = null;
        foreach (string part in serverFirst.Split(',')) {
            if (part.StartsWith("r=", StringComparison.Ordinal)) {
                r = part[2..];
            } else if (part.StartsWith("s=", StringComparison.Ordinal)) {
                s = part[2..];
            } else if (part.StartsWith("i=", StringComparison.Ordinal)) {
                i = part[2..];
            }
        }
        if (r is null || s is null || i is null || !int.TryParse(i, out int iterations) || iterations < 1) {
            throw new PgException("bad SCRAM server-first-message");
        }

        if (!r.StartsWith(_nonce, StringComparison.Ordinal) || r.Length == _nonce.Length) {
            throw new PgException("SCRAM server nonce does not extend the client nonce");
        }

        byte[] salt = Convert.FromBase64String(s);
        byte[] salted = Rfc2898DeriveBytes.Pbkdf2(_password, salt, iterations, HashAlgorithmName.SHA256, 32);
        byte[] clientKey = HMACSHA256.HashData(salted, "Client Key"u8);
        byte[] storedKey = SHA256.HashData(clientKey);
        string withoutProof = "c=biws,r=" + r;
        _authMessage = _firstBare + "," + serverFirst + "," + withoutProof;
        byte[] signature = HMACSHA256.HashData(storedKey, Encoding.UTF8.GetBytes(_authMessage));
        for (int k = 0; k < signature.Length; k++) {
            signature[k] ^= clientKey[k];
        }

        _serverKey = HMACSHA256.HashData(salted, "Server Key"u8);
        return withoutProof + ",p=" + Convert.ToBase64String(signature);
    }

    /// <summary>Checks the server-final-message. Throws if the server proof is wrong or the server sent an error.</summary>
    public void VerifyServerFinal(string serverFinal) {
        if (_serverKey is null) {
            throw new InvalidOperationException("ClientFinal was not called");
        }

        if (!serverFinal.StartsWith("v=", StringComparison.Ordinal)) {
            throw new PgException("SCRAM failed: " + serverFinal);
        }

        byte[] expected = HMACSHA256.HashData(_serverKey, Encoding.UTF8.GetBytes(_authMessage));
        byte[] got;
        try {
            got = Convert.FromBase64String(serverFinal[2..]);
        } catch (FormatException) {
            throw new PgException("bad SCRAM server signature");
        }
        if (!CryptographicOperations.FixedTimeEquals(expected, got)) {
            throw new PgException("SCRAM server signature does not match");
        }
    }
}
