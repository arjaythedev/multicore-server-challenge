//! Gzip for response bodies, through the vendored libdeflate (vendor/libdeflate, built freestanding by build.sh).
//! Each worker process makes one compressor on first use and keeps it; every call writes a fresh gzip stream, so
//! nothing of one response carries into the next. libdeflate gets its memory from the page allocator through the
//! compressor's own allocation hooks.
const std = @import("std");

const Compressor = opaque {};

/// libdeflate's `struct libdeflate_options` (libdeflate.h).
const Options = extern struct {
    sizeof_options: usize = @sizeOf(Options),
    malloc_func: *const fn (usize) callconv(.c) ?*anyopaque,
    free_func: *const fn (?*anyopaque) callconv(.c) void,
};

extern fn libdeflate_alloc_compressor_ex(level: c_int, options: *const Options) ?*Compressor;
extern fn libdeflate_gzip_compress(c: *Compressor, in: [*]const u8, in_len: usize, out: [*]u8, out_avail: usize) usize;

/// The fastest level: the bodies are small and the cost is paid on every response.
const level = 1;

var compressor: ?*Compressor = null;

/// Each block keeps its length in the 16 bytes in front of what libdeflate sees.
const prefix = 16;

fn alloc(n: usize) callconv(.c) ?*anyopaque {
    const mem = std.heap.page_allocator.alignedAlloc(u8, .@"16", prefix + n) catch return null;
    std.mem.writeInt(usize, mem[0..@sizeOf(usize)], mem.len, .little);
    return mem.ptr + prefix;
}

fn free(p: ?*anyopaque) callconv(.c) void {
    const user: [*]u8 = @ptrCast(p orelse return);
    const base: [*]align(16) u8 = @alignCast(user - prefix);
    const len = std.mem.readInt(usize, base[0..@sizeOf(usize)], .little);
    std.heap.page_allocator.free(base[0..len]);
}

/// Compresses `in` into `out` as one gzip member. Returns the gzip length, or 0 if it does not fit in `out`.
pub fn compress(in: []const u8, out: []u8) usize {
    const c = compressor orelse blk: {
        const opts: Options = .{ .malloc_func = alloc, .free_func = free };
        compressor = libdeflate_alloc_compressor_ex(level, &opts) orelse @panic("out of memory");
        break :blk compressor.?;
    };
    return libdeflate_gzip_compress(c, in.ptr, in.len, out.ptr, out.len);
}

/// Decodes a gzip member with the standard library's decompressor (tests only).
pub fn testDecode(gz: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(gz);
    var d: std.compress.flate.Decompress = .init(&in, .gzip, &.{});
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer aw.deinit();
    _ = try d.reader.streamRemaining(&aw.writer);
    return aw.toOwnedSlice();
}

test "gzip round trip" {
    var src: [6000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(1);
    for (&src, 0..) |*b, i| b.* = if (i % 7 == 0) prng.random().int(u8) else "{\"slug\":\"a-b\"}"[i % 14];
    var out: [6000]u8 = undefined;
    for (0..3) |_| {
        const n = compress(&src, &out);
        try std.testing.expect(n > 0 and n < src.len);
        const plain = try testDecode(out[0..n]);
        defer std.testing.allocator.free(plain);
        try std.testing.expectEqualSlices(u8, &src, plain);
    }
    try std.testing.expectEqual(@as(usize, 0), compress(&src, out[0..8]));
}
