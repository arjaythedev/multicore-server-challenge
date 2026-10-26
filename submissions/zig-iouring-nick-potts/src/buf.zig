//! Response buffers. Each worker process is single-threaded, so buffers come from per-size-class free lists with
//! no locking. A response is built after a fixed header reserve; `finish` writes the status line and headers into
//! the reserve so header and body leave in one contiguous send. Header values follow their colon with no space
//! (the whitespace is optional in HTTP/1.1), a few bytes less per response.
//!
//! gzip is used only to save segments: a response that needs three or more of its connection's TCP segments as
//! identity is gzipped (pz.zig) for a client that accepts it, and sent that way only if it then needs fewer segments. The encoder aims
//! for two (the client ACKs at once after two full segments, otherwise once more on its delayed-ACK timer). On a CPU
//! without PCLMULQDQ, whose CRC would cost more than the ACKs save, every body goes out as identity.
const std = @import("std");
const pz = @import("pz.zig");

/// Room for the longest head `finish` writes: the longest status line, a 7-digit length, Content-Encoding and
/// Connection: close.
pub const header_reserve = 192;
comptime {
    const longest = Status.unavailable.line().len + ct_len.len + 7 + 2 + gzip_headers.len + close.len + 2;
    std.debug.assert(longest <= header_reserve);
}

const ct_len = "Content-Type:application/json\r\nContent-Length:";
const gzip_headers = "Content-Encoding:gzip\r\n";
const close = "Connection:close\r\n";

fn segments(n: usize, mss: usize) usize {
    return (n + mss - 1) / mss;
}

fn digits(n: usize) usize {
    return if (n < 10) 1 else 1 + digits(n / 10);
}

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

    /// Swaps the body for its gzip form if the response (`head` bytes before the body) then needs fewer than
    /// `segs` segments. The encoder ends its Huffman block once the rest fits two segments as stored bytes.
    fn compress(b: *Buf, head: usize, segs: usize, mss: usize) bool {
        b.ensure(3); // pz reads up to 3 bytes past the body
        const n = b.len - header_reserve;
        var dst = Buf.init();
        dst.ensure(pz.outBound(n));
        const m = pz.encode(b.ptr[header_reserve..b.len], dst.ptr[header_reserve..][0..pz.outBound(n)], 2 * mss - head - 4);
        if (segments(head + digits(m) + m, mss) >= segs) {
            dst.release();
            return false;
        }
        dst.len = @intCast(header_reserve + m);
        b.release();
        b.* = dst;
        return true;
    }

    /// Writes the head in front of the body and returns the whole response. With `accept_gzip`, a body that saves
    /// segments of `mss` bytes that way is sent gzipped (see the file comment).
    pub fn finish(b: *Buf, status: Status, keep_alive: bool, accept_gzip: bool, mss: usize) []const u8 {
        const line = status.line();
        // Every head line but Content-Length's digits.
        const fixed = line.len + ct_len.len + 2 + (if (keep_alive) 0 else close.len) + 2;
        const identity = b.len - header_reserve;
        const id_segs = segments(fixed + digits(identity) + identity, mss);
        const gzipped = accept_gzip and pz.has_pclmul and status != .no_content and id_segs > 2 and identity <= pz.max_input and
            b.compress(fixed + gzip_headers.len, id_segs, mss);
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
            .unavailable => "HTTP/1.1 503 Service Unavailable\r\nRetry-After:1\r\n",
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
    const r = b.finish(.ok, true, true, 1448);
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r\nContent-Type:application/json\r\nContent-Length:7\r\n\r\n{\"a\":1}", r);
}

test "a 503 says when to retry, and its longest head fits the reserve" {
    var b = Buf.init();
    defer b.release();
    b.append("{\"errors\":{\"body\":[\"server overloaded\"]}}");
    const r = b.finish(.unavailable, false, true, 1448);
    try std.testing.expect(std.mem.startsWith(u8, r, "HTTP/1.1 503 Service Unavailable\r\nRetry-After:1\r\nContent-Type:application/json\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, r, "Connection:close\r\n\r\n{") != null);
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

fn decode(gz: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(gz);
    var d: std.compress.flate.Decompress = .init(&in, .gzip, &.{});
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer aw.deinit();
    _ = try d.reader.streamRemaining(&aw.writer);
    return aw.toOwnedSlice();
}

test "gzip only when it saves segments, aiming for two" {
    pz.detectCpu();
    var text: [20000]u8 = undefined;
    jsonish(&text);
    var noise: [4000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    prng.random().bytes(&noise);
    const Case = struct { body: []const u8, accept: bool, keep_alive: bool, gzipped: bool };
    const cases = [_]Case{
        .{ .body = text[0..2000], .accept = true, .keep_alive = true, .gzipped = false },
        .{ .body = text[0..4000], .accept = true, .keep_alive = true, .gzipped = true },
        .{ .body = text[0..4000], .accept = true, .keep_alive = false, .gzipped = true },
        .{ .body = text[0..4000], .accept = false, .keep_alive = true, .gzipped = false },
        .{ .body = &noise, .accept = true, .keep_alive = true, .gzipped = false },
        .{ .body = &text, .accept = true, .keep_alive = true, .gzipped = true },
    };
    for (cases) |c| for ([_]usize{ 1428, 1448 }) |mss| {
        var b = Buf.init();
        defer b.release();
        b.append(c.body);
        const r = b.finish(.ok, c.keep_alive, c.accept, mss);
        const head, const sent = split(r);
        try std.testing.expectEqual(c.gzipped, hasHeader(head, gzip_headers));
        try std.testing.expect(!hasHeader(head, "Vary"));
        try std.testing.expectEqual(!c.keep_alive, hasHeader(head, close));
        var want: [16]u8 = undefined;
        try std.testing.expect(hasHeader(head, try std.fmt.bufPrint(&want, "Length:{d}\r\n", .{sent.len})));
        if (c.gzipped) {
            if (c.body.len <= 4000) try std.testing.expect(r.len <= 2 * mss);
            const plain = try decode(sent);
            defer std.testing.allocator.free(plain);
            try std.testing.expectEqualSlices(u8, c.body, plain);
        } else try std.testing.expectEqualSlices(u8, c.body, sent);
    };
}

test "a gzip form that saves no segment goes out as identity" {
    // Noise then text: the compressed size grows with the noise, so some mixes save a segment and some don't.
    pz.detectCpu();
    var src: [6000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(3);
    prng.random().bytes(src[0..3000]);
    jsonish(src[3000..]);
    var seen = [2]bool{ false, false };
    var noise: usize = 0;
    while (noise < 3000) : (noise += 16) {
        const body = src[3000 - noise ..][0..3000];
        var b = Buf.init();
        defer b.release();
        b.append(body);
        const r = b.finish(.ok, true, true, 1448);
        const head, const sent = split(r);
        const gz = hasHeader(head, gzip_headers);
        if (gz) {
            try std.testing.expect(segments(r.len, 1448) < segments(r.len - sent.len + body.len, 1448));
            const plain = try decode(sent);
            defer std.testing.allocator.free(plain);
            try std.testing.expectEqualSlices(u8, body, plain);
        } else try std.testing.expectEqualSlices(u8, body, sent);
        seen[@intFromBool(gz)] = true;
    }
    try std.testing.expect(seen[0] and seen[1]);
}
