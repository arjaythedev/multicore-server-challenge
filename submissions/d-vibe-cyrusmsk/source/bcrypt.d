/**
 * Password hashing on top of the `passwd` package's bcrypt implementation.
 *
 * SPEC.md rule 7: every password is hashed with bcrypt cost 10 and every login
 * verifies against the stored hash, so this module only does the two things the
 * challenge needs: hash() for POST /api/users and PUT /api/user, verify() for
 * POST /api/users/login.
 */
module conduit.bcrypt;

import passwd;
import passwd.bcrypt;

/// SPEC.md: bcrypt cost 10.
enum bcryptCost = 10;

/// bcrypt's own limit: longer passwords are not usable (Go's bcrypt rejects them too).
private enum maxPasswordLength = 72;

/// Hashes a password into a crypt(3) string "$2b$10$<22-char salt><31-char digest>".
/// Returns null when the password is longer than bcrypt can hash.
string hashPassword(const(char)[] password) @safe
{
    if (password.length > maxPasswordLength) return null;

    // genSalt() reads 16 random bytes and writes them with bcrypt's base64 variant.
    const salt = Bcrypt.genSalt(bcryptCost);
    return password.crypt(idup(salt)).idup;
}

/// Verifies a password against a stored crypt(3) hash (any $2*$ bcrypt variant,
/// which is what the seeded database holds).
bool verifyPassword(const(char)[] password, const(char)[] storedHash) @safe
{
    if (password.length > maxPasswordLength) return false;
    try {
        return password.canCryptTo(storedHash);
    } catch (Exception e) {
        // A malformed hash is a failed login, not a 500.
        return false;
    }
}

@safe unittest
{
    // The seeded database stores this hash of "password123" (bench/seed/seed.go).
    immutable seededHash = "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq";
    assert(verifyPassword("password123", seededHash));
    assert(!verifyPassword("password124", seededHash));
    assert(!verifyPassword("", seededHash));
    assert(!verifyPassword("x", "not-a-hash"));
    assert(!verifyPassword("x", ""));

    const h = hashPassword("hunter2");
    assert(h !is null);
    assert(h.length == 60, h);
    assert(h[0 .. 7] == "$2b$10$", h);
    assert(verifyPassword("hunter2", h));
    assert(!verifyPassword("hunter3", h));
    {
        char[] long_;
        foreach (i; 0 .. 73) long_ ~= 'p';
        assert(hashPassword(long_) is null);
    }
}
