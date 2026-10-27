using Conduit.Auth;

namespace Conduit.Api;

/// <summary>Password hashing and checking as the API needs it. <see cref="BcryptPasswords"/> is the real one.</summary>
public interface IPasswords {
    /// <summary>Hashes <paramref name="password"/> with a fresh salt; <paramref name="done"/> gets the stored form, on another thread.</summary>
    void Hash(byte[] password, Action<string> done);

    /// <summary>Checks <paramref name="password"/> against <paramref name="storedHash"/>; <paramref name="done"/> gets the result, on another thread.</summary>
    void Verify(byte[] password, string storedHash, Action<bool> done);
}

/// <summary><see cref="IPasswords"/> over the bcrypt threads of <see cref="BcryptService"/>.</summary>
public sealed class BcryptPasswords : IPasswords {
    /// <summary>The bcrypt threads that do the work.</summary>
    private readonly BcryptService _bcrypt;

    /// <summary>Wraps <paramref name="bcrypt"/>.</summary>
    public BcryptPasswords(BcryptService bcrypt) => _bcrypt = bcrypt;

    /// <inheritdoc />
    public void Hash(byte[] password, Action<string> done) => _bcrypt.Hash(password, done);

    /// <inheritdoc />
    public void Verify(byte[] password, string storedHash, Action<bool> done) => _bcrypt.Verify(password, storedHash, done);
}
