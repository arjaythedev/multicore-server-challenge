/**
 * Fast base64 encoding and decoding for D.
 *
 * The public API mirrors $(LREF2 std, base64), so moving between the two is
 * mostly a matter of changing the import:
 * -----
 * import base64;
 *
 * ubyte[] data = [0x14, 0xfb, 0x9c, 0x03, 0xd9, 0x7e];
 * assert(Base64.encode(data) == "FPucA9l+");
 * assert(Base64.decode("FPucA9l+") == data);
 * -----
 *
 * There are two flavours of every function: one that writes into a buffer
 * supplied by the caller, which is allocation free and is what the hot loops
 * use, and one that allocates the result.
 *
 * The hot loops are written in a style that the compiler auto-vectorises:
 * each one is a single loop over a trip count that is only known at run time,
 * whose body is plain byte arithmetic. On AArch64 the compiler turns that into
 * `ld3`/`st4` interleaved load/store instructions and a chain of vector
 * compares and selects, with no hand written SIMD intrinsics involved. See
 * `benchmark/README.md` for measured throughput.
 *
 * Copyright: 2026, Sergei Giniatulin
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Authors: Sergei Giniatulin
 */
module base64;

import std.traits : isArray;
import std.range.primitives : ElementType, isOutputRange;
import std.range.primitives : isOutputRange;

public import base64.internal : Base64Exception;

/**
 * Implementation of standard _Base64 encoding.
 *
 * See $(LREF Base64Impl) for a description of the available functions.
 */
alias Base64 = Base64Impl!('+', '/');

/**
 * Variation of _Base64 encoding that is safe for use in URLs and filenames.
 *
 * See $(LREF Base64Impl) for a description of the available functions.
 */
alias Base64URL = Base64Impl!('-', '_');

/**
 * Unpadded variation of _Base64 encoding that is safe for use in URLs and
 * filenames, as used in RFCs 4648 and 7515 (JWS/JWT/JWE).
 *
 * See $(LREF Base64Impl) for a description of the available functions.
 */
alias Base64URLNoPadding = Base64Impl!('-', '_', Base64.NoPadding);

/**
 * Template for implementing _Base64 encoding.
 *
 * For most purposes, direct usage of this template is not necessary; instead,
 * this package provides default implementations: $(LREF Base64), implementing
 * basic _Base64 encoding, and $(LREF Base64URL) and
 * $(LREF Base64URLNoPadding), that implement the _Base64 variant for use in
 * URLs and filenames, with and without padding, respectively.
 *
 * Customized _Base64 encoding schemes can be implemented by instantiating
 * this template with the appropriate arguments. For example:
 * -----
 * // Non-standard Base64 format for embedding in regular expressions.
 * alias Base64Re = Base64Impl!('!', '=', Base64.NoPadding);
 * -----
 *
 * NOTE:
 * Encoded strings will not have any padding if the $(D_PARAM Padding)
 * parameter is set to $(LREF NoPadding).
 */
template Base64Impl(char Map62th, char Map63th, char Padding = '=')
{
    import base64.detail.encoder : encodeBuffer, encodeTail, encodeValue;
    import base64.detail.decoder : decodeBuffer, decodeFastGroups, decodeTail,
        findInvalid;
    import base64.internal : Base64Exception, encodedLength;
    import std.exception : enforce;

    /// Represents a no-padding encoding.
    enum NoPadding = '\0';

    // Verify Base64 characters
    static assert(Map62th < 'A' || Map62th > 'Z', "Character '" ~ Map62th ~ "' cannot be used twice");
    static assert(Map63th < 'A' || Map63th > 'Z', "Character '" ~ Map63th ~ "' cannot be used twice");
    static assert(Padding < 'A' || Padding > 'Z', "Character '" ~ Padding ~ "' cannot be used twice");
    static assert(Map62th < 'a' || Map62th > 'z', "Character '" ~ Map62th ~ "' cannot be used twice");
    static assert(Map63th < 'a' || Map63th > 'z', "Character '" ~ Map63th ~ "' cannot be used twice");
    static assert(Padding < 'a' || Padding > 'z', "Character '" ~ Padding ~ "' cannot be used twice");
    static assert(Map62th < '0' || Map62th > '9', "Character '" ~ Map62th ~ "' cannot be used twice");
    static assert(Map63th < '0' || Map63th > '9', "Character '" ~ Map63th ~ "' cannot be used twice");
    static assert(Padding < '0' || Padding > '9', "Character '" ~ Padding ~ "' cannot be used twice");
    static assert(Map62th != Map63th, "Character '" ~ Map63th ~ "' cannot be used twice");
    static assert(Map62th != Padding, "Character '" ~ Map62th ~ "' cannot be used twice");
    static assert(Map63th != Padding, "Character '" ~ Map63th ~ "' cannot be used twice");
    static assert(Map62th != NoPadding, "'\\0' is not a valid Base64 character");
    static assert(Map63th != NoPadding, "'\\0' is not a valid Base64 character");

    /* Encode functions */

    /**
     * Calculates the length needed to store the encoded string corresponding
     * to an input of the given length.
     *
     * Params:
     *  sourceLength = Length of the source array.
     *
     * Returns:
     *  The length of a Base64 encoding of an array of the given length.
     */
    @safe @nogc
    pure nothrow size_t encodeLength(in size_t sourceLength)
    {
        return encodedLength!Padding(sourceLength);
    }

    /**
     * Encode $(D_PARAM source) into a `char[]` buffer using Base64 encoding.
     *
     * Params:
     *  source = The array to _encode.
     *  buffer = The `char[]` buffer to store the encoded result.
     *
     * Returns:
     *  The slice of $(D_PARAM buffer) that contains the encoded string.
     */
    @trusted
    pure char[] encode(R1, R2)(const scope R1 source, return scope R2 buffer)
    if (isArray!R1 && is(ElementType!R1 : ubyte) && is(R2 == char[]))
    in
    {
        assert(buffer.length >= encodeLength(source.length),
            "Insufficient buffer for encoding");
    }
    out (result)
    {
        assert(result.length == encodeLength(source.length),
            "The length of result is different from Base64");
    }
    do
    {
        char[] buf = buffer;
        immutable srcLen = source.length;
        if (srcLen == 0)
            return buf[0 .. 0];

        // The auto-vectorised bulk of the work.
        encodeBuffer!(Map62th, Map63th)(source, buf);

        // The remaining 0, 1 or 2 bytes and the padding characters.
        encodeTail!(Map62th, Map63th, Padding)(source, buf);

        return buf[0 .. encodeLength(srcLen)];
    }

    /**
     * Encodes $(D_PARAM source) into a newly allocated `char[]`.
     */
    @safe
    pure char[] encode(Range)(Range source)
    if (isArray!Range && is(ElementType!Range : ubyte))
    {
        auto buffer = new char[encodeLength(source.length)];
        return encode(source, buffer);
    }

    /* Decode functions */

    /**
     * Given a Base64 encoded string, calculates the length of the decoded
     * string.
     *
     * Params:
     *  sourceLength = The length of the Base64 encoding.
     *
     * Returns:
     *  The length of the decoded string corresponding to a Base64 encoding of
     * length $(D_PARAM sourceLength).
     */
    @safe @nogc
    pure nothrow size_t decodeLength(in size_t sourceLength)
    {
        static if (Padding == NoPadding)
            return (sourceLength / 4) * 3
                + (sourceLength % 4 < 2 ? 0 : sourceLength % 4 == 2 ? 1 : 2);
        else
            return (sourceLength / 4) * 3;
    }

    // Used in decode contracts. Calculates the actual size the decoded result
    // should have, taking into account trailing padding.
    @safe
    pure @nogc nothrow private size_t realDecodeLength(R)(R source)
    {
        auto expect = decodeLength(source.length);
        static if (Padding != NoPadding)
        {
            if (source.length % 4 == 0)
            {
                expect -= source.length == 0       ? 0 :
                          source[$ - 2] == Padding ? 2 :
                          source[$ - 1] == Padding ? 1 : 0;
            }
        }
        return expect;
    }

    /**
     * Decodes $(D_PARAM source) into the given buffer.
     *
     * New line characters (`\r` and `\n`) are ignored.
     *
     * Params:
     *  source = The array to _decode.
     *  buffer = The buffer to store the decoded result.
     *
     * Returns:
     *  The slice of $(D_PARAM buffer) containing the decoded result.
     *
     * Throws:
     *  $(LREF Base64Exception) if $(D_PARAM source) contains characters
     *  outside the base alphabet of the current Base64 encoding scheme.
     */
    @trusted
    ubyte[] decode(R1, R2)(const scope R1 source, return scope R2 buffer)
    if (isArray!R1 && is(ElementType!R1 : dchar) &&
        is(R2 == ubyte[]) && isOutputRange!(R2, ubyte))
    in
    {
        assert(buffer.length >= realDecodeLength(source),
            "Insufficient buffer for decoding");
    }
    out (result)
    {
        immutable expect = realDecodeLength(source);
        assert(result.length == expect,
            "The length of result is different from the expected length");
    }
    do
    {
        immutable srcLen = source.length;
        if (srcLen == 0)
            return cast(ubyte[]) buffer[0 .. 0];

        static if (Padding != NoPadding)
            enforce(srcLen % 4 == 0,
                new Base64Exception("Invalid length of encoded data"));

        // The auto-vectorised bulk of the work. It does not look at padding,
        // which can only ever be in the last group, so a failure here means
        // the input contains a character that is not in the alphabet. Locate
        // it only once the fast path has rejected the input.
        if (!decodeBuffer!(Map62th, Map63th, Padding)(source, buffer))
        {
            immutable i = findInvalid!(Map62th, Map63th, Padding)(source);
            throw new Base64Exception("Invalid character: " ~ source[i]);
        }

        // The last group, which may hold padding or an incomplete group.
        immutable size_t tail = decodeTail!(Map62th, Map63th, Padding)(source, buffer);
        immutable size_t decoded = decodeFastGroups!Padding(source) * 3 + tail;

        return buffer[0 .. decoded];
    }

    /**
     * Decodes $(D_PARAM source) into a newly allocated `ubyte[]`.
     *
     * Throws:
     *  $(LREF Base64Exception) if $(D_PARAM source) contains characters
     *  outside the base alphabet of the current Base64 encoding scheme.
     */
    ubyte[] decode(Range)(Range source)
    if (isArray!Range && is(ElementType!Range : dchar))
    {
        auto buffer = new ubyte[decodeLength(source.length)];
        return decode(source, buffer);
    }
}
