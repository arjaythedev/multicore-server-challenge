//! Response buffers. Each worker process is single-threaded, so buffers come from per-size-class free lists with
//! no locking. A response is built after a fixed header reserve; `finish` writes the status line and headers into
//! the reserve so header and body leave in one contiguous send.
//!
//! gzip is used only to save a packet pair: a response that needs three or more TCP segments as identity is
//! gzipped for a client that accepts it, and sent that way only if the whole response then fits in two segments
//! (the client ACKs at once after two full segments, otherwise once more on its delayed-ACK timer). Such responses
//! carry `Vary: Accept-Encoding`, compressed or not, since their representation depends on that header.
const std = @import("std");
const gzip = @import("gzip.zig");

/// Two segments of the smallest MSS the server sees on Ethernet: IPv6 with TCP timestamps, 1500 - 40 - 20 - 12.
pub const two_segments = 2 * 1428;
/// Above this, level-1 gzip of our JSON (about 2.4x) cannot reach two segments, so it is not tried.
pub const gzip_max_body = 7 << 10;

/// Room for the longest head `finish` writes: the longest status line, a 7-digit length, both encoding headers and
/// Connection: close.
pub const header_reserve = 192;
comptime {
    const longest = Status.unavailable.line().len + ct_len.len + 7 + 2 + gzip_headers.len + vary.len + close.len + 2;
    std.debug.assert(longest <= header_reserve);
}

const ct_len = "Content-Type: application/json\r\nContent-Length: ";
const gzip_headers = "Content-Encoding: gzip\r\n";
const vary = "Vary: Accept-Encoding\r\n";
const close = "Connection: close\r\n";

const classes = [_]u32{ 4 << 10, 16 << 10, 64 << 10, 256 << 10, 1 << 20, 4 << 20 };

const FreeNode = struct { next: ?*FreeNode };
var free_lists: [classes.len]?*FreeNode = @splat(null);

fn classFor(n: usize) ?u8 {
    for (classes, 0..) |c, i| if (n <= c) return @intCast(i);
    return null;
}

fn take(class: u8) [*]u8 {
    if (free_lists[class]) |node| {
        free_lists[class] = node.next;
        return @ptrCast(node);
    }
    const mem = std.heap.page_allocator.alignedAlloc(u8, .@"16", classes[class]) catch @panic("out of memory");
    return mem.ptr;
}

fn give(ptr: [*]u8, class: u8) void {
    const node: *FreeNode = @ptrCast(@alignCast(ptr));
    node.next = free_lists[class];
    free_lists[class] = node;
}

pub const Buf = struct {
    ptr: [*]u8 = undefined,
    len: u32 = 0,
    class: u8 = no_class,

    const no_class = 0xff;

    pub fn init() Buf {
        var b: Buf = .{};
        b.ptr = take(0);
        b.class = 0;
        b.len = header_reserve;
        return b;
    }

    pub fn active(b: *const Buf) bool {
        return b.class != no_class;
    }

    pub fn release(b: *Buf) void {
        if (b.class != no_class) give(b.ptr, b.class);
        b.* = .{};
    }

    pub fn cap(b: *const Buf) usize {
        return classes[b.class];
    }

    pub fn ensure(b: *Buf, extra: usize) void {
        const need = @as(usize, b.len) + extra;
        if (need <= classes[b.class]) return;
        const c = classFor(need) orelse @panic("response too large");
        const p = take(c);
        @memcpy(p[0..b.len], b.ptr[0..b.len]);
        give(b.ptr, b.class);
        b.ptr = p;
        b.class = c;
    }

    pub inline fn append(b: *Buf, bytes: []const u8) void {
        b.ensure(bytes.len);
        @memcpy(b.ptr[b.len..][0..bytes.len], bytes);
        b.len += @intCast(bytes.len);
    }

    pub inline fn byte(b: *Buf, c: u8) void {
        b.ensure(1);
        b.ptr[b.len] = c;
        b.len += 1;
    }

    /// Bytes written after the header reserve.
    pub fn body(b: *const Buf) []u8 {
        return b.ptr[header_reserve..b.len];
    }

    /// Drop the body, keeping the buffer.
    pub fn resetBody(b: *Buf) void {
        b.len = header_reserve;
    }

    /// Swaps the body for its gzip form if that fits in `room` bytes.
    fn compress(b: *Buf, room: usize) bool {
        const src = b.body();
        var dst = Buf.init();
        dst.ensure(room);
        const n = gzip.compress(src, dst.ptr[header_reserve..][0..room]);
        if (n == 0) {
            dst.release();
            return false;
        }
        dst.len = @intCast(header_reserve + n);
        b.release();
        b.* = dst;
        return true;
    }

    /// Writes the head in front of the body and returns the whole response. With `accept_gzip`, a body that saves
    /// a segment that way is sent gzipped (see the file comment).
    pub fn finish(b: *Buf, status: Status, keep_alive: bool, accept_gzip: bool) []const u8 {
        const line = status.line();
        // Every head line but Content-Length's digits and the encoding headers; a body near two segments has 4 digits.
        const fixed = line.len + ct_len.len + 2 + (if (keep_alive) 0 else close.len) + 2;
        const identity = b.len - header_reserve;
        const eligible = status != .no_content and identity <= gzip_max_body and fixed + 4 + identity > two_segments;
        const gzipped = eligible and accept_gzip and b.compress(two_segments - (fixed + 4 + gzip_headers.len + vary.len));
        const body_len = b.len - header_reserve;
        var head: [header_reserve]u8 = undefined;
        @memcpy(head[0..line.len], line);
        var n: usize = line.len;
        if (status != .no_content) {
            @memcpy(head[n..][0..ct_len.len], ct_len);
            n += ct_len.len;
            n += formatUint(head[n..], body_len);
            head[n] = '\r';
            head[n + 1] = '\n';
            n += 2;
        }
        if (gzipped) {
            @memcpy(head[n..][0..gzip_headers.len], gzip_headers);
            n += gzip_headers.len;
        }
        if (eligible) {
            @memcpy(head[n..][0..vary.len], vary);
            n += vary.len;
        }
        if (!keep_alive) {
            @memcpy(head[n..][0..close.len], close);
            n += close.len;
        }
        head[n] = '\r';
        head[n + 1] = '\n';
        n += 2;
        const start = header_reserve - n;
        @memcpy(b.ptr[start..header_reserve], head[0..n]);
        return b.ptr[start..b.len];
    }
};

pub const Status = enum {
    ok,
    created,
    no_content,
    unauthorized,
    forbidden,
    not_found,
    unprocessable,
    internal,
    unavailable,

    /// The status line, and for 503 the Retry-After header after it.
    pub fn line(s: Status) []const u8 {
        return switch (s) {
            .ok => "HTTP/1.1 200 OK\r\n",
            .created => "HTTP/1.1 201 Created\r\n",
            .no_content => "HTTP/1.1 204 No Content\r\n",
            .unauthorized => "HTTP/1.1 401 Unauthorized\r\n",
            .forbidden => "HTTP/1.1 403 Forbidden\r\n",
            .not_found => "HTTP/1.1 404 Not Found\r\n",
            .unprocessable => "HTTP/1.1 422 Unprocessable Entity\r\n",
            .internal => "HTTP/1.1 500 Internal Server Error\r\n",
            .unavailable => "HTTP/1.1 503 Service Unavailable\r\nRetry-After: 1\r\n",
        };
    }
};

pub fn formatUint(out: []u8, v: u64) usize {
    var tmp: [20]u8 = undefined;
    var i: usize = tmp.len;
    var x = v;
    while (true) {
        i -= 1;
        tmp[i] = @intCast('0' + x % 10);
        x /= 10;
        if (x == 0) break;
    }
    const n = tmp.len - i;
    @memcpy(out[0..n], tmp[i..]);
    return n;
}

test "finish places head before body" {
    var b = Buf.init();
    defer b.release();
    b.append("{\"a\":1}");
    const r = b.finish(.ok, true, true);
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 7\r\n\r\n{\"a\":1}", r);
}

test "a 503 says when to retry, and its longest head fits the reserve" {
    var b = Buf.init();
    defer b.release();
    b.append("{\"errors\":{\"body\":[\"server overloaded\"]}}");
    const r = b.finish(.unavailable, false, true);
    try std.testing.expect(std.mem.startsWith(u8, r, "HTTP/1.1 503 Service Unavailable\r\nRetry-After: 1\r\nContent-Type: application/json\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, r, "Connection: close\r\n\r\n{") != null);
}

fn jsonish(out: []u8) void {
    for (out, 0..) |*c, i| c.* = "{\"tag\":\"lorem\"},"[i % 16];
}

/// Splits a finished response into its head (without the blank line) and body.
fn split(r: []const u8) struct { []const u8, []const u8 } {
    const e = std.mem.indexOf(u8, r, "\r\n\r\n").?;
    return .{ r[0 .. e + 2], r[e + 4 ..] };
}

fn hasHeader(head: []const u8, h: []const u8) bool {
    return std.mem.indexOf(u8, head, h) != null;
}

test "gzip only when it brings a 3-segment response down to 2" {
    var text: [gzip_max_body + 1]u8 = undefined;
    jsonish(&text);
    var noise: [4000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    prng.random().bytes(&noise);
    const Case = struct { body: []const u8, accept: bool, keep_alive: bool, gzipped: bool, vary: bool };
    const cases = [_]Case{
        .{ .body = text[0..2000], .accept = true, .keep_alive = true, .gzipped = false, .vary = false },
        .{ .body = text[0..4000], .accept = true, .keep_alive = true, .gzipped = true, .vary = true },
        .{ .body = text[0..4000], .accept = true, .keep_alive = false, .gzipped = true, .vary = true },
        .{ .body = text[0..4000], .accept = false, .keep_alive = true, .gzipped = false, .vary = true },
        .{ .body = &noise, .accept = true, .keep_alive = true, .gzipped = false, .vary = true },
        .{ .body = text[0..gzip_max_body], .accept = true, .keep_alive = true, .gzipped = true, .vary = true },
        .{ .body = &text, .accept = true, .keep_alive = true, .gzipped = false, .vary = false },
    };
    for (cases) |c| {
        var b = Buf.init();
        defer b.release();
        b.append(c.body);
        const r = b.finish(.ok, c.keep_alive, c.accept);
        const head, const sent = split(r);
        try std.testing.expectEqual(c.gzipped, hasHeader(head, gzip_headers));
        try std.testing.expectEqual(c.vary, hasHeader(head, vary));
        try std.testing.expectEqual(!c.keep_alive, hasHeader(head, close));
        var want: [16]u8 = undefined;
        try std.testing.expect(hasHeader(head, try std.fmt.bufPrint(&want, "Length: {d}\r\n", .{sent.len})));
        if (c.gzipped) {
            try std.testing.expect(r.len <= two_segments);
            const plain = try gzip.testDecode(sent);
            defer std.testing.allocator.free(plain);
            try std.testing.expectEqualSlices(u8, c.body, plain);
        } else try std.testing.expectEqualSlices(u8, c.body, sent);
    }
}

test "a gzip form that just misses two segments goes out as identity" {
    // Noise then text: the compressed size grows with the noise, so some prefix length is the last that fits.
    var src: [6000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(3);
    prng.random().bytes(src[0..3000]);
    jsonish(src[3000..]);
    var seen = [2]bool{ false, false };
    var noise: usize = 0;
    while (noise < 3000) : (noise += 16) {
        var b = Buf.init();
        defer b.release();
        b.append(src[3000 - noise ..][0..3000]);
        const r = b.finish(.ok, true, true);
        const head, const sent = split(r);
        const gz = hasHeader(head, gzip_headers);
        if (gz) try std.testing.expect(r.len <= two_segments) else try std.testing.expectEqual(3000, sent.len);
        seen[@intFromBool(gz)] = true;
    }
    try std.testing.expect(seen[0] and seen[1]);
}
