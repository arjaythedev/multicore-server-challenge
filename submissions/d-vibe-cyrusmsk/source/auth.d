/// HS256 JWT issuing and verification (SPEC.md).
///
/// The crypto is jwtlited's OpenSSL backend (`HS256Handler`); only the claims
/// the spec defines are checked here. The header must say HS256, the HMAC over
/// `header.payload` must verify with `JWT_SECRET`, `exp` must be a JSON integer
/// in the future, and `sub` must be a decimal string. No verification cache.
module conduit.auth;

import jwtlited;
import jwtlited.openssl : HS256Handler;
import vibe.data.json : Json, parseJsonString;

import std.base64 : Base64URLNoPadding;

import std.datetime : Clock, SysTime, UTC;
import std.format : format;
import std.string : indexOf;

/// A token lives for 30 days (SPEC.md).
enum tokenTTL = 30 * 24 * 60 * 60;

/// One handler per worker thread: the OpenSSL context inside is not safe to
/// share between threads, and loading the same key per thread is cheap.
///
/// Note: the handler is never copied (its OpenSSL backend disables copying);
/// it lives in thread-local storage from startup and is only loaded once.
static HS256Handler handler;

/// Loads `JWT_SECRET` into this thread's handler. Called once per worker thread.
void initAuth(string secret)
{
    if (!handler.loadKey(secret))
        throw new Exception("cannot load the JWT secret");
}

/// Issues a fresh token with exactly the three claims the spec defines.
string issueToken(long userId, long now)
{
    auto payload = format!`{"sub":"%d","iat":%d,"exp":%d}`(userId, now, now + tokenTTL);
    String token;
    if (handler.encode(token, payload) <= 0)
        throw new Exception("cannot issue a token");
    return token[].idup;
}

/// Verifies a presented token. Returns the user id, or 0 when the token is
/// missing, malformed, forged, expired, or has a non-decimal `sub`.
bool verifyToken(const(char)[] token, out long userId)
{
    userId = 0;
    if (token.length < 4 || token.length > 1024)
        return false;
    // Header structure, `"alg":"HS256"`, and the HMAC. jwtlited throws
    // (rather than failing) on some malformed tokens, so anything it
    // chokes on is simply not a token.
    bool valid;
    try
        valid = handler.validate(token);
    catch (Throwable)
        return false;
    if (!valid)
        return false;

    // The payload jwtlited just authenticated, decoded with the local base64.
    const firstDot = token.indexOf('.');
    const rest = token[firstDot + 1 .. $];
    const secondDot = rest.indexOf('.');
    const payload = rest[0 .. secondDot];
    const decodedLength = base64DecodedLength(payload);
    if (decodedLength <= 0 || decodedLength > 512)
        return false;
    // The buffer is ours and never escapes: the cast only reinterprets it so the
    // JSON parser accepts it, and the parser itself rejects invalid UTF-8.
    char[512] buffer;
    string claims;
    try
        claims = cast(string) Base64URLNoPadding.decode(payload, (cast(ubyte[]) buffer)[0 .. decodedLength]);
    catch (Exception)
        return false;

    return checkClaims(claims, userId);
}

/// Length of base64url (no padding) data, or -1 when it cannot be valid.
private int base64DecodedLength(const(char)[] data) pure nothrow @safe @nogc
{
    immutable rem = data.length % 4;
    if (rem == 1)
        return -1;
    return cast(int)(data.length / 4 * 3 + (rem == 0 ? 0 : rem == 2 ? 1 : 2));
}

private bool checkClaims(string claims, out long userId)
{
    userId = 0;
    try
    {
        const(Json) json = parseJsonString(claims);
        if (json.type != Json.Type.object)
            return false;
        const(Json) exp = json["exp"];
        if (exp.type != Json.Type.int_ || exp.get!long <= nowUnix())
            return false;
        const(Json) sub = json["sub"];
        if (sub.type != Json.Type.string || !parseDecimal(sub.get!string, userId))
            return false;
        return true;
    }
    catch (Exception)
    {
        return false;
    }
}

long nowUnix() @safe nothrow
{
    try
        return Clock.currTime(UTC()).toUnixTime();
    catch (Exception)
        return 0;
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
