using System;
using System.Security.Cryptography;
using System.Text;

/// <summary>SCRAM-SHA-256 without channel binding, as Postgres runs it (RFC 5802, RFC 7677). The server proves it knows
/// the password too: its signature is checked before the login counts.</summary>
sealed class Scram(string password)
{
    readonly string _nonce = Convert.ToBase64String(RandomNumberGenerator.GetBytes(18));
    byte[]? _serverSignature;

    string ClientFirstBare => "n=,r=" + _nonce;

    /// <summary>The client-first-message: no channel binding ("n,,"), our nonce.</summary>
    public byte[] ClientFirst() => Encoding.ASCII.GetBytes("n,," + ClientFirstBare);

    /// <summary>The client-final-message with our proof, for the server-first-message.</summary>
    public byte[] ClientFinal(ReadOnlySpan<byte> serverFirstBytes)
    {
        string serverFirst = Encoding.ASCII.GetString(serverFirstBytes);
        string[] parts = serverFirst.Split(',');
        if (parts.Length < 3 || !parts[0].StartsWith("r=" + _nonce, StringComparison.Ordinal) || !parts[1].StartsWith("s=", StringComparison.Ordinal)
            || !parts[2].StartsWith("i=", StringComparison.Ordinal))
            throw new InvalidOperationException("malformed SCRAM server-first-message");
        byte[] salt = Convert.FromBase64String(parts[1][2..]);
        int iterations = int.Parse(parts[2].AsSpan(2), System.Globalization.CultureInfo.InvariantCulture);
        string withoutProof = "c=biws,r=" + parts[0][2..]; // biws = base64("n,,")
        byte[] authMessage = Encoding.ASCII.GetBytes(ClientFirstBare + "," + serverFirst + "," + withoutProof);
        Span<byte> salted = stackalloc byte[32], clientKey = stackalloc byte[32], storedKey = stackalloc byte[32], proof = stackalloc byte[32];
        Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(password), salt, salted, iterations, HashAlgorithmName.SHA256);
        HMACSHA256.HashData(salted, "Client Key"u8, clientKey);
        SHA256.HashData(clientKey, storedKey);
        HMACSHA256.HashData(storedKey, authMessage, proof);
        for (int i = 0; i < 32; i++) proof[i] ^= clientKey[i];
        Span<byte> serverKey = stackalloc byte[32];
        HMACSHA256.HashData(salted, "Server Key"u8, serverKey);
        _serverSignature = HMACSHA256.HashData(serverKey, authMessage);
        return Encoding.ASCII.GetBytes(withoutProof + ",p=" + Convert.ToBase64String(proof));
    }

    /// <summary>Checks the server-final-message's signature.</summary>
    public void VerifyServerFinal(ReadOnlySpan<byte> serverFinalBytes)
    {
        string verifier = Encoding.ASCII.GetString(serverFinalBytes).Split(',')[0];
        if (_serverSignature is null || !verifier.StartsWith("v=", StringComparison.Ordinal)
            || !CryptographicOperations.FixedTimeEquals(Convert.FromBase64String(verifier[2..]), _serverSignature))
            throw new InvalidOperationException("the SCRAM server signature doesn't match");
    }
}
