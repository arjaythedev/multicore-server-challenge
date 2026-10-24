//! The multicore server challenge's Conduit API on fourneau: shards (a
//! thread, an io_uring and a fiber per connection each, sharing nothing),
//! each with its own pipelined Postgres connections, and bcrypt on worker
//! threads of its own.
//!
//! Configured by DATABASE_URL, JWT_SECRET, HOST and PORT only.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const pg = @import("pg.zig");
const jwt = @import("jwt.zig");
const password = @import("password.zig");
const shard_module = @import("shard.zig");

/// The box: 8 vCPUs shared with Postgres, which does most of the work. The
/// defaults are the box's; `CONDUIT_*` overrides them for measuring only
/// (start.sh sets none).
const Tuning = struct {
    shards: u32 = 2,
    /// With Postgres saturating the CPUs, two had too small a share: logins
    /// queued past their 10 s (91% of them, 55k users on 4 CPUs).
    bcrypt_workers: u32 = 4,
    /// Per shard: Postgres connections for reads and for writes (writes
    /// wait for their commit's flush, so reads never queue behind one).
    /// 6 and 9 measured alike on 4 CPUs (13,904 and 13,947 req/s at
    /// saturation), 3 too few; the box runs Postgres on twice the CPUs.
    reads: u32 = 8,
    writes: u32 = 2,

    fn from(environ: std.process.Environ) !Tuning {
        var tuning: Tuning = .{};
        inline for (.{ "shards", "bcrypt_workers", "reads", "writes" }) |name| {
            var key: [64]u8 = undefined;
            const upper = std.ascii.upperString(&key, "CONDUIT_" ++ name);
            if (environ.getPosix(upper)) |text| @field(tuning, name) = try std.fmt.parseInt(u32, text, 10);
        }
        if (tuning.shards == 0 or tuning.reads == 0 or tuning.writes == 0) return error.Tuning;
        // Postgres's 100 connections, 95 ours at most.
        if (tuning.shards * (tuning.reads + tuning.writes) > 95) return error.TooManyConnections;
        return tuning;
    }
};
/// Per shard: requests in flight at most.
const slots_per_shard = 2048;
/// All shards: the service's 200,000 descriptors, less Postgres's and a margin.
const connections_max = 196 * 1024;

pub fn main(init: std.process.Init.Minimal) !void {
    const environ = init.environ;
    const database_url = environ.getPosix("DATABASE_URL") orelse return error.NoDatabaseUrl;
    const secret = environ.getPosix("JWT_SECRET") orelse return error.NoJwtSecret;
    const host = environ.getPosix("HOST") orelse "0.0.0.0";
    const port = try std.fmt.parseInt(u16, environ.getPosix("PORT") orelse "80", 10);

    raise_descriptor_limit();
    // No transparent huge pages in this process: a connection touches a few
    // pages of each slab, and a 2 MiB page per touch would hold tens of KiB
    // per idle connection where THP is `always` (Ubuntu's `madvise` gives
    // none anyway).
    const thp = linux.prctl(@intFromEnum(linux.PR.SET_THP_DISABLE), 1, 0, 0, 0);
    if (linux.errno(thp) != .SUCCESS) return error.ThpDisable;
    const url = try pg.parse_url(database_url);
    const gpa = std.heap.page_allocator;
    const key = try gpa.create(jwt.Key);
    key.* = .init(secret);
    const tuning: Tuning = try .from(environ);
    const passwords = try gpa.create(password.Pool);
    passwords.* = .{};
    try passwords.start(tuning.bcrypt_workers);
    const options: shard_module.Options = .{
        .url = url,
        .reads = tuning.reads,
        .writes = tuning.writes,
        .slots = slots_per_shard,
        .connections_max = connections_fitting() / tuning.shards,
        .address = try std.Io.net.IpAddress.parse(host, port),
        .key = key,
        .passwords = passwords,
    };
    for (1..tuning.shards) |_| {
        const thread = try std.Thread.spawn(.{}, shard_module.run, .{options});
        thread.detach();
    }
    std.debug.print("conduit on {s}:{d}: {d} shards of {d} reads and {d} writes, {d} bcrypt workers\n", .{
        host, port, tuning.shards, tuning.reads, tuning.writes, tuning.bcrypt_workers,
    });
    shard_module.run(options);
}

/// The connection slots the kernel's map limit leaves room for: a fiber's
/// stack sits over a guard page, two maps a fiber (`vm.max_map_count` is
/// 65,530 on a kernel left at its default: 32k fibers, where a failed map
/// would be a crash). Past the slots, the longest idle are closed.
fn connections_fitting() u32 {
    const maps_reserved = 8192; // the rest of the process: slabs, rings, libc
    var buffer: [32]u8 = undefined;
    const fd = linux.open("/proc/sys/vm/max_map_count", .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(fd) != .SUCCESS) return connections_max;
    defer _ = linux.close(@intCast(fd));
    const got = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(got) != .SUCCESS) return connections_max;
    const text = std.mem.trim(u8, buffer[0..got], " \n");
    const maps = std.fmt.parseInt(u64, text, 10) catch return connections_max;
    if (maps <= maps_reserved) return 1024;
    const fibers = (maps - maps_reserved) / 2;
    return @intCast(@min(connections_max, fibers));
}

/// The soft limit up to the hard one: a connection is a descriptor.
fn raise_descriptor_limit() void {
    var limit: linux.rlimit = undefined;
    if (linux.errno(linux.getrlimit(.NOFILE, &limit)) != .SUCCESS) return;
    limit.cur = limit.max;
    _ = linux.setrlimit(.NOFILE, &limit);
}

test {
    _ = @import("api.zig");
    _ = @import("json.zig");
    _ = @import("jwt.zig");
    _ = @import("password.zig");
    _ = @import("pg.zig");
    _ = @import("scram.zig");
    _ = @import("time.zig");
    _ = @import("url.zig");
}
