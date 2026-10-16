/**
 * base64 encoder written on $(LREF2 core, simd, intel-intrinsics) vector types.
 *
 * Only compiled when `version(SIMD)` (or the auto-detection in
 * $(LREF base64.internal.useSimd)) says this build can take the SIMD path; the
 * plain byte loop in `base64.detail.encoder` is what gets compiled otherwise.
 *
 * One iteration encodes 16 groups: 48 input bytes in, 64 characters out, in
 * vectors of 16 bytes.
 *
 * The layout needs several `shufflevector` calls because `intel-intrinsics` has no
 * interleaved load:
 *
 * - three 16-byte loads carry the 48 input bytes, and six shuffles
 *   de-interleave them into the `b0`, `b1`, `b2` byte streams that the 6-bit
 *   extraction is expressed against,
 * - the character mapping is the same arithmetic as the scalar path, run over
 *   16 bytes at a time,
 * - the four character streams are interleaved back into group order with
 *   eight shuffles and written out as four contiguous stores.
 *
 * That is more shuffles than the `ld3`/`st4` instruction pair auto-vectorisation
 * gets out of the loop in `encoder.d` for free, but the mapping is spelled out
 * here rather than left to the compiler, which is what `version(SIMD)` exists
 * to compare.
 *
 * Copyright: 2026, Sergei Giniatulin
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 */
module base64.detail.simd_encoder;

import inteli.emmintrin;
import inteli.smmintrin;
import inteli.tmmintrin;
import inteli.types;
import core.simd : ubyte16;
import ldc.llvmasm;

import ldc.simd : equalMask, greaterMask, loadUnaligned, shufflevector,
    storeUnaligned;

private void storeVec(ubyte16 v, ubyte* p) @trusted pure nothrow @nogc {
    _mm_storeu_si128(cast(__m128i*) p, cast(__m128i) v);
}

/// Number of 3-byte groups handled by one iteration of the vector loop.
enum size_t lanes = 16;

/// `mask ? a : b`, spelled as the bit-select idiom every vector backend has an
/// instruction for.
private ubyte16 blend(ubyte16 a, ubyte16 b, ubyte16 mask) @safe pure nothrow @nogc
{
    return cast(ubyte16)(a ^ (cast(ubyte16)(a ^ b) & mask));
}

/// The vector version of $(LREF base64.detail.encoder.encodeValue).
///
/// The offset is selected first and the value added once, which the scalar
/// formulation cannot do: it saves two adds per vector over adding 65 first and
/// adjusting afterwards.

version (AArch64)
private ubyte16 tbl4(ubyte16 t0, ubyte16 t1, ubyte16 t2, ubyte16 t3, ubyte16 idx)
    @trusted pure nothrow @nogc
{
    return __ir_pure!(`%r = call <16 x i8> @llvm.aarch64.neon.tbl4.v16i8(<16 x i8> %0, <16 x i8> %1, <16 x i8> %2, <16 x i8> %3, <16 x i8> %4)
                       ret <16 x i8> %r`, ubyte16)(t0, t1, t2, t3, idx);
}

private enum bool hasTbl4 = __traits(compiles, { ubyte16 _x; _x = tbl4(_x, _x, _x, _x, _x); });

private ubyte16 toChar(char Map62th, char Map63th)(ubyte16 value_)
        @safe pure nothrow @nogc
{
    immutable ubyte16 k25 = [25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25];
    immutable ubyte16 k51 = [51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51];
    immutable ubyte16 k62 = [62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62];
    immutable ubyte16 k63 = [63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63];
    immutable ubyte16 k65 = [65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65];
    immutable ubyte16 k71 = [71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71];
    immutable ubyte16 km4 = [252, 252, 252, 252, 252, 252, 252, 252, 252, 252, 252, 252, 252, 252, 252, 252];
    immutable ubyte16 c62 = [
        Map62th, Map62th, Map62th, Map62th, Map62th, Map62th, Map62th, Map62th,
        Map62th, Map62th, Map62th, Map62th, Map62th, Map62th, Map62th, Map62th
    ];
    immutable ubyte16 c63 = [
        Map63th, Map63th, Map63th, Map63th, Map63th, Map63th, Map63th, Map63th,
        Map63th, Map63th, Map63th, Map63th, Map63th, Map63th, Map63th, Map63th
    ];

    // The offset a value carries: 'A' below 26, 'a' below 52, and -4 above,
    // with the two characters that belong to no range fixed up on top.
    ubyte16 mAlpha = cast(ubyte16) greaterMask!ubyte16(value_, k25);
    ubyte16 mUpper = cast(ubyte16) greaterMask!ubyte16(value_, k51);
    ubyte16 d = blend(k65, k71, mAlpha);
    d = blend(d, km4, mUpper);
    ubyte16 c = cast(ubyte16)(value_ + d);
    c = blend(c, c62, cast(ubyte16) equalMask!ubyte16(value_, k62));
    c = blend(c, c63, cast(ubyte16) equalMask!ubyte16(value_, k63));
    return c;
}

/**
 * Encodes every complete 3-byte group of $(D_PARAM src), in whole blocks of
 * $(LREF lanes) groups; the caller deals with the remainder.
 */
package(base64) void encodeBuffer(char Map62th, char Map63th)
    (const(ubyte)[] src, char[] dst) @trusted pure nothrow @nogc
in
{
    assert(dst.length >= src.length / 3 * 4, "Output buffer too small");
}
do
{
    immutable size_t blocks = (src.length / 3) / lanes;
    if (blocks == 0)
        return;

    const(ubyte)* s = src.ptr;
    char* o = dst.ptr;

    foreach (immutable blk; 0 .. blocks)
    {
        // Three 16-byte loads carry the 48 input bytes.
        ubyte16 a = cast(ubyte16) _mm_loadu_si128(cast(const(__m128i)*) s);
        ubyte16 b = cast(ubyte16) _mm_loadu_si128(cast(const(__m128i)*) (s + 16));
        ubyte16 cVec = cast(ubyte16) _mm_loadu_si128(cast(const(__m128i)*) (s + 32));

        // De-interleave into the three byte streams.
        //
        // `a` holds input bytes 0..15, `b` 16..31 and `cVec` 32..47. The masks
        // name those input byte positions, offset by 16 for `b` and by 32 for
        // `cVec`, and each stream is gathered in two shuffles because 48 bytes
        // do not fit in the 32 that a pair of vectors addresses.
        //
        // b0: 0 3 6 9 12 15 | 18 21 24 27 30 | 33 36 39 42 45
        // b1: 1 4 7 10 13   | 16 19 22 25 28 31 | 34 37 40 43 46
        // b2: 2 5 8 11 14   | 17 20 23 26 29  | 32 35 38 41 44 47
        ubyte16 t0 = shufflevector!(ubyte16, 0, 3, 6, 9, 12, 15, 18, 21, 24, 27, 30, 0, 0, 0, 0, 0)(a, b);
        ubyte16 t1 = shufflevector!(ubyte16, 1, 4, 7, 10, 13, 16, 19, 22, 25, 28, 31, 0, 0, 0, 0, 0)(a, b);
        ubyte16 t2 = shufflevector!(ubyte16, 2, 5, 8, 11, 14, 17, 20, 23, 26, 29, 0, 0, 0, 0, 0, 0)(a, b);

        ubyte16 b0 = shufflevector!(ubyte16, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 17, 20, 23, 26, 29)(t0, cVec);
        ubyte16 b1 = shufflevector!(ubyte16, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 18, 21, 24, 27, 30)(t1, cVec);
        ubyte16 b2 = shufflevector!(ubyte16, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 16, 19, 22, 25, 28, 31)(t2, cVec);

        // The 6-bit values and the characters they map to.
        ubyte16 c0, c1, c2, c3;
        static if (hasTbl4)
        {
            ubyte16 tab0 = cast(ubyte16) _mm_setr_epi8(
                'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P');
            ubyte16 tab1 = cast(ubyte16) _mm_setr_epi8(
                'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'a', 'b', 'c', 'd', 'e', 'f');
            ubyte16 tab2 = cast(ubyte16) _mm_setr_epi8(
                'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v');
            ubyte16 tab3 = cast(ubyte16) _mm_setr_epi8(
                'w', 'x', 'y', 'z', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', Map62th, Map63th);
            // map compile-time chars already encoded in t3 literals? ensure Map62/63:
            // (the setr above uses Map62th/Map63th template constants directly)

            c0 = tbl4(tab0, tab1, tab2, tab3, cast(ubyte16)(b0 >> 2));
            c1 = tbl4(tab0, tab1, tab2, tab3, cast(ubyte16)((b0 << 4 | b1 >> 4) & 63));
            c2 = tbl4(tab0, tab1, tab2, tab3, cast(ubyte16)((b1 << 2 | b2 >> 6) & 63));
            c3 = tbl4(tab0, tab1, tab2, tab3, cast(ubyte16)(b2 & 63));
        }
        else
        {
            c0 = toChar!(Map62th, Map63th)(cast(ubyte16)(b0 >> 2));
            c1 = toChar!(Map62th, Map63th)(cast(ubyte16)((b0 << 4 | b1 >> 4) & 63));
            c2 = toChar!(Map62th, Map63th)(cast(ubyte16)((b1 << 2 | b2 >> 6) & 63));
            c3 = toChar!(Map62th, Map63th)(cast(ubyte16)(b2 & 63));
        }

        // Interleave the four character streams back into group order: first
        // each adjacent pair, then those pairs. Groups 0..7 out of the low
        // shuffles, groups 8..15 out of the high ones.
        ubyte16 lo01 = shufflevector!(ubyte16, 0, 16, 1, 17, 2, 18, 3, 19, 4, 20, 5, 21, 6, 22, 7, 23)(c0, c1);
        ubyte16 lo23 = shufflevector!(ubyte16, 0, 16, 1, 17, 2, 18, 3, 19, 4, 20, 5, 21, 6, 22, 7, 23)(c2, c3);
        ubyte16 hi01 = shufflevector!(ubyte16, 8, 24, 9, 25, 10, 26, 11, 27, 12, 28, 13, 29, 14, 30, 15, 31)(c0, c1);
        ubyte16 hi23 = shufflevector!(ubyte16, 8, 24, 9, 25, 10, 26, 11, 27, 12, 28, 13, 29, 14, 30, 15, 31)(c2, c3);

        storeVec(
            shufflevector!(ubyte16, 0, 1, 16, 17, 2, 3, 18, 19, 4, 5, 20, 21, 6, 7, 22, 23)(lo01, lo23),
            cast(ubyte*) o);
        storeVec(
            shufflevector!(ubyte16, 8, 9, 24, 25, 10, 11, 26, 27, 12, 13, 28, 29, 14, 15, 30, 31)(lo01, lo23),
            cast(ubyte*) (o + 16));
        storeVec(
            shufflevector!(ubyte16, 0, 1, 16, 17, 2, 3, 18, 19, 4, 5, 20, 21, 6, 7, 22, 23)(hi01, hi23),
            cast(ubyte*) (o + 32));
        storeVec(
            shufflevector!(ubyte16, 8, 9, 24, 25, 10, 11, 26, 27, 12, 13, 28, 29, 14, 15, 30, 31)(hi01, hi23),
            cast(ubyte*) (o + 48));

        s += 48;
        o += 64;
    }
}
