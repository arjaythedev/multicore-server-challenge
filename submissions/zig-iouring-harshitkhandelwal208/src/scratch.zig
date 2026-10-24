//! Per-thread bump allocator for request-lifetime data; reset between requests.
const std = @import("std");
const Buf = @import("buf.zig").Buf;

pub const Scratch = struct {
    buf: Buf,
    /// Chunks that outgrew the first block; freed on reset.
    extra: [16][]u8 = undefined,
    n_extra: usize = 0,
    used: usize = 0,

    pub fn init(cap: usize) !Scratch {
        return .{ .buf = try Buf.init(cap) };
    }

    pub fn reset(self: *Scratch) void {
        for (self.extra[0..self.n_extra]) |e| @import("buf.zig").gpa.free(e);
        self.n_extra = 0;
        self.used = 0;
    }

    pub fn alloc(self: *Scratch, n: usize) error{OutOfMemory}![]u8 {
        if (self.used + n <= self.buf.cap) {
            const r = self.buf.ptr[self.used..][0..n];
            self.used += n;
            return r;
        }
        if (self.n_extra == self.extra.len) return error.OutOfMemory;
        const m = try @import("buf.zig").gpa.alloc(u8, n);
        self.extra[self.n_extra] = m;
        self.n_extra += 1;
        return m;
    }
};
