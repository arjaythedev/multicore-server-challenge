//! Overload shedding (flag `shed`): under CPU saturation the server refuses route classes in a fixed, measured cost
//! order, heaviest first, with an immediate 503, within a strict error budget. Without overload it refuses nothing.
//!
//! Every `interval_ns` worker 0 reads the box's idle and iowait time from /proc/stat and adds the run time of every
//! idle-priority hasher of every worker (/proc/<tid>/schedstat, from the tids they record in `box`): password hashing
//! runs at idle priority (bcrypt.zig) and takes only CPU nothing else wants, so its CPU counts as idle. It publishes in
//! `box` the depth: how many entries of `order` to refuse. The first entry is refused as soon as idle falls below
//! `on_idle` (3%), and one more each further second below it; above `off_idle` (8%) the depth falls one entry a
//! second; in between it holds. Every worker reads the depth in its tick and refuses the entries above it in full.
//!
//! Every refusal spends from the worker's error budget. Each request earns 0.9% of an error, a refusal costs a whole
//! one, and nothing is spent that was not earned, so from start-up on the refusals never exceed 0.9% of requests. A
//! refusal of entry r needs credit for r + 1 errors, so the heavier entries get the budget first; a request the
//! budget does not pay for is served. Every other response with status 400 or above spends a whole error too, into
//! debt of at most `debt_carries` times what a `carry_ns` earns, so the worker refuses nothing while its refusals and
//! recent other errors exceed 0.9% of its requests. Unspent credit carries at most what the last `carry_ns` of
//! requests earned, so a quiet spell banks no errors for later.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const http = @import("http.zig");
const sys = @import("sys.zig");
const Route = http.Route;

const ms = std.time.ns_per_ms;

/// The refusal order, heaviest first. `register` and `login` were measured on this server: on Hetzner at submit
/// 2b10541, the cost per request (Postgres share plus hasher CPU) the shed then learned, in its 10 s log lines of the
/// 174k and 183k user holds on 25 Oct 04:40-05:25: `register` 17.6 ms (mean of 3 lines), `login` 15.5 ms (mean of
/// 8). The rest follow #7 (rust7) on the same workload at 100,000 users: Postgres µs per request of each endpoint,
/// from pg_stat_statements executor time mapped onto measured backend CPU; `list` is the mix-weighted mean of its
/// four forms. Routes measured nowhere go
/// last: `user_put` hashes only when a password is sent, and the load never sends one. `not_found` is never refused.
pub const order = [_]Route{
    .register, // 17.6 ms
    .login, // 15.5 ms
    .feed, // 847 µs
    .article_create, // 297 µs
    .list, // about 236 µs
    .favorite, // 194 µs
    .comments, // 150 µs
    .comment_create, // 107 µs
    .article, // 86 µs
    .profile, // 21 µs
    .tags, // 12 µs
    .unfavorite,
    .article_update,
    .article_delete,
    .comment_delete,
    .follow,
    .unfollow,
    .user_put,
    .user_get,
};

const nclasses = @typeInfo(Route).@"enum".field_names.len;
const unranked = std.math.maxInt(u8);
/// Each route's place in `order`; `unranked` for `not_found`.
const position = blk: {
    var p: [nclasses]u8 = @splat(unranked);
    for (order, 0..) |r, i| {
        if (p[@intFromEnum(r)] != unranked) @compileError("a route twice in the shed order");
        p[@intFromEnum(r)] = i;
    }
    if (order.len != nclasses - 1 or p[@intFromEnum(Route.not_found)] != unranked)
        @compileError("the shed order must hold every route but not_found");
    break :blk p;
};

pub const interval_ns = 100 * ms;
/// Below this idle share of the box's CPU the depth rises, above `off_idle` it falls.
const on_idle = 0.03;
const off_idle = 0.08;
/// Readings in a row that move the depth one entry: one second.
const step_readings = std.time.ns_per_s / interval_ns;
/// The error budget in thousandths of an error per request. A policy, not a measurement: with every other error it
/// keeps the errors under 1% of requests.
const budget_milli = 9;
const error_milli = 1000;
const carry_ns = std.time.ns_per_s;
/// Debt from other error responses is kept to what this many carry periods earn, so errors long past (an earlier
/// load step in the same process) don't keep refusals off for minutes.
const debt_carries = 10;
const report_ns = 10 * std.time.ns_per_s;
const max_hashers = 256;

/// The page every process shares (`share`): worker 0's depth and the idle-priority hashers' tids.
pub const Box = struct {
    /// The entries of `order` to refuse.
    depth: std.atomic.Value(u32) = .init(0),
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

/// The depth, moved by the idle share: up below `on_idle`, down above `off_idle`, one entry per second of readings.
pub const Trigger = struct {
    depth: u32 = 0,
    /// Readings in a row on the same side since the depth last moved.
    run: u32 = 0,

    pub fn update(t: *Trigger, idle: f64) void {
        if (idle < on_idle) {
            if (t.depth == 0) {
                t.depth = 1;
                t.run = 0;
            } else if (t.step()) t.depth = @min(t.depth + 1, order.len);
        } else if (idle > off_idle and t.depth > 0) {
            if (t.step()) t.depth -= 1;
        } else t.run = 0;
    }

    fn step(t: *Trigger) bool {
        t.run += 1;
        if (t.run < step_readings) return false;
        t.run = 0;
        return true;
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
    box.depth.store(t.depth, .monotonic);
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

/// What the controller knows of one request in flight.
pub const Ticket = struct {
    /// Whether its response is already counted against the budget: the controller's refusals spend when decided.
    counted: bool = false,
};

/// Requests and refusals of one route since the last report.
const Class = struct {
    requests: u32 = 0,
    refused: u32 = 0,
};

pub const Controller = struct {
    classes: [nclasses]Class = @splat(.{}),
    /// The entries refused, as `box` had it at the last interval's end.
    depth: u32 = 0,
    /// Worker 0's alone.
    sampler: ?Sampler = null,
    interval_end: u64 = 0,

    /// Since the last report: intervals, those overloaded, and the lowest and summed idle readings in thousandths.
    intervals: u32 = 0,
    overloaded: u32 = 0,
    idle_min: u32 = 1000,
    idle_sum: u64 = 0,

    /// Unspent budget and its cap, in thousandths of an error; the cap is what the last `carry_ns` earned. Below zero
    /// while other error responses have spent more than was earned.
    credit: i64 = 0,
    cap: i64 = 0,
    carry_end: u64 = 0,
    carry_requests: u64 = 0,

    report_end: u64 = 0,

    /// A routed request arrives; true if it is to be refused.
    pub fn admit(c: *Controller, class: Route) bool {
        c.credit = @min(c.credit + budget_milli, c.cap);
        c.carry_requests += 1;
        const k = &c.classes[@intFromEnum(class)];
        k.requests += 1;
        const r = position[@intFromEnum(class)];
        if (r >= c.depth or !c.spend(r)) return false;
        k.refused += 1;
        return true;
    }

    /// A response with status 400 or above that the controller did not decide on went out.
    pub fn failed(c: *Controller) void {
        c.credit = @max(c.credit - error_milli, -debt_carries * c.cap);
    }

    /// When worker 0 must tick again (monotonic ns), so it reads the box's CPU even while it has no requests.
    pub fn due(c: *const Controller) ?u64 {
        return if (c.sampler != null) c.interval_end else null;
    }

    /// Ends the interval, the carry period and the report period that are over at `now` (monotonic ns). Call it
    /// every event loop iteration.
    pub fn tick(c: *Controller, now: u64) void {
        if (now < c.interval_end) return;
        if (c.interval_end == 0) {
            c.carry_end = now + carry_ns;
            c.report_end = now + report_ns;
        }
        c.endInterval();
        c.interval_end = now + interval_ns;
        if (now >= c.carry_end) {
            c.cap = budget_milli * @as(i64, @intCast(c.carry_requests));
            c.credit = @min(c.credit, c.cap);
            c.carry_requests = 0;
            c.carry_end = now + carry_ns;
        }
        if (now >= c.report_end) {
            var buf: [2048]u8 = undefined;
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
        c.depth = box.depth.load(.monotonic);
        const idle = box.idle_milli.load(.monotonic);
        c.intervals += 1;
        c.overloaded += @intFromBool(c.depth > 0);
        c.idle_min = @min(c.idle_min, idle);
        c.idle_sum += idle;
    }

    /// Spends one error for a refusal of entry `r`, which must leave an error's credit for each entry above it, so
    /// the heavier entries get the budget first.
    fn spend(c: *Controller, r: u8) bool {
        if (c.credit < error_milli * (@as(i64, r) + 1)) return false;
        c.credit -= error_milli;
        return true;
    }

    /// One line on what was refused since the last report, or null if nothing was and the box was never overloaded.
    fn summary(c: *const Controller, buf: []u8) ?[]const u8 {
        var w: std.Io.Writer = .fixed(buf);
        const intervals: f64 = @floatFromInt(@max(c.intervals, 1));
        w.print("shed in the last {d} s: depth {d}, overloaded {d:.0}% of the time, idle lowest {d:.1}% average {d:.1}%;", .{
            report_ns / std.time.ns_per_s,
            c.depth,
            @as(f64, @floatFromInt(c.overloaded)) * 100 / intervals,
            @as(f64, @floatFromInt(c.idle_min)) / 10,
            @as(f64, @floatFromInt(c.idle_sum)) / 10 / intervals,
        }) catch {};
        var any = c.overloaded > 0;
        for (order, 1..) |route, n| {
            const k = c.classes[@intFromEnum(route)];
            if (k.refused == 0) continue;
            any = true;
            w.print(" {d} {s}: {d} refused of {d};", .{ n, @tagName(route), k.refused, k.requests }) catch {};
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
    /// One request in this many is a register (entry 1); the rest alternate login (entry 2) and tags (entry 11).
    every: u32 = 200,
    /// One served request in this many fails on its own, at random (0: none).
    fail_in: u32 = 0,
    prng: std.Random.DefaultPrng = .init(11),
    requests: u64 = 0,
    errors: u64 = 0,
    failures: u64 = 0,
    refused: [nclasses]u64 = @splat(0),
    arrived: [nclasses]u64 = @splat(0),

    fn init() Sim {
        box.depth.store(0, .monotonic);
        box.idle_milli.store(1000, .monotonic);
        var s: Sim = .{};
        s.c.tick(s.now);
        return s;
    }

    /// One request of `class`, served unless refused.
    fn request(s: *Sim, class: Route) void {
        s.requests += 1;
        s.arrived[@intFromEnum(class)] += 1;
        if (s.c.admit(class)) {
            s.errors += 1;
            s.refused[@intFromEnum(class)] += 1;
            return;
        }
        if (s.fail_in != 0 and s.prng.random().uintLessThan(u32, s.fail_in) == 0) {
            s.c.failed();
            s.errors += 1;
            s.failures += 1;
        }
    }

    /// A reading of `idle`, then `n` requests spread over one interval.
    fn interval(s: *Sim, n: u32, idle: f64) void {
        publish(&s.trigger, idle);
        for (0..n) |i| {
            s.request(if (i % s.every == 0) .register else if (i % 2 == 0) .login else .tags);
            s.now += interval_ns / n;
            s.c.tick(s.now);
        }
    }

    fn count(s: *Sim) void {
        s.refused = @splat(0);
        s.arrived = @splat(0);
    }

    fn refusals(s: *const Sim, class: Route) u64 {
        return s.refused[@intFromEnum(class)];
    }

    fn arrivals(s: *const Sim, class: Route) u64 {
        return s.arrived[@intFromEnum(class)];
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
    try testing.expectEqual(0, t.depth);
    t.update(idleShare(a, b, 0));
    try testing.expectEqual(1, t.depth);
}

test "the depth rises one entry a second below 3% idle, holds between 3% and 8%, and falls one a second above 8%" {
    var t: Trigger = .{};
    t.update(0.5);
    try testing.expectEqual(0, t.depth);
    t.update(0.05);
    try testing.expectEqual(0, t.depth);
    // On at once, then one more entry per further second.
    t.update(0.01);
    try testing.expectEqual(1, t.depth);
    for (0..9) |_| t.update(0.01);
    try testing.expectEqual(1, t.depth);
    t.update(0.01);
    try testing.expectEqual(2, t.depth);
    for (0..10) |_| t.update(0.01);
    try testing.expectEqual(3, t.depth);
    // Holds, and a run broken by a reading between restarts its second.
    for (0..100) |_| t.update(0.05);
    try testing.expectEqual(3, t.depth);
    for (0..9) |_| t.update(0.1);
    t.update(0.05);
    for (0..9) |_| t.update(0.1);
    try testing.expectEqual(3, t.depth);
    t.update(0.1);
    try testing.expectEqual(2, t.depth);
    for (0..20) |_| t.update(0.1);
    try testing.expectEqual(0, t.depth);
    for (0..20) |_| t.update(0.1);
    try testing.expectEqual(0, t.depth);
    // Never past the table.
    for (0..10 * order.len + 50) |_| t.update(0);
    try testing.expectEqual(order.len, t.depth);
}

test "the order holds every route but not_found, sign-ups and sign-ins first" {
    try testing.expectEqual(.register, order[0]);
    try testing.expectEqual(.login, order[1]);
    try testing.expectEqual(unranked, position[@intFromEnum(Route.not_found)]);
    var c: Controller = .{ .depth = order.len, .credit = 1_000_000, .cap = 1_000_000 };
    try testing.expect(!c.admit(.not_found));
    try testing.expect(c.admit(.user_get));
}

test "with CPU idle nothing is refused" {
    var s: Sim = .init();
    for (0..600) |_| s.interval(1000, 0.5);
    try testing.expectEqual(0, s.errors);
    try testing.expectEqual(0, s.c.depth);
}

test "refusals follow the table: below 3% idle register in full, a second later login too, never tags" {
    var s: Sim = .init();
    for (0..20) |_| s.interval(1000, 0.5);
    // The first reading below 3% reaches the controller within the interval; the next nine refuse entry 1 alone.
    s.interval(1000, 0.01);
    s.count();
    for (0..9) |_| s.interval(1000, 0.01);
    try testing.expectEqual(1, s.c.depth);
    try testing.expectEqual(s.arrivals(.register), s.refusals(.register));
    try testing.expectEqual(0, s.refusals(.login) + s.refusals(.tags));
    // A further full second below 3%: entry 2 too.
    s.interval(1000, 0.01);
    s.count();
    for (0..5) |_| s.interval(1000, 0.01);
    try testing.expectEqual(2, s.c.depth);
    try testing.expectEqual(s.arrivals(.register), s.refusals(.register));
    try testing.expect(s.refusals(.login) > 0);
    try testing.expectEqual(0, s.refusals(.tags));
    var buf: [2048]u8 = undefined;
    const line = s.c.summary(&buf).?;
    try testing.expect(std.mem.indexOf(u8, line, "depth 2,") != null);
    try testing.expect(std.mem.indexOf(u8, line, " 1 register: ") != null);
    try testing.expect(std.mem.indexOf(u8, line, " 2 login: ") != null);
}

test "between 3% and 8% idle the refusals hold, above 8% they shrink an entry a second and stop" {
    var s: Sim = .init();
    for (0..20) |_| s.interval(1000, 0.5);
    for (0..12) |_| s.interval(1000, 0.01);
    try testing.expectEqual(2, s.c.depth);
    s.count();
    for (0..50) |_| s.interval(1000, 0.05);
    try testing.expectEqual(2, s.c.depth);
    try testing.expectEqual(s.arrivals(.register), s.refusals(.register));
    try testing.expect(s.refusals(.login) > 0);
    // A second above 8%: login is served again, register still refused.
    for (0..10) |_| s.interval(1000, 0.1);
    s.count();
    for (0..9) |_| s.interval(1000, 0.1);
    try testing.expectEqual(1, s.c.depth);
    try testing.expectEqual(0, s.refusals(.login));
    try testing.expectEqual(s.arrivals(.register), s.refusals(.register));
    // Another: nothing is refused.
    s.interval(1000, 0.1);
    const errors = s.errors;
    for (0..100) |_| s.interval(1000, 0.1);
    try testing.expectEqual(0, s.c.depth);
    try testing.expectEqual(errors, s.errors);
}

test "the refusals never exceed the budget, however the load moves" {
    var s: Sim = .init();
    var prng: std.Random.DefaultPrng = .init(7);
    const rnd = prng.random();
    for (0..3000) |_| {
        // Bursts, lulls and quiet spells, always overloaded.
        publish(&s.trigger, 0);
        const n = switch (rnd.uintLessThan(u8, 10)) {
            0 => 0,
            1, 2 => rnd.uintLessThan(u32, 50) + 1,
            else => rnd.uintLessThan(u32, 3000) + 1,
        };
        if (n == 0) {
            s.now += interval_ns;
            s.c.tick(s.now);
        }
        for (0..n) |_| {
            s.request(@enumFromInt(rnd.intRangeLessThan(u8, 1, nclasses)));
            try testing.expect(s.errors * error_milli <= s.requests * budget_milli);
            s.now += interval_ns / n;
            s.c.tick(s.now);
        }
    }
    // The bound held with the budget in use.
    try testing.expect(s.errors * error_milli > s.requests * budget_milli / 2);
}

test "a long overload spends the budget on the heaviest entries first" {
    for ([_]u32{ 500, 100 }) |every| {
        var s: Sim = .init();
        s.every = every;
        for (0..20) |_| s.interval(1000, 0.5);
        // A minute of overload, every entry refused, then another, counted.
        for (0..600) |_| s.interval(1000, 0.01);
        s.count();
        const requests = s.requests;
        const errors = s.errors;
        // Credit unspent when the count starts, at most one second's earnings.
        const carried: u64 = @intCast(@divFloor(@max(s.c.credit, 0), error_milli) + 1);
        for (0..600) |_| s.interval(1000, 0.01);
        const budget = (s.requests - requests) * budget_milli / error_milli;
        try testing.expect(s.errors - errors <= budget + carried);
        if (s.arrivals(.register) < budget) {
            // At 0.2% register can use only part of the budget: all of it is refused, and login gets the rest.
            try testing.expectEqual(s.arrivals(.register), s.refusals(.register));
            try testing.expect(s.refusals(.login) > 0);
        } else {
            // At 1% register alone needs more than the budget, and gets nearly all of it.
            try testing.expect(s.refusals(.register) * 10 >= budget * 9);
        }
        try testing.expect(s.refusals(.tags) * 100 < budget);
    }
}

test "other error responses spend from the budget, and the refusals get what is left" {
    for ([_]u32{ 400, 111 }) |fail_in| {
        var s: Sim = .init();
        s.fail_in = fail_in;
        for (0..20) |_| s.interval(1000, 0.5);
        // Two minutes of overload, with the other errors falling at random among the requests served.
        for (0..1200) |_| s.interval(1000, 0.01);
        const refusals = s.errors - s.failures;
        if (fail_in == 400) {
            // 0.25% fail: together with the refusals they stay within 0.9%, and register gets most of the rest.
            try testing.expect(s.errors * error_milli <= s.requests * budget_milli + 2 * error_milli);
            try testing.expect(s.refusals(.register) * 1000 > s.requests * 4);
            try testing.expect(s.refusals(.login) < s.refusals(.register));
        } else {
            // 0.9% fail, the whole budget: the credit drifts around zero and next to nothing is refused.
            try testing.expect(refusals * 1000 < s.requests);
        }
    }
}

test "debt from other errors is bounded, so refusals resume soon after they stop" {
    var s: Sim = .init();
    for (0..20) |_| s.interval(1000, 0.5);
    // A burst of 100,000 other errors, then steady overload.
    for (0..100_000) |_| s.c.failed();
    s.count();
    for (0..150) |_| s.interval(1000, 0.01);
    // Ten seconds of earnings repay the floor; the refusals are back within fifteen.
    try testing.expect(s.refusals(.register) > 0);
}
