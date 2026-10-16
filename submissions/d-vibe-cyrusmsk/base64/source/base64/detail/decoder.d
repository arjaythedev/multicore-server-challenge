/**
 * Internals of the base64 decoder.
 *
 * Nothing in here is part of the public API; the entry points are the
 * $(LREF Base64Impl) members in `base64.package`.
 *
 * The bulk of the work is done by one loop whose trip count is only known at
 * run time (`src.length / 4`). As in the encoder, every statement in the body
 * is plain byte arithmetic, and the loop reads four consecutive input
 * characters per iteration while writing three consecutive output bytes. On
 * AArch64 LDC turns that into an `ld4` (load four interleaved 16 byte
 * vectors), a chain of vector compares and bit selects that recovers the 6-bit
 * value of every character, and a `st3` (store three interleaved vectors).
 *
 * Invalid characters are detected inside the loop; the caller then re-runs a
 * scalar scan to find the offending position.
 *
 * Copyright: 2026, Sergei Giniatulin
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 */
module base64.detail.decoder;

import std.exception : enforce;

import base64.internal : Base64Exception, NoPadding, useSimd;

/// Number of groups below which the scalar path wins: the vectorised loop
/// pays for a prologue and an epilogue that do not pay off for a few groups.
enum size_t vectorGroups = 32;

/**
 * Maps an ASCII _character to its 6-bit _value, or 0xFF if it is not part of
 * the alphabet.
 *
 * The nested selects matter: they are what the compiler can turn into vector
 * compares and bit selects (an `if`/`else if` chain stays scalar). Each range
 * is tested with a single unsigned comparison, which is both the cheapest form
 * and the reason the characters just past each range, `{`, `|`, `}`, `~`,
 * `` ` `` and `[`, are correctly rejected: the subtraction wraps around to a
 * large value.
 *
 * The two alphabet specific characters are fixed up on top of the three ranges
 * because they are allowed to sit in the gap between 'Z' and 'a': `-` and `_`
 * in the URL alphabet do exactly that, and would otherwise be mis-decoded.
 */
package(base64) ubyte decodeValue(char Map62th, char Map63th, char Padding)
        (char c) @safe pure nothrow @nogc
do
{
    immutable ubyte lo = cast(ubyte)(c - 'a');
    immutable ubyte up = cast(ubyte)(c - 'A');
    immutable ubyte di = cast(ubyte)(c - '0');

    // The padding character needs no test of its own: the static asserts on
    // Base64Impl keep it out of the three ranges, so it falls through to 0xFF
    // here anyway.
    ubyte v = lo <= 25 ? cast(ubyte)(lo + 26)
          : up <= 25 ? up
          : di <= 9 ? cast(ubyte)(di + 52)
          : 0xFF;
    if (c == Map62th)
        v = 62;
    if (c == Map63th)
        v = 63;
    return v;
}

/// The reverse of `encodeValue`, as a table over all 256 inputs. Used by the
/// scalar paths only: a table lookup cannot be vectorised.
private ubyte[256] makeValueTable(char Map62th, char Map63th, char Padding)()
        @safe pure nothrow
{
    ubyte[256] table;
    foreach (i; 0 .. 256)
        table[i] = decodeValue!(Map62th, Map63th, Padding)(cast(char) i);
    return table;
}

/// Number of complete 4-character groups that $(LREF decodeBuffer) may process.
///
/// Padding, if present, is always in the very last group, so that group is left
/// to $(LREF decodeTail).
package(base64) size_t decodeFastGroups(char Padding)(const(char)[] src)
        @safe pure nothrow @nogc
do
{
    immutable bool padded = Padding != NoPadding && src.length >= 4
        && (src[$ - 1] == Padding || src[$ - 2] == Padding);
    return src.length / 4 - (padded ? 1 : 0);
}

/// Decodes the complete 4-character groups of $(D_PARAM src), each to three
/// bytes.
///
/// Returns `true` when every character seen was valid.
package(base64) bool decodeBuffer(char Map62th, char Map63th, char Padding)
    (const(char)[] src, ubyte[] dst) @trusted pure nothrow @nogc
in
{
    assert(dst.length >= src.length / 4 * 3, "Output buffer too small");
}
do
{
    immutable size_t groups = decodeFastGroups!Padding(src);
    if (groups == 0)
        return true;

    static if (useSimd)
    {
        import base64.detail.simd_decoder : simdLanes = lanes;
        import base64.detail.simd_decoder : decodeSimd = decodeBuffer;

        immutable size_t blocks = groups / simdLanes;
        if (blocks != 0)
        {
            immutable size_t done = blocks * simdLanes;
            // Only whole blocks of groups, so that the padded group at the end
            // is left to decodeTail.
            if (!decodeSimd!(Map62th, Map63th, Padding)(
                    src[0 .. done * 4], dst[0 .. done * 3]))
                return false;
            if (groups == done)
                return true;
            return decodePlain!(Map62th, Map63th, Padding)(
                src[done * 4 .. groups * 4], dst[done * 3 .. $]);
        }
    }

    return decodePlain!(Map62th, Map63th, Padding)(src[0 .. groups * 4], dst);
}

/// Decodes the complete 4-character groups of $(D_PARAM src), whose length is
/// exactly four times the group count.
private bool decodePlain(char Map62th, char Map63th, char Padding)
    (const(char)[] src, ubyte[] dst) @trusted pure nothrow @nogc
in
{
    assert(src.length % 4 == 0, "Only complete groups");
    assert(dst.length >= src.length / 4 * 3, "Output buffer too small");
}
do
{
    immutable size_t groups = src.length / 4;
    const(char)* s = src.ptr;
    ubyte* o = dst.ptr;

    if (groups < vectorGroups)
    {
        static immutable ubyte[256] table = makeValueTable!(Map62th, Map63th, Padding);
        ubyte bad = 0;
        foreach (immutable g; 0 .. groups)
        {
            // A table lookup, one load per character.
            ubyte a = table[s[g * 4 + 0]];
            ubyte b = table[s[g * 4 + 1]];
            ubyte c = table[s[g * 4 + 2]];
            ubyte d = table[s[g * 4 + 3]];
            bad |= a | b | c | d;

            o[g * 3 + 0] = cast(ubyte)(a << 2 | b >> 4);
            o[g * 3 + 1] = cast(ubyte)(b << 4 | c >> 2);
            o[g * 3 + 2] = cast(ubyte)(c << 6 | d);
        }
        return bad <= 63;
    }

    // Accumulates every character seen by the loop below; the compiler turns
    // this into a vector reduce. Valid 6-bit values are all below 64, so a
    // result above 63 means an invalid character was fed in. Two independent
    // accumulators keep the reduce from serialising the loop.
    ubyte seen0 = 0, seen1 = 0;

    // One loop, one trip count. As in the encoder, the character mapping is
    // expanded inline for all four characters of a group.
    foreach (immutable g; 0 .. groups)
    {
        ubyte a = decodeValue!(Map62th, Map63th, Padding)(s[g * 4 + 0]);
        ubyte b = decodeValue!(Map62th, Map63th, Padding)(s[g * 4 + 1]);
        ubyte c = decodeValue!(Map62th, Map63th, Padding)(s[g * 4 + 2]);
        ubyte d = decodeValue!(Map62th, Map63th, Padding)(s[g * 4 + 3]);
        seen0 |= a | b;
        seen1 |= c | d;

        o[g * 3 + 0] = cast(ubyte)(a << 2 | b >> 4);
        o[g * 3 + 1] = cast(ubyte)(b << 4 | c >> 2);
        o[g * 3 + 2] = cast(ubyte)(c << 6 | d);
    }

    return (seen0 | seen1) <= 63;
}

/// Scans $(D_PARAM src) for the first character that is not in the alphabet.
/// Returns `src.length` when the input is clean.
package(base64) size_t findInvalid(char Map62th, char Map63th, char Padding)
    (const(char)[] src) @safe pure nothrow @nogc
{
    foreach (i, c; src)
        if (decodeValue!(Map62th, Map63th, Padding)(c) == 0xFF)
            return i;
    return src.length;
}

/// Decodes the trailing group(s) of $(D_PARAM src): the last group, which is
/// the only one that may hold padding, plus an unaligned tail, which can only
/// occur for the unpadded variant.
///
/// Returns the number of bytes written.
package(base64) size_t decodeTail(char Map62th, char Map63th, char Padding)
    (const(char)[] src, ubyte[] dst) @trusted pure
{
    immutable size_t groups = decodeFastGroups!Padding(src);
    immutable size_t tail = src.length - groups * 4;
    if (tail == 0)
        return 0;

    const(char)* s = src.ptr + groups * 4;
    ubyte* o = dst.ptr + groups * 3;
    static immutable ubyte[256] value = makeValueTable!(Map62th, Map63th, Padding);

    if (Padding != NoPadding && tail == 4)
    {
        // The last group carries padding: "xx==" or "xxx=".
        ubyte a = value[s[0]];
        ubyte b = value[s[1]];
        enforce(a <= 63 && b <= 63, new Base64Exception(invalidChar(s[0])));
        o[0] = cast(ubyte)(a << 2 | b >> 4);

        if (s[2] == Padding)
        {
            enforce(s[3] == Padding, new Base64Exception(invalidChar(s[3])));
            return 1;
        }

        ubyte c = value[s[2]];
        enforce(c <= 63, new Base64Exception(invalidChar(s[2])));
        o[1] = cast(ubyte)(b << 4 | c >> 2);

        enforce(s[3] == Padding, new Base64Exception(invalidChar(s[3])));
        return 2;
    }

    if (tail == 2 || tail == 3)
    {
        // An unaligned tail: two characters carry one byte, three carry two.
        ubyte a = value[s[0]];
        ubyte b = value[s[1]];
        enforce(a <= 63 && b <= 63, new Base64Exception(invalidChar(s[0])));
        o[0] = cast(ubyte)(a << 2 | b >> 4);
        if (tail == 2)
            return 1;

        ubyte c = value[s[2]];
        enforce(c <= 63, new Base64Exception(invalidChar(s[2])));
        o[1] = cast(ubyte)(b << 4 | c >> 2);
        return 2;
    }

    // A single character, or a job the caller has already rejected.
    throw new Base64Exception("Invalid length of encoded data");
}

private string invalidChar(char c) @safe pure nothrow
{
    return "Invalid character: '" ~ c ~ "'";
}
