//! Startup: read the environment, check every SQL statement against the live schema, then fork the workers.
//!
//! Each worker is a single-threaded process with its own SO_REUSEPORT listening socket, io_uring, write connection
//! and bcrypt threads, and the kernel spreads connections across them. LimitNOFILE applies per process, which
//! several workers also need to hold 250k connections. With two or more workers the parent also forks the drain
//! process, which owns every read connection and runs one read queue for all workers (drain.zig); a lone worker
//! keeps its own read connections. A process that dies is not replaced: the parent stops the others and exits, so a
//! crash is visible.
//!
//! CONDUIT_FLAGS (flags.zig) is read here, before forking; every process then runs the server built for it.
//!
//! Two scheduling settings. Each worker's event loop and the drain process run under SCHED_BATCH (as #130 does), so a
//! loop woken by a completion no longer preempts a running Postgres backend; ZIG_SCHED_BATCH=0 keeps the default
//! policy. The bcrypt hashers stay at SCHED_IDLE and the watchdog at normal priority. ZIG_LOOP_NICE=N (0 to 19, default
//! 0) sets nice N on each worker's event loop. Both apply to the calling thread only, after the bcrypt threads start.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const pz = @import("pz.zig");
const pg = @import("pg.zig");
const db = @import("db.zig");
const mega = @import("mega.zig");
const jwt = @import("jwt.zig");
const bcrypt = @import("bcrypt.zig");
const loop = @import("loop.zig");
const drain = @import("drain.zig");
const shed = @import("shed.zig");
const flags = @import("flags.zig");
const Flags = flags.Flags;

const Sizing = struct {
    workers: usize,
    /// Read connections per worker: all of them with one worker, none with a drain process.
    read_conns: u16,
    write_conns: u16,
    bcrypt_threads: usize,
    /// The drain process's read connections; 0 without one.
    drain_reads: u16,
};

/// ZIG_SCHED_BATCH and ZIG_LOOP_NICE (see the top of this file).
const Sched = struct {
    batch: bool = true,
    loop_nice: u5 = 0,

    fn parse(batch: ?[]const u8, nice: ?[]const u8) Sched {
        var s: Sched = .{};
        if (batch) |b| if (b.len > 0) {
            s.batch = if (std.mem.eql(u8, b, "1")) true else if (std.mem.eql(u8, b, "0")) false else sys.fatal("ZIG_SCHED_BATCH: '{s}' is not 0 or 1", .{b});
        };
        if (nice) |n| if (n.len > 0) {
            s.loop_nice = std.fmt.parseInt(u5, n, 10) catch sys.fatal("ZIG_LOOP_NICE: '{s}' is not 0 to 19", .{n});
            if (s.loop_nice > 19) sys.fatal("ZIG_LOOP_NICE: '{s}' is not 0 to 19", .{n});
        };
        return s;
    }

    /// Applies the settings to the calling thread: SCHED_BATCH if set, and on a worker's event loop the nice.
    fn apply(s: Sched, event_loop: bool) void {
        if (s.batch) {
            const param: linux.sched_param = .{ .priority = 0 };
            _ = sys.check(linux.sched_setscheduler(0, .{ .mode = .BATCH }, &param)) catch sys.fatal("SCHED_BATCH", .{});
        }
        // PRIO_PROCESS with 0 is the calling thread on Linux.
        if (event_loop and s.loop_nice > 0) _ = sys.check(linux.syscall3(.setpriority, 0, 0, s.loop_nice)) catch sys.fatal("nice {d}", .{s.loop_nice});
    }
};

/// Read connections: one per core, as #47 runs 8 read lanes (#56 and #53 settled on 5/8 before the drain gap, when
/// fewer backends meant bigger drains). Each worker has one write connection.
fn sizing(cpus: usize) Sizing {
    const workers = @max(1, cpus / 2);
    const reads: u16 = @intCast(@max(1, cpus));
    const one = workers == 1;
    return .{
        .workers = workers,
        .read_conns = if (one) reads else 0,
        .write_conns = 1,
        .bcrypt_threads = @max(1, std.math.divCeil(usize, cpus, workers) catch 1),
        .drain_reads = if (one) 0 else reads,
    };
}

pub fn main(init: std.process.Init.Minimal) void {
    const env = init.environ;
    const url_text = env.getPosix("DATABASE_URL") orelse sys.fatal("DATABASE_URL is not set", .{});
    const secret = env.getPosix("JWT_SECRET") orelse sys.fatal("JWT_SECRET is not set", .{});
    const host = env.getPosix("HOST") orelse "0.0.0.0";
    const port = std.fmt.parseInt(u16, env.getPosix("PORT") orelse "3000", 10) catch sys.fatal("bad PORT", .{});
    const url = pg.parseUrl(url_text) catch sys.fatal("bad DATABASE_URL", .{});
    var bad: []const u8 = "";
    const sched = Sched.parse(env.getPosix("ZIG_SCHED_BATCH"), env.getPosix("ZIG_LOOP_NICE"));
    const fl = flags.parse(env.getPosix("CONDUIT_FLAGS") orelse "", &bad) catch |e| switch (e) {
        error.UnknownFlag => sys.fatal("CONDUIT_FLAGS: unknown flag '{s}' (flags: " ++ flags.known ++ ")", .{bad}),
        error.BadValue => sys.fatal("CONDUIT_FLAGS: '{s}' is not name=on or name=off", .{bad}),
    };
    // ZIG_MEGA_TAG_TEXT=1 and ZIG_MEGA_NAME_IDS=1 prepare MEGA with tags as text and with one name lookup per list
    // (sql.zig); both off by default.
    mega.tag_text = onOff(env, "ZIG_MEGA_TAG_TEXT");
    mega.name_ids = onOff(env, "ZIG_MEGA_NAME_IDS");
    if (mega.tag_text) sys.log("ZIG_MEGA_TAG_TEXT=1: MEGA sends each article's tags as one text", .{});
    if (mega.name_ids) sys.log("ZIG_MEGA_NAME_IDS=1: MEGA looks each list's tag name or username up once", .{});

    if (env.getPosix("ZIG_LANE_STATS")) |v| db.lane_stats = if (std.mem.eql(u8, v, "1")) true else if (v.len == 0 or std.mem.eql(u8, v, "0")) false else sys.fatal("ZIG_LANE_STATS: '{s}' is not 0 or 1", .{v});
    if (env.getPosix("ZIG_FEED3")) |v| {
        db.feed3_idle = if (v.len == 0) 0 else std.fmt.parseInt(u8, v, 10) catch 255;
        if (db.feed3_idle > 100) sys.fatal("ZIG_FEED3: '{s}' is not an idle percentage, 0 to 100", .{v});
    }
    if (env.getPosix("ZIG_READ_CAP")) |v| {
        db.read_cap = if (v.len == 0) 0 else std.fmt.parseInt(u8, v, 10) catch sys.fatal("ZIG_READ_CAP: '{s}' is not a drain count", .{v});
    }
    if (env.getPosix("ZIG_LANE_SEP")) |v| {
        const sep = if (v.len == 0) 0 else std.fmt.parseInt(u8, v, 10) catch sys.fatal("ZIG_LANE_SEP: '{s}' is not ms, 0 to 255", .{v});
        db.lane_sep_ns = @as(u64, sep) * std.time.ns_per_ms;
    }
    if (db.lane_stats or db.feed3_idle > 0 or db.read_cap > 0 or db.lane_sep_ns > 0) sys.log("lane stats {s}, third feed drain {s} (at {d}% idle), read drains in flight at most {d} (0: no cap), shared starts {d} ms from feed starts", .{
        if (db.lane_stats) "on" else "off", if (db.feed3_idle > 0) "on" else "off", db.feed3_idle,
        db.read_cap,                        db.lane_sep_ns / std.time.ns_per_ms,
    });
    // ZIG_MEGA_SORTED_IDS=1 prepares MEGA with its article id set built in id order (sql.zig); off by default.
    const sorted = env.getPosix("ZIG_MEGA_SORTED_IDS") orelse "";
    mega.sorted_ids = if (std.mem.eql(u8, sorted, "1")) true else if (sorted.len == 0 or std.mem.eql(u8, sorted, "0")) false else sys.fatal("ZIG_MEGA_SORTED_IDS: '{s}' is not 0 or 1", .{sorted});
    if (mega.sorted_ids) sys.log("ZIG_MEGA_SORTED_IDS=1: MEGA builds its article id set in id order", .{});

    loop.buf_runs = envUint(env, "ZIG_BUF_RUNS", 1) == 1;
    loop.cq_budget = @intCast(envUint(env, "ZIG_CQ_BUDGET", 1 << 20));
    loop.fixed_files = @intCast(envUint(env, "ZIG_FIXED_FILES", 2));
    loop.pg_poll_first = @intCast(envUint(env, "ZIG_PG_POLL_FIRST", 2));
    loop.ack_skip_ns = envUint(env, "ZIG_ACK_SKIP_MS", 19) * std.time.ns_per_ms;
    loop.stats_on = envUint(env, "ZIG_URING_STATS", 1) == 1;
    if (loop.buf_runs or loop.cq_budget > 0 or loop.fixed_files > 0 or loop.pg_poll_first > 0 or loop.ack_skip_ns > 0 or loop.stats_on)
        sys.log("ring knobs: buffer runs {}, completion budget {d}, fixed files {d}, postgres poll-first {d}, quickack skip under {d} ms, stats {}", .{
            loop.buf_runs, loop.cq_budget, loop.fixed_files, loop.pg_poll_first, loop.ack_skip_ns / std.time.ns_per_ms, loop.stats_on,
        });

    jwt.init(secret);
    ignoreSigpipe();
    raiseFileLimit();
    pz.detectCpu();

    // Refuse to start unless every statement prepares and describes the expected types.
    for ([_]bool{ false, true }) |write| {
        const c = db.openConn(url, write, 0) catch |e| sys.fatal("startup check failed: {s}", .{@errorName(e)});
        sys.closeFd(c.fd);
        std.heap.page_allocator.free(c.rbuf);
    }

    // The bcrypt self-test and calibration (about 3.4 CPU-seconds) run once here; the workers inherit the pick.
    bcrypt.prepare(env.getPosix("ZIG_BCRYPT_KERNEL") orelse "");

    const sz = sizing(sys.cpuCount());
    if (env.getPosix("ZIG_SEND_PACE")) |v| {
        const mbit = if (v.len == 0) 0 else std.fmt.parseInt(u32, v, 10) catch sys.fatal("ZIG_SEND_PACE: '{s}' is not Mbit/s", .{v});
        loop.pace.per_ms = @as(u64, mbit) * 125 / sz.workers;
        if (mbit > 0) sys.log("send pace {d} Mbit/s, {d} bytes per ms per worker", .{ mbit, loop.pace.per_ms });
    }
    var fbuf: [64]u8 = undefined;
    sys.log("{d} workers x ({d} read + {d} write postgres connections, {d} bcrypt threads), sha-ni {}, gzip {s}, flags {s}", .{
        sz.workers, sz.read_conns, sz.write_conns, sz.bcrypt_threads, jwt.usingShaNi(),
        if (!pz.has_pclmul) "off (no pclmulqdq)" else if (pz.has_vpclmul) "on (vpclmulqdq crc)" else "on (pclmulqdq crc)",
        flags.format(fl, &fbuf),
    });
    if (!sched.batch or sched.loop_nice > 0) sys.log("scheduling: SCHED_BATCH {s}, event loop nice {d}", .{ if (sched.batch) "on" else "off", sched.loop_nice });
    flags.dispatch(fl, serve, .{ url, host, port, sz, sched });
}

/// Forks the workers and the drain process, all running the server built for `F`, and waits for one to exit.
fn serve(comptime F: Flags, url: pg.Url, host: []const u8, port: u16, sz: Sizing, sched: Sched) void {
    var pids: [257]linux.pid_t = undefined;
    const n = @min(sz.workers, pids.len - 1);
    if (sz.drain_reads > 0) drain.setup(n);
    if (F.shed) shed.share();
    for (0..n) |i| {
        const rc = linux.fork();
        if (linux.errno(rc) != .SUCCESS) sys.fatal("fork failed", .{});
        if (rc == 0) worker(F, url, host, port, sz, sched, i);
        pids[i] = @intCast(rc);
    }
    var procs = n;
    if (sz.drain_reads > 0) {
        const rc = linux.fork();
        if (linux.errno(rc) != .SUCCESS) sys.fatal("fork failed", .{});
        if (rc == 0) drainProcess(F, url, sz, sched, n);
        pids[n] = @intCast(rc);
        procs += 1;
    }
    var status: i32 = 0;
    const dead = linux.wait4(-1, &status, 0, null);
    const what = if (procs > n and dead == pids[n]) "drain process" else "worker";
    sys.log("{s} {d} exited (status {d}); stopping", .{ what, dead, status });
    for (pids[0..procs]) |p| _ = linux.kill(p, .TERM);
    linux.exit_group(1);
}

fn worker(comptime F: Flags, url: pg.Url, host: []const u8, port: u16, sz: Sizing, sched: Sched, index: usize) noreturn {
    _ = linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), @intFromEnum(linux.SIG.TERM), 0, 0, 0);
    db.conns = openConns(url, sz.read_conns, sz.write_conns);
    if (sz.drain_reads > 0) drain.becomeWorker(index);
    bcrypt.start(F, sz.bcrypt_threads) catch sys.fatal("bcrypt threads", .{});
    sched.apply(true);
    if (F.shed and index == 0) shed.ctl.sampler = .{};
    loop.run(F, listen(host, port));
}

fn drainProcess(comptime F: Flags, url: pg.Url, sz: Sizing, sched: Sched, workers: usize) noreturn {
    _ = linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), @intFromEnum(linux.SIG.TERM), 0, 0, 0);
    db.conns = openConns(url, sz.drain_reads, 0);
    drain.becomeDrain();
    sched.apply(false);
    sys.log("drain process: {d} read postgres connections for {d} workers, rings {d} MB ask + {d} MB answer per worker", .{
        sz.drain_reads, workers, drain.ask_bytes >> 20, drain.answer_bytes >> 20,
    });
    loop.run(F, null);
}

/// `reads` read connections, then `writes` write connections.
fn openConns(url: pg.Url, reads: u16, writes: u16) []db.Conn {
    const conns = std.heap.page_allocator.alloc(db.Conn, reads + writes) catch sys.fatal("oom", .{});
    for (conns, 0..) |*c, i| {
        const write = i >= reads;
        c.* = db.openConn(url, write, @intCast(i)) catch |e| sys.fatal("postgres connect: {s}", .{@errorName(e)});
    }
    return conns;
}

fn listen(host: []const u8, port: u16) i32 {
    const Ip4 = std.Io.net.Ip4Address;
    const Ip6 = std.Io.net.Ip6Address;
    var fd: i32 = undefined;
    if (Ip4.parse(host, port)) |a| {
        fd = @intCast(sys.check(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)) catch sys.fatal("socket", .{}));
        listenerOptions(fd);
        const sa: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = @bitCast(a.bytes) };
        _ = sys.check(linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in))) catch sys.fatal("bind {s}:{d}", .{ host, port });
    } else |_| {
        const a = Ip6.parse(host, port) catch sys.fatal("bad HOST {s}", .{host});
        fd = @intCast(sys.check(linux.socket(linux.AF.INET6, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)) catch sys.fatal("socket", .{}));
        listenerOptions(fd);
        // "::" also accepts IPv4.
        sys.setsockoptInt(fd, linux.IPPROTO.IPV6, linux.IPV6.V6ONLY, 0) catch {};
        const sa: linux.sockaddr.in6 = .{ .port = std.mem.nativeToBig(u16, port), .flowinfo = 0, .addr = a.bytes, .scope_id = 0 };
        _ = sys.check(linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in6))) catch sys.fatal("bind [{s}]:{d}", .{ host, port });
    }
    _ = sys.check(linux.listen(fd, 65535)) catch sys.fatal("listen", .{});
    return fd;
}

/// Accepted sockets inherit TCP_NODELAY from the listener, so it is set once here rather than per connection.
fn listenerOptions(fd: i32) void {
    sys.setsockoptInt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, 1) catch sys.fatal("SO_REUSEADDR", .{});
    sys.setsockoptInt(fd, linux.SOL.SOCKET, linux.SO.REUSEPORT, 1) catch sys.fatal("SO_REUSEPORT", .{});
    sys.setsockoptInt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, 1) catch sys.fatal("TCP_NODELAY", .{});
}

/// An environment knob: unset, empty or `0` is off, `1` is on; anything else stops the server.
fn onOff(env: anytype, comptime name: []const u8) bool {
    const v = env.getPosix(name) orelse "";
    if (std.mem.eql(u8, v, "1")) return true;
    if (v.len == 0 or std.mem.eql(u8, v, "0")) return false;
    sys.fatal(name ++ ": '{s}' is not 0 or 1", .{v});
}

/// An unsigned knob from the environment, 0 when unset or empty; anything else above `max` stops the server.
fn envUint(env: anytype, comptime name: []const u8, max: u64) u64 {
    const v = env.getPosix(name) orelse return 0;
    if (v.len == 0) return 0;
    const n = std.fmt.parseInt(u64, v, 10) catch max + 1;
    if (n > max) sys.fatal(name ++ ": '{s}' is not a number from 0 to {d}", .{ v, max });
    return n;
}

fn ignoreSigpipe() void {
    const act: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = std.mem.zeroes(linux.sigset_t), .flags = 0 };
    _ = linux.sigaction(.PIPE, &act, null);
}

fn raiseFileLimit() void {
    var lim: linux.rlimit = undefined;
    if (linux.errno(linux.getrlimit(.NOFILE, &lim)) != .SUCCESS) return;
    lim.cur = lim.max;
    _ = linux.setrlimit(.NOFILE, &lim);
}

test "scheduling settings: parsed from the environment, applied to the calling thread only" {
    try std.testing.expectEqual(Sched{ .batch = true }, Sched.parse(null, null));
    try std.testing.expectEqual(Sched{ .batch = false }, Sched.parse("0", ""));
    try std.testing.expectEqual(Sched{ .batch = true }, Sched.parse("", ""));
    try std.testing.expectEqual(Sched{ .batch = true, .loop_nice = 2 }, Sched.parse("1", "2"));
    const T = struct {
        fn run(s: Sched, event_loop: bool, out: *[2]usize) void {
            s.apply(event_loop);
            out[0] = linux.syscall1(.sched_getscheduler, 0);
            out[1] = linux.syscall2(.getpriority, 0, 0);
        }
    };
    // Nice 19, which any thread may take whatever nice it runs at; the raw syscall returns 20 - nice.
    const s: Sched = .{ .batch = true, .loop_nice = 19 };
    const mine = linux.syscall2(.getpriority, 0, 0);
    var got: [2]usize = undefined;
    var t = try std.Thread.spawn(.{}, T.run, .{ s, true, &got });
    t.join();
    try std.testing.expectEqual(@intFromEnum(linux.SCHED.Mode.BATCH), got[0]);
    try std.testing.expectEqual(20 - 19, got[1]);
    t = try std.Thread.spawn(.{}, T.run, .{ s, false, &got });
    t.join();
    try std.testing.expectEqual(@intFromEnum(linux.SCHED.Mode.BATCH), got[0]);
    try std.testing.expectEqual(mine, got[1]);
    // This thread is untouched.
    try std.testing.expectEqual(@intFromEnum(linux.SCHED.Mode.NORMAL), linux.syscall1(.sched_getscheduler, 0));
    try std.testing.expectEqual(mine, linux.syscall2(.getpriority, 0, 0));
}

test {
    _ = @import("flags.zig");
    _ = @import("shed.zig");
    _ = @import("api.zig");
    _ = @import("http.zig");
    _ = @import("json.zig");
    _ = @import("jwt.zig");
    _ = @import("bcrypt.zig");
    _ = @import("buf.zig");
    _ = @import("pz.zig");
    _ = @import("sha256.zig");
    _ = @import("mega.zig");
    _ = @import("threads.zig");
    _ = @import("shared.zig");
    _ = @import("drain.zig");
    _ = @import("loop.zig");
    _ = @import("sql.zig");
}
