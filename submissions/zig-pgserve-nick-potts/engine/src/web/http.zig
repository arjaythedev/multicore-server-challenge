//! HTTP/1.1 request heads, routes and query strings. Only what the API needs: method, target, Authorization,
//! Content-Length, Connection and Accept-Encoding. Routing mirrors the reference server's Go 1.22 ServeMux patterns.
const std = @import("std");

pub const Method = enum { get, post, put, delete, other };

pub const Head = struct {
    method: Method,
    target: []const u8,
    auth: ?[]const u8 = null,
    content_length: usize = 0,
    keep_alive: bool = true,
    /// The client accepts a gzip response body.
    gzip: bool = false,
    /// Bytes up to and including the blank line.
    len: usize,
};

pub const Parsed = union(enum) {
    incomplete,
    bad,
    head: Head,
};

pub const max_head = 16 * 1024;

pub fn parseHead(buf: []const u8) Parsed {
    const end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse {
        return if (buf.len > max_head) .bad else .incomplete;
    };
    const line_end = std.mem.indexOf(u8, buf[0..end], "\r\n") orelse end;
    const line = buf[0..line_end];
    const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse return .bad;
    const sp2 = std.mem.lastIndexOfScalar(u8, line, ' ') orelse return .bad;
    if (sp2 <= sp1) return .bad;
    const version = line[sp2 + 1 ..];
    var h: Head = .{
        .method = method(line[0..sp1]),
        .target = line[sp1 + 1 .. sp2],
        .len = end + 4,
    };
    if (std.mem.eql(u8, version, "HTTP/1.0")) {
        h.keep_alive = false;
    } else if (!std.mem.eql(u8, version, "HTTP/1.1")) return .bad;

    var accept: AcceptGzip = .{};
    var p = line_end + 2;
    while (p < end) {
        const e = std.mem.indexOfPos(u8, buf[0 .. end + 2], p, "\r\n") orelse end;
        const hl = buf[p..e];
        p = e + 2;
        const colon = std.mem.indexOfScalar(u8, hl, ':') orelse continue;
        const name = hl[0..colon];
        const value = std.mem.trim(u8, hl[colon + 1 ..], " \t");
        switch (name.len) {
            13 => if (std.ascii.eqlIgnoreCase(name, "authorization")) {
                h.auth = value;
            },
            14 => if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                h.content_length = std.fmt.parseInt(usize, value, 10) catch return .bad;
            },
            10 => if (std.ascii.eqlIgnoreCase(name, "connection")) {
                if (std.ascii.eqlIgnoreCase(value, "close")) h.keep_alive = false;
                if (std.ascii.eqlIgnoreCase(value, "keep-alive")) h.keep_alive = true;
            },
            15 => if (std.ascii.eqlIgnoreCase(name, "accept-encoding")) accept.add(value),
            17 => if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) return .bad,
            else => {},
        }
    }
    h.gzip = accept.ok();
    return .{ .head = h };
}

/// What the Accept-Encoding lines say about gzip (RFC 9110 12.5.3). Several lines read as one comma-separated list.
/// gzip (or its alias x-gzip) is acceptable when listed with a nonzero weight, or, when neither is listed, when `*`
/// has a nonzero weight. An element whose weight does not parse is ignored. Anything else means identity.
const AcceptGzip = struct {
    listed: bool = false,
    listed_ok: bool = false,
    star_ok: bool = false,

    fn add(a: *AcceptGzip, value: []const u8) void {
        var it = std.mem.splitScalar(u8, value, ',');
        while (it.next()) |elem| {
            var parts = std.mem.splitScalar(u8, elem, ';');
            const coding = std.mem.trim(u8, parts.first(), " \t");
            var nonzero = true;
            const valid = while (parts.next()) |param| {
                const eq = std.mem.indexOfScalar(u8, param, '=') orelse break false;
                if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, param[0..eq], " \t"), "q")) continue;
                nonzero = weightNonzero(std.mem.trim(u8, param[eq + 1 ..], " \t")) orelse break false;
            } else true;
            if (!valid) continue;
            if (std.ascii.eqlIgnoreCase(coding, "gzip") or std.ascii.eqlIgnoreCase(coding, "x-gzip")) {
                a.listed = true;
                a.listed_ok = a.listed_ok or nonzero;
            } else if (std.mem.eql(u8, coding, "*")) {
                a.star_ok = a.star_ok or nonzero;
            }
        }
    }

    fn ok(a: AcceptGzip) bool {
        return if (a.listed) a.listed_ok else a.star_ok;
    }
};

/// Whether a qvalue ("0" or "1", then up to three decimals, at most 1) is above zero; null if it is not one.
fn weightNonzero(q: []const u8) ?bool {
    if (q.len == 0 or q.len > 5) return null;
    if (q.len > 1 and q[1] != '.') return null;
    const frac = if (q.len > 2) q[2..] else "";
    for (frac) |c| if (!std.ascii.isDigit(c)) return null;
    return switch (q[0]) {
        '0' => std.mem.indexOfNone(u8, frac, "0") != null,
        '1' => if (std.mem.indexOfNone(u8, frac, "0") == null) true else null,
        else => null,
    };
}

fn method(m: []const u8) Method {
    if (std.mem.eql(u8, m, "GET")) return .get;
    if (std.mem.eql(u8, m, "POST")) return .post;
    if (std.mem.eql(u8, m, "PUT")) return .put;
    if (std.mem.eql(u8, m, "DELETE")) return .delete;
    return .other;
}

pub const Route = enum {
    not_found,
    tags,
    list,
    feed,
    article,
    comments,
    profile,
    user_get,
    user_put,
    register,
    login,
    follow,
    unfollow,
    favorite,
    unfavorite,
    article_create,
    article_update,
    article_delete,
    comment_create,
    comment_delete,
};

pub const Match = struct {
    route: Route,
    /// Raw (still percent-encoded) path parameters.
    a: []const u8 = "",
    b: []const u8 = "",
    query: []const u8 = "",
};

pub fn route(m: Method, target: []const u8) Match {
    var path = target;
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, target, '?')) |q| {
        path = target[0..q];
        query = target[q + 1 ..];
    }
    if (!std.mem.startsWith(u8, path, "/api/")) return .{ .route = .not_found };
    var segs: [6][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, path["/api/".len..], '/');
    while (it.next()) |s| {
        if (n == segs.len or s.len == 0) return .{ .route = .not_found };
        segs[n] = s;
        n += 1;
    }
    const eq = std.mem.eql;
    const s0 = segs[0];
    var r: Match = .{ .route = .not_found, .query = query };
    if (eq(u8, s0, "tags")) {
        if (n == 1 and m == .get) r.route = .tags;
    } else if (eq(u8, s0, "user")) {
        if (n == 1) r.route = switch (m) {
            .get => .user_get,
            .put => .user_put,
            else => .not_found,
        };
    } else if (eq(u8, s0, "users")) {
        if (n == 1 and m == .post) r.route = .register;
        if (n == 2 and m == .post and eq(u8, segs[1], "login")) r.route = .login;
    } else if (eq(u8, s0, "profiles")) {
        if (n >= 2) r.a = segs[1];
        if (n == 2 and m == .get) r.route = .profile;
        if (n == 3 and eq(u8, segs[2], "follow")) r.route = switch (m) {
            .post => .follow,
            .delete => .unfollow,
            else => .not_found,
        };
    } else if (eq(u8, s0, "articles")) {
        if (n >= 2) r.a = segs[1];
        switch (n) {
            1 => r.route = switch (m) {
                .get => .list,
                .post => .article_create,
                else => .not_found,
            },
            2 => r.route = switch (m) {
                .get => if (eq(u8, segs[1], "feed")) .feed else .article,
                .put => .article_update,
                .delete => .article_delete,
                else => .not_found,
            },
            3 => {
                if (eq(u8, segs[2], "favorite")) r.route = switch (m) {
                    .post => .favorite,
                    .delete => .unfavorite,
                    else => .not_found,
                };
                if (eq(u8, segs[2], "comments")) r.route = switch (m) {
                    .get => .comments,
                    .post => .comment_create,
                    else => .not_found,
                };
            },
            4 => if (eq(u8, segs[2], "comments") and m == .delete) {
                r.route = .comment_delete;
                r.b = segs[3];
            },
            else => {},
        }
    }
    return r;
}

/// Percent-decodes `s` into `out` (which must be at least s.len). With `plus`, '+' is a space (query strings).
/// Returns null on a malformed escape, as Go's url.PathUnescape / QueryUnescape fail.
pub fn unescape(s: []const u8, out: []u8, plus: bool) ?[]u8 {
    var o: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '%') {
            if (i + 2 >= s.len) return null;
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch return null;
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch return null;
            out[o] = hi * 16 + lo;
            i += 3;
        } else {
            out[o] = if (plus and c == '+') ' ' else c;
            i += 1;
        }
        o += 1;
    }
    return out[0..o];
}

/// The first value of `key` in a query string, still escaped, as Go's url.Values.Get sees it. Pairs whose key or
/// value fails to unescape are skipped, as url.ParseQuery drops them.
pub fn queryGet(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        if (std.mem.indexOfScalar(u8, pair, ';') != null) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=');
        const k = if (eq) |e| pair[0..e] else pair;
        const v = if (eq) |e| pair[e + 1 ..] else "";
        var kb: [64]u8 = undefined;
        if (k.len > kb.len) continue;
        const kd = unescape(k, &kb, true) orelse continue;
        if (!std.mem.eql(u8, kd, key)) continue;
        if (!validEscapes(v)) continue;
        return v;
    }
    return null;
}

fn validEscapes(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%') {
            if (i + 2 >= s.len) return false;
            if (!std.ascii.isHex(s[i + 1]) or !std.ascii.isHex(s[i + 2])) return false;
            i += 2;
        }
    }
    return true;
}

test "head" {
    const req = "GET /api/articles?limit=10 HTTP/1.1\r\nHost: x\r\nAuthorization: Token abc\r\nContent-Length: 0\r\n\r\n";
    const p = parseHead(req);
    try std.testing.expect(p == .head);
    try std.testing.expectEqualStrings("Token abc", p.head.auth.?);
    try std.testing.expectEqual(req.len, p.head.len);
    try std.testing.expect(parseHead("GET / HTTP/1.1\r\nHost") == .incomplete);
}

test "accept-encoding" {
    const cases = [_]struct { []const u8, bool }{
        .{ "gzip", true },
        .{ "GZIP", true },
        .{ "x-gzip", true },
        .{ "X-Gzip;Q=1", true },
        .{ "gzip, deflate, br", true },
        .{ "br ,  gzip ", true },
        .{ "gzip;q=0", false },
        .{ "gzip;q=0.0", false },
        .{ "gzip;q=0.00", false },
        .{ "gzip; q=0.000", false },
        .{ "gzip ; q = 0", false },
        .{ "gzip;q=0.", false },
        .{ "gzip;q=1.", true },
        .{ "gzip;q=0.5", true },
        .{ "gzip;q=0.001", true },
        .{ "gzip;q=1.000", true },
        .{ "gzip;q=0, x-gzip", true },
        .{ "*", true },
        .{ "*;q=0.5", true },
        .{ "*;q=0", false },
        .{ "gzip;q=0, *", false },
        .{ "br", false },
        .{ "identity", false },
        .{ "xgzip", false },
        .{ "gzipx", false },
        .{ "", false },
        .{ ",, ,", false },
        .{ "gzip;q=", false },
        .{ "gzip;q=1.5", false },
        .{ "gzip;q=0.0001", false },
        .{ "gzip;q=.5", false },
        .{ "gzip;q=2", false },
        .{ "gzip;q", false },
        .{ "gzip;q=abc, br", false },
        .{ "gzip;q=bad, *", true },
        .{ "gzip;level=9", true },
    };
    for (cases) |c| {
        var buf: [128]u8 = undefined;
        const req = try std.fmt.bufPrint(&buf, "GET / HTTP/1.1\r\nAccept-Encoding: {s}\r\n\r\n", .{c[0]});
        const p = parseHead(req);
        std.testing.expectEqual(c[1], p.head.gzip) catch |e| {
            std.debug.print("Accept-Encoding: {s}\n", .{c[0]});
            return e;
        };
    }
    try std.testing.expect(!parseHead("GET / HTTP/1.1\r\nHost: x\r\n\r\n").head.gzip);
    try std.testing.expect(parseHead("GET / HTTP/1.1\r\nAccept-Encoding: br\r\naccept-encoding: gzip\r\n\r\n").head.gzip);
    try std.testing.expect(!parseHead("GET / HTTP/1.1\r\nAccept-Encoding: *\r\nAccept-Encoding: gzip;q=0\r\n\r\n").head.gzip);
}

test "route" {
    try std.testing.expectEqual(Route.feed, route(.get, "/api/articles/feed?limit=1").route);
    try std.testing.expectEqual(Route.article_update, route(.put, "/api/articles/feed").route);
    const m = route(.delete, "/api/articles/a-b-1/comments/12");
    try std.testing.expectEqual(Route.comment_delete, m.route);
    try std.testing.expectEqualStrings("12", m.b);
    try std.testing.expectEqual(Route.not_found, route(.get, "/api/articles/").route);
    try std.testing.expectEqualStrings("05", queryGet("limit=05&offset=005", "limit").?);
    try std.testing.expect(queryGet("limit=%zz&limit=3", "limit") != null);
}
