//! Growable byte buffer on the thread-safe general allocator. Used for response rendering and PG send/recv buffers.
const std = @import("std");

pub const gpa = std.heap.smp_allocator;

pub const Buf = struct {
    ptr: [*]u8 = undefined,
    len: usize = 0,
    cap: usize = 0,

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
        const m = if (self.cap == 0)
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
