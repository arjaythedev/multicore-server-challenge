//! Allocation in the current Postgres memory context (the executor's per-query context while the scan
//! runs). Nothing is freed individually: the context is reset when the statement ends or aborts.

const std = @import("std");
const c = @import("pg_c");

pub fn alloc(comptime T: type, n: usize) []T {
    const p: [*]T = @ptrCast(@alignCast(c.shim_palloc(@max(n * @sizeOf(T), 1))));
    return p[0..n];
}

pub fn dupe(s: []const u8) []const u8 {
    const p = alloc(u8, s.len);
    @memcpy(p, s);
    return p;
}

/// A std.mem.Allocator over palloc, for std containers used within one execution.
pub const palloc = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &.{ .alloc = pallocAlloc, .resize = pallocResize, .remap = pallocRemap, .free = pallocFree },
};

fn pallocAlloc(_: *anyopaque, len: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
    return @ptrCast(c.shim_palloc(@max(len, 1)));
}
fn pallocResize(_: *anyopaque, buf: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    return new_len <= buf.len;
}
fn pallocRemap(_: *anyopaque, buf: []u8, _: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
    if (new_len <= buf.len) return buf.ptr;
    return @ptrCast(c.shim_repalloc(buf.ptr, new_len));
}
fn pallocFree(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}
