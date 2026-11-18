# JSON output: string escaping, and Postgres timestamps reformatted to the spec's RFC 3339 form.

from buf import BytePtr, ByteBuf

comptime HEX = "0123456789abcdef"


@inline(.always)
def needs_escape(c: UInt8) -> Bool:
    return c < 0x20 or c == 34 or c == 92  # control, '"', '\'


def put_json_str(mut out: ByteBuf, p: BytePtr, n: Int):
    """A JSON string literal. Bytes >= 0x80 pass through: Postgres sends valid UTF-8 (client_encoding UTF8)."""
    out.reserve(n + 2)
    out.put(34)
    var run = 0  # start of the current run of bytes that need no escaping
    for i in range(n):
        var c = p[unsafe_offset=i]
        if not needs_escape(c):
            continue
        if i > run:
            out.put_bytes(p.unsafe_offset(run), i - run)
        run = i + 1
        out.put(92)
        if c == 34 or c == 92:
            out.put(c)
        elif c == 10:
            out.put(110)  # n
        elif c == 13:
            out.put(114)  # r
        elif c == 9:
            out.put(116)  # t
        elif c == 8:
            out.put(98)  # b
        elif c == 12:
            out.put(102)  # f
        else:
            out.put_str("u00")
            out.put(HEX.ptr()[unsafe_offset=Int(c >> 4)])
            out.put(HEX.ptr()[unsafe_offset=Int(c & 15)])
    if n > run:
        out.put_bytes(p.unsafe_offset(run), n - run)
    out.put(34)


def put_json_str_or_null(mut out: ByteBuf, p: BytePtr, n: Int):
    if n < 0:
        out.put_str("null")
    else:
        put_json_str(out, p, n)


def put_json_str(mut out: ByteBuf, s: StringSlice):
    put_json_str(out, BytePtr(unsafe_from_address=Int(s.unsafe_ptr())), s.byte_length())


def put_timestamp(mut out: ByteBuf, p: BytePtr, n: Int):
    """Postgres timestamptz text with DateStyle ISO and TimeZone UTC ("2025-04-01 12:00:00.123456+00", fraction
    omitted or shortened when it has trailing zeros) to "2025-04-01T12:00:00.123Z": truncated, not rounded."""
    out.reserve(26)
    out.put(34)
    if n < 19:
        out.put_bytes(p, n)  # not a timestamp we know; pass it through
        out.put(34)
        return
    out.put_bytes(p, 10)
    out.put(84)  # T
    out.put_bytes(p.unsafe_offset(11), 8)
    out.put(46)  # .
    var digits = 0
    if n > 19 and p[unsafe_offset=19] == 46:
        var i = 20
        while i < n and digits < 3 and p[unsafe_offset=i] >= 48 and p[unsafe_offset=i] <= 57:
            out.put(p[unsafe_offset=i])
            digits += 1
            i += 1
    while digits < 3:
        out.put(48)
        digits += 1
    out.put(90)  # Z
    out.put(34)
