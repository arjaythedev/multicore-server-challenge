//! Response buffers. Each worker process is single-threaded, so buffers come from per-size-class free lists with
//! no locking. A response is built after a fixed header reserve; `finish` writes the status line and headers into
//! the reserve so header and body leave in one contiguous send. Bodies always go out uncompressed.
const std = @import("std");

/// Room for the longest head `finish` writes: the longest status line, a 7-digit length and Connection: close.
pub const header_reserve = 192;
comptime {
    const longest = Status.internal.line().len + ct_len.len + 7 + 2 + close.len + 2;
    std.debug.assert(longest <= header_reserve);
}

const ct_len = "Content-Type: application/json\r\nContent-Length: ";
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

    /// Writes the head in front of the body and returns the whole response.
    pub fn finish(b: *Buf, status: Status, keep_alive: bool) []const u8 {
        const body_len = b.len - header_reserve;
        var head: [header_reserve]u8 = undefined;
        var n: usize = 0;
        const line = status.line();
        @memcpy(head[0..line.len], line);
        n = line.len;
        if (status != .no_content) {
            @memcpy(head[n..][0..ct_len.len], ct_len);
            n += ct_len.len;
            n += formatUint(head[n..], body_len);
            head[n] = '\r';
            head[n + 1] = '\n';
            n += 2;
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
    const r = b.finish(.ok, true);
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 7\r\n\r\n{\"a\":1}", r);
}
