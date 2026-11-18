# HTTP/1.1 request parsing and response framing. Requests are parsed in place: a Request holds offsets into the
# connection's input bytes, nothing is copied.

from buf import BytePtr, ByteBuf
from json import put_json_str

comptime METHOD_OTHER = 0
comptime METHOD_GET = 1
comptime METHOD_POST = 2
comptime METHOD_PUT = 3
comptime METHOD_DELETE = 4

comptime MAX_HEADER_BYTES = 16 * 1024
comptime MAX_BODY_BYTES = 1024 * 1024

# parse_request results besides "bytes consumed"
comptime PARSE_INCOMPLETE = 0
comptime PARSE_BAD = -1
comptime PARSE_TOO_LARGE = -2
comptime PARSE_UNSUPPORTED = -3

comptime CR: UInt8 = 13
comptime LF: UInt8 = 10
comptime SP: UInt8 = 32
comptime COLON: UInt8 = 58
comptime QMARK: UInt8 = 63


struct Request(ImplicitlyCopyable):
    var method: Int
    var path_off: Int
    var path_len: Int
    var query_off: Int
    var query_len: Int
    var auth_off: Int
    var auth_len: Int
    var body_off: Int
    var body_len: Int
    var keep_alive: Bool

    def __init__(out self):
        self.method = METHOD_OTHER
        self.path_off = 0
        self.path_len = 0
        self.query_off = 0
        self.query_len = 0
        self.auth_off = 0
        self.auth_len = 0
        self.body_off = 0
        self.body_len = 0
        self.keep_alive = True


@inline(.always)
def lower(b: UInt8) -> UInt8:
    return b | 0x20 if b >= 65 and b <= 90 else b


def eq_lit(p: BytePtr, n: Int, lit: StaticString) -> Bool:
    if n != lit.byte_length():
        return False
    var l = lit.unsafe_ptr()
    for i in range(n):
        if p[unsafe_offset=i] != l[unsafe_offset=i]:
            return False
    return True


def eq_lit_ci(p: BytePtr, n: Int, lit: StaticString) -> Bool:
    """Case-insensitive compare against a lowercase literal."""
    if n != lit.byte_length():
        return False
    var l = lit.unsafe_ptr()
    for i in range(n):
        if lower(p[unsafe_offset=i]) != l[unsafe_offset=i]:
            return False
    return True


def contains_token_ci(p: BytePtr, n: Int, lit: StaticString) -> Bool:
    """Whether a comma-separated header value contains `lit` (lowercase) as one of its tokens."""
    var i = 0
    while i < n:
        while i < n and (p[unsafe_offset=i] == SP or p[unsafe_offset=i] == 44):
            i += 1
        var start = i
        while i < n and p[unsafe_offset=i] != 44:
            i += 1
        var end = i
        while end > start and p[unsafe_offset=end - 1] == SP:
            end -= 1
        if eq_lit_ci(p.unsafe_offset(start), end - start, lit):
            return True
    return False


def find_header_end(p: BytePtr, n: Int) -> Int:
    """Offset just past the CRLFCRLF that ends the headers, or -1."""
    var i = 3
    while i < n:
        if p[unsafe_offset=i] == LF:
            if p[unsafe_offset=i - 1] == CR and p[unsafe_offset=i - 2] == LF and p[unsafe_offset=i - 3] == CR:
                return i + 1
            i += 1
        else:
            # The last byte of the terminator is LF; anything else lets us skip ahead.
            i += 1
    return -1


def parse_request(p: BytePtr, n: Int, mut req: Request) -> Int:
    """Parses one request at `p`. Returns the bytes it occupies (headers + body), or a PARSE_* code."""
    var head = find_header_end(p, n)
    if head < 0:
        return PARSE_TOO_LARGE if n > MAX_HEADER_BYTES else PARSE_INCOMPLETE
    if head > MAX_HEADER_BYTES:
        return PARSE_TOO_LARGE
    req = Request()

    # request line: METHOD SP target SP HTTP/1.x CRLF
    var i = 0
    while i < head and p[unsafe_offset=i] != SP:
        i += 1
    if eq_lit(p, i, "GET"):
        req.method = METHOD_GET
    elif eq_lit(p, i, "POST"):
        req.method = METHOD_POST
    elif eq_lit(p, i, "PUT"):
        req.method = METHOD_PUT
    elif eq_lit(p, i, "DELETE"):
        req.method = METHOD_DELETE
    i += 1
    var t0 = i
    while i < head and p[unsafe_offset=i] != SP and p[unsafe_offset=i] != QMARK:
        i += 1
    req.path_off = t0
    req.path_len = i - t0
    if i < head and p[unsafe_offset=i] == QMARK:
        i += 1
        var q0 = i
        while i < head and p[unsafe_offset=i] != SP:
            i += 1
        req.query_off = q0
        req.query_len = i - q0
    if i >= head or req.path_len == 0:
        return PARSE_BAD
    i += 1
    var v0 = i
    while i < head and p[unsafe_offset=i] != CR:
        i += 1
    if eq_lit(p.unsafe_offset(v0), i - v0, "HTTP/1.1"):
        req.keep_alive = True
    elif eq_lit(p.unsafe_offset(v0), i - v0, "HTTP/1.0"):
        req.keep_alive = False
    else:
        return PARSE_BAD
    i += 2

    # headers
    var content_length = 0
    while i < head - 2:
        var n0 = i
        while i < head and p[unsafe_offset=i] != COLON and p[unsafe_offset=i] != CR:
            i += 1
        if i >= head or p[unsafe_offset=i] != COLON:
            return PARSE_BAD
        var name = p.unsafe_offset(n0)
        var name_len = i - n0
        i += 1
        while i < head and (p[unsafe_offset=i] == SP or p[unsafe_offset=i] == 9):
            i += 1
        var val0 = i
        while i < head and p[unsafe_offset=i] != CR:
            i += 1
        var val_end = i
        while val_end > val0 and (p[unsafe_offset=val_end - 1] == SP or p[unsafe_offset=val_end - 1] == 9):
            val_end -= 1
        var val = p.unsafe_offset(val0)
        var val_len = val_end - val0
        i += 2
        var c = lower(name[])
        if c == 99 and eq_lit_ci(name, name_len, "content-length"):  # 'c'
            if val_len == 0 or val_len > 9:
                return PARSE_BAD
            content_length = 0
            for k in range(val_len):
                var d = Int(val[unsafe_offset=k]) - 48
                if d < 0 or d > 9:
                    return PARSE_BAD
                content_length = content_length * 10 + d
        elif c == 99 and eq_lit_ci(name, name_len, "connection"):
            if contains_token_ci(val, val_len, "close"):
                req.keep_alive = False
            elif contains_token_ci(val, val_len, "keep-alive"):
                req.keep_alive = True
        elif c == 97 and eq_lit_ci(name, name_len, "authorization"):  # 'a'
            req.auth_off = val0
            req.auth_len = val_len
        elif c == 116 and eq_lit_ci(name, name_len, "transfer-encoding"):  # 't'
            return PARSE_UNSUPPORTED

    if content_length > MAX_BODY_BYTES:
        return PARSE_TOO_LARGE
    if head + content_length > n:
        return PARSE_INCOMPLETE
    req.body_off = head
    req.body_len = content_length
    return head + content_length


def status_line(status: Int) -> StaticString:
    if status == 200:
        return "HTTP/1.1 200 OK\r\n"
    if status == 201:
        return "HTTP/1.1 201 Created\r\n"
    if status == 204:
        return "HTTP/1.1 204 No Content\r\n"
    if status == 400:
        return "HTTP/1.1 400 Bad Request\r\n"
    if status == 401:
        return "HTTP/1.1 401 Unauthorized\r\n"
    if status == 403:
        return "HTTP/1.1 403 Forbidden\r\n"
    if status == 404:
        return "HTTP/1.1 404 Not Found\r\n"
    if status == 413:
        return "HTTP/1.1 413 Content Too Large\r\n"
    if status == 422:
        return "HTTP/1.1 422 Unprocessable Content\r\n"
    if status == 431:
        return "HTTP/1.1 431 Request Header Fields Too Large\r\n"
    if status == 501:
        return "HTTP/1.1 501 Not Implemented\r\n"
    return "HTTP/1.1 500 Internal Server Error\r\n"


comptime LENGTH_DIGITS = 8


struct Response:
    """Writes one response into the output buffer. The body is written after the headers, and Content-Length is
    filled in at the end into a fixed-width, space-padded slot, so the body never has to be copied."""

    var status_at: Int  # where this response starts in the buffer, to roll it back
    var length_at: Int
    var body_at: Int

    def __init__(out self, mut out_buf: ByteBuf, status: Int, keep_alive: Bool):
        self.status_at = out_buf.len
        out_buf.put_str(status_line(status))
        if not keep_alive:
            out_buf.put_str("Connection: close\r\n")
        if status == 204:
            out_buf.put_str("\r\n")
            self.length_at = -1
            self.body_at = out_buf.len
            return
        out_buf.put_str("Content-Type: application/json\r\nContent-Length: ")
        self.length_at = out_buf.len
        out_buf.put_str("        \r\n\r\n")  # LENGTH_DIGITS spaces
        self.body_at = out_buf.len

    def finish(self, mut out_buf: ByteBuf):
        if self.length_at < 0:
            return
        var n = out_buf.len - self.body_at
        var at = self.length_at + LENGTH_DIGITS - 1
        while True:
            out_buf.ptr[unsafe_offset=at] = UInt8(48 + n % 10)
            n //= 10
            at -= 1
            if n == 0:
                break


def error_response(mut out_buf: ByteBuf, status: Int, keep_alive: Bool, msg: StaticString):
    var r = Response(out_buf, status, keep_alive)
    out_buf.put_str('{"errors":{"body":[')
    put_json_str(out_buf, msg)
    out_buf.put_str("]}}")
    r.finish(out_buf)
