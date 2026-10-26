/// Password hashing: bcrypt cost 10, on top of the `passwd` package (which
/// carries OpenBSD test vectors, so there is no hand-rolled crypto here).
///
/// SPEC.md rule 7: every password is hashed with bcrypt cost 10, and every
/// login verifies against the stored hash.
module conduit.bcrypt;

import passwd;
import passwd.bcrypt;

/// bcrypt cost 10 (SPEC.md).
enum bcryptCost = 10;

/// bcrypt's own limit: longer passwords are unusable (Go's bcrypt rejects
/// them too, and the conformance suite expects a 422 for a 73-byte password).
private enum maxPasswordLength = 72;

/// Hashes a password into `$2b$10$<salt><digest>`, or null when it is too long.
string hashPassword(const(char)[] password) @safe
{
    if (password.length > maxPasswordLength)
        return null;
    return password.crypt(Bcrypt.genSalt(bcryptCost)).idup;
}

/// Verifies a password against a stored hash (any `$2*` bcrypt variant, which
/// is what the seeded database holds). A malformed hash is a failed login.
bool verifyPassword(const(char)[] password, const(char)[] storedHash) @safe
{
    if (password.length > maxPasswordLength)
        return false;
    try
        return password.canCryptTo(storedHash);
    catch (Exception)
        return false;
}
