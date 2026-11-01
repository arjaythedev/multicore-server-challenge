//! Growable byte buffer on the thread-safe general allocator. Used for response rendering and PG send/recv buffers.
const std = @import("std");

pub const gpa = std.heap.smp_allocator;

pub const Buf = struct {
    ptr: [*]u8 = undefined,
    len: usize = 0,
    cap: usize = 0,
    pool: ?*Pool = null,

    pub fn init(cap: usize) !Buf {
        const m = try gpa.alloc(u8, cap);
        return .{ .ptr = m.ptr, .len = 0, .cap = cap };
    }

    pub fn deinit(self: *Buf) void {
        if (self.cap != 0) gpa.free(self.ptr[0..self.cap]);
        self.* = .{};
    }

    pub inline fn slice(self: *const Buf) []u8 {
        return self.ptr[0..self.len];
    }

    pub inline fn reset(self: *Buf) void {
        self.len = 0;
    }

    pub fn grow(self: *Buf, need: usize) void {
        var ncap = if (self.cap == 0) 4096 else self.cap;
        while (ncap < need) ncap *= 2;
        const old = self.ptr[0..self.cap];
        const m = if (self.pool) |pool| blk: {
            const next = pool.take(ncap);
            if (self.len != 0) @memcpy(next[0..self.len], old[0..self.len]);
            if (self.cap != 0) pool.release(old);
            break :blk next;
        } else if (self.cap == 0)
            gpa.alloc(u8, ncap) catch @panic("out of memory")
        else
            gpa.realloc(old, ncap) catch @panic("out of memory");
        self.ptr = m.ptr;
        self.cap = ncap;
    }

    pub inline fn ensure(self: *Buf, extra: usize) void {
        if (self.cap - self.len < extra) self.grow(self.len + extra);
    }

    pub inline fn put(self: *Buf, b: u8) void {
        self.ensure(1);
        self.ptr[self.len] = b;
        self.len += 1;
    }

    pub inline fn putSlice(self: *Buf, s: []const u8) void {
        self.ensure(s.len);
        @memcpy(self.ptr[self.len..][0..s.len], s);
        self.len += s.len;
    }

    /// Reserve `n` bytes and return them for the caller to fill.
    pub inline fn reserve(self: *Buf, n: usize) []u8 {
        self.ensure(n);
        const r = self.ptr[self.len..][0..n];
        self.len += n;
        return r;
    }

    pub inline fn putInt(self: *Buf, comptime T: type, v: T, endian: std.builtin.Endian) void {
        const n = @sizeOf(T);
        self.ensure(n);
        std.mem.writeInt(T, self.ptr[self.len..][0..n], v, endian);
        self.len += n;
    }
};

/// Worker-local response storage. Each class retains at most 256 KiB, or one large
/// allocation; buffers above 4 MiB are never retained. No cross-request data is cached.
pub const Pool = struct {
    slots: [11][64][*]u8 = undefined,
    counts: [11]usize = @splat(0),

    fn class(cap: usize) ?usize {
        if (cap < 4096 or cap > 4 * 1024 * 1024 or !std.math.isPowerOfTwo(cap)) return null;
        return @ctz(cap) - 12;
    }

    pub fn take(self: *Pool, cap: usize) []u8 {
        if (class(cap)) |k| {
            if (self.counts[k] != 0) {
                self.counts[k] -= 1;
                return self.slots[k][self.counts[k]][0..cap];
            }
        }
        return gpa.alloc(u8, cap) catch @panic("out of memory");
    }

    pub fn release(self: *Pool, bytes: []u8) void {
        if (class(bytes.len)) |k| {
            const limit = @max(1, @min(64, 256 * 1024 / bytes.len));
            if (self.counts[k] < limit) {
                self.slots[k][self.counts[k]] = bytes.ptr;
                self.counts[k] += 1;
                return;
            }
        }
        gpa.free(bytes);
    }

    pub fn deinit(self: *Pool) void {
        for (self.counts, 0..) |n, k| {
            for (self.slots[k][0..n]) |p| gpa.free(p[0 .. @as(usize, 4096) << @intCast(k)]);
        }
        self.counts = @splat(0);
    }
};

test "response pool reuses every bounded size class and preserves growing data" {
    var pool: Pool = .{};
    defer pool.deinit();
    var b: Buf = .{ .pool = &pool };
    defer b.deinit();
    b.putSlice("retained data");
    const first = b.ptr;
    b.ensure(8192);
    try std.testing.expectEqualStrings("retained data", b.slice());
    const reused = pool.take(4096);
    try std.testing.expectEqual(first, reused.ptr);
    pool.release(reused);
    for (0..11) |k| {
        const size = @as(usize, 4096) << @intCast(k);
        const bytes = pool.take(size);
        pool.release(bytes);
        const again = pool.take(size);
        try std.testing.expectEqual(bytes.ptr, again.ptr);
        pool.release(again);
    }
}
