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

/// The box: 8 vCPUs shared with Postgres, which does most of the work.
const shards_count = 2;
const bcrypt_workers = 2;
/// Per shard: Postgres connections for reads and for writes (writes wait
/// for their commit's flush, so reads never queue behind one), and the
/// requests in flight at most.
const reads_per_shard = 6;
const writes_per_shard = 2;
const slots_per_shard = 2048;
/// Per shard: the service's 200,000 descriptors, less Postgres's and a margin.
const connections_per_shard = 98 * 1024;

pub fn main(init: std.process.Init.Minimal) !void {
    const environ = init.environ;
    const database_url = environ.getPosix("DATABASE_URL") orelse return error.NoDatabaseUrl;
    const secret = environ.getPosix("JWT_SECRET") orelse return error.NoJwtSecret;
    const host = environ.getPosix("HOST") orelse "0.0.0.0";
    const port = try std.fmt.parseInt(u16, environ.getPosix("PORT") orelse "80", 10);

    raise_descriptor_limit();
    const url = try pg.parse_url(database_url);
    const gpa = std.heap.page_allocator;
    const key = try gpa.create(jwt.Key);
    key.* = .init(secret);
    const passwords = try gpa.create(password.Pool);
    passwords.* = .{};
    try passwords.start(bcrypt_workers);
    const options: shard_module.Options = .{
        .url = url,
        .reads = reads_per_shard,
        .writes = writes_per_shard,
        .slots = slots_per_shard,
        .connections_max = connections_per_shard,
        .address = try std.Io.net.IpAddress.parse(host, port),
        .key = key,
        .passwords = passwords,
    };
    for (1..shards_count) |_| {
        const thread = try std.Thread.spawn(.{}, shard_module.run, .{options});
        thread.detach();
    }
    std.debug.print("conduit on {s}:{d}: {d} shards\n", .{ host, port, shards_count });
    shard_module.run(options);
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
