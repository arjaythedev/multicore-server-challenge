//! Tiny futex-based synchronisation primitives (the standard library's moved behind std.Io).
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

fn futexWait(addr: *const u32, expect: u32, timeout_ns: ?u64) void {
    var ts: linux.timespec = undefined;
    var tp: ?*const linux.timespec = null;
    if (timeout_ns) |t| {
        ts = .{ .sec = @intCast(t / 1_000_000_000), .nsec = @intCast(t % 1_000_000_000) };
        tp = &ts;
    }
    _ = linux.futex_4arg(addr, .{ .cmd = .WAIT, .private = true }, expect, tp);
}

fn futexWake(addr: *const u32, n: u32) void {
    _ = linux.futex_3arg(addr, .{ .cmd = .WAKE, .private = true }, n);
}

/// Drepper's three-state futex mutex.
pub const Mutex = struct {
    s: u32 = 0,

    pub fn lock(self: *Mutex) void {
        if (@cmpxchgStrong(u32, &self.s, 0, 1, .acquire, .monotonic) == null) return;
        while (@atomicRmw(u32, &self.s, .Xchg, 2, .acquire) != 0) futexWait(&self.s, 2, null);
    }

    pub fn unlock(self: *Mutex) void {
        if (@atomicRmw(u32, &self.s, .Sub, 1, .release) != 1) {
            @atomicStore(u32, &self.s, 0, .release);
            futexWake(&self.s, 1);
        }
    }
};

/// A counter threads can sleep on until it changes.
pub const Signal = struct {
    seq: u32 = 0,

    pub fn current(self: *const Signal) u32 {
        return @atomicLoad(u32, &self.seq, .acquire);
    }

    pub fn notify(self: *Signal) void {
        _ = @atomicRmw(u32, &self.seq, .Add, 1, .release);
        futexWake(&self.seq, 1);
    }

    /// Sleep until `seq != seen` or the timeout passes.
    pub fn wait(self: *Signal, seen: u32, timeout_ns: ?u64) void {
        futexWait(&self.seq, seen, timeout_ns);
    }
};
