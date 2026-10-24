//! A shard: one thread, its io_uring, its share of the connections (the
//! kernel spreads them, SO_REUSEPORT), its own Postgres connections, and
//! result slots that bound its requests in flight. Shared with the other
//! shards: the JWT key and the bcrypt workers, read-only and locked.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const Io = std.Io;
const fourneau = @import("fourneau");
const Evented = @import("zig_io_evented");
const pg = @import("pg.zig");
const sql = @import("sql.zig");
const api = @import("api.zig");
const jwt = @import("jwt.zig");
const password = @import("password.zig");
const batch = @import("batch.zig");

pub const Server = fourneau.server.ServerType(App, .{
    .send_then_receive = Evented.sendThenReceive,
});

/// What fourneau's server calls, per request, on the connection's fiber.
pub const App = struct {
    shard: *Shard,

    pub const Response = api.Response;

    pub fn handle(app: *App, request: *Server.Request) Response {
        var context: api.Context = .{ .shard = app.shard, .head = request.head, .request = request };
        return api.route(&context);
    }

    pub fn release(app: *App, response: *Response) void {
        if (response.slot) |slot| app.shard.slots.release(app.shard.io, slot);
        response.* = undefined;
    }
};

/// Fixed buffers for requests in flight, each its group's rows and then
/// its response: taken before a group is sent, given back once the
/// response is sent. A request finding none waits its turn, so a shard
/// never holds more in flight than it has slots.
pub const Slots = struct {
    memory: []u8,
    slot_bytes: u32,
    rows_bytes: u32,
    free: []u32,
    free_count: u32,
    /// Requests waiting for a slot, oldest first.
    waiting: []*Waiting,
    waiting_head: u32 = 0,
    waiting_count: u32 = 0,

    const Waiting = struct { parked: Evented.Parked = .{}, slot: u32 = undefined };

    /// `waiting_max`: every connection of the shard may wait for a slot.
    pub fn init(gpa: std.mem.Allocator, count: u32, slot_bytes: u32, rows_bytes: u32, waiting_max: u32) !Slots {
        assert(rows_bytes < slot_bytes);
        const free = try gpa.alloc(u32, count);
        // Lowest first: the slots in use stay few and warm.
        for (free, 0..) |*index, position| index.* = @intCast(count - 1 - position);
        return .{
            .memory = try pg.alloc_untouched(gpa, @as(usize, count) * slot_bytes),
            .slot_bytes = slot_bytes,
            .rows_bytes = rows_bytes,
            .free = free,
            .free_count = count,
            .waiting = try gpa.alloc(*Waiting, waiting_max),
        };
    }

    pub fn acquire(slots: *Slots, io: Io) u32 {
        if (slots.free_count > 0) {
            slots.free_count -= 1;
            return slots.free[slots.free_count];
        }
        assert(slots.waiting_count < slots.waiting.len);
        var waiting: Waiting = .{};
        const tail = (slots.waiting_head + slots.waiting_count) % slots.waiting.len;
        slots.waiting[tail] = &waiting;
        slots.waiting_count += 1;
        Evented.park(io, &waiting.parked);
        return waiting.slot;
    }

    pub fn release(slots: *Slots, io: Io, slot: u32) void {
        if (slots.waiting_count > 0) {
            const waiting = slots.waiting[slots.waiting_head];
            slots.waiting_head = @intCast((slots.waiting_head + 1) % slots.waiting.len);
            slots.waiting_count -= 1;
            waiting.slot = slot;
            assert(Evented.unpark(io, &waiting.parked));
            return;
        }
        assert(slots.free_count < slots.free.len);
        slots.free[slots.free_count] = slot;
        slots.free_count += 1;
    }

    pub fn rows(slots: *Slots, slot: u32) []u8 {
        const start = @as(usize, slot) * slots.slot_bytes;
        return slots.memory[start..][0..slots.rows_bytes];
    }

    pub fn output(slots: *Slots, slot: u32) []u8 {
        const start = @as(usize, slot) * slots.slot_bytes + slots.rows_bytes;
        return slots.memory[start..][0 .. slots.slot_bytes - slots.rows_bytes];
    }
};

pub const Options = struct {
    url: pg.Url,
    reads: u32,
    writes: u32,
    slots: u32,
    connections_max: u32,
    address: Io.net.IpAddress,
    key: *const jwt.Key,
    passwords: *password.Pool,
};

pub const Shard = struct {
    io: Io,
    key: *const jwt.Key,
    passwords: *password.Pool,
    /// The batched reads (batch.zig) and the connections they go out on.
    reads: batch.Reads = undefined,
    read_connections: []pg.Connection,
    /// Everything else, in groups of one commit (batch.zig): writes (each
    /// waits for its commit's flush, so reads never queue behind one) and
    /// the rare reads not batched.
    writes: batch.Writes = undefined,
    write_connections: []pg.Connection,
    slots: Slots,
    jwt_memory: []u8,
};

pub fn run(options: Options) void {
    run_or_fail(options) catch |err| std.debug.panic("shard: {t}", .{err});
}

fn run_or_fail(options: Options) !noreturn {
    const gpa = std.heap.page_allocator;
    const config: fourneau.server.Config = .{
        .connections_max = options.connections_max,
        .head_bytes_max = 8 * 1024,
        .target_bytes_max = 2 * 1024,
        .headers_max = 32,
        .body_bytes_max = 64 * 1024,
        .response_head_bytes_max = 1024,
        .send_bytes_max = 32 * 1024,
        .scratch_bytes_max = 64 * 1024,
        // Behind no proxy: a user's next page is seconds away, and every
        // idle connection held is a reconnect saved.
        .idle_timeout_ms = 600_000,
    };
    const database_connections = options.reads + options.writes;
    var runtime: Evented = undefined;
    try fourneau.listen.runtime_init(Evented, &runtime, gpa, .{
        .thread_limit = 0,
        .log2_ring_entries = 12,
        .fibers_max = config.fibers_max() + database_connections,
    });
    const io = runtime.io();
    var shard: Shard = .{
        .io = io,
        .key = options.key,
        .passwords = options.passwords,
        .read_connections = try gpa.alloc(pg.Connection, options.reads),
        .write_connections = try gpa.alloc(pg.Connection, options.writes),
        .slots = try .init(gpa, options.slots, 256 * 1024, 128 * 1024, options.connections_max),
        .jwt_memory = try gpa.alloc(u8, jwt.memory_bytes),
    };
    const statements = &sql.statements.values;
    var group: Io.Group = .init;
    for ([_][]pg.Connection{ shard.read_connections, shard.write_connections }) |connections| {
        for (connections) |*connection| {
            const fd = try pg.connect_at_start(options.url, statements);
            connection.* = try .init(gpa, io, fd, options.url, statements);
        }
    }
    shard.reads.init(io, shard.read_connections);
    shard.writes.init(io, shard.write_connections);
    for ([_][]pg.Connection{ shard.read_connections, shard.write_connections }) |connections| {
        for (connections) |*connection| try group.concurrent(io, pg.Connection.read_loop, .{connection});
    }
    const listener = try options.address.listen(io, .{ .reuse_address = true, .kernel_backlog = 65535 });
    var app: App = .{ .shard = &shard };
    var server = try Server.init(gpa, io, &app, listener, config);
    try server.run();
}
