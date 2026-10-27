//! Overload shedding (flag `shed`, off by default): while the box's CPU is saturated, sign-ups and logins get an
//! immediate 503. Nothing else is ever refused, and without overload nothing is.
//!
//! Every `interval_ns` worker 0 reads the box's idle and iowait time from /proc/stat and adds the run time of every
//! idle-priority hasher of every worker (/proc/<tid>/schedstat, from the tids they record in `box`): password hashing
//! runs at idle priority (bcrypt.zig) and takes only CPU nothing else wants, so its CPU counts as idle. A full second
//! of readings below `on_idle` (3%) turns refusals on, a full second above `off_idle` (8%) turns them off, and in
//! between they hold. Worker 0 publishes the state in `box`; every worker reads it in its tick.
//!
//! There is no error budget. Sign-ups and logins were 0.07% of requests in a hold at 183,000 users, so refusing all
//! of them stays far below the 1% error limit on its own.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const http = @import("http.zig");
const sys = @import("sys.zig");
const Route = http.Route;

const ms = std.time.ns_per_ms;

/// The routes refused under overload: the two that hash a password on every request.
pub fn refusable(route: Route) bool {
    return route == .register or route == .login;
}

const nclasses = @typeInfo(Route).@"enum".field_names.len;

pub const interval_ns = 100 * ms;
/// A second below this idle share of the box's CPU turns refusals on, a second above `off_idle` turns them off.
const on_idle = 0.03;
const off_idle = 0.08;
/// Readings in a row that flip the state: one second.
const step_readings = std.time.ns_per_s / interval_ns;
const report_ns = 10 * std.time.ns_per_s;
const max_hashers = 256;

/// The page every process shares (`share`): worker 0's state and the idle-priority hashers' tids.
pub const Box = struct {
    /// Whether sign-ups and logins are refused.
    on: std.atomic.Value(bool) = .init(false),
    /// The last reading's idle share, hasher CPU counted as idle, in thousandths.
    idle_milli: std.atomic.Value(u32) = .init(1000),
    hashers: std.atomic.Value(u32) = .init(0),
    tids: [max_hashers]std.atomic.Value(i32) = @splat(.init(0)),
};

var unshared: Box = .{};
pub var box: *Box = &unshared;

/// Maps `box` shared, so the processes forked after it see one page.
pub fn share() void {
    const rc = linux.mmap(null, @sizeOf(Box), .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED, .ANONYMOUS = true }, -1, 0);
    if (linux.errno(rc) != .SUCCESS) sys.fatal("shed: mmap failed", .{});
    box = @ptrFromInt(rc);
    box.* = .{};
}

/// An idle-priority hasher thread records its tid, so its CPU counts as idle.
pub fn addHasher(tid: i32) void {
    const i = box.hashers.fetchAdd(1, .monotonic);
    if (i < max_hashers) box.tids[i].store(tid, .monotonic);
}

/// The CPU times of the first line of /proc/stat, in clock ticks: idle and iowait, and all of them.
pub const Stat = struct { idle: u64, total: u64 };

pub fn parseStat(text: []const u8) ?Stat {
    var it = std.mem.tokenizeScalar(u8, text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len], ' ');
    if (!std.mem.eql(u8, it.next() orelse return null, "cpu")) return null;
    // user nice system idle iowait irq softirq steal; guest time is counted in user and nice already.
    var s: Stat = .{ .idle = 0, .total = 0 };
    for (0..8) |i| {
        const x = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
        if (i == 3 or i == 4) s.idle += x;
        s.total += x;
    }
    return s;
}

/// The box's idle share between two /proc/stat samples, counting `hasher_ns` of idle-priority hashing as idle.
pub fn idleShare(a: Stat, b: Stat, hasher_ns: u64) f64 {
    // /proc/stat counts in USER_HZ ticks, 100 a second on every Linux ABI.
    const tick_ns = std.time.ns_per_s / 100;
    const total: f64 = @floatFromInt((b.total -| a.total) * tick_ns);
    if (total == 0) return 1;
    const idle: f64 = @floatFromInt((b.idle -| a.idle) * tick_ns + hasher_ns);
    return @min(1, idle / total);
}

/// The state, moved by the idle share: on after a second below `on_idle`, off after a second above `off_idle`.
pub const Trigger = struct {
    on: bool = false,
    /// Readings in a row past the threshold that would flip the state.
    run: u32 = 0,

    pub fn update(t: *Trigger, idle: f64) void {
        const flip = if (t.on) idle > off_idle else idle < on_idle;
        if (!flip) {
            t.run = 0;
            return;
        }
        t.run += 1;
        if (t.run < step_readings) return;
        t.run = 0;
        t.on = !t.on;
    }
};

/// Worker 0's reader of the box's CPU.
pub const Sampler = struct {
    trigger: Trigger = .{},
    stat: ?Stat = null,
    hasher_ns: u64 = 0,

    fn sample(s: *Sampler) void {
        var buf: [256]u8 = undefined;
        const stat = parseStat(readFile("/proc/stat", &buf) orelse return) orelse return;
        var hasher_ns: u64 = 0;
        for (box.tids[0..@min(box.hashers.load(.monotonic), max_hashers)]) |*tid| {
            const t = tid.load(.monotonic);
            if (t == 0) continue;
            var path: [32:0]u8 = undefined;
            const p = std.fmt.bufPrintSentinel(&path, "/proc/{d}/schedstat", .{t}, 0) catch continue;
            hasher_ns += parseRunNs(readFile(p, &buf) orelse continue) orelse continue;
        }
        if (s.stat) |prev| publish(&s.trigger, idleShare(prev, stat, hasher_ns -| s.hasher_ns));
        s.stat = stat;
        s.hasher_ns = hasher_ns;
    }
};

fn publish(t: *Trigger, idle: f64) void {
    t.update(idle);
    box.on.store(t.on, .monotonic);
    box.idle_milli.store(@intFromFloat(idle * 1000), .monotonic);
}

/// The first field of /proc/<tid>/schedstat: the thread's time on a CPU, ns.
pub fn parseRunNs(text: []const u8) ?u64 {
    var it = std.mem.tokenizeAny(u8, text, " \n");
    return std.fmt.parseInt(u64, it.next() orelse return null, 10) catch null;
}

fn readFile(path: [*:0]const u8, buf: []u8) ?[]const u8 {
    const fd = sys.check(linux.open(path, .{ .CLOEXEC = true }, 0)) catch return null;
    defer sys.closeFd(@intCast(fd));
    const n = sys.readSome(@intCast(fd), buf) catch return null;
    return buf[0..n];
}

/// Requests and refusals of one route since the last report.
const Class = struct {
    requests: u32 = 0,
    refused: u32 = 0,
};

pub const Controller = struct {
    classes: [nclasses]Class = @splat(.{}),
    /// Whether refusals are on, as `box` had it at the last interval's end.
    on: bool = false,
    /// Worker 0's alone.
    sampler: ?Sampler = null,
    interval_end: u64 = 0,

    /// Since the last report: intervals, those overloaded, and the lowest and summed idle readings in thousandths.
    intervals: u32 = 0,
    overloaded: u32 = 0,
    idle_min: u32 = 1000,
    idle_sum: u64 = 0,

    report_end: u64 = 0,

    /// A routed request arrives; true if it is to be refused.
    pub fn refuse(c: *Controller, class: Route) bool {
        if (!refusable(class)) return false;
        const k = &c.classes[@intFromEnum(class)];
        k.requests += 1;
        if (!c.on) return false;
        k.refused += 1;
        return true;
    }

    /// When worker 0 must tick again (monotonic ns), so it reads the box's CPU even while it has no requests.
    pub fn due(c: *const Controller) ?u64 {
        return if (c.sampler != null) c.interval_end else null;
    }

    /// Ends the interval and the report period that are over at `now` (monotonic ns). Call it every event loop
    /// iteration.
    pub fn tick(c: *Controller, now: u64) void {
        if (now < c.interval_end) return;
        if (c.interval_end == 0) c.report_end = now + report_ns;
        c.endInterval();
        c.interval_end = now + interval_ns;
        if (now >= c.report_end) {
            var buf: [512]u8 = undefined;
            if (c.summary(&buf)) |line| if (!builtin.is_test) sys.log("{s}", .{line});
            c.classes = @splat(.{});
            c.intervals = 0;
            c.overloaded = 0;
            c.idle_min = 1000;
            c.idle_sum = 0;
            c.report_end = now + report_ns;
        }
    }

    fn endInterval(c: *Controller) void {
        if (c.sampler) |*s| if (!builtin.is_test) s.sample();
        c.on = box.on.load(.monotonic);
        const idle = box.idle_milli.load(.monotonic);
        c.intervals += 1;
        c.overloaded += @intFromBool(c.on);
        c.idle_min = @min(c.idle_min, idle);
        c.idle_sum += idle;
    }

    /// One line on what was refused since the last report, or null if nothing was and the box was never overloaded.
    fn summary(c: *const Controller, buf: []u8) ?[]const u8 {
        var w: std.Io.Writer = .fixed(buf);
        const intervals: f64 = @floatFromInt(@max(c.intervals, 1));
        w.print("shed in the last {d} s: {s}, overloaded {d:.0}% of the time, idle lowest {d:.1}% average {d:.1}%;", .{
            report_ns / std.time.ns_per_s,
            if (c.on) "on" else "off",
            @as(f64, @floatFromInt(c.overloaded)) * 100 / intervals,
            @as(f64, @floatFromInt(c.idle_min)) / 10,
            @as(f64, @floatFromInt(c.idle_sum)) / 10 / intervals,
        }) catch {};
        var any = c.overloaded > 0;
        for ([_]Route{ .register, .login }) |route| {
            const k = c.classes[@intFromEnum(route)];
            if (k.refused == 0) continue;
            any = true;
            w.print(" {s}: {d} refused of {d};", .{ @tagName(route), k.refused, k.requests }) catch {};
        }
        return if (any) w.buffered() else null;
    }
};

/// This worker's controller.
pub var ctl: Controller = .{};

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// A worker in a test, also playing worker 0: each interval opens with a reading of the box's idle share.
const Sim = struct {
    c: Controller = .{},
    trigger: Trigger = .{},
    now: u64 = 1,
    refused: [nclasses]u64 = @splat(0),
    arrived: [nclasses]u64 = @splat(0),

    fn init() Sim {
        box.on.store(false, .monotonic);
        box.idle_milli.store(1000, .monotonic);
        var s: Sim = .{};
        s.c.tick(s.now);
        return s;
    }

    /// A reading of `idle`, then `n` requests spread over one interval, every route in turn.
    fn interval(s: *Sim, n: u32, idle: f64) void {
        publish(&s.trigger, idle);
        for (0..n) |i| {
            const class: Route = @enumFromInt(i % nclasses);
            s.arrived[@intFromEnum(class)] += 1;
            if (s.c.refuse(class)) s.refused[@intFromEnum(class)] += 1;
            s.now += interval_ns / n;
            s.c.tick(s.now);
        }
    }

    fn count(s: *Sim) void {
        s.refused = @splat(0);
        s.arrived = @splat(0);
    }

    fn refusals(s: *const Sim) u64 {
        var n: u64 = 0;
        for (s.refused) |r| n += r;
        return n;
    }
};

test "/proc/stat's first line and a schedstat line parse" {
    const line = "cpu  4705 356 584 3699176 23 0 21 0 7 1\ncpu0 1393 280 234 852393 15 0 21 0 0 0\n";
    try testing.expectEqual(Stat{ .idle = 3699176 + 23, .total = 4705 + 356 + 584 + 3699176 + 23 + 0 + 21 + 0 }, parseStat(line).?);
    try testing.expectEqual(null, parseStat("cpu0 1 2 3\n"));
    try testing.expectEqual(null, parseStat("cpu  1 2 3 4 5 6 7\ncpu0 1 2 3 4 5 6 7\n"));
    try testing.expectEqual(null, parseStat("intr 1 2 3 4 5 6 7 8\n"));
    try testing.expectEqual(12345678, parseRunNs("12345678 999 42\n").?);
    try testing.expectEqual(null, parseRunNs(""));
}

test "the idle share counts idle and iowait, and the idle-priority hashers' CPU" {
    const a: Stat = .{ .idle = 1000, .total = 10_000 };
    // 8 CPUs for 100 ms: 80 ticks, 2 of them idle.
    const b: Stat = .{ .idle = 1002, .total = 10_080 };
    try testing.expectApproxEqAbs(0.025, idleShare(a, b, 0), 1e-9);
    // Hashers ran 400 ms of the 800: half the box.
    try testing.expectApproxEqAbs(0.525, idleShare(a, b, 400 * ms), 1e-9);
    try testing.expectEqual(1, idleShare(a, a, 0));
    try testing.expectEqual(1, idleShare(a, b, 10 * std.time.ns_per_s));
}

test "hasher CPU counted as idle keeps the trigger off when only hashing is busy" {
    // Every CPU busy, hashers on 60% of it.
    const a: Stat = .{ .idle = 0, .total = 0 };
    const b: Stat = .{ .idle = 0, .total = 80 };
    var t: Trigger = .{};
    for (0..100) |_| t.update(idleShare(a, b, 480 * ms));
    try testing.expect(!t.on);
    for (0..step_readings) |_| t.update(idleShare(a, b, 0));
    try testing.expect(t.on);
}

test "the trigger turns on after a second below 3% idle, holds between 3% and 8%, and turns off after a second above 8%" {
    var t: Trigger = .{};
    for (0..100) |_| t.update(0.05);
    try testing.expect(!t.on);
    // Nine readings below 3% are not a second; a reading between restarts the run.
    for (0..9) |_| t.update(0.01);
    t.update(0.05);
    for (0..9) |_| t.update(0.01);
    try testing.expect(!t.on);
    t.update(0.01);
    try testing.expect(t.on);
    // Holds between, and below.
    for (0..100) |_| t.update(0.05);
    for (0..100) |_| t.update(0.0);
    try testing.expect(t.on);
    for (0..9) |_| t.update(0.1);
    t.update(0.05);
    for (0..9) |_| t.update(0.1);
    try testing.expect(t.on);
    t.update(0.1);
    try testing.expect(!t.on);
}

test "with CPU idle nothing is refused" {
    var s: Sim = .init();
    for (0..600) |_| s.interval(1000, 0.5);
    try testing.expectEqual(0, s.refusals());
    try testing.expect(!s.c.on);
}

test "a dip below 3% shorter than a second refuses nothing" {
    var s: Sim = .init();
    for (0..20) |_| s.interval(1000, 0.5);
    for (0..50) |_| {
        for (0..9) |_| s.interval(1000, 0.01);
        s.interval(1000, 0.5);
    }
    try testing.expectEqual(0, s.refusals());
}

test "under overload every sign-up and login is refused, and nothing else" {
    var s: Sim = .init();
    for (0..20) |_| s.interval(1000, 0.5);
    for (0..11) |_| s.interval(1000, 0.0);
    try testing.expect(s.c.on);
    s.count();
    for (0..600) |_| s.interval(1000, 0.0);
    try testing.expect(s.arrived[@intFromEnum(Route.register)] > 0);
    try testing.expect(s.arrived[@intFromEnum(Route.login)] > 0);
    for (s.arrived, s.refused, 0..) |a, r, i| {
        const expected = if (refusable(@enumFromInt(i))) a else 0;
        try testing.expectEqual(expected, r);
    }
    var buf: [512]u8 = undefined;
    const line = s.c.summary(&buf).?;
    try testing.expect(std.mem.indexOf(u8, line, ": on,") != null);
    try testing.expect(std.mem.indexOf(u8, line, " register: ") != null);
    try testing.expect(std.mem.indexOf(u8, line, " login: ") != null);
}

test "refusals hold between 3% and 8% idle and stop a second after idle passes 8%" {
    var s: Sim = .init();
    for (0..20) |_| s.interval(1000, 0.5);
    for (0..11) |_| s.interval(1000, 0.0);
    s.count();
    for (0..50) |_| s.interval(1000, 0.05);
    try testing.expect(s.c.on);
    try testing.expectEqual(s.arrived[@intFromEnum(Route.login)], s.refused[@intFromEnum(Route.login)]);
    for (0..11) |_| s.interval(1000, 0.1);
    try testing.expect(!s.c.on);
    s.count();
    for (0..100) |_| s.interval(1000, 0.1);
    try testing.expectEqual(0, s.refusals());
}
