/// HS256 JWT issuing and verification (SPEC.md).
///
/// The crypto is jwtlited's pure-Phobos backend (`HS256Handler`); only the
/// claims the spec defines are checked here. The header must say HS256, the
/// HMAC over `header.payload` must verify with `JWT_SECRET`, `exp` must be a
/// JSON integer in the future, and `sub` must be a decimal string. There is no
/// verification cache.
module conduit.auth;

import jwtlited;
import jwtlited.phobos : HS256Handler;

import asdf : deserialize;

import std.base64 : Base64URLNoPadding;
import std.datetime : Clock, UTC;
import std.format : format;
import std.string : indexOf;

/// The secret, read once in main() and never changed.
__gshared string g_secret;

/// A token lives for 30 days (SPEC.md).
enum tokenTTL = 30 * 24 * 60 * 60;

/// One handler per worker thread: jwtlited keeps a static header buffer, and
/// each worker thread is a separate fiber scheduler, so the handler is loaded
/// lazily in that thread's TLS on first use.
private static HS256Handler handler;
private static bool loaded;

/// Records the secret. Calls in every thread that will serve requests; each
/// thread loads its own copy on first use.
void initAuth(string secret)
{
    g_secret = secret;
    ensureLoaded();
}

private void ensureLoaded()
{
    if (loaded)
        return;
    if (g_secret.length == 0 || !handler.loadKey(g_secret))
        throw new Exception("JWT_SECRET is required");
    loaded = true;
}

/// Issues a fresh token with exactly the three claims the spec defines.
string issueToken(long userId, long now)
{
    ensureLoaded();
    auto payload = format!`{"sub":"%d","iat":%d,"exp":%d}`(userId, now, now + tokenTTL);
    char[512] buffer;
    immutable n = handler.encode(buffer[], payload);
    if (n <= 0)
        throw new Exception("cannot issue a token");
    return buffer[0 .. n].idup;
}

/// Verifies a presented token. Returns the user id, or false when the token is
/// missing, malformed, forged, expired, or has a non-decimal `sub`.
bool verifyToken(const(char)[] token, out long userId)
{
    userId = 0;
    ensureLoaded();
    if (token.length < 4 || token.length > 2048)
        return false;

    // jwtlited throws (rather than failing) on some malformed tokens, so
    // anything it chokes on is simply not a token.
    bool valid;
    try
        valid = handler.validate(token);
    catch (Throwable)
        return false;
    if (!valid)
        return false;

    const firstDot = token.indexOf('.');
    if (firstDot < 0)
        return false;
    const rest = token[firstDot + 1 .. $];
    const secondDot = rest.indexOf('.');
    if (secondDot < 0)
        return false;
    const payload = rest[0 .. secondDot];
    if (payload.length == 0 || payload.length > 4096)
        return false;

    immutable needed = Base64URLNoPadding.decodeLength(payload.length);
    if (needed <= 0 || needed > 1024)
        return false;
    ubyte[1024] buffer;
    ubyte[] decoded;
    try
        decoded = Base64URLNoPadding.decode(payload, buffer[0 .. needed]);
    catch (Exception)
        return false;

    TokenClaims claims;
    try
        claims = deserialize!TokenClaims(cast(string) decoded);
    catch (Exception)
        return false;

    if (claims.exp <= nowUnix())
        return false;
    return parseDecimal(claims.sub, userId);
}

/// The claims the spec defines. asdf rejects a payload whose `sub` is not a
/// string or whose `exp` is not an integer, so a malformed or forged payload
/// simply fails to deserialize.
private struct TokenClaims
{
    string sub;
    long exp;
}

/// Digits only, no sign or spaces, fitting in a long.
private bool parseDecimal(const(char)[] s, out long value) pure nothrow @safe
{
    value = 0;
    if (s.length == 0 || s.length > 18)
        return false;
    long parsed;
    foreach (c; s)
    {
        if (c < '0' || c > '9')
            return false;
        parsed = parsed * 10 + (c - '0');
    }
    value = parsed;
    return true;
}

long nowUnix() @safe nothrow
{
    try
        return Clock.currTime(UTC()).toUnixTime();
    catch (Exception)
        return 0;
}
