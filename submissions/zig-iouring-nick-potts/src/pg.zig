//! The Postgres v3 wire protocol, written from scratch: URL parsing, a blocking startup with SCRAM-SHA-256 (and
//! md5/cleartext/trust), statement preparation with type checks, message encoding for Bind/Execute/Sync, and
//! decoding of binary DataRows. The event loop drives the steady state; this file only knows the protocol.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const sql = @import("sql.zig");
const Oid = sql.Oid;

pub const Url = struct {
    user: []const u8,
    password: []const u8,
    host: []const u8,
    port: u16,
    database: []const u8,
};

pub fn parseUrl(url: []const u8) !Url {
    var rest = url;
    if (std.mem.startsWith(u8, rest, "postgres://")) {
        rest = rest["postgres://".len..];
    } else if (std.mem.startsWith(u8, rest, "postgresql://")) {
        rest = rest["postgresql://".len..];
    } else return error.BadUrl;
    var u: Url = .{ .user = "postgres", .password = "", .host = "127.0.0.1", .port = 5432, .database = "postgres" };
    if (std.mem.indexOfScalar(u8, rest, '?')) |q| rest = rest[0..q];
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| {
        const cred = rest[0..at];
        rest = rest[at + 1 ..];
        if (std.mem.indexOfScalar(u8, cred, ':')) |c| {
            u.user = cred[0..c];
            u.password = cred[c + 1 ..];
        } else u.user = cred;
    }
    var hostport = rest;
    if (std.mem.indexOfScalar(u8, rest, '/')) |s| {
        hostport = rest[0..s];
        if (s + 1 < rest.len) u.database = rest[s + 1 ..];
    }
    if (hostport.len > 0 and hostport[0] == '[') {
        const e = std.mem.indexOfScalar(u8, hostport, ']') orelse return error.BadUrl;
        u.host = hostport[1..e];
        if (e + 2 <= hostport.len and hostport[e + 1] == ':') u.port = try std.fmt.parseInt(u16, hostport[e + 2 ..], 10);
    } else if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |c| {
        u.host = hostport[0..c];
        u.port = try std.fmt.parseInt(u16, hostport[c + 1 ..], 10);
    } else if (hostport.len > 0) u.host = hostport;
    if (std.mem.eql(u8, u.host, "localhost")) u.host = "127.0.0.1";
    return u;
}

// ---------------------------------------------------------------- encoding

/// A growable outgoing byte buffer for protocol messages.
pub const Out = struct {
    list: std.ArrayList(u8) = .empty,

    const gpa = std.heap.smp_allocator;

    pub fn deinit(o: *Out) void {
        o.list.deinit(gpa);
    }

    pub fn bytes(o: *Out, b: []const u8) void {
        o.list.appendSlice(gpa, b) catch @panic("oom");
    }

    pub fn byte(o: *Out, b: u8) void {
        o.list.append(gpa, b) catch @panic("oom");
    }

    pub fn int16(o: *Out, v: i16) void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(i16, &b, v, .big);
        o.bytes(&b);
    }

    pub fn int32(o: *Out, v: i32) void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(i32, &b, v, .big);
        o.bytes(&b);
    }

    pub fn int64(o: *Out, v: i64) void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(i64, &b, v, .big);
        o.bytes(&b);
    }

    pub fn cstr(o: *Out, s: []const u8) void {
        o.bytes(s);
        o.byte(0);
    }

    /// Starts a message; returns the offset to patch with `end`.
    pub fn begin(o: *Out, t: u8) usize {
        o.byte(t);
        const at = o.list.items.len;
        o.int32(0);
        return at;
    }

    pub fn end(o: *Out, at: usize) void {
        const len: i32 = @intCast(o.list.items.len - at);
        std.mem.writeInt(i32, o.list.items[at..][0..4], len, .big);
    }

    pub fn reserve(o: *Out, n: usize) []u8 {
        o.list.ensureUnusedCapacity(gpa, n) catch @panic("oom");
        const s = o.list.items.len;
        o.list.items.len += n;
        return o.list.items[s..][0..n];
    }
};

pub fn parseMsg(o: *Out, name: []const u8, text: []const u8, params: []const Oid) void {
    const at = o.begin('P');
    o.cstr(name);
    o.cstr(text);
    o.int16(@intCast(params.len));
    for (params) |p| o.int32(@intCast(@intFromEnum(p)));
    o.end(at);
}

pub fn describeStmt(o: *Out, name: []const u8) void {
    const at = o.begin('D');
    o.byte('S');
    o.cstr(name);
    o.end(at);
}

pub fn sync(o: *Out) void {
    o.bytes(&.{ 'S', 0, 0, 0, 4 });
}

/// Has Postgres send the results it holds so far; unlike Sync, the pipeline goes on.
pub fn flush(o: *Out) void {
    o.bytes(&.{ 'H', 0, 0, 0, 4 });
}

/// Bind with every parameter and every result column in binary. Returns the offset after the parameter count,
/// where the caller writes each parameter, then calls `bindEnd`.
pub fn bindBegin(o: *Out, stmt_name: []const u8, nparams: u16) usize {
    const at = o.begin('B');
    o.byte(0); // unnamed portal
    o.cstr(stmt_name);
    o.bytes(&.{ 0, 1, 0, 1 }); // one format code: binary, for all parameters
    o.int16(@intCast(nparams));
    return at;
}

pub fn bindEnd(o: *Out, at: usize) void {
    o.bytes(&.{ 0, 1, 0, 1 }); // one result format code: binary
    o.end(at);
    // Execute the unnamed portal, all rows.
    o.bytes(&.{ 'E', 0, 0, 0, 9, 0, 0, 0, 0, 0 });
}

pub fn paramInt(o: *Out, v: i64) void {
    o.int32(8);
    o.int64(v);
}

pub fn paramInt4(o: *Out, v: i32) void {
    o.int32(4);
    o.int32(v);
}

/// Whether Postgres takes `s` as a text value: valid UTF-8 without NUL. Anything else fails the whole statement
/// it rides in (22021), and so every request batched into it.
pub fn textOk(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, 0) == null and std.unicode.utf8ValidateSlice(s);
}

pub fn paramText(o: *Out, s: []const u8) void {
    o.int32(@intCast(s.len));
    o.bytes(s);
}

pub fn paramNull(o: *Out) void {
    o.int32(-1);
}

/// A one-dimensional binary array header; the caller then writes `n` elements (length + bytes, or -1).
pub fn arrayBegin(o: *Out, elem: Oid, n: usize) usize {
    const at = o.list.items.len;
    o.int32(0); // parameter length, patched by arrayEnd
    o.int32(1); // ndim
    o.int32(1); // may contain nulls
    o.int32(@intCast(@intFromEnum(elem)));
    o.int32(@intCast(n));
    o.int32(1); // lower bound
    return at;
}

pub fn arrayEnd(o: *Out, at: usize) void {
    const len: i32 = @intCast(o.list.items.len - at - 4);
    std.mem.writeInt(i32, o.list.items[at..][0..4], len, .big);
}

// ---------------------------------------------------------------- decoding

/// One DataRow, decoded lazily.
pub const Row = struct {
    off: [40]u32 = undefined,
    len: [40]i32 = undefined,
    data: []const u8 = &.{},
    n: u16 = 0,

    pub fn parse(r: *Row, payload: []const u8) !void {
        const n = std.mem.readInt(u16, payload[0..2], .big);
        if (n > r.off.len) return error.TooManyColumns;
        r.n = n;
        r.data = payload;
        var p: usize = 2;
        for (0..n) |i| {
            const l = std.mem.readInt(i32, payload[p..][0..4], .big);
            p += 4;
            r.off[i] = @intCast(p);
            r.len[i] = l;
            if (l > 0) p += @intCast(l);
        }
    }

    pub inline fn isNull(r: *const Row, i: usize) bool {
        return r.len[i] < 0;
    }

    pub inline fn raw(r: *const Row, i: usize) []const u8 {
        if (r.len[i] < 0) return &.{};
        return r.data[r.off[i]..][0..@intCast(r.len[i])];
    }

    pub inline fn text(r: *const Row, i: usize) []const u8 {
        return r.raw(i);
    }

    pub inline fn textOrNull(r: *const Row, i: usize) ?[]const u8 {
        return if (r.isNull(i)) null else r.raw(i);
    }

    pub inline fn int(r: *const Row, i: usize) i64 {
        return std.mem.readInt(i64, r.raw(i)[0..8], .big);
    }

    pub inline fn boolean(r: *const Row, i: usize) bool {
        return r.raw(i)[0] != 0;
    }

    pub fn textArray(r: *const Row, i: usize) TextArray {
        const a = r.raw(i);
        if (a.len < 12) return .{ .s = &.{}, .left = 0 };
        const ndim = std.mem.readInt(i32, a[0..4], .big);
        if (ndim == 0) return .{ .s = &.{}, .left = 0 };
        const n = std.mem.readInt(i32, a[12..16], .big);
        return .{ .s = a[20..], .left = @intCast(n) };
    }
};

pub const TextArray = struct {
    s: []const u8,
    left: u32,

    pub fn next(t: *TextArray) ?[]const u8 {
        if (t.left == 0) return null;
        t.left -= 1;
        const l = std.mem.readInt(i32, t.s[0..4], .big);
        if (l < 0) {
            t.s = t.s[4..];
            return "";
        }
        const n: usize = @intCast(l);
        const v = t.s[4..][0..n];
        t.s = t.s[4 + n ..];
        return v;
    }
};

pub const ErrorInfo = struct {
    code: [5]u8 = "00000".*,
    msg: [200]u8 = undefined,
    msg_len: u8 = 0,

    pub fn parse(payload: []const u8) ErrorInfo {
        var e: ErrorInfo = .{};
        var p: usize = 0;
        while (p < payload.len and payload[p] != 0) {
            const field = payload[p];
            p += 1;
            const end = std.mem.indexOfScalarPos(u8, payload, p, 0) orelse break;
            const v = payload[p..end];
            if (field == 'C' and v.len == 5) e.code = v[0..5].*;
            if (field == 'M') {
                const l = @min(v.len, e.msg.len);
                @memcpy(e.msg[0..l], v[0..l]);
                e.msg_len = @intCast(l);
            }
            p = end + 1;
        }
        return e;
    }

    pub fn message(e: *const ErrorInfo) []const u8 {
        return e.msg[0..e.msg_len];
    }

    pub fn is(e: *const ErrorInfo, code: []const u8) bool {
        return std.mem.eql(u8, &e.code, code);
    }
};

// ---------------------------------------------------------------- blocking startup

/// A connection during startup: blocking reads into a small buffer.
pub const Blocking = struct {
    fd: i32,
    buf: [64 * 1024]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    pub fn readMsg(b: *Blocking) !struct { t: u8, body: []const u8 } {
        while (true) {
            if (b.end - b.start >= 5) {
                const len: usize = @intCast(std.mem.readInt(i32, b.buf[b.start + 1 ..][0..4], .big));
                if (len + 1 > b.buf.len) return error.MessageTooLarge;
                if (b.end - b.start >= len + 1) {
                    const t = b.buf[b.start];
                    const body = b.buf[b.start + 5 .. b.start + 1 + len];
                    b.start += len + 1;
                    return .{ .t = t, .body = body };
                }
            }
            if (b.start > 0) {
                std.mem.copyForwards(u8, b.buf[0 .. b.end - b.start], b.buf[b.start..b.end]);
                b.end -= b.start;
                b.start = 0;
            }
            const n = try sys.readSome(b.fd, b.buf[b.end..]);
            if (n == 0) return error.ConnectionClosed;
            b.end += n;
        }
    }

    pub fn send(b: *Blocking, o: *Out) !void {
        try sys.writeAll(b.fd, o.list.items);
        o.list.clearRetainingCapacity();
    }
};

pub fn tcpConnect(u: Url) !i32 {
    var addr4: linux.sockaddr.in = undefined;
    var addr6: linux.sockaddr.in6 = undefined;
    var family: u32 = linux.AF.INET;
    if (parseIp4(u.host)) |ip| {
        addr4 = .{ .port = std.mem.nativeToBig(u16, u.port), .addr = ip };
    } else {
        family = linux.AF.INET6;
        addr6 = .{ .port = std.mem.nativeToBig(u16, u.port), .flowinfo = 0, .addr = parseIp6(u.host) orelse return error.BadHost, .scope_id = 0 };
    }
    const fd: i32 = @intCast(try sys.check(linux.socket(family, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
    errdefer sys.closeFd(fd);
    if (family == linux.AF.INET) {
        _ = try sys.check(linux.connect(fd, &addr4, @sizeOf(linux.sockaddr.in)));
    } else {
        _ = try sys.check(linux.connect(fd, &addr6, @sizeOf(linux.sockaddr.in6)));
    }
    try sys.setsockoptInt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, 1);
    return fd;
}

fn parseIp4(s: []const u8) ?u32 {
    var parts: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, s, '.');
    var i: usize = 0;
    while (it.next()) |p| : (i += 1) {
        if (i >= 4) return null;
        parts[i] = std.fmt.parseInt(u8, p, 10) catch return null;
    }
    if (i != 4) return null;
    return @bitCast(parts);
}

fn parseIp6(s: []const u8) ?[16]u8 {
    if (std.mem.eql(u8, s, "::1")) {
        var a: [16]u8 = @splat(0);
        a[15] = 1;
        return a;
    }
    return null;
}

/// Opens a connection and authenticates. `gucs` are session settings sent in the startup packet.
pub fn connect(u: Url, gucs: []const [2][]const u8) !*Blocking {
    const fd = try tcpConnect(u);
    const b = try std.heap.smp_allocator.create(Blocking);
    b.* = .{ .fd = fd };
    var o: Out = .{};
    defer o.deinit();
    o.int32(0);
    o.int32(196608);
    o.cstr("user");
    o.cstr(u.user);
    o.cstr("database");
    o.cstr(u.database);
    for (gucs) |g| {
        o.cstr(g[0]);
        o.cstr(g[1]);
    }
    o.byte(0);
    std.mem.writeInt(i32, o.list.items[0..4], @intCast(o.list.items.len), .big);
    try b.send(&o);

    var scram: Scram = undefined;
    while (true) {
        const m = try b.readMsg();
        switch (m.t) {
            'R' => {
                const code = std.mem.readInt(i32, m.body[0..4], .big);
                switch (code) {
                    0 => {},
                    3 => {
                        const at = o.begin('p');
                        o.cstr(u.password);
                        o.end(at);
                        try b.send(&o);
                    },
                    5 => {
                        const salt = m.body[4..8];
                        var inner: [32]u8 = undefined;
                        md5hex(&inner, &.{ u.password, u.user });
                        var outer: [32]u8 = undefined;
                        md5hex(&outer, &.{ &inner, salt });
                        const at = o.begin('p');
                        o.bytes("md5");
                        o.cstr(&outer);
                        o.end(at);
                        try b.send(&o);
                    },
                    10 => {
                        if (std.mem.indexOf(u8, m.body, "SCRAM-SHA-256") == null) return error.UnsupportedAuth;
                        scram = Scram.init();
                        const first = scram.clientFirst();
                        const at = o.begin('p');
                        o.cstr("SCRAM-SHA-256");
                        o.int32(@intCast(first.len));
                        o.bytes(first);
                        o.end(at);
                        try b.send(&o);
                    },
                    11 => {
                        const final = try scram.clientFinal(u.password, m.body[4..]);
                        const at = o.begin('p');
                        o.bytes(final);
                        o.end(at);
                        try b.send(&o);
                    },
                    12 => try scram.verifyServer(m.body[4..]),
                    else => return error.UnsupportedAuth,
                }
            },
            'E' => {
                const e = ErrorInfo.parse(m.body);
                sys.log("postgres startup error {s}: {s}", .{ &e.code, e.message() });
                return error.StartupFailed;
            },
            'Z' => return b,
            else => {},
        }
    }
}

fn md5hex(out: *[32]u8, parts: []const []const u8) void {
    var h = std.crypto.hash.Md5.init(.{});
    for (parts) |p| h.update(p);
    var d: [16]u8 = undefined;
    h.final(&d);
    const hex = "0123456789abcdef";
    for (d, 0..) |c, i| {
        out[i * 2] = hex[c >> 4];
        out[i * 2 + 1] = hex[c & 15];
    }
}

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const b64 = std.base64.standard;

const Scram = struct {
    nonce: [24]u8,
    first_bare: [64]u8,
    first_bare_len: usize,
    out: [512]u8,
    server_sig: [32]u8,

    fn init() Scram {
        var s: Scram = undefined;
        var raw: [18]u8 = undefined;
        sys.randomBytes(&raw);
        _ = b64.Encoder.encode(&s.nonce, &raw);
        return s;
    }

    fn clientFirst(s: *Scram) []const u8 {
        const bare = std.fmt.bufPrint(&s.first_bare, "n=,r={s}", .{&s.nonce}) catch unreachable;
        s.first_bare_len = bare.len;
        return std.fmt.bufPrint(&s.out, "n,,{s}", .{bare}) catch unreachable;
    }

    fn clientFinal(s: *Scram, password: []const u8, server_first: []const u8) ![]const u8 {
        var nonce: []const u8 = "";
        var salt_b64: []const u8 = "";
        var iters: u32 = 0;
        var it = std.mem.splitScalar(u8, server_first, ',');
        while (it.next()) |attr| {
            if (attr.len < 2) continue;
            switch (attr[0]) {
                'r' => nonce = attr[2..],
                's' => salt_b64 = attr[2..],
                'i' => iters = try std.fmt.parseInt(u32, attr[2..], 10),
                else => {},
            }
        }
        if (!std.mem.startsWith(u8, nonce, &s.nonce)) return error.ScramNonce;
        var salt: [64]u8 = undefined;
        const salt_len = try b64.Decoder.calcSizeForSlice(salt_b64);
        try b64.Decoder.decode(salt[0..salt_len], salt_b64);
        var salted: [32]u8 = undefined;
        try std.crypto.pwhash.pbkdf2(&salted, password, salt[0..salt_len], iters, HmacSha256);
        var client_key: [32]u8 = undefined;
        HmacSha256.create(&client_key, "Client Key", &salted);
        var stored: [32]u8 = undefined;
        Sha256.hash(&client_key, &stored, .{});
        var without_proof: [256]u8 = undefined;
        const wp = try std.fmt.bufPrint(&without_proof, "c=biws,r={s}", .{nonce});
        var auth_msg: [1024]u8 = undefined;
        const am = try std.fmt.bufPrint(&auth_msg, "{s},{s},{s}", .{ s.first_bare[0..s.first_bare_len], server_first, wp });
        var client_sig: [32]u8 = undefined;
        HmacSha256.create(&client_sig, am, &stored);
        var proof: [32]u8 = undefined;
        for (&proof, client_key, client_sig) |*p, k, g| p.* = k ^ g;
        var server_key: [32]u8 = undefined;
        HmacSha256.create(&server_key, "Server Key", &salted);
        HmacSha256.create(&s.server_sig, am, &server_key);
        var proof_b64: [44]u8 = undefined;
        _ = b64.Encoder.encode(&proof_b64, &proof);
        return std.fmt.bufPrint(&s.out, "{s},p={s}", .{ wp, &proof_b64 });
    }

    fn verifyServer(s: *Scram, final: []const u8) !void {
        if (!std.mem.startsWith(u8, final, "v=")) return error.ScramServer;
        var sig: [32]u8 = undefined;
        b64.Decoder.decode(&sig, final[2..]) catch return error.ScramServer;
        if (!std.mem.eql(u8, &sig, &s.server_sig)) return error.ScramServer;
    }
};

/// Prepares `name` and checks Postgres describes exactly `cols` as its result. Any mismatch is fatal: the server
/// must not start on a schema it was not written for.
pub fn prepareChecked(b: *Blocking, name: []const u8, text: []const u8, params: []const Oid, cols: []const Oid) !void {
    var o: Out = .{};
    defer o.deinit();
    parseMsg(&o, name, text, params);
    describeStmt(&o, name);
    sync(&o);
    try b.send(&o);
    var failed = false;
    while (true) {
        const m = try b.readMsg();
        switch (m.t) {
            '1', 't' => {},
            'T' => {
                const n = std.mem.readInt(u16, m.body[0..2], .big);
                if (n != cols.len) {
                    sys.log("statement {s}: {d} result columns, expected {d}", .{ name, n, cols.len });
                    failed = true;
                    continue;
                }
                var p: usize = 2;
                for (0..n) |i| {
                    const end = std.mem.indexOfScalarPos(u8, m.body, p, 0).?;
                    const col_name = m.body[p..end];
                    p = end + 1 + 4 + 2;
                    const typ = std.mem.readInt(u32, m.body[p..][0..4], .big);
                    p += 4 + 2 + 4 + 2;
                    if (typ != @intFromEnum(cols[i])) {
                        sys.log("statement {s}: column {d} ({s}) has type oid {d}, expected {d}", .{ name, i, col_name, typ, @intFromEnum(cols[i]) });
                        failed = true;
                    }
                }
            },
            'n' => if (cols.len != 0) {
                sys.log("statement {s}: returns no rows, expected {d} columns", .{ name, cols.len });
                failed = true;
            },
            'E' => {
                const e = ErrorInfo.parse(m.body);
                sys.log("statement {s} does not prepare: {s} {s}", .{ name, &e.code, e.message() });
                failed = true;
            },
            'Z' => return if (failed) error.SchemaMismatch else {},
            else => {},
        }
    }
}

/// Runs a simple query and returns the first column of the first row (or null).
pub fn queryScalar(b: *Blocking, text: []const u8, out: []u8) !?[]u8 {
    var o: Out = .{};
    defer o.deinit();
    const at = o.begin('Q');
    o.cstr(text);
    o.end(at);
    try b.send(&o);
    var result: ?[]u8 = null;
    while (true) {
        const m = try b.readMsg();
        switch (m.t) {
            'D' => if (result == null) {
                const l = std.mem.readInt(i32, m.body[2..6], .big);
                if (l >= 0) {
                    const n: usize = @min(@as(usize, @intCast(l)), out.len);
                    @memcpy(out[0..n], m.body[6..][0..n]);
                    result = out[0..n];
                }
            },
            'E' => {
                const e = ErrorInfo.parse(m.body);
                sys.log("query failed: {s} {s}", .{ &e.code, e.message() });
                return error.QueryFailed;
            },
            'Z' => return result,
            else => {},
        }
    }
}

test "text Postgres takes: valid UTF-8 without NUL" {
    for ([_][]const u8{ "", "dragons", "caf\xc3\xa9", "\xf0\x9f\x90\x89", "\xef\xbf\xbd", "\xf4\x8f\xbf\xbf" }) |s|
        try std.testing.expect(textOk(s));
    // NUL; a lone continuation byte; a truncated sequence; an overlong '/'; a surrogate; past U+10FFFF.
    for ([_][]const u8{ "\x00", "a\x00b", "\xff", "\x80", "caf\xc3", "\xc0\xaf", "\xed\xa0\x80", "\xf4\x90\x80\x80" }) |s|
        try std.testing.expect(!textOk(s));
}
