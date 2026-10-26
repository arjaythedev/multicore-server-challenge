//! Thin checked wrappers over raw Linux syscalls. The server talks to the kernel directly (io_uring and a few
//! setup calls), so it does not depend on std's evolving I/O layers.
const std = @import("std");
const linux = std.os.linux;

pub const Error = error{Syscall};

pub fn check(rc: usize) Error!usize {
    const e = linux.errno(rc);
    if (e != .SUCCESS) {
        last_errno = e;
        return error.Syscall;
    }
    return rc;
}

pub threadlocal var last_errno: linux.E = .SUCCESS;

pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("conduit: " ++ fmt ++ "\n", args);
    linux.exit_group(1);
}

/// One line on stderr in one write, so lines from several processes at once don't interleave.
pub fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(buf[0 .. buf.len - 1]);
    w.print("conduit[{d}]: " ++ fmt, .{linux.getpid()} ++ args) catch {};
    const n = w.buffered().len;
    buf[n] = '\n';
    writeAll(2, buf[0 .. n + 1]) catch {};
}

pub fn nowSec() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @intCast(ts.sec);
}

pub fn monoNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn setsockoptInt(fd: i32, level: i32, opt: u32, value: c_int) Error!void {
    _ = try check(linux.setsockopt(fd, level, opt, std.mem.asBytes(&value), @sizeOf(c_int)));
}

pub fn closeFd(fd: i32) void {
    _ = linux.close(fd);
}

pub fn writeAll(fd: i32, bytes: []const u8) Error!void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = try check(linux.write(fd, bytes[off..].ptr, bytes.len - off));
        off += n;
    }
}

pub fn readSome(fd: i32, buf: []u8) Error!usize {
    return check(linux.read(fd, buf.ptr, buf.len));
}

pub fn cpuCount() usize {
    var set: linux.cpu_set_t = undefined;
    const rc = linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &set);
    if (linux.errno(rc) != .SUCCESS) return 1;
    var n: usize = 0;
    for (set) |w| n += @popCount(w);
    return @max(n, 1);
}

pub fn randomBytes(buf: []u8) void {
    var off: usize = 0;
    while (off < buf.len) {
        const rc = linux.getrandom(buf[off..].ptr, buf.len - off, 0);
        if (linux.errno(rc) != .SUCCESS) fatal("getrandom failed", .{});
        off += rc;
    }
}
