//! Conduit (RealWorld) API server: Zig, io_uring, hand-written HTTP/1.1 and PostgreSQL wire protocol.
const std = @import("std");
const linux = std.os.linux;
const server = @import("server.zig");
const pg = @import("pg.zig");
const jwt = @import("jwt.zig");
const bcpool = @import("bcpool.zig");
const sys = @import("sys.zig");
const bcrypt = @import("bcrypt.zig");

pub const std_options: std.Options = .{ .log_level = .info };

fn envInt(init: std.process.Init, name: []const u8, default: u32) u32 {
    const v = init.environ_map.get(name) orelse return default;
    return std.fmt.parseInt(u32, v, 10) catch default;
}

pub fn main(init: std.process.Init) !void {
    // A write to a connection the peer has closed must fail with EPIPE, not kill the process (the Postgres handshake
    // uses plain writes; everything else already passes MSG_NOSIGNAL).
    const ignore: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(.PIPE, &ignore, null);

    const gpa = @import("buf.zig").gpa;
    const url = init.environ_map.get("DATABASE_URL") orelse "postgres://conduit:conduit@127.0.0.1:5432/conduit";
    const secret = init.environ_map.get("JWT_SECRET") orelse return error.MissingJwtSecret;
    const host_s = init.environ_map.get("HOST") orelse "0.0.0.0";
    const port = envInt(init, "PORT", 80);

    const url_scratch = try gpa.alloc(u8, 1024);
    const db = try pg.parseUrl(url, url_scratch);

    var host: [4]u8 = undefined;
    {
        var it = std.mem.splitScalar(u8, host_s, '.');
        var i: usize = 0;
        while (it.next()) |p| : (i += 1) {
            if (i >= 4) return error.BadHost;
            host[i] = try std.fmt.parseInt(u8, p, 10);
        }
        if (i != 4) return error.BadHost;
    }

    const cpus: u32 = @intCast(std.Thread.getCpuCount() catch 4);
    // Workers are shared-nothing, so they can be threads of one process or separate processes. A process is limited to
    // LimitNOFILE open files (200,000 on the benchmark box), so by default every worker is its own process: the
    // number of connections is then bounded by memory and CPU, not by a per-process limit.
    const workers_wanted = @max(1, envInt(init, "WORKERS", @max(1, (cpus + 3) / 4)));
    const procs = @max(1, @min(envInt(init, "PROCS", workers_wanted), workers_wanted));
    const threads = (workers_wanted + procs - 1) / procs; // workers (threads) per process
    // The number actually started (WORKERS rounded up to a multiple of PROCS): connection counts are per started worker.
    const workers = procs * threads;
    // Postgres connections: about one per CPU in total. More backends than cores only add context switches and cache
    // pressure inside Postgres (measured: 36 connections cost ~25% of the throughput of 6 on 6 CPUs); depth, not
    // width, keeps each backend busy. A quarter of them (at least one per worker) are for writes.
    const total_conns = @min(envInt(init, "DB_CONNS", @max(4, cpus)), 95);
    const writes_total = envInt(init, "DB_WRITE_CONNS", @max(workers, total_conns / 4));
    var cfg = server.Config{
        .host = host,
        .port = @intCast(port),
        .db = db,
        .secret = secret,
        .threads = threads,
        .pg_read = @max(1, (total_conns -| writes_total) / workers),
        .pg_write = @max(1, writes_total / workers),
        .pg_depth = std.math.clamp(envInt(init, "PG_DEPTH", 4), 1, 32), // standalone and grouped writes share this bounded depth
        .read_depth = std.math.clamp(envInt(init, "READ_DEPTH", envInt(init, "PG_DEPTH", 4)), 1, 32),
        .packed_reads = envInt(init, "PACKED_READS", 0) != 0,
        .ack_delay = envInt(init, "ACK_DELAY", 0) != 0,
        .gzip_mode = @min(envInt(init, "GZIP", 0), 2),
        .gzip_min = @max(1024, envInt(init, "GZIP_MIN", 1024)),
        .comments_shared_pct = @min(envInt(init, "COMMENTS_SHARED_PCT", 50), 100),
        .send_zc_min = @max(1, envInt(init, "SEND_ZC_MIN", 256)),
        .write_group_max = std.math.clamp(envInt(init, "WRITE_GROUP_MAX", 32), 1, 128),
        .write_window_us = @min(envInt(init, "WRITE_WINDOW_US", 0), 10000),
        .write_arrays = envInt(init, "WRITE_ARRAYS", 0) != 0,
        .batch_max = @max(1, @min(envInt(init, "BATCH_MAX", 64), 256)),
        .read_window_us = envInt(init, "READ_WINDOW_US", 100000), // a staged read waits at most this long for company
        .read_hold_min = envInt(init, "READ_HOLD_MIN", 2048), // ... unless this many are staged already (a full plan batch)
        .plan_min = envInt(init, "PLAN_MIN", 16), // batches of at least this many reads are answered by the planner (0 = never)
        .plan_max = @max(1, @min(envInt(init, "PLAN_MAX", 2048), 2048)),
        .plan_split = envInt(init, "PLAN_SPLIT", 0) != 0,
        .adaptive_window = envInt(init, "ADAPTIVE_WINDOW", 1) != 0,
        .send_zc = envInt(init, "SEND_ZC", 1) != 0,
        .pin_cpus = envInt(init, "PIN_CPUS", 0) != 0,
        .bc_threads = @max(1, envInt(init, "BCRYPT_THREADS", @max(1, (cpus / 4 + procs - 1) / procs))),
        .bc_lanes = std.math.clamp(envInt(init, "BCRYPT_LANES", 4), 1, bcrypt.max_lanes),
        .bc_wait_ms = envInt(init, "BCRYPT_WAIT_MS", 250),
        .bc_auto = envInt(init, "BCRYPT_AUTO", 0) != 0 and init.environ_map.get("BCRYPT_LANES") == null,
        .bc_idle_ms = envInt(init, "BCRYPT_IDLE_MS", 0),
        .bc_stale_ms = std.math.clamp(envInt(init, "BCRYPT_STALE_MS", 9500), 1000, 9500),
        .stats = init.environ_map.get("STATS") != null,
        .no_pbuf = init.environ_map.get("NO_PBUF") != null,
        .test_fail_groups = init.environ_map.get("TEST_FAIL_GROUPS") != null,
        .test_fail_batches = init.environ_map.get("TEST_FAIL_BATCHES") != null,
    };
    const global_reads = envInt(init, "READ_COORDINATOR", 0) != 0;
    if (procs + @intFromBool(global_reads) > 64 or workers > 64) return error.TooManyWorkers;
    const global_read_count = @max(1, total_conns -| (cfg.pg_write * workers));
    if (global_reads) {
        cfg.hub = try @import("hub.zig").Hub.init(workers);
        cfg.pg_read = 0;
    }
    const actual_connections = (cfg.pg_read + cfg.pg_write) * workers + (if (global_reads) global_read_count else 0);
    if (actual_connections > 95) return error.TooManyDbConnections;

    if (procs > 1 or global_reads) {
        // Supervisor: fork one process per worker group (before any thread exists), then wait. If any child exits the
        // whole service stops, so a crash is visible instead of silently halving capacity.
        std.log.info("{d} processes x {d} worker(s), {d}+{d} postgres connections per worker, listening on {s}:{d}", .{ procs, threads, cfg.pg_read, cfg.pg_write, host_s, port });
        if (global_reads) std.log.info("shared read drain: {d} backends, depth {d}; {d} write backends total", .{ global_read_count, cfg.read_depth, cfg.pg_write * workers });
        var pids: [64]i32 = undefined;
        var n: usize = 0;
        const children = procs + @intFromBool(global_reads);
        while (n < children) : (n += 1) {
            const rc = linux.fork();
            if (sys.errnoOf(rc) != .SUCCESS) return error.ForkFailed;
            if (rc == 0) {
                // child: die with the supervisor
                _ = linux.prctl(1, @backingInt(linux.SIG.KILL), 0, 0, 0); // PR_SET_PDEATHSIG
                if (linux.getppid() == 1) linux.exit(1);
                if (global_reads and n == procs) {
                    var drain_cfg = cfg;
                    drain_cfg.coordinator = true;
                    drain_cfg.threads = 1;
                    drain_cfg.pg_read = global_read_count;
                    drain_cfg.pg_write = 0;
                    return runProcess(drain_cfg, secret, workers);
                }
                return runProcess(cfg, secret, n * threads);
            }
            pids[n] = @intCast(rc);
        }
        var status: i32 = 0;
        _ = linux.waitpid(-1, &status, 0);
        for (pids[0..n]) |pid| _ = linux.kill(pid, .TERM);
        std.log.err("a worker process exited (status {d}); stopping", .{status});
        std.process.exit(1);
    }
    std.log.info("{d} worker thread(s), {d}+{d} postgres connections each, listening on {s}:{d}", .{ threads, cfg.pg_read, cfg.pg_write, host_s, port });
    return runProcess(cfg, secret, 0);
}

fn runProcess(cfg: server.Config, secret: []const u8, first_id: usize) !void {
    const gpa = @import("buf.zig").gpa;
    const shared = try gpa.create(server.Shared);
    shared.* = .{
        .cfg = cfg,
        .jwt = jwt.Key.init(secret),
        .bc = .{ .lanes = cfg.bc_lanes, .wait_ns = @as(u64, cfg.bc_wait_ms) * 1_000_000 },
    };
    shared.bc.idle_ns = @as(u64, cfg.bc_idle_ms) * std.time.ns_per_ms;
    shared.bc.stale_ns = @as(u64, cfg.bc_stale_ms) * std.time.ns_per_ms;
    if (!cfg.coordinator) {
        if (cfg.bc_auto) {
            const calibration = bcrypt.calibrate();
            shared.bc.lanes = calibration.lanes;
            std.log.info("bcrypt calibration: {d} lanes, {d} us/hash (cost 10)", .{ calibration.lanes, calibration.ns_per_hash / 1000 });
        }
        try shared.bc.start(cfg.bc_threads);
    }
    var i: usize = 1;
    while (i < cfg.threads) : (i += 1) {
        const t = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, server.workerMain, .{ shared, first_id + i });
        t.detach();
    }
    server.workerMain(shared, first_id);
}
