/**
 * Internals of the base64 encoder.
 *
 * Nothing in here is part of the public API; see the $(LREF Base64Impl)
 * template in `base64.package` for the entry points.
 *
 * There are three implementations of the bulk of the work, and which one gets
 * compiled is decided at compile time:
 *
 * - $(LREF simd_encoder): written on `core.simd` vector types, compiled under
 *   `version(SIMD)`,
 * - $(LREF encodeVectorized): one loop over a run-time group count, in which
 *   the shape of the computation lets the compiler auto-vectorise it. On
 *   AArch64 this becomes `ld3` (load three interleaved 16 byte vectors), a
 *   chain of `ushr`/`usra` (shift and accumulate), `cmhi`/`cmeq` (compare) and
 *   `bsl`/`bif` (select) instructions, and a `st4` (store four interleaved
 *   vectors),
 * - $(LREF encodeScalar): a 64-entry alphabet lookup per character, used for
 *   short inputs where the vector loops' prologue costs more than it saves.
 *
 * Copyright: 2026, Sergei Giniatulin
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 */
module base64.detail.encoder;

import base64.internal : encodedLength, NoPadding, useSimd;

static if (useSimd)
{
    import base64.detail.simd_encoder : encodeSimd = encodeBuffer,
        simdLanes = lanes;
}

/// Number of groups below which the scalar path wins.
enum size_t vectorGroups = 8;

/// Maps a 6-bit _value to the ASCII character that encodes it.
///
/// Written as a chain of comparisons and adds, so that the compiler can run the
/// whole thing on vector registers: 16 values are handled by one instruction.
package(base64) ubyte encodeValue(char Map62th, char Map63th)(ubyte value_)
        @safe pure nothrow @nogc
in
{
    assert(value_ < 64, "6-bit values only");
}
do
{
    ubyte c = cast(ubyte)(value_ + 65);
    if (value_ >= 26)
        // 'a'..'z' need +6 on top of 'A', '0'..'9' need -69.
        c = value_ < 52 ? cast(ubyte)(c + 6) : cast(ubyte)(c - 69);
    if (value_ >= 62)
        // The two characters that do not fit a contiguous range.
        c = value_ == 62 ? cast(ubyte) Map62th : cast(ubyte) Map63th;
    return c;
}

/// The alphabet, as a table for the scalar path.
private char[64] makeAlphabet(char Map62th, char Map63th)() @safe pure nothrow
{
    char[64] table;
    foreach (v; 0 .. 64)
        table[v] = cast(char) encodeValue!(Map62th, Map63th)(cast(ubyte) v);
    return table;
}

/// Encodes $(D_PARAM groups) complete 3-byte groups with one table lookup per
/// character.
private void encodeScalar(char Map62th, char Map63th)
    (const(ubyte)* s, char* o, size_t groups) @trusted pure nothrow @nogc
do
{
    static immutable char[64] table = makeAlphabet!(Map62th, Map63th);

    foreach (immutable g; 0 .. groups)
    {
        immutable x0 = s[g * 3 + 0];
        o[g * 4 + 0] = table[x0 >> 2];
        o[g * 4 + 1] = table[(x0 << 4 | s[g * 3 + 1] >> 4) & 63];
        o[g * 4 + 2] = table[(s[g * 3 + 1] << 2 | s[g * 3 + 2] >> 6) & 63];
        o[g * 4 + 3] = table[s[g * 3 + 2] & 63];
    }
}

/// Encodes $(D_PARAM groups) complete 3-byte groups with one loop whose trip
/// count is only known at run time, which is the shape the compiler
/// auto-vectorises.
private void encodeVectorized(char Map62th, char Map63th)
    (const(ubyte)* s, char* o, size_t groups) @trusted pure nothrow @nogc
do
{
    // Hoisting the character mapping into its own function would stop the
    // compiler from vectorising the whole body, so it is expanded inline here
    // for all four characters of a group.
    foreach (immutable g; 0 .. groups)
    {
        ubyte x0 = s[g * 3 + 0];
        ubyte x1 = s[g * 3 + 1];
        ubyte x2 = s[g * 3 + 2];

        o[g * 4 + 0] = encodeValue!(Map62th, Map63th)(cast(ubyte)(x0 >> 2));
        o[g * 4 + 1] = encodeValue!(Map62th, Map63th)(cast(ubyte)(x0 << 4 | x1 >> 4) & 63);
        o[g * 4 + 2] = encodeValue!(Map62th, Map63th)(cast(ubyte)(x1 << 2 | x2 >> 6) & 63);
        o[g * 4 + 3] = encodeValue!(Map62th, Map63th)(cast(ubyte)(x2 & 63));
    }
}

/// Encodes every complete 3-byte group of $(D_PARAM src) to four characters
/// at the front of $(D_PARAM dst).
///
/// $(D_PARAM src.length - 3 * groups) trailing bytes are left for
/// $(LREF encodeTail).
package(base64) void encodeBuffer(char Map62th, char Map63th)
    (const(ubyte)[] src, char[] dst) @trusted pure nothrow @nogc
in
{
    assert(dst.length >= src.length / 3 * 4, "Output buffer too small");
}
do
{
    immutable size_t groups = src.length / 3;
    if (groups == 0)
        return;

    const(ubyte)* s = src.ptr;
    char* o = dst.ptr;

    static if (useSimd)
    {
        immutable size_t blocks = groups / simdLanes;
        if (blocks != 0)
        {
            encodeSimd!(Map62th, Map63th)(src[0 .. blocks * simdLanes * 3],
                dst[0 .. blocks * simdLanes * 4]);
            s += blocks * simdLanes * 3;
            o += blocks * simdLanes * 4;
        }

        immutable size_t rest = groups - blocks * simdLanes;
        if (rest < vectorGroups)
        {
            if (rest != 0)
                encodeScalar!(Map62th, Map63th)(s, o, rest);
            return;
        }
        encodeVectorized!(Map62th, Map63th)(s, o, rest);
        return;
    }

    if (groups < vectorGroups)
    {
        encodeScalar!(Map62th, Map63th)(s, o, groups);
        return;
    }
    encodeVectorized!(Map62th, Map63th)(s, o, groups);
}

/// Encodes the trailing 0, 1 or 2 bytes of $(D_PARAM src), including the
/// padding characters.
package(base64) void encodeTail(char Map62th, char Map63th, char Padding)
    (const(ubyte)[] src, char[] dst) @trusted pure nothrow @nogc
in
{
    assert(dst.length >= encodedLength!Padding(src.length),
        "Output buffer too small");
}
do
{
    immutable size_t groups = src.length / 3;
    immutable size_t remain = src.length - groups * 3;
    if (remain == 0)
        return;

    const(ubyte)* s = src.ptr + groups * 3;
    char* o = dst.ptr + groups * 4;

    if (remain == 1)
    {
        ubyte b0 = s[0];
        o[0] = encodeValue!(Map62th, Map63th)(cast(ubyte)(b0 >> 2));
        o[1] = encodeValue!(Map62th, Map63th)(cast(ubyte)(b0 & 3) << 4);
        static if (Padding != NoPadding)
        {
            o[2] = Padding;
            o[3] = Padding;
        }
    }
    else
    {
        ubyte b0 = s[0];
        ubyte b1 = s[1];
        o[0] = encodeValue!(Map62th, Map63th)(cast(ubyte)(b0 >> 2));
        o[1] = encodeValue!(Map62th, Map63th)(cast(ubyte)(b0 << 4 | b1 >> 4) & 63);
        o[2] = encodeValue!(Map62th, Map63th)(cast(ubyte)(b1 << 2) & 63);
        static if (Padding != NoPadding)
            o[3] = Padding;
    }
}
