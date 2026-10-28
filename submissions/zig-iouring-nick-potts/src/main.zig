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
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const pz = @import("pz.zig");
const pg = @import("pg.zig");
const db = @import("db.zig");
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
    const fl = flags.parse(env.getPosix("CONDUIT_FLAGS") orelse "", &bad) catch |e| switch (e) {
        error.UnknownFlag => sys.fatal("CONDUIT_FLAGS: unknown flag '{s}' (flags: " ++ flags.known ++ ")", .{bad}),
        error.BadValue => sys.fatal("CONDUIT_FLAGS: '{s}' is not name=on or name=off", .{bad}),
    };

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
    bcrypt.prepare();

    const sz = sizing(sys.cpuCount());
    var fbuf: [64]u8 = undefined;
    sys.log("{d} workers x ({d} read + {d} write postgres connections, {d} bcrypt threads), sha-ni {}, gzip {s}, flags {s}", .{
        sz.workers, sz.read_conns, sz.write_conns, sz.bcrypt_threads, jwt.usingShaNi(),
        if (!pz.has_pclmul) "off (no pclmulqdq)" else if (pz.has_vpclmul) "on (vpclmulqdq crc)" else "on (pclmulqdq crc)",
        flags.format(fl, &fbuf),
    });
    flags.dispatch(fl, serve, .{ url, host, port, sz });
}

/// Forks the workers and the drain process, all running the server built for `F`, and waits for one to exit.
fn serve(comptime F: Flags, url: pg.Url, host: []const u8, port: u16, sz: Sizing) void {
    var pids: [257]linux.pid_t = undefined;
    const n = @min(sz.workers, pids.len - 1);
    if (sz.drain_reads > 0) drain.setup(n);
    if (F.shed) shed.share();
    for (0..n) |i| {
        const rc = linux.fork();
        if (linux.errno(rc) != .SUCCESS) sys.fatal("fork failed", .{});
        if (rc == 0) worker(F, url, host, port, sz, i);
        pids[i] = @intCast(rc);
    }
    var procs = n;
    if (sz.drain_reads > 0) {
        const rc = linux.fork();
        if (linux.errno(rc) != .SUCCESS) sys.fatal("fork failed", .{});
        if (rc == 0) drainProcess(F, url, sz, n);
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

fn worker(comptime F: Flags, url: pg.Url, host: []const u8, port: u16, sz: Sizing, index: usize) noreturn {
    _ = linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), @intFromEnum(linux.SIG.TERM), 0, 0, 0);
    db.conns = openConns(url, sz.read_conns, sz.write_conns);
    if (sz.drain_reads > 0) drain.becomeWorker(index);
    bcrypt.start(F, sz.bcrypt_threads) catch sys.fatal("bcrypt threads", .{});
    if (F.shed and index == 0) shed.ctl.sampler = .{};
    loop.run(F, listen(host, port));
}

fn drainProcess(comptime F: Flags, url: pg.Url, sz: Sizing, workers: usize) noreturn {
    _ = linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), @intFromEnum(linux.SIG.TERM), 0, 0, 0);
    db.conns = openConns(url, sz.drain_reads, 0);
    drain.becomeDrain();
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
}
