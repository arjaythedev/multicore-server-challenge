/**
 * Shared internals of the base64 package.
 *
 * Copyright: 2026, Sergei Giniatulin
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 */
module base64.internal;

/// The $(D_PARAM Padding) template parameter value that stands for "no
/// padding characters in the output".
enum NoPadding = '\0';

/// Whether the two hot loops are written with `core.simd` vector types
/// (`detail/simd_encoder.d` and `detail/simd_decoder.d`) or with plain byte
/// loops that the compiler auto-vectorises (`detail/encoder.d` and
/// `detail/decoder.d`).
///
/// `core.simd` is not implemented on every compiler and target pair, so the
/// default is a compile-time probe of what this build actually supports. The
/// build can force either way:
/// -----
/// ldmd2 -version=SIMD ...      # always use core.simd
/// ldmd2 -version=no_SIMD ...    # always use the plain byte loops
/// -----
/// which is what the `SIMD` and `no_SIMD` dub configurations, and
/// `benchmark/run.sh`, use so that the two can be compared.
public enum bool useSimd = detectSimd;

version (SIMD)
    private enum detectSimd = true;
else version (no_SIMD)
    private enum detectSimd = false;
else
    // The Intel-intrinsics (table based) path is taken by default on every
    // target that can compile it; `no_SIMD` opts back into the plain loops.
    private enum detectSimd = true;

/// Length of the encoding of $(D_PARAM sourceLength) bytes. Shared by the
/// public $(LREF encodeLength) and the internal contracts.
package(base64) size_t encodedLength(char Padding)(in size_t sourceLength)
        @safe pure nothrow @nogc
{
    static if (Padding == NoPadding)
        return sourceLength / 3 * 4
            + (sourceLength % 3 == 1 ? 2 : sourceLength % 3 == 2 ? 3 : 0);
    else
        return (sourceLength / 3 + (sourceLength % 3 ? 1 : 0)) * 4;
}

/**
 * Thrown when base64 encoded input cannot be decoded, either because it is not
 * a multiple of four characters long, or because it contains a character that
 * is not part of the alphabet.
 */
class Base64Exception : Exception
{
    ///
    @safe pure nothrow @nogc
    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }
}
