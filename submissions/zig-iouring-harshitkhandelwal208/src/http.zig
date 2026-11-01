//! HTTP/1.1 request parsing (keep-alive, Content-Length and chunked bodies) and response head assembly.
const std = @import("std");
const Scratch = @import("scratch.zig").Scratch;

pub const max_head = 16 * 1024;
pub const max_body = 8 * 1024 * 1024;
pub const max_chunks = 1024;

pub const Method = enum { get, post, put, delete, other };

pub const Head = struct {
    method: Method,
    path: []const u8, // raw (still percent-encoded), without the query
    query: []const u8, // raw, without '?'
    auth: ?[]const u8 = null,
    content_length: usize = 0,
    chunked: bool = false,
    keep_alive: bool = true,
    gzip: bool = false,
    identity: bool = true,
    head_len: usize = 0, // bytes up to and including the blank line
};

pub const Parsed = union(enum) {
    need_more,
    bad: u16,
    ok: Head,
};

fn trimOws(s: []const u8) []const u8 {
    var a: usize = 0;
    var b = s.len;
    while (a < b and (s[a] == ' ' or s[a] == '\t')) a += 1;
    while (b > a and (s[b - 1] == ' ' or s[b - 1] == '\t')) b -= 1;
    return s[a..b];
}

pub fn parseHead(data: []const u8) Parsed {
    const end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse {
        if (data.len > max_head) return .{ .bad = 431 };
        return .need_more;
    };
    if (end + 4 > max_head) return .{ .bad = 431 };
    const head = data[0..end];
    const line_end = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
    const line = head[0..line_end];
    const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse return .{ .bad = 400 };
    const sp2 = std.mem.lastIndexOfScalar(u8, line, ' ') orelse return .{ .bad = 400 };
    if (sp2 <= sp1) return .{ .bad = 400 };
    const m = line[0..sp1];
    const target = line[sp1 + 1 .. sp2];
    const ver = line[sp2 + 1 ..];
    var h: Head = .{
        .method = if (std.mem.eql(u8, m, "GET")) .get else if (std.mem.eql(u8, m, "POST")) .post else if (std.mem.eql(u8, m, "PUT")) .put else if (std.mem.eql(u8, m, "DELETE")) .delete else .other,
        .path = target,
        .query = "",
        .head_len = end + 4,
    };
    if (std.mem.eql(u8, ver, "HTTP/1.1")) {
        h.keep_alive = true;
    } else if (std.mem.eql(u8, ver, "HTTP/1.0")) {
        h.keep_alive = false;
    } else return .{ .bad = 505 };
    if (target.len == 0 or target[0] != '/') return .{ .bad = 400 };
    if (std.mem.indexOfScalar(u8, target, '?')) |q| {
        h.path = target[0..q];
        h.query = target[q + 1 ..];
    }
    var gzip_q: ?u16 = null;
    var identity_q: ?u16 = null;
    var star_q: ?u16 = null;
    var have_cl = false;
    var has_close = false;
    var pos = line_end;
    while (pos + 2 <= head.len) {
        pos += 2; // skip CRLF
        const le = std.mem.indexOfPos(u8, head, pos, "\r\n") orelse head.len;
        const l = head[pos..le];
        pos = le;
        if (l.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse return .{ .bad = 400 };
        const name = l[0..colon];
        if (name.len == 0 or name[name.len - 1] == ' ' or name[0] == ' ' or name[0] == '\t') return .{ .bad = 400 };
        const val = trimOws(l[colon + 1 ..]);
        switch (name.len) {
            13 => if (std.ascii.eqlIgnoreCase(name, "authorization")) {
                h.auth = val;
            },
            14 => if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                if (val.len == 0 or val.len > 12) return .{ .bad = 400 };
                var n: usize = 0;
                for (val) |c| {
                    if (c < '0' or c > '9') return .{ .bad = 400 };
                    n = n * 10 + (c - '0');
                }
                if (have_cl and n != h.content_length) return .{ .bad = 400 };
                have_cl = true;
                h.content_length = n;
            },
            10 => if (std.ascii.eqlIgnoreCase(name, "connection")) {
                var it = std.mem.tokenizeAny(u8, val, ", \t");
                while (it.next()) |tok| {
                    if (std.ascii.eqlIgnoreCase(tok, "close")) {
                        has_close = true;
                        h.keep_alive = false;
                    } else if (std.ascii.eqlIgnoreCase(tok, "keep-alive")) {
                        if (!has_close) h.keep_alive = true;
                    }
                }
            },
            15 => if (std.ascii.eqlIgnoreCase(name, "accept-encoding")) {
                var codings = std.mem.splitScalar(u8, val, ',');
                while (codings.next()) |coding| {
                    var params = std.mem.splitScalar(u8, coding, ';');
                    const encoding = trimOws(params.next().?);
                    var q: u16 = 1000;
                    var have_q = false;
                    while (params.next()) |raw| {
                        const param = trimOws(raw);
                        const eq = std.mem.indexOfScalar(u8, param, '=') orelse {
                            q = 0;
                            continue;
                        };
                        if (!std.ascii.eqlIgnoreCase(trimOws(param[0..eq]), "q") or have_q) {
                            q = 0;
                            continue;
                        }
                        have_q = true;
                        q = quality(trimOws(param[eq + 1 ..])) orelse 0;
                    }
                    if (std.ascii.eqlIgnoreCase(encoding, "gzip")) gzip_q = @min(gzip_q orelse q, q);
                    if (std.ascii.eqlIgnoreCase(encoding, "identity")) identity_q = @min(identity_q orelse q, q);
                    if (std.mem.eql(u8, encoding, "*")) star_q = @min(star_q orelse q, q);
                }
            },
            17 => if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
                if (std.ascii.eqlIgnoreCase(val, "chunked")) h.chunked = true else return .{ .bad = 501 };
            },
            else => {},
        }
    }
    h.gzip = (gzip_q orelse star_q orelse 0) > 0;
    h.identity = (identity_q orelse star_q orelse 1000) > 0;
    if (h.chunked and have_cl) return .{ .bad = 400 };
    if (h.content_length > max_body) return .{ .bad = 413 };
    return .{ .ok = h };
}

fn quality(s: []const u8) ?u16 {
    if (s.len == 0 or (s[0] != '0' and s[0] != '1')) return null;
    if (s.len == 1) return if (s[0] == '1') 1000 else 0;
    if (s[1] != '.' or s.len > 5) return null;
    var n: u16 = 0;
    var scale: u16 = 100;
    for (s[2..]) |c| {
        if (c < '0' or c > '9' or (s[0] == '1' and c != '0')) return null;
        n += @as(u16, c - '0') * scale;
        scale /= 10;
    }
    return if (s[0] == '1') 1000 else n;
}

pub const Body = union(enum) {
    need_more,
    bad: u16,
    /// `data` is the body; `consumed` is the number of bytes after the head that belong to this request.
    ok: struct { data: []const u8, consumed: usize },
};

/// `rest` is everything buffered after the head.
pub fn takeBody(h: *const Head, rest: []const u8, sc: *Scratch) Body {
    if (!h.chunked) {
        if (rest.len < h.content_length) return .need_more;
        return .{ .ok = .{ .data = rest[0..h.content_length], .consumed = h.content_length } };
    }
    // Chunked: validate the framing first (sizes), then copy the payload into scratch memory.
    // Framing is re-checked from the start whenever more bytes arrive, so everything that is scanned is bounded: at most
    // `max_chunks` chunks, size lines of at most 64 bytes (extensions included) and 4 KiB of trailers. Payload bytes are
    // jumped over by their size, never scanned.
    var pos: usize = 0;
    var total: usize = 0;
    var n_chunks: usize = 0;
    while (true) {
        const le = std.mem.indexOfPos(u8, rest, pos, "\r\n") orelse return if (rest.len - pos > 64) .{ .bad = 400 } else .need_more;
        if (le - pos > 64) return .{ .bad = 400 };
        var size_s = rest[pos..le];
        if (std.mem.indexOfScalar(u8, size_s, ';')) |sc_i| size_s = size_s[0..sc_i];
        size_s = trimOws(size_s);
        if (size_s.len == 0 or size_s.len > 8) return .{ .bad = 400 };
        const size = std.fmt.parseInt(usize, size_s, 16) catch return .{ .bad = 400 };
        pos = le + 2;
        if (size == 0) {
            // trailers until an empty line
            const trailers_at = pos;
            while (true) {
                if (pos - trailers_at > 4096) return .{ .bad = 400 };
                const te = std.mem.indexOfPos(u8, rest, pos, "\r\n") orelse return if (rest.len - pos > 4096) .{ .bad = 400 } else .need_more;
                const empty = te == pos;
                pos = te + 2;
                if (empty) break;
            }
            break;
        }
        total += size;
        n_chunks += 1;
        if (n_chunks > max_chunks) return .{ .bad = 413 };
        if (total > max_body) return .{ .bad = 413 };
        if (pos + size + 2 > rest.len) return .need_more;
        if (rest[pos + size] != '\r' or rest[pos + size + 1] != '\n') return .{ .bad = 400 };
        pos += size + 2;
    }
    const out = sc.alloc(total) catch return .{ .bad = 500 };
    var w: usize = 0;
    var p: usize = 0;
    while (true) {
        const le = std.mem.indexOfPos(u8, rest, p, "\r\n").?;
        var size_s = rest[p..le];
        if (std.mem.indexOfScalar(u8, size_s, ';')) |sc_i| size_s = size_s[0..sc_i];
        const size = std.fmt.parseInt(usize, trimOws(size_s), 16) catch unreachable;
        p = le + 2;
        if (size == 0) break;
        @memcpy(out[w .. w + size], rest[p .. p + size]);
        w += size;
        p += size + 2;
    }
    return .{ .ok = .{ .data = out, .consumed = pos } };
}

/// Percent-decode `in` into `out` (which must be at least as long). `plus` turns '+' into a space (query strings).
pub fn pctDecode(out: []u8, in: []const u8, plus: bool) ?[]u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < in.len) : (i += 1) {
        const c = in[i];
        if (c == '%') {
            if (i + 2 >= in.len) return null;
            const hi = std.fmt.charToDigit(in[i + 1], 16) catch return null;
            const lo = std.fmt.charToDigit(in[i + 2], 16) catch return null;
            out[n] = hi * 16 + lo;
            i += 2;
        } else if (plus and c == '+') {
            out[n] = ' ';
        } else out[n] = c;
        n += 1;
    }
    return out[0..n];
}

/// First value for `key` in a raw query string (still encoded), or null. A key without '=' has an empty value.
pub fn queryGet(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=');
        const k = if (eq) |e| pair[0..e] else pair;
        if (std.mem.eql(u8, k, key)) return if (eq) |e| pair[e + 1 ..] else "";
    }
    return null;
}

pub fn statusLine(code: u16) []const u8 {
    return switch (code) {
        200 => "HTTP/1.1 200 OK\r\n",
        201 => "HTTP/1.1 201 Created\r\n",
        204 => "HTTP/1.1 204 No Content\r\n",
        400 => "HTTP/1.1 400 Bad Request\r\n",
        401 => "HTTP/1.1 401 Unauthorized\r\n",
        403 => "HTTP/1.1 403 Forbidden\r\n",
        404 => "HTTP/1.1 404 Not Found\r\n",
        405 => "HTTP/1.1 405 Method Not Allowed\r\n",
        406 => "HTTP/1.1 406 Not Acceptable\r\n",
        411 => "HTTP/1.1 411 Length Required\r\n",
        413 => "HTTP/1.1 413 Content Too Large\r\n",
        422 => "HTTP/1.1 422 Unprocessable Entity\r\n",
        431 => "HTTP/1.1 431 Request Header Fields Too Large\r\n",
        500 => "HTTP/1.1 500 Internal Server Error\r\n",
        501 => "HTTP/1.1 501 Not Implemented\r\n",
        503 => "HTTP/1.1 503 Service Unavailable\r\n",
        505 => "HTTP/1.1 505 HTTP Version Not Supported\r\n",
        else => "HTTP/1.1 500 Internal Server Error\r\n",
    };
}

pub const head_room = 256;

/// The response is assembled in one buffer: `head_room` bytes reserved in front of the body, and the head is
/// written right-aligned just before the body so the whole response is one contiguous slice.
/// `buf[head_room..]` holds the body on entry. Returns the slice to send.
pub fn finishResponse(buf: []u8, body_len: usize, code: u16, keep_alive: bool) []u8 {
    return finishEncodedResponse(buf, body_len, code, keep_alive, false, false);
}

pub fn finishEncodedResponse(buf: []u8, body_len: usize, code: u16, keep_alive: bool, gzip: bool, vary: bool) []u8 {
    var tmp: [head_room]u8 = undefined;
    var n: usize = 0;
    const sl = statusLine(code);
    @memcpy(tmp[n..][0..sl.len], sl);
    n += sl.len;
    if (code != 204) {
        const ct = "Content-Type: application/json\r\n";
        @memcpy(tmp[n..][0..ct.len], ct);
        n += ct.len;
        const cl = std.fmt.bufPrint(tmp[n..], "Content-Length: {d}\r\n", .{body_len}) catch unreachable;
        n += cl.len;
    }
    if (code != 204 and gzip) {
        const c = "Content-Encoding: gzip\r\n";
        @memcpy(tmp[n..][0..c.len], c);
        n += c.len;
    }
    if (vary) {
        const c = "Vary: Accept-Encoding\r\n";
        @memcpy(tmp[n..][0..c.len], c);
        n += c.len;
    }
    if (!keep_alive) {
        const c = "Connection: close\r\n";
        @memcpy(tmp[n..][0..c.len], c);
        n += c.len;
    }
    tmp[n] = '\r';
    tmp[n + 1] = '\n';
    n += 2;
    const start = head_room - n;
    @memcpy(buf[start..head_room], tmp[0..n]);
    return buf[start .. head_room + (if (code == 204) 0 else body_len)];
}

test "gzip negotiation respects explicit exclusions and quality values" {
    const plain = parseHead("GET / HTTP/1.1\r\n\r\n");
    try std.testing.expect(plain == .ok);
    try std.testing.expect(!plain.ok.gzip and plain.ok.identity);
    const cases = .{
        .{ "", false, true },
        .{ "gzip", true, true },
        .{ "GZip;q=0.001", true, true },
        .{ "*;q=1, gzip;q=0", false, true },
        .{ "gzip;q=0, *;q=1", false, true },
        .{ "gzip;q=1.000", true, true },
        .{ "gzip;q=1.001", false, true },
        .{ "gzip;q=0.000", false, true },
        .{ "br", false, true },
        .{ "gzip;q=garbage", false, true },
        .{ "gzip;q=0\r\nAccept-Encoding: *", false, true },
        .{ "gzip;q=0.1234", false, true },
        .{ "identity", false, true },
        .{ "identity;q=0", false, false },
        .{ "gzip, identity;q=0", true, false },
        .{ "GZip;Q=1, Identity;Q=0", true, false },
        .{ "gzip;q=0, identity;q=0", false, false },
        .{ "*;q=0", false, false },
        .{ "*;q=0, gzip", true, false },
        .{ "gzip;q=0.001, *;q=0", true, false },
        .{ "*;q=0, identity", false, true },
        .{ "identity;q=0.001, *;q=0", false, true },
        .{ "*;q=0, identity, gzip", true, true },
        .{ "*;q=1, identity;q=0", true, false },
        .{ "identity;q=1.001, gzip", true, false },
        .{ "identity;q=garbage, gzip", true, false },
        .{ "identity;q=0.1234, gzip", true, false },
        .{ "gzip;q=1, gzip;q=0, identity", false, true },
        .{ "identity;q=1, identity;q=0, gzip", true, false },
        .{ "identity;q=0, identity;q=1, gzip", true, false },
        .{ "*;q=0, *;q=1", false, false },
        .{ "*;q=1, *;q=0, identity", false, true },
        .{ "identity;q=1\r\nAccept-Encoding: identity;q=0, gzip", true, false },
        .{ "identity;q=0\r\nAccept-Encoding: *", true, false },
        .{ "*;q=0\r\nAccept-Encoding: identity, gzip", true, true },
    };
    inline for (cases) |c| {
        const p = parseHead("GET / HTTP/1.1\r\nAccept-Encoding: " ++ c[0] ++ "\r\n\r\n");
        try std.testing.expect(p == .ok);
        try std.testing.expectEqual(c[1], p.ok.gzip);
        try std.testing.expectEqual(c[2], p.ok.identity);
    }
}

test "empty 406 response has zero-length framing without content encoding" {
    var buf: [head_room]u8 = undefined;
    const response = finishEncodedResponse(&buf, 0, 406, true, false, true);
    try std.testing.expectEqualStrings("HTTP/1.1 406 Not Acceptable\r\nContent-Type: application/json\r\nContent-Length: 0\r\nVary: Accept-Encoding\r\n\r\n", response);
}

test "parse head" {
    const req = "GET /api/articles?limit=5&offset=0 HTTP/1.1\r\nHost: x\r\nAuthorization: Token abc.def.ghi\r\nContent-Length: 0\r\n\r\n";
    const p = parseHead(req);
    try std.testing.expect(p == .ok);
    try std.testing.expectEqualStrings("/api/articles", p.ok.path);
    try std.testing.expectEqualStrings("limit=5&offset=0", p.ok.query);
    try std.testing.expectEqualStrings("Token abc.def.ghi", p.ok.auth.?);
    try std.testing.expect(parseHead("GET / HTTP/1.1\r\nHost: x\r\n") == .need_more);
    try std.testing.expectEqual(@as(u16, 400), parseHead("GET\r\n\r\n").bad);

    // Empty authorization header preserves presence (empty string)
    const p_empty_auth = parseHead("GET /api/articles HTTP/1.1\r\nHost: x\r\nAuthorization:\r\n\r\n");
    try std.testing.expect(p_empty_auth == .ok);
    try std.testing.expect(p_empty_auth.ok.auth != null);
    try std.testing.expectEqualStrings("", p_empty_auth.ok.auth.?);

    // Absent authorization header is null
    const p_no_auth = parseHead("GET /api/articles HTTP/1.1\r\nHost: x\r\n\r\n");
    try std.testing.expect(p_no_auth == .ok);
    try std.testing.expect(p_no_auth.ok.auth == null);

    // Connection: close takes precedence regardless of token order
    const p_close_first = parseHead("GET / HTTP/1.1\r\nHost: x\r\nConnection: close, keep-alive\r\n\r\n");
    try std.testing.expect(p_close_first == .ok);
    try std.testing.expect(!p_close_first.ok.keep_alive);

    const p_keepalive_first = parseHead("GET / HTTP/1.1\r\nHost: x\r\nConnection: keep-alive, close\r\n\r\n");
    try std.testing.expect(p_keepalive_first == .ok);
    try std.testing.expect(!p_keepalive_first.ok.keep_alive);

    const p_multi_conn = parseHead("GET / HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\nConnection: close\r\n\r\n");
    try std.testing.expect(p_multi_conn == .ok);
    try std.testing.expect(!p_multi_conn.ok.keep_alive);
}

test "chunked" {
    var sc = try Scratch.init(1024);
    const h = Head{ .method = .post, .path = "/", .query = "", .chunked = true };
    const r = takeBody(&h, "5\r\nhello\r\n6;x=1\r\n world\r\n0\r\n\r\nNEXT", &sc);
    try std.testing.expect(r == .ok);
    try std.testing.expectEqualStrings("hello world", r.ok.data);
    try std.testing.expectEqual(@as(usize, 30), r.ok.consumed);
    try std.testing.expect(takeBody(&h, "5\r\nhel", &sc) == .need_more);
}

test "pct" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("a b+c", pctDecode(&b, "a%20b%2Bc", false).?);
    try std.testing.expectEqualStrings("a b c", pctDecode(&b, "a+b%20c", true).?);
    try std.testing.expect(pctDecode(&b, "a%2", false) == null);
    try std.testing.expect(pctDecode(&b, "a%zz", false) == null);
}

test "chunk framing is bounded" {
    var sc = try Scratch.init(1 << 16);
    const h = Head{ .method = .post, .path = "/", .query = "", .chunked = true };
    var buf: [10000]u8 = undefined;
    var n: usize = 3;
    @memcpy(buf[0..3], "0\r\n");
    while (n + 6 < buf.len) : (n += 5) @memcpy(buf[n..][0..5], "a:b\r\n");
    try std.testing.expectEqual(@as(u16, 400), takeBody(&h, buf[0..n], &sc).bad);
    var ext: [200]u8 = undefined;
    @memcpy(ext[0..4], "5;x=");
    @memset(ext[4..190], 'y');
    @memcpy(ext[190..194], "\r\nab");
    try std.testing.expectEqual(@as(u16, 400), takeBody(&h, ext[0..194], &sc).bad);
    const ok = takeBody(&h, "5;name=v\r\nhello\r\n0\r\nX-T: 1\r\n\r\nNEXT", &sc);
    try std.testing.expectEqualStrings("hello", ok.ok.data);
}
