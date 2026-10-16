/**
 * base64 decoder written on $(LREF2 core, simd, intel-intrinsics) vector types.
 *
 * Only compiled when `version(SIMD)` (or the auto-detection in
 * $(LREF base64.internal.useSimd)) says this build can take the SIMD path; the
 * plain byte loop in `base64.detail.decoder` is what gets compiled otherwise.
 *
 * One iteration decodes 16 groups: 64 characters in, 48 bytes out, in vectors
 * of 16 bytes.
 *
 * As in the encoder, the layout has to be built out of `shufflevector` calls,
 * because `intel-intrinsics` has no interleaved load: the four character streams are
 * gathered with twelve shuffles, the four 6-bit values per group are recovered
 * with the same range arithmetic as the scalar path, and the three output
 * streams are written back with six more shuffles.
 *
 * Invalid characters are detected inside the loop, by the same trick as the
 * plain loop: a value above 63 can only come from a character outside the
 * alphabet, so the four value streams are OR-ed into accumulators that the
 * caller inspects once at the end.
 *
 * Copyright: 2026, Sergei Giniatulin
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 */
module base64.detail.simd_decoder;

import inteli.emmintrin;
import inteli.smmintrin;
import inteli.tmmintrin;
import inteli.types;
import core.simd : ubyte16;
import base64.detail.decoder : decodeValue;
import ldc.llvmasm;

import ldc.simd : equalMask, greaterMask, loadUnaligned, shufflevector,
    storeUnaligned;

/// Number of 4-character groups handled by one iteration of the vector loop.
enum size_t lanes = 16;

private void storeVec(ubyte16 v, ubyte* p) @trusted pure nothrow @nogc {
    _mm_storeu_si128(cast(__m128i*) p, cast(__m128i) v);
}



version (AArch64)
{
    private ubyte16 tbl4_(ubyte16 a, ubyte16 b, ubyte16 c, ubyte16 d, ubyte16 idx)
        @trusted pure nothrow @nogc
    {
        return __ir_pure!(`%r = call <16 x i8> @llvm.aarch64.neon.tbl4.v16i8(<16 x i8> %0, <16 x i8> %1, <16 x i8> %2, <16 x i8> %3, <16 x i8> %4)
                           ret <16 x i8> %r`, ubyte16)(a, b, c, d, idx);
    }

    private ubyte16 tbx4_(ubyte16 acc, ubyte16 a, ubyte16 b, ubyte16 c, ubyte16 d, ubyte16 idx)
        @trusted pure nothrow @nogc
    {
        return __ir_pure!(`%r = call <16 x i8> @llvm.aarch64.neon.tbx4.v16i8(<16 x i8> %0, <16 x i8> %1, <16 x i8> %2, <16 x i8> %3, <16 x i8> %4, <16 x i8> %5)
                           ret <16 x i8> %r`, ubyte16)(acc, a, b, c, d, idx);
    }

    private ubyte16 uqsub_(ubyte16 a, ubyte16 b) @trusted pure nothrow @nogc
    {
        return __ir_pure!(`%r = call <16 x i8> @llvm.aarch64.neon.uqsub.v16i8(<16 x i8> %0, <16 x i8> %1)
                           ret <16 x i8> %r`, ubyte16)(a, b);
    }
}

private enum bool hasTbl4 = __traits(compiles, { ubyte16 _x; _x = tbl4_(_x, _x, _x, _x, _x); });

/// `mask ? a : b`, as the bit-select idiom.
private ubyte16 blend(ubyte16 a, ubyte16 b, ubyte16 mask) @safe pure nothrow @nogc
{
    return cast(ubyte16)(a ^ (cast(ubyte16)(a ^ b) & mask));
}

/// Every byte of a constant vector, for the range masks.
private ubyte16 filled(ubyte value_) @trusted pure nothrow @nogc
{
    align(16) ubyte[16] buf;
    buf[] = value_;
    return *cast(const(ubyte16)*) buf.ptr;
}

/// The vector version of $(LREF base64.detail.decoder.decodeValue).
///
/// Returns 0xFF for characters outside the alphabet, which is also how invalid
/// input is spotted: the caller tests for values above 63.
private ubyte16 toValue(char Map62th, char Map63th, char Padding)(ubyte16 chars)
        @safe pure nothrow @nogc
{
    immutable ubyte16 k25 = filled(25);
    immutable ubyte16 k9 = filled(9);
    immutable ubyte16 outOfRange = filled(0xFF);

    // One subtraction per range, each tested by a single unsigned comparison:
    // the subtraction wraps around to a large value for the characters just
    // below a range, which is what keeps `{`, `|`, `}`, `~`, `` ` `` and `[`
    // out.
    ubyte16 lo = cast(ubyte16)(chars - 'a');
    ubyte16 up = cast(ubyte16)(chars - 'A');
    ubyte16 di = cast(ubyte16)(chars - '0');

    ubyte16 mLo = cast(ubyte16)(~cast(ubyte16) greaterMask!ubyte16(lo, k25));
    ubyte16 mUp = cast(ubyte16)(~cast(ubyte16) greaterMask!ubyte16(up, k25));
    ubyte16 mDi = cast(ubyte16)(~cast(ubyte16) greaterMask!ubyte16(di, k9));

    ubyte16 v = blend(outOfRange, cast(ubyte16)(di + 52), mDi);
    v = blend(v, up, mUp);
    v = blend(v, cast(ubyte16)(lo + 26), mLo);

    // The two characters that belong to no range.
    v = blend(v, filled(62), cast(ubyte16) equalMask!ubyte16(chars, filled(Map62th)));
    v = blend(v, filled(63), cast(ubyte16) equalMask!ubyte16(chars, filled(Map63th)));

    // Padding is not a range character either, so blend it back to invalid.
    static if (Padding != '\0')
        v = blend(v, outOfRange, cast(ubyte16) equalMask!ubyte16(chars, filled(Padding)));

    return v;
}

/**
 * Decodes $(D_PARAM groups) complete groups of four characters with vector
 * types, in whole blocks of $(LREF lanes) groups.
 *
 * Returns `false` when a character outside the alphabet was seen, in which case
 * the caller has to locate it with a scalar scan.
 */
package(base64) bool decodeBuffer(char Map62th, char Map63th, char Padding)
    (const(char)[] src, ubyte[] dst) @trusted pure nothrow @nogc
in
{
    assert(dst.length >= src.length / 4 * 3, "Output buffer too small");
}
do
{
    immutable size_t blocks = (src.length / 4) / lanes;
    if (blocks == 0)
        return true;

    const(char)* s = src.ptr;
    ubyte* o = dst.ptr;


    static if (hasTbl4)
    {
        static immutable ubyte[64] _L1 = () {
            ubyte[64] t;
            foreach (int i; 0 .. 64)
            {
                ubyte v = cast(ubyte) decodeValue!(Map62th, Map63th, Padding)(cast(char) i);
                t[i] = (v <= 63) ? v : cast(ubyte) 255;
            }
            return t;
        }();
        static immutable ubyte[64] _L2 = () {
            ubyte[64] t;
            t[0] = 0;
            foreach (int i; 1 .. 64)
            {
                char ch = cast(char)(i + 63);
                ubyte v = cast(ubyte) decodeValue!(Map62th, Map63th, Padding)(ch);
                t[i] = (v <= 63) ? v : cast(ubyte) 255;
            }
            return t;
        }();
        ubyte16 t1r0 = *cast(ubyte16*) _L1.ptr;
        ubyte16 t1r1 = *cast(ubyte16*)(_L1.ptr + 16);
        ubyte16 t1r2 = *cast(ubyte16*)(_L1.ptr + 32);
        ubyte16 t1r3 = *cast(ubyte16*)(_L1.ptr + 48);
        ubyte16 t2r0 = *cast(ubyte16*) _L2.ptr;
        ubyte16 t2r1 = *cast(ubyte16*)(_L2.ptr + 16);
        ubyte16 t2r2 = *cast(ubyte16*)(_L2.ptr + 32);
        ubyte16 t2r3 = *cast(ubyte16*)(_L2.ptr + 48);

        ubyte16 decodeVec(ubyte16 str) @trusted pure nothrow @nogc
        {
            ubyte16 idx = uqsub_(str, filled(63));
            ubyte16 d1 = tbl4_(t1r0, t1r1, t1r2, t1r3, str);
            ubyte16 d2 = tbx4_(idx, t2r0, t2r1, t2r2, t2r3, idx);
            return cast(ubyte16)(d1 | d2);
        }
    }

    // Two independent accumulators keep the reduce from serialising the loop.
    ubyte16 acc0 = filled(0);
    ubyte16 acc1 = filled(0);

    foreach (immutable blk; 0 .. blocks)
    {
        // Four 16-byte loads carry the 64 input characters.
        ubyte16 v0 = cast(ubyte16) _mm_loadu_si128(cast(const(__m128i)*) s);
        ubyte16 v1 = cast(ubyte16) _mm_loadu_si128(cast(const(__m128i)*) (s + 16));
        ubyte16 v2 = cast(ubyte16) _mm_loadu_si128(cast(const(__m128i)*) (s + 32));
        ubyte16 v3 = cast(ubyte16) _mm_loadu_si128(cast(const(__m128i)*) (s + 48));

        // De-interleave into the four character streams.
        ubyte16 a = gatherStream!0(v0, v1, v2, v3);
        ubyte16 b = gatherStream!1(v0, v1, v2, v3);
        ubyte16 c = gatherStream!2(v0, v1, v2, v3);
        ubyte16 d = gatherStream!3(v0, v1, v2, v3);

        ubyte16 va, vb, vc, vd;
        static if (hasTbl4)
        {
            va = decodeVec(a);
            vb = decodeVec(b);
            vc = decodeVec(c);
            vd = decodeVec(d);
        }
        else
        {
            va = toValue!(Map62th, Map63th, Padding)(a);
            vb = toValue!(Map62th, Map63th, Padding)(b);
            vc = toValue!(Map62th, Map63th, Padding)(c);
            vd = toValue!(Map62th, Map63th, Padding)(d);
        }

        acc0 = cast(ubyte16)(acc0 | va | vb);
        acc1 = cast(ubyte16)(acc1 | vc | vd);

        ubyte16 o0 = cast(ubyte16)(va << 2 | vb >> 4);
        ubyte16 o1 = cast(ubyte16)(vb << 4 | vc >> 2);
        ubyte16 o2 = cast(ubyte16)(vc << 6 | vd);

        // Write the three output streams back in group order.
        storeInterleaved(o0, o1, o2, cast(ubyte*) o);

        s += 64;
        o += 48;
    }

    // A value above 63 can only come from a character outside the alphabet.
    foreach (x; acc0.array)
        if (x > 63)
            return false;
    foreach (x; acc1.array)
        if (x > 63)
            return false;
    return true;
}

/**
 * Gathers the characters at positions $(D_PARAM offset), $(D_PARAM offset) + 4,
 * and so on, across the four loaded vectors: one of the four streams a group
 * carries.
 */
private ubyte16 gatherStream(ubyte offset)(ubyte16 v0, ubyte16 v1, ubyte16 v2,
    ubyte16 v3) @safe pure nothrow @nogc
{
    // `v0` holds characters 0..15, `v1` 16..31, `v2` 32..47 and `v3` 48..63, so
    // a mask index of `n` means character `n` of `v0`, and 16 + n of `v1`.
    ubyte16 t0, t1;

    static if (offset == 0)
    {
        t0 = shufflevector!(ubyte16, 0, 4, 8, 12, 16, 20, 24, 28, 0, 0, 0, 0, 0, 0, 0, 0)(v0, v1);
        t1 = shufflevector!(ubyte16, 0, 4, 8, 12, 16, 20, 24, 28, 0, 0, 0, 0, 0, 0, 0, 0)(v2, v3);
    }
    else static if (offset == 1)
    {
        t0 = shufflevector!(ubyte16, 1, 5, 9, 13, 17, 21, 25, 29, 0, 0, 0, 0, 0, 0, 0, 0)(v0, v1);
        t1 = shufflevector!(ubyte16, 1, 5, 9, 13, 17, 21, 25, 29, 0, 0, 0, 0, 0, 0, 0, 0)(v2, v3);
    }
    else static if (offset == 2)
    {
        t0 = shufflevector!(ubyte16, 2, 6, 10, 14, 18, 22, 26, 30, 0, 0, 0, 0, 0, 0, 0, 0)(v0, v1);
        t1 = shufflevector!(ubyte16, 2, 6, 10, 14, 18, 22, 26, 30, 0, 0, 0, 0, 0, 0, 0, 0)(v2, v3);
    }
    else
    {
        t0 = shufflevector!(ubyte16, 3, 7, 11, 15, 19, 23, 27, 31, 0, 0, 0, 0, 0, 0, 0, 0)(v0, v1);
        t1 = shufflevector!(ubyte16, 3, 7, 11, 15, 19, 23, 27, 31, 0, 0, 0, 0, 0, 0, 0, 0)(v2, v3);
    }

    return shufflevector!(ubyte16, 0, 1, 2, 3, 4, 5, 6, 7, 16, 17, 18, 19, 20, 21, 22, 23)(t0, t1);
}

/**
 * Writes the three output streams back in group order: 16 groups, 48 bytes.
 *
 * Each of the three 16-byte stores needs the pair of streams interleaved one way
 * and the third stream dropped in at every third byte, which is two shuffles
 * per store.
 */
private void storeInterleaved(ubyte16 o0, ubyte16 o1, ubyte16 o2, ubyte* o)
        @trusted pure nothrow @nogc
{
    // Streams 0 and 1 interleaved for the groups each store covers: groups
    // 0..7, then 5..12, then 10..15.
    ubyte16 p = shufflevector!(ubyte16, 0, 16, 1, 17, 2, 18, 3, 19, 4, 20, 5, 21, 6, 22, 7, 23)(o0, o1);
    ubyte16 q = shufflevector!(ubyte16, 5, 21, 6, 22, 7, 23, 8, 24, 9, 25, 10, 26, 0, 0, 0, 0)(o0, o1);
    ubyte16 r = shufflevector!(ubyte16, 10, 26, 11, 27, 12, 28, 13, 29, 14, 30, 15, 31, 0, 0, 0, 0)(o0, o1);

    // Groups 0..4 and the first byte of group 5.
    storeVec(
        shufflevector!(ubyte16, 0, 1, 16, 2, 3, 17, 4, 5, 18, 6, 7, 19, 8, 9, 20, 10)(p, o2),
        cast(ubyte*) o);
    // The rest of group 5 through group 10.
    storeVec(
        shufflevector!(ubyte16, 1, 21, 2, 3, 22, 4, 5, 23, 6, 7, 24, 8, 9, 25, 10, 11)(q, o2),
        cast(ubyte*) (o + 16));
    // The rest of group 10 through group 15.
    storeVec(
        shufflevector!(ubyte16, 26, 2, 3, 27, 4, 5, 28, 6, 7, 29, 8, 9, 30, 10, 11, 31)(r, o2),
        cast(ubyte*) (o + 32));
}
