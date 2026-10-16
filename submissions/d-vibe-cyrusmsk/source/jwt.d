/**
 * HS256 JWT issue/verify on top of jwtlited.
 *
 * SPEC.md: header `Authorization: Token <jwt>`, HS256 signed with JWT_SECRET,
 * claims exactly {"sub": "<user id as decimal string>", "iat": now, "exp": now + 30 days}.
 * The signature and `exp` are verified on every request - there is no verification cache.
 *
 * jwtlited does the crypto work: it base64-decodes the header to check that it says
 * HS256, HMACs `header.payload` with the secret and compares it with the signature,
 * and decodes the payload into the caller's buffer. Only the three claims are checked
 * here, because jwtlited leaves payload validation to the application.
 */
module conduit.jwt;

import jwtlited;
import jwtlited.phobos : HS256Handler;

import std.datetime : Clock, SysTime, UTC;
import std.format : format;
import std.string : indexOf;

/// Loaded once from JWT_SECRET before any worker thread starts, then read-only.
__gshared HS256Handler g_handler;

void initJwt(string secret) @trusted
{
    g_handler = HS256Handler.init;
    g_handler.loadKey(cast(const(char)[]) secret);
}

enum tokenTTL = 30 * 24 * 60 * 60; // 30 days, as in SPEC.md

/// Issues a fresh token for a user id, with exactly the three required claims.
char[] issueToken(long userId, long now) @trusted
{
    auto payload = format!`{"sub":"%d","iat":%d,"exp":%d}`(userId, now, now + tokenTTL);
    String tok;
    const len = g_handler.encode(tok, payload);
    assert(len > 0);
    return tok[0 .. len].dup;
}

/// Verifies a token: HS256 header, HMAC with our secret, `exp` present and in the
/// future, and `sub` a decimal string. Returns the user id, or 0 when invalid.
bool verifyToken(const(char)[] token, out long userId) @trusted
{
    userId = 0;
    if (token.length < 4 || token.length > 1024) return false;

    // Split into header.payload.signature.
    const firstDot = token.indexOf('.');
    if (firstDot <= 0) return false;
    const rest = token[firstDot + 1 .. $];
    const secondDot = rest.indexOf('.');
    if (secondDot <= 0) return false;
    const(char)[] payload = rest[0 .. secondDot];
    if (rest[secondDot + 1 .. $].indexOf('.') >= 0) return false; // only three parts

    const declen = decodedLength(payload);
    if (declen <= 0 || declen > 512) return false;

    // jwtlited: checks "alg" is HS256, verifies the signature and decodes the payload.
    char[512] buf;
    if (!g_handler.decode(token, buf[0 .. declen])) return false;

    const(char)[] claims = buf[0 .. declen];
    long exp;
    if (!claimNumber(claims, "exp", exp)) return false;
    if (exp <= nowUnix()) return false;
    const(char)[] sub;
    if (!claimString(claims, "sub", sub)) return false;
    long id;
    if (!parseDecimal(sub, id)) return false;
    userId = id;
    return true;
}

private long nowUnix() @trusted nothrow
{
    return cast(long) Clock.currTime(UTC()).toUnixTime();
}

/// Length of base64url (no padding) data, or -1 when it cannot be valid.
private int decodedLength(const(char)[] data) pure nothrow @safe @nogc
{
    immutable rem = data.length % 4;
    if (rem == 1) return -1;
    return cast(int)(data.length / 4 * 3 + (rem == 0 ? 0 : rem == 2 ? 1 : 2));
}

/// Reads a top-level `"key": <integer>` out of a flat claims object.
private bool claimNumber(const(char)[] json, const(char)[] key, out long value) pure nothrow @safe
{
    const(char)[] raw;
    return claim(json, key, raw) && parseDecimal(raw, value);
}

/// Reads a top-level `"key": "<string>"` out of a flat claims object.
private bool claimString(const(char)[] json, const(char)[] key, out const(char)[] value) pure nothrow @safe
{
    const(char)[] raw;
    if (!claim(json, key, raw)) return false;
    if (raw.length < 2 || raw[0] != '"' || raw[$ - 1] != '"') return false;
    value = raw[1 .. $ - 1];
    return true;
}

/// Returns the raw text of a top-level member's value (numbers, or "strings"
/// with escapes left as they were). Enough for the claims the spec defines, and
/// strict enough to reject anything shaped differently.
private bool claim(const(char)[] json, const(char)[] key, out const(char)[] value) pure nothrow @safe
{
    value = null;
    if (json.length < 2 || json[0] != '{' || json[$ - 1] != '}') return false;

    size_t i = 1;
    while (i < json.length) {
        // skip separators
        if (json[i] == ',' || json[i] == ' ') {
            i++;
            continue;
        }
        // key
        if (json[i] != '"') return false;
        auto k = scanString(json, i);
        if (k is null) return false;
        const(char)[] kText = json[i + 1 .. i + k.length - 1];
        i += k.length;
        if (i >= json.length || json[i] != ':') return false;
        i++;
        if (i < json.length && json[i] == ' ') i++;
        // value
        ptrdiff_t end;
        if (json[i] == '"') {
            auto v = scanString(json, i);
            if (v is null) return false;
            end = i + v.length;
        } else {
            end = i;
            while (end < json.length && json[end] != ',' && json[end] != '}') end++;
            immutable n = end - i;
            foreach (c; json[i .. cast(size_t) end])
                if (!(c >= '0' && c <= '9' || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E')) {
                    end = -1;
                    break;
                }
            if (end < 0) return false;
        }
        if (end <= i || end > json.length) return false;
        if (kText == key) {
            value = json[i .. cast(size_t) end];
            return true;
        }
        i = cast(size_t) end;
    }
    return false;
}

/// Scans a JSON string starting at `i` (which must point at the opening quote),
/// including the closing quote. Escaped characters are left untouched.
private const(char)[] scanString(const(char)[] json, size_t i) pure nothrow @safe
{
    if (i >= json.length || json[i] != '"') return null;
    size_t j = i + 1;
    while (j < json.length) {
        immutable c = json[j];
        if (c == '\\') {
            if (++j >= json.length) return null;
        } else if (c == '"') {
            return json[i .. j + 1];
        }
        j++;
    }
    return null;
}

/// Parses a decimal string (digits only, no sign or spaces) into a long.
private bool parseDecimal(const(char)[] s, out long value) pure nothrow @safe
{
    value = 0;
    if (s.length == 0 || s.length > 18) return false;
    long v;
    foreach (c; s) {
        if (c < '0' || c > '9') return false;
        v = v * 10 + (c - '0');
    }
    value = v;
    return true;
}

@safe unittest
{
    import std.base64 : Base64URLNoPadding;
    import std.datetime : Clock, UTC;

    const secret = "multicore-server-challenge";
    initJwt(secret);
    const now = cast(long) Clock.currTime(UTC()).toUnixTime();
    long id = 0;

    // A token we issue ourselves verifies, and a valid foreign one too.
    auto tok = issueToken(42, now);
    assert(tok.length > 20);
    assert(verifyToken(tok, id));
    assert(id == 42);
    assert(verifyToken(mint(secret, format!`{"sub":"42","iat":%d,"exp":%d}`(now, now + tokenTTL)), id) && id == 42);

    // Signed with another secret
    assert(!verifyToken(mint("other-secret", format!`{"sub":"42","iat":%d,"exp":%d}`(now, now + 3600)), id));
    // exp in the past
    assert(!verifyToken(mint(secret, format!`{"sub":"42","iat":%d,"exp":%d}`(now - 4000, now - 3600)), id));
    // no exp claim
    assert(!verifyToken(mint(secret, format!`{"sub":"42","iat":%d}`(now)), id));
    // sub must be a decimal string, not a number or garbage
    assert(!verifyToken(mint(secret, format!`{"sub":42,"iat":%d,"exp":%d}`(now, now + 3600)), id));
    assert(!verifyToken(mint(secret, format!`{"sub":"abc","iat":%d,"exp":%d}`(now, now + 3600)), id));
    assert(!verifyToken(mint(secret, format!`{"sub":"","iat":%d,"exp":%d}`(now, now + 3600)), id));

    // alg none, structural garbage, empty
    assert(!verifyToken(algNoneToken(format!`{"sub":"42","exp":%d}`(now + 3600)), id));
    assert(!verifyToken("not.a.jwt", id));
    assert(!verifyToken("", id));
}

/// Mints an HS256 token with an arbitrary body (stands in for the harness's mints).
private string mint(string secret, const(char)[] claims) @trusted
{
    import std.base64 : Base64URLNoPadding;

    immutable header = Base64URLNoPadding.encode(cast(ubyte[]) cast(char[]) `{"alg":"HS256","typ":"JWT"}`);
    immutable payload = Base64URLNoPadding.encode(cast(ubyte[]) cast(char[]) claims);
    immutable msg = cast(string) header ~ "." ~ cast(string) payload;
    import std.digest.hmac : hmac;
    import std.digest.sha : SHA256;

    auto m = hmac!SHA256(cast(const(ubyte)[]) secret).put(cast(const(ubyte)[]) msg).finish();
    immutable sig = Base64URLNoPadding.encode(m);
    return cast(string) msg ~ "." ~ cast(string) sig;
}

/// An alg:none token: jwtlited must reject it because the header isn't HS256.
private string algNoneToken(const(char)[] claims) @trusted
{
    import std.base64 : Base64URLNoPadding;

    immutable header = Base64URLNoPadding.encode(cast(ubyte[]) cast(char[]) `{"alg":"none"}`);
    immutable payload = Base64URLNoPadding.encode(cast(ubyte[]) cast(char[]) claims);
    return (cast(string) header ~ "." ~ cast(string) payload ~ ".").idup;
}
