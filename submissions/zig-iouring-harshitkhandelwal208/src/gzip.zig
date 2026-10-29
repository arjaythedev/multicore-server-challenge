//! Optional level-1 gzip through libdeflate; no custom codec on the request path.
const Buf = @import("buf.zig").Buf;
const Compressor = opaque {};
extern "deflate" fn libdeflate_alloc_compressor(level: c_int) ?*Compressor;
extern "deflate" fn libdeflate_free_compressor(compressor: ?*Compressor) void;
extern "deflate" fn libdeflate_gzip_compress_bound(compressor: *Compressor, size: usize) usize;
extern "deflate" fn libdeflate_gzip_compress(compressor: *Compressor, input: [*]const u8, size: usize, output: [*]u8, capacity: usize) usize;

pub const Encoder = struct {
    compressor: ?*Compressor = null,

    pub fn encode(self: *Encoder, input: []const u8, output: *Buf, headroom: usize) ?[]const u8 {
        if (self.compressor == null) self.compressor = libdeflate_alloc_compressor(1) orelse return null;
        const bound = libdeflate_gzip_compress_bound(self.compressor.?, input.len);
        output.reset();
        output.ensure(headroom + bound);
        const n = libdeflate_gzip_compress(self.compressor.?, input.ptr, input.len, output.ptr + headroom, bound);
        if (n == 0) return null;
        output.len = headroom + n;
        return output.slice()[headroom..];
    }

    pub fn deinit(self: *Encoder) void {
        libdeflate_free_compressor(self.compressor);
        self.compressor = null;
    }
};
