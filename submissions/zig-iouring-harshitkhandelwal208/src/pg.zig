//! PostgreSQL frontend/backend protocol 3.0: startup + SCRAM-SHA-256 (blocking, at start-up only), binary-format
//! parameter encoding, and incremental framing of pipelined replies. No libpq.
const std = @import("std");
const linux = std.os.linux;
const Buf = @import("buf.zig").Buf;
const sys = @import("sys.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;

pub const Config = struct {
    addr: [4]u8,
    port: u16,
    user: []const u8,
    password: []const u8,
    database: []const u8,
};

pub fn parseUrl(url: []const u8, scratch: []u8) !Config {
    var rest = url;
    inline for (.{ "postgres://", "postgresql://" }) |pfx| {
        if (std.mem.startsWith(u8, rest, pfx)) rest = rest[pfx.len..];
    }
    const at = std.mem.lastIndexOfScalar(u8, rest, '@') orelse return error.BadUrl;
    const cred = rest[0..at];
    rest = rest[at + 1 ..];
    const colon = std.mem.indexOfScalar(u8, cred, ':');
    const user = cred[0 .. colon orelse cred.len];
    const pass = if (colon) |c| cred[c + 1 ..] else "";
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.BadUrl;
    const hostport = rest[0..slash];
    var db = rest[slash + 1 ..];
    if (std.mem.indexOfScalar(u8, db, '?')) |q| db = db[0..q];
    var host = hostport;
    var port: u16 = 5432;
    if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |c| {
        host = hostport[0..c];
        port = try std.fmt.parseInt(u16, hostport[c + 1 ..], 10);
    }
    var addr: [4]u8 = undefined;
    if (std.mem.eql(u8, host, "localhost") or host.len == 0) {
        addr = .{ 127, 0, 0, 1 };
    } else {
        var it = std.mem.splitScalar(u8, host, '.');
        var i: usize = 0;
        while (it.next()) |part| : (i += 1) {
            if (i >= 4) return error.BadUrl;
            addr[i] = try std.fmt.parseInt(u8, part, 10);
        }
        if (i != 4) return error.BadUrl;
    }
    // Percent-decode user / password / database into scratch.
    var n: usize = 0;
    const u = try decodeInto(scratch, &n, user);
    const pw = try decodeInto(scratch, &n, pass);
    const d = try decodeInto(scratch, &n, db);
    return .{ .addr = addr, .port = port, .user = u, .password = pw, .database = d };
}

fn decodeInto(out: []u8, n: *usize, s: []const u8) ![]const u8 {
    const start = n.*;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (n.* >= out.len) return error.BadUrl;
        if (s[i] == '%' and i + 2 < s.len) {
            out[n.*] = try std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16);
            i += 2;
        } else out[n.*] = s[i];
        n.* += 1;
    }
    return out[start..n.*];
}

// ---------------------------------------------------------------------------------------------
// Blocking helpers for the handshake
// ---------------------------------------------------------------------------------------------

fn writeAll(fd: i32, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const rc = linux.write(fd, data.ptr + off, data.len - off);
        switch (sys.errnoOf(rc)) {
            .SUCCESS => off += rc,
            .INTR => {},
            else => return error.WriteFailed,
        }
    }
}

fn readExact(fd: i32, out: []u8) !void {
    var off: usize = 0;
    while (off < out.len) {
        const rc = linux.read(fd, out.ptr + off, out.len - off);
        switch (sys.errnoOf(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.Closed;
                off += rc;
            },
            .INTR => {},
            else => return error.ReadFailed,
        }
    }
}

/// Reads one backend message into `b` (cleared first). Returns the message type.
fn readMsg(fd: i32, b: *Buf) !u8 {
    var hdr: [5]u8 = undefined;
    try readExact(fd, &hdr);
    const len = std.mem.readInt(u32, hdr[1..5], .big);
    if (len < 4 or len > (1 << 24)) return error.Protocol;
    b.reset();
    const body = b.reserve(len - 4);
    try readExact(fd, body);
    return hdr[0];
}

fn errorText(body: []const u8) []const u8 {
    // ErrorResponse fields: 'M' message
    var i: usize = 0;
    while (i < body.len and body[i] != 0) {
        const t = body[i];
        const end = std.mem.indexOfScalarPos(u8, body, i + 1, 0) orelse return "";
        if (t == 'M') return body[i + 1 .. end];
        i = end + 1;
    }
    return "";
}

pub const session_params = [_][2][]const u8{
    .{ "client_encoding", "UTF8" },
    .{ "plan_cache_mode", "force_generic_plan" },
    .{ "jit", "off" },
    .{ "enable_memoize", "off" },
    .{ "max_parallel_workers_per_gather", "0" },
    .{ "client_min_messages", "warning" },
    .{ "application_name", "conduit-zig" },
};

fn setTimeouts(fd: i32, secs: i64) void {
    const tv: linux.timeval = .{ .sec = secs, .usec = 0 };
    inline for (.{ linux.SO.RCVTIMEO, linux.SO.SNDTIMEO }) |o| {
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, o, @ptrCast(&tv), @sizeOf(linux.timeval));
    }
}

/// Removes the handshake timeouts once the connection is ready (the event loop owns it from then on).
pub fn clearTimeouts(fd: i32) void {
    setTimeouts(fd, 0);
}

/// Connects, authenticates and returns a connected socket (blocking mode) once ReadyForQuery arrives.
pub fn connect(cfg: Config) !i32 {
    const s = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (sys.errnoOf(s) != .SUCCESS) return error.SocketFailed;
    const fd: i32 = @intCast(s);
    errdefer _ = linux.close(fd);
    setTimeouts(fd, 5); // a stalled server must not hang the handshake (connect honours SO_SNDTIMEO)
    var sa: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, cfg.port), .addr = @bitCast(cfg.addr) };
    if (sys.errnoOf(linux.connect(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return error.ConnectFailed;
    const one: c_int = 1;
    _ = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, @ptrCast(&one), @sizeOf(c_int));

    var out = try Buf.init(512);
    defer out.deinit();
    // StartupMessage
    out.putInt(u32, 0, .big);
    out.putInt(u32, 196608, .big);
    inline for (.{ .{ "user", cfg.user }, .{ "database", cfg.database } }) |kv| {
        out.putSlice(kv[0]);
        out.put(0);
        out.putSlice(kv[1]);
        out.put(0);
    }
    for (session_params) |kv| {
        out.putSlice(kv[0]);
        out.put(0);
        out.putSlice(kv[1]);
        out.put(0);
    }
    out.put(0);
    std.mem.writeInt(u32, out.ptr[0..4], @intCast(out.len), .big);
    try writeAll(fd, out.slice());

    var in = try Buf.init(1024);
    defer in.deinit();
    var scram: Scram = undefined;
    while (true) {
        const t = try readMsg(fd, &in);
        const body = in.slice();
        switch (t) {
            'R' => {
                const code = std.mem.readInt(u32, body[0..4], .big);
                switch (code) {
                    0 => {},
                    3 => {
                        out.reset();
                        out.put('p');
                        out.putInt(u32, @intCast(4 + cfg.password.len + 1), .big);
                        out.putSlice(cfg.password);
                        out.put(0);
                        try writeAll(fd, out.slice());
                    },
                    10 => {
                        // Offered mechanisms: need SCRAM-SHA-256.
                        if (std.mem.indexOf(u8, body[4..], "SCRAM-SHA-256") == null) return error.UnsupportedAuth;
                        scram = Scram.init();
                        out.reset();
                        out.put('p');
                        out.putInt(u32, 0, .big);
                        out.putSlice("SCRAM-SHA-256\x00");
                        const first = scram.clientFirst();
                        out.putInt(u32, @intCast(first.len), .big);
                        out.putSlice(first);
                        std.mem.writeInt(u32, out.ptr[1..5], @intCast(out.len - 1), .big);
                        try writeAll(fd, out.slice());
                    },
                    11 => {
                        out.reset();
                        out.put('p');
                        out.putInt(u32, 0, .big);
                        try scram.clientFinal(&out, body[4..], cfg.password);
                        std.mem.writeInt(u32, out.ptr[1..5], @intCast(out.len - 1), .big);
                        try writeAll(fd, out.slice());
                    },
                    12 => try scram.verifyServer(body[4..]),
                    else => return error.UnsupportedAuth,
                }
            },
            'E' => {
                std.log.err("postgres: {s}", .{errorText(body)});
                return error.AuthFailed;
            },
            'Z' => break,
            else => {}, // ParameterStatus, BackendKeyData, NoticeResponse
        }
    }
    return fd;
}

const Scram = struct {
    nonce_b64: [24]u8,
    first_bare: [64]u8,
    first_bare_len: usize,
    auth_msg: [512]u8,
    auth_len: usize,
    server_sig: [32]u8,
    first_msg: [96]u8,

    fn init() Scram {
        var s: Scram = undefined;
        var raw: [18]u8 = undefined;
        sys.randomBytes(&raw);
        _ = std.base64.standard.Encoder.encode(&s.nonce_b64, &raw);
        const bare = std.fmt.bufPrint(&s.first_bare, "n=,r={s}", .{s.nonce_b64}) catch unreachable;
        s.first_bare_len = bare.len;
        return s;
    }

    fn clientFirst(self: *Scram) []const u8 {
        return std.fmt.bufPrint(&self.first_msg, "n,,{s}", .{self.first_bare[0..self.first_bare_len]}) catch unreachable;
    }

    fn clientFinal(self: *Scram, out: *Buf, server_first: []const u8, password: []const u8) !void {
        var r: ?[]const u8 = null;
        var salt_b64: ?[]const u8 = null;
        var iters: ?u32 = null;
        var it = std.mem.splitScalar(u8, server_first, ',');
        while (it.next()) |kv| {
            if (kv.len < 2 or kv[1] != '=') continue;
            switch (kv[0]) {
                'r' => r = kv[2..],
                's' => salt_b64 = kv[2..],
                'i' => iters = try std.fmt.parseInt(u32, kv[2..], 10),
                else => {},
            }
        }
        const nonce = r orelse return error.Protocol;
        if (!std.mem.startsWith(u8, nonce, &self.nonce_b64)) return error.Protocol;
        var salt: [64]u8 = undefined;
        const sl = try std.base64.standard.Decoder.calcSizeForSlice(salt_b64 orelse return error.Protocol);
        if (sl > salt.len) return error.Protocol;
        try std.base64.standard.Decoder.decode(salt[0..sl], salt_b64.?);
        var salted: [32]u8 = undefined;
        try std.crypto.pwhash.pbkdf2(&salted, password, salt[0..sl], iters orelse return error.Protocol, Hmac);
        var client_key: [32]u8 = undefined;
        Hmac.create(&client_key, "Client Key", &salted);
        var stored: [32]u8 = undefined;
        Sha256.hash(&client_key, &stored, .{});
        const am = try std.fmt.bufPrint(&self.auth_msg, "{s},{s},c=biws,r={s}", .{ self.first_bare[0..self.first_bare_len], server_first, nonce });
        self.auth_len = am.len;
        var sig: [32]u8 = undefined;
        Hmac.create(&sig, am, &stored);
        var proof: [32]u8 = undefined;
        for (&proof, client_key, sig) |*p, a, b| p.* = a ^ b;
        var server_key: [32]u8 = undefined;
        Hmac.create(&server_key, "Server Key", &salted);
        Hmac.create(&self.server_sig, am, &server_key);
        var proof_b64: [44]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&proof_b64, &proof);
        out.putSlice("c=biws,r=");
        out.putSlice(nonce);
        out.putSlice(",p=");
        out.putSlice(&proof_b64);
    }

    fn verifyServer(self: *Scram, msg: []const u8) !void {
        if (!std.mem.startsWith(u8, msg, "v=")) return error.AuthFailed;
        var want: [44]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&want, &self.server_sig);
        if (!std.mem.eql(u8, msg[2..], &want)) return error.AuthFailed;
    }
};

pub const Prep = struct { id: u16, sql: []const u8, params: []const u32, results: ?[]const u32 = null };

/// Parse each statement on a connected (blocking) socket. Statement `id` is named "s<id>".
pub fn prepareAll(fd: i32, items: []const Prep) !void {
    var out = try Buf.init(8192);
    defer out.deinit();
    for (items) |it| {
        out.put('P');
        const at = out.len;
        out.putInt(u32, 0, .big);
        var nb: [8]u8 = undefined;
        out.putSlice(stmtName(&nb, it.id));
        out.put(0);
        out.putSlice(it.sql);
        out.put(0);
        out.putInt(u16, @intCast(it.params.len), .big);
        for (it.params) |o| out.putInt(u32, o, .big);
        std.mem.writeInt(u32, out.ptr[at..][0..4], @intCast(out.len - at), .big);
        out.put('D');
        const desc_at = out.len;
        out.putInt(u32, 0, .big);
        out.put('S');
        out.putSlice(stmtName(&nb, it.id));
        out.put(0);
        std.mem.writeInt(u32, out.ptr[desc_at..][0..4], @intCast(out.len - desc_at), .big);
    }
    out.putSlice("S\x00\x00\x00\x04");
    try writeAll(fd, out.slice());
    var in = try Buf.init(1024);
    defer in.deinit();
    var described: usize = 0;
    while (true) {
        const t = try readMsg(fd, &in);
        switch (t) {
            'T', 'n' => {
                if (described >= items.len) return error.Protocol;
                const it = items[described];
                if (it.results) |expected| {
                    validateDescription(if (t == 'n') "\x00\x00" else in.slice(), expected) catch |err| {
                        std.log.err("postgres statement s{d}: result columns/OIDs do not match the decoder", .{it.id});
                        return err;
                    };
                }
                described += 1;
            },
            'E' => {
                std.log.err("postgres prepare: {s}", .{errorText(in.slice())});
                return error.PrepareFailed;
            },
            'Z' => {
                if (described != items.len) return error.Protocol;
                return;
            },
            else => {},
        }
    }
}

pub fn validateDescription(bytes: []const u8, expected: []const u32) !void {
    if (bytes.len < 2 or std.mem.readInt(u16, bytes[0..2], .big) != expected.len) return error.ResultShape;
    var pos: usize = 2;
    for (expected) |want| {
        const end = std.mem.indexOfScalarPos(u8, bytes, pos, 0) orelse return error.Protocol;
        pos = end + 1;
        if (bytes.len - pos < 18) return error.Protocol;
        const actual = std.mem.readInt(u32, bytes[pos + 6 ..][0..4], .big);
        if (actual != want) return error.ResultShape;
        pos += 18;
    }
    if (pos != bytes.len) return error.Protocol;
}

fn stmtName(buf: *[8]u8, i: u16) []const u8 {
    return std.fmt.bufPrint(buf, "s{d}", .{i}) catch unreachable;
}

// ---------------------------------------------------------------------------------------------
// Batch encoding (extended protocol, binary parameters and results)
// ---------------------------------------------------------------------------------------------

pub const oid = struct {
    pub const bool_ = 16;
    pub const int8 = 20;
    pub const int4 = 23;
    pub const text = 25;
    pub const text_array = 1009;
    pub const int8_array = 1016;
    pub const int4_array = 1007;
};

/// Appends Bind/Execute pairs and a final Sync into `b`.
pub const Enc = struct {
    b: *Buf,
    bind_at: usize = 0,
    nparams_at: usize = 0,
    nparams: u16 = 0,
    n_exec: u8 = 0, // statements executed so far in this batch

    pub fn init(b: *Buf) Enc {
        return .{ .b = b };
    }

    /// Start a statement. Params follow via the `p*` methods; call `exec()` when done.
    pub fn bind(self: *Enc, stmt: u16) void {
        const b = self.b;
        self.bind_at = b.len;
        b.put('B');
        b.putInt(u32, 0, .big); // length, patched in exec()
        b.put(0); // portal ""
        var nb: [8]u8 = undefined;
        b.putSlice(stmtName(&nb, stmt));
        b.put(0);
        b.putInt(u16, 1, .big); // one parameter format code ...
        b.putInt(u16, 1, .big); // ... binary, for all parameters
        self.nparams_at = b.len;
        b.putInt(u16, 0, .big);
        self.nparams = 0;
    }

    pub fn pInt8(self: *Enc, v: i64) void {
        self.b.putInt(i32, 8, .big);
        self.b.putInt(i64, v, .big);
        self.nparams += 1;
    }

    pub fn pInt4(self: *Enc, v: i32) void {
        self.b.putInt(i32, 4, .big);
        self.b.putInt(i32, v, .big);
        self.nparams += 1;
    }

    pub fn pText(self: *Enc, s: []const u8) void {
        self.b.ensure(4 + s.len);
        self.b.putInt(i32, @intCast(s.len), .big);
        self.b.putSlice(s);
        self.nparams += 1;
    }

    pub fn pNull(self: *Enc) void {
        self.b.putInt(i32, -1, .big);
        self.nparams += 1;
    }

    pub fn pTextOpt(self: *Enc, s: ?[]const u8) void {
        if (s) |v| self.pText(v) else self.pNull();
    }

    pub fn pTextArray(self: *Enc, items: []const []const u8) void {
        var total: usize = 12;
        if (items.len != 0) total += 8;
        for (items) |it| total += 4 + it.len;
        const b = self.b;
        b.ensure(4 + total);
        b.putInt(i32, @intCast(total), .big);
        b.putInt(i32, if (items.len == 0) 0 else 1, .big); // ndim
        b.putInt(i32, 0, .big); // no nulls
        b.putInt(i32, oid.text, .big);
        if (items.len != 0) {
            b.putInt(i32, @intCast(items.len), .big);
            b.putInt(i32, 1, .big); // lower bound
            for (items) |it| {
                b.putInt(i32, @intCast(it.len), .big);
                b.putSlice(it);
            }
        }
        self.nparams += 1;
    }

    pub fn pInt8Array(self: *Enc, items: []const i64) void {
        const b = self.b;
        if (items.len == 0) {
            b.putInt(i32, 12, .big);
            b.putInt(i32, 0, .big); // ndim
            b.putInt(i32, 0, .big);
            b.putInt(i32, oid.int8, .big);
            self.nparams += 1;
            return;
        }
        const total: i32 = @intCast(20 + items.len * 12);
        b.ensure(4 + @as(usize, @intCast(total)));
        b.putInt(i32, total, .big);
        b.putInt(i32, 1, .big);
        b.putInt(i32, 0, .big);
        b.putInt(i32, oid.int8, .big);
        b.putInt(i32, @intCast(items.len), .big);
        b.putInt(i32, 1, .big);
        for (items) |v| {
            b.putInt(i32, 8, .big);
            b.putInt(i64, v, .big);
        }
        self.nparams += 1;
    }

    pub fn pInt4Array(self: *Enc, items: []const i32) void {
        const b = self.b;
        const total: i32 = @intCast(20 + items.len * 8);
        b.ensure(4 + @as(usize, @intCast(total)));
        b.putInt(i32, total, .big);
        b.putInt(i32, 1, .big);
        b.putInt(i32, 0, .big);
        b.putInt(i32, oid.int4, .big);
        b.putInt(i32, @intCast(items.len), .big);
        b.putInt(i32, 1, .big);
        for (items) |v| {
            b.putInt(i32, 4, .big);
            b.putInt(i32, v, .big);
        }
        self.nparams += 1;
    }

    /// Finish Bind (all results binary) and append Execute.
    pub fn exec(self: *Enc) void {
        const b = self.b;
        b.putInt(u16, 1, .big); // one result format code ...
        b.putInt(u16, 1, .big); // ... binary
        std.mem.writeInt(u16, b.ptr[self.nparams_at..][0..2], self.nparams, .big);
        std.mem.writeInt(u32, b.ptr[self.bind_at + 1 ..][0..4], @intCast(b.len - self.bind_at - 1), .big);
        b.putSlice("E\x00\x00\x00\x09\x00\x00\x00\x00\x00");
        self.n_exec += 1;
    }

    pub fn sync(self: *Enc) void {
        self.b.putSlice("S\x00\x00\x00\x04");
    }
};

// ---------------------------------------------------------------------------------------------
// Reply parsing
// ---------------------------------------------------------------------------------------------

pub const Msg = struct { kind: u8, body: []const u8 };

pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn next(self: *Reader) ?Msg {
        if (self.pos + 5 > self.data.len) return null;
        const len = std.mem.readInt(u32, self.data[self.pos + 1 ..][0..4], .big);
        const end = self.pos + 1 + len;
        const m = Msg{ .kind = self.data[self.pos], .body = self.data[self.pos + 5 .. end] };
        self.pos = end;
        return m;
    }
};

/// Split a DataRow body into `n` columns (null = SQL NULL).
pub inline fn cols(body: []const u8, comptime n: usize) [n]?[]const u8 {
    var out: [n]?[]const u8 = undefined;
    var p: usize = 2;
    inline for (0..n) |i| {
        const l = std.mem.readInt(i32, body[p..][0..4], .big);
        p += 4;
        if (l < 0) {
            out[i] = null;
        } else {
            out[i] = body[p..][0..@intCast(l)];
            p += @intCast(l);
        }
    }
    return out;
}

pub inline fn i64Of(b: []const u8) i64 {
    return std.mem.readInt(i64, b[0..8], .big);
}

pub inline fn i32Of(b: []const u8) i32 {
    return std.mem.readInt(i32, b[0..4], .big);
}

/// Iterates the elements of a one-dimensional binary text[] value.
pub const TextArray = struct {
    data: []const u8,
    pos: usize,
    left: u32,

    pub fn init(b: []const u8) TextArray {
        const ndim = std.mem.readInt(i32, b[0..4], .big);
        if (ndim == 0) return .{ .data = b, .pos = 12, .left = 0 };
        return .{ .data = b, .pos = 20, .left = std.mem.readInt(u32, b[12..16], .big) };
    }

    pub fn next(self: *TextArray) ?[]const u8 {
        if (self.left == 0) return null;
        self.left -= 1;
        const l: usize = @intCast(std.mem.readInt(i32, self.data[self.pos..][0..4], .big));
        const s = self.data[self.pos + 4 ..][0..l];
        self.pos += 4 + l;
        return s;
    }
};

/// Validated one-dimensional, non-null binary int8[] used by packed read headers.
pub const Int8Array = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(b: []const u8) !Int8Array {
        if (b.len < 12 or i32Of(b[4..]) != 0 or i32Of(b[8..]) != oid.int8) return error.Protocol;
        const dims = i32Of(b);
        if (dims == 0) {
            if (b.len != 12) return error.Protocol;
            return .{ .data = &.{} };
        }
        if (dims != 1 or b.len < 20) return error.Protocol;
        const count = i32Of(b[12..]);
        if (count < 0 or @as(u64, @intCast(count)) * 12 + 20 != b.len) return error.Protocol;
        var p: usize = 20;
        while (p < b.len) : (p += 12) if (i32Of(b[p..]) != 8) return error.Protocol;
        return .{ .data = b[20..] };
    }

    pub fn next(self: *Int8Array) ?i64 {
        if (self.pos == self.data.len) return null;
        const n = i64Of(self.data[self.pos + 4 ..]);
        self.pos += 12;
        return n;
    }

    pub fn contains(self: Int8Array, id: i64) bool {
        var it = self;
        while (it.next()) |x| if (x == id) return true;
        return false;
    }
};

test "startup description and packed array validation reject decoder mismatches" {
    try validateDescription("\x00\x00", &.{});
    try std.testing.expectError(error.ResultShape, validateDescription("\x00\x00", &.{oid.int8}));
    var b: Buf = .{};
    defer b.deinit();
    b.putInt(u16, 1, .big);
    b.putSlice("id\x00");
    b.putInt(u32, 0, .big);
    b.putInt(u16, 0, .big);
    b.putInt(u32, oid.int8, .big);
    b.putInt(u16, 8, .big);
    b.putInt(i32, -1, .big);
    b.putInt(u16, 0, .big);
    try validateDescription(b.slice(), &.{oid.int8});
    try std.testing.expectError(error.ResultShape, validateDescription(b.slice(), &.{oid.text}));
    try std.testing.expectError(error.Protocol, Int8Array.init(""));
    b.reset();
    b.putInt(u32, 0, .big);
    b.putInt(u32, 0, .big);
    b.putInt(u32, oid.int8, .big);
    var empty = try Int8Array.init(b.slice());
    try std.testing.expect(empty.next() == null);
    b.ptr[11] = oid.text;
    try std.testing.expectError(error.Protocol, Int8Array.init(b.slice()));
}

/// SQLSTATE of an ErrorResponse body, or null.
pub fn sqlstate(body: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < body.len and body[i] != 0) {
        const t = body[i];
        const end = std.mem.indexOfScalarPos(u8, body, i + 1, 0) orelse return null;
        if (t == 'C') return body[i + 1 .. end];
        i = end + 1;
    }
    return null;
}

/// Incremental framing of a pipelined reply stream: finds batch boundaries (ReadyForQuery).
pub const Stream = struct {
    buf: Buf,
    start: usize = 0, // first byte of the oldest unfinished batch
    scan: usize = 0, // next message boundary to examine
    end: usize = 0, // bytes valid in buf

    pub fn init(cap: usize) !Stream {
        return .{ .buf = try Buf.init(cap) };
    }

    /// Free space to receive into; guarantees at least `min` bytes.
    pub fn space(self: *Stream, min: usize) []u8 {
        if (self.start == self.end) {
            self.start = 0;
            self.scan = 0;
            self.end = 0;
        }
        if (self.buf.cap - self.end < min) {
            if (self.start > 0 and self.start >= self.buf.cap / 2) {
                // compact
                const n = self.end - self.start;
                std.mem.copyForwards(u8, self.buf.ptr[0..n], self.buf.ptr[self.start..self.end]);
                self.scan -= self.start;
                self.end = n;
                self.start = 0;
            }
            if (self.buf.cap - self.end < min) {
                self.buf.len = self.end;
                self.buf.grow(self.end + min);
            }
        }
        return self.buf.ptr[self.end..self.buf.cap];
    }

    pub fn received(self: *Stream, n: usize) void {
        self.end += n;
    }

    /// If a complete batch is buffered, returns its bytes (ending with ReadyForQuery). Call `done()` afterwards.
    pub fn nextBatch(self: *Stream) ?[]const u8 {
        const d = self.buf.ptr;
        while (self.scan + 5 <= self.end) {
            const len = std.mem.readInt(u32, d[self.scan + 1 ..][0..4], .big);
            const mend = self.scan + 1 + len;
            if (mend > self.end) return null;
            const kind = d[self.scan];
            self.scan = mend;
            if (kind == 'Z') return d[self.start..mend];
        }
        return null;
    }

    pub fn done(self: *Stream) void {
        self.start = self.scan;
    }
};
