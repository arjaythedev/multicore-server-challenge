using System.Text;

namespace Conduit.Auth;

/// <summary>bcrypt at cost 10, as SPEC.md requires.</summary>
public static class Passwords
{
    private const int WorkFactor = 10;

    /// <summary>bcrypt only uses the first 72 bytes, so longer passwords are rejected instead of silently truncated.</summary>
    public const int MaxBytes = 72;

    public static bool TooLong(string password) => Encoding.UTF8.GetByteCount(password) > MaxBytes;

    public static string Hash(string password) => BCrypt.Net.BCrypt.HashPassword(password, WorkFactor);

    public static bool Verify(string password, string hash) => BCrypt.Net.BCrypt.Verify(password, hash);
}
