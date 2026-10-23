/// Password hashing: bcrypt cost 10, on top of the `passwd` package (which
/// carries OpenBSD test vectors, so there is no hand-rolled crypto here).
///
/// SPEC.md rule 7: every password is hashed with bcrypt cost 10, and every
/// login verifies against the stored hash.
module conduit.bcrypt;

import passwd;
import passwd.bcrypt;
import core.atomic : atomicOp;
import photon : offload;

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

private shared int passwordActive;
private __gshared int passwordSlots;
private __gshared bool passwordWorkersReady;
private __gshared string dummyHash;

/// Called once after initPhoton(), before workers start. At most `slots`
/// hashes run on photon's offload pool; beyond that the caller hashes on its
/// scheduler instead of building an unbounded queue during the login ramp.
void initPasswordWorkers(int slots = 4)
{
    passwordSlots = slots;
    dummyHash = hashPassword("conduit-dummy-password").idup;
    passwordWorkersReady = true;
}

/// The hash used for a missing email, so a failed login costs the same bcrypt
/// verification as a wrong password for an existing account.
string dummyPasswordHash() nothrow
{
    return dummyHash;
}

private T inPasswordSlot(T)(T delegate() work)
{
    if (!passwordWorkersReady)
        return work();
    const active = atomicOp!"+="(passwordActive, 1);
    if (active > passwordSlots)
    {
        atomicOp!"-="(passwordActive, 1);
        return work();
    }
    scope (exit)
        atomicOp!"-="(passwordActive, 1);
    return offload(work);
}

string hashPasswordOffload(const(char)[] password)
{
    return inPasswordSlot(() => hashPassword(password));
}

bool verifyPasswordOffload(const(char)[] password, const(char)[] storedHash)
{
    return inPasswordSlot(() => verifyPassword(password, storedHash));
}
