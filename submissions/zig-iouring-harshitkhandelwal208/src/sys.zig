//! Thin helpers over raw Linux syscalls: no libc, no std.Io on any hot path.
const std = @import("std");
const linux = std.os.linux;

pub const Errno = linux.E;

pub inline fn errnoOf(rc: usize) Errno {
    return linux.errno(rc);
}

pub fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// Seconds since the Unix epoch.
pub fn nowUnix() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

pub fn randomBytes(buf: []u8) void {
    var off: usize = 0;
    while (off < buf.len) {
        const rc = linux.getrandom(buf.ptr + off, buf.len - off, 0);
        switch (errnoOf(rc)) {
            .SUCCESS => off += rc,
            .INTR => {},
            else => @panic("getrandom failed"),
        }
    }
}

/// Anonymous private mapping; pages are zero and untouched pages cost nothing.
pub fn mapAnon(len: usize) ![]align(4096) u8 {
    const rc = linux.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    if (errnoOf(rc) != .SUCCESS) return error.OutOfMemory;
    const p: [*]align(4096) u8 = @ptrFromInt(rc);
    return p[0..len];
}

pub fn unmap(mem: []align(4096) u8) void {
    _ = linux.munmap(mem.ptr, mem.len);
}

pub fn cpuCount() usize {
    return std.Thread.getCpuCount() catch 1;
}

pub fn pinCpu(cpu: usize) void {
    var set: linux.cpu_set_t = std.mem.zeroes(linux.cpu_set_t);
    const word_idx = cpu / (@sizeOf(usize) * 8);
    const bit_idx: u6 = @intCast(cpu % (@sizeOf(usize) * 8));
    set[word_idx] |= (@as(usize, 1) << bit_idx);
    linux.sched_setaffinity(0, &set) catch {};
}

pub fn envGet(environ: [*:null]const ?[*:0]const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (environ[i]) |e| : (i += 1) {
        const s = std.mem.span(e);
        if (s.len > name.len and s[name.len] == '=' and std.mem.eql(u8, s[0..name.len], name)) return s[name.len + 1 ..];
    }
    return null;
}
