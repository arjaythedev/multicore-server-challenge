//! Reads in batches: a statement's own cost in Postgres (Bind, executor
//! start and end, the transaction) is most of a cheap read's, so reads of
//! one kind waiting together go out as one statement, each request a row
//! of `unnest`ed parameters and its rows tagged with its index (sql.zig's
//! batched statements). Each request is still its own execution of its
//! query, in the statement's snapshot, while it is served; nothing outlives
//! the statement.
//!
//! Writes in groups (`Writes`): the requests waiting for a write
//! connection go out together under one Sync, one implicit transaction,
//! so one commit and one flush of the WAL serve them all, and each
//! response waits for that commit. If any fails, the transaction is
//! rolled back whole, and each request is sent again alone, to get its own
//! answer.
//!
//! No timer: a read waits in its kind's queue only while every read
//! connection has a batch in flight. A connection that finishes its batch
//! sends the kind whose oldest read has waited longest, all of it (up to
//! `pg.batch_max`). At low load every batch is one read and nothing waits; under load
//! batches grow by themselves.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Evented = @import("zig_io_evented");
const pg = @import("pg.zig");
const sql = @import("sql.zig");

pub const Kind = enum(u8) {
    article,
    comments,
    profile,
    user,
    login,
    tags,
    list_all,
    list_tag,
    list_author,
    list_favorited,
    feed,
};

const kinds_count = @typeInfo(Kind).@"enum".field_names.len;

/// A request waiting for its write group, on its fiber's stack.
pub const Write = struct {
    waiter: pg.Waiter,
    /// Its statements, encoded (`pg.Encoded`).
    encoded: []const u8,
    statements: u8,
    /// Sent again alone, after a group it was in failed.
    alone: bool = false,
    /// It went out with others: a failure may have been theirs.
    grouped: bool = false,
    next: ?*Write = null,
};

/// Bytes a write group carries at most: well within a connection's output.
const write_group_bytes_max = 256 * 1024;

pub const Writes = struct {
    io: Io,
    connections: []pg.Connection,
    head: ?*Write = null,
    tail: ?*Write = null,

    /// In place: each connection calls back here when it is idle.
    pub fn init(writes: *Writes, io: Io, connections: []pg.Connection) void {
        writes.* = .{ .io = io, .connections = connections };
        for (connections) |*connection| connection.idle = .{ .context = writes, .function = on_idle };
    }

    /// Queue the request, send what can go, wait for its commit; if its
    /// group failed, once more alone.
    pub fn write(writes: *Writes, pending: *Write) pg.Results {
        writes.wait(pending);
        const failed = pending.waiter.failure orelse return .{ .waiter = &pending.waiter };
        if (failed != .sql or !pending.grouped) return .{ .waiter = &pending.waiter };
        pending.waiter = .{ .rows = pending.waiter.rows };
        pending.alone = true;
        pending.grouped = false;
        writes.wait(pending);
        return .{ .waiter = &pending.waiter };
    }

    fn wait(writes: *Writes, pending: *Write) void {
        pending.next = null;
        if (writes.tail) |tail| tail.next = pending else writes.head = pending;
        writes.tail = pending;
        writes.dispatch();
        if (!pending.waiter.done) Evented.park(writes.io, &pending.waiter.parked);
        assert(pending.waiter.done);
    }

    fn on_idle(context: *anyopaque, connection: *pg.Connection) void {
        const writes: *Writes = @ptrCast(@alignCast(context));
        _ = connection;
        writes.dispatch();
    }

    fn dispatch(writes: *Writes) void {
        // Bounded: each pass fills a connection, or ends.
        for (0..writes.connections.len + 1) |_| {
            if (writes.head == null) return;
            const connection = for (writes.connections) |*connection| {
                if (!connection.broken and connection.load() == 0) break connection;
            } else {
                for (writes.connections) |*connection| if (!connection.broken) return;
                writes.fail_all();
                return;
            };
            writes.send(connection);
        } else unreachable;
    }

    fn fail_all(writes: *Writes) void {
        while (writes.head) |pending| {
            writes.head = pending.next;
            pending.waiter.failure = .broken;
            pending.waiter.done = true;
            _ = Evented.unpark(writes.io, &pending.waiter.parked);
        }
        writes.tail = null;
    }

    /// The queue's head, and those after it while they fit: one group. A
    /// request sent again alone goes alone.
    fn send(writes: *Writes, connection: *pg.Connection) void {
        const batch = &connection.batch;
        batch.* = .{};
        var parts: [pg.batch_max][]const u8 = undefined;
        var bytes: usize = 0;
        // Bounded: a group is `batch_max` requests at most.
        for (0..pg.batch_max) |position| {
            const pending = writes.head orelse break;
            if (position > 0 and (pending.alone or bytes + pending.encoded.len > write_group_bytes_max)) break;
            writes.head = pending.next;
            parts[position] = pending.encoded;
            bytes += pending.encoded.len;
            batch.waiters[position] = &pending.waiter;
            batch.statements[position] = pending.statements;
            batch.count += 1;
            if (pending.alone) break;
        }
        if (writes.head == null) writes.tail = null;
        for (batch.waiters[0..batch.count]) |waiter| {
            const pending: *Write = @alignCast(@fieldParentPtr("waiter", waiter));
            pending.grouped = batch.count > 1;
        }
        _ = connection.send_parts(batch, &.{}, parts[0..batch.count]);
    }
};

/// A read waiting for its batch, on its fiber's stack.
pub const Pending = struct {
    waiter: pg.Waiter,
    viewer: i64 = 0,
    key: []const u8 = "",
    limit: i64 = 0,
    offset: i64 = 0,
    sequence: u64 = 0,
    next: ?*Pending = null,
};

const Queue = struct {
    head: ?*Pending = null,
    tail: ?*Pending = null,
    count: u32 = 0,
};

pub const Reads = struct {
    io: Io,
    connections: []pg.Connection,
    queues: [kinds_count]Queue = @splat(.{}),
    sequence: u64 = 0,

    /// In place: each connection calls back here when it is idle.
    pub fn init(reads: *Reads, io: Io, connections: []pg.Connection) void {
        reads.* = .{ .io = io, .connections = connections };
        for (connections) |*connection| connection.idle = .{ .context = reads, .function = on_idle };
    }

    /// Queue the read, send what can go, and wait for its answers. What
    /// Postgres would refuse fails here, alone, with Postgres's own code:
    /// in a batch its error would fail every request of the statement.
    pub fn read(reads: *Reads, kind: Kind, pending: *Pending) pg.Results {
        if (refused(pending)) |code| {
            pending.waiter.failure = .{ .sql = code };
            pending.waiter.done = true;
            return .{ .waiter = &pending.waiter };
        }
        pending.sequence = reads.sequence;
        reads.sequence += 1;
        pending.next = null;
        const queue = &reads.queues[@backingInt(kind)];
        if (queue.tail) |tail| tail.next = pending else queue.head = pending;
        queue.tail = pending;
        queue.count += 1;
        reads.dispatch();
        if (!pending.waiter.done) Evented.park(reads.io, &pending.waiter.parked);
        assert(pending.waiter.done);
        return .{ .waiter = &pending.waiter };
    }

    /// A key that is not text to Postgres (not UTF-8, or a NUL in it:
    /// 22021), or a page past what int8 holds (the feed adds the limit
    /// to the offset: 22003).
    fn refused(pending: *const Pending) ?[5]u8 {
        if (!std.unicode.utf8ValidateSlice(pending.key)) return "22021".*;
        if (std.mem.indexOfScalar(u8, pending.key, 0) != null) return "22021".*;
        _ = std.math.add(i64, pending.limit, pending.offset) catch return "22003".*;
        return null;
    }

    fn on_idle(context: *anyopaque, connection: *pg.Connection) void {
        const reads: *Reads = @ptrCast(@alignCast(context));
        _ = connection;
        reads.dispatch();
    }

    /// A batch onto every idle connection while reads wait.
    fn dispatch(reads: *Reads) void {
        // Bounded: each pass fills a connection, or ends.
        for (0..reads.connections.len + 1) |_| {
            const kind = reads.oldest() orelse return;
            const connection = reads.idle_connection(kind) orelse {
                if (reads.all_broken()) reads.fail_all();
                return;
            };
            connection.last_kind = @backingInt(kind);
            reads.send(connection, kind);
        } else unreachable;
    }

    fn oldest(reads: *const Reads) ?Kind {
        var best: ?Kind = null;
        var best_sequence: u64 = std.math.maxInt(u64);
        for (&reads.queues, 0..) |*queue, index| {
            const head = queue.head orelse continue;
            if (head.sequence < best_sequence) {
                best_sequence = head.sequence;
                best = @fromBackingInt(@intCast(index));
            }
        }
        return best;
    }

    /// An idle connection, one that last ran the kind if any is: a backend
    /// running one kind keeps its plan and the kind's index pages warm in
    /// its core's caches (p50 -5%, p99 -10% at 50k users on 4 CPUs).
    fn idle_connection(reads: *Reads, kind: Kind) ?*pg.Connection {
        var any: ?*pg.Connection = null;
        for (reads.connections) |*connection| {
            if (connection.broken or connection.load() != 0) continue;
            if (connection.last_kind == @backingInt(kind)) return connection;
            if (any == null) any = connection;
        }
        return any;
    }

    fn all_broken(reads: *const Reads) bool {
        for (reads.connections) |*connection| if (!connection.broken) return false;
        return true;
    }

    /// No connection left: every queued read fails at once.
    fn fail_all(reads: *Reads) void {
        for (&reads.queues) |*queue| {
            while (queue.head) |pending| {
                queue.head = pending.next;
                pending.waiter.failure = .broken;
                pending.waiter.done = true;
                _ = Evented.unpark(reads.io, &pending.waiter.parked);
            }
            queue.* = .{};
        }
    }

    /// Up to `batch_max` of a kind's reads, oldest first, as one group.
    fn send(reads: *Reads, connection: *pg.Connection, kind: Kind) void {
        const queue = &reads.queues[@backingInt(kind)];
        assert(queue.count > 0);
        var index: [pg.batch_max]i32 = undefined;
        var viewer: [pg.batch_max]i64 = undefined;
        var limit: [pg.batch_max]i64 = undefined;
        var offset: [pg.batch_max]i64 = undefined;
        var key: [pg.batch_max][]const u8 = undefined;
        const batch = &connection.batch;
        batch.* = .{ .tagged = true };
        // Bounded: a batch is `batch_max` reads at most.
        for (0..pg.batch_max) |position| {
            const pending = queue.head orelse break;
            queue.head = pending.next;
            queue.count -= 1;
            index[position] = @intCast(position);
            viewer[position] = pending.viewer;
            limit[position] = pending.limit;
            offset[position] = pending.offset;
            key[position] = pending.key;
            batch.waiters[position] = &pending.waiter;
            batch.count += 1;
        }
        if (queue.head == null) queue.tail = null;
        const n = batch.count;
        const i: pg.Param = .{ .int4_array = index[0..n] };
        const v: pg.Param = .{ .int8_array = viewer[0..n] };
        const k: pg.Param = .{ .text_array = key[0..n] };
        const l: pg.Param = .{ .int8_array = limit[0..n] };
        const o: pg.Param = .{ .int8_array = offset[0..n] };
        const S = sql.S;
        const call = struct {
            fn of(statement: S, params: []const pg.Param) pg.Call {
                return .{ .statement = @backingInt(statement), .params = params };
            }
        }.of;
        _ = switch (kind) {
            .article => connection.send(batch, &.{call(.batch_article, &.{ i, v, k })}),
            .comments => connection.send(batch, &.{call(.batch_comments, &.{ i, v, k })}),
            .profile => connection.send(batch, &.{call(.batch_profile, &.{ i, v, k })}),
            .user => connection.send(batch, &.{call(.batch_user, &.{ i, v })}),
            .login => connection.send(batch, &.{call(.batch_login, &.{ i, v, k })}),
            .tags => connection.send(batch, &.{call(.batch_tags, &.{})}),
            .list_all => connection.send(batch, &.{
                call(.batch_list_all, &.{ i, v, l, o, k }),
                call(.batch_count_all, &.{ i, v, k }),
            }),
            .list_tag => connection.send(batch, &.{
                call(.batch_list_tag, &.{ i, v, l, o, k }),
                call(.batch_count_tag, &.{ i, v, k }),
            }),
            .list_author => connection.send(batch, &.{
                call(.batch_list_author, &.{ i, v, l, o, k }),
                call(.batch_count_author, &.{ i, v, k }),
            }),
            .list_favorited => connection.send(batch, &.{
                call(.batch_list_favorited, &.{ i, v, l, o, k }),
                call(.batch_count_favorited, &.{ i, v, k }),
            }),
            .feed => connection.send(batch, &.{
                call(.batch_list_feed, &.{ i, v, l, o, k }),
                call(.batch_count_feed, &.{ i, v, k }),
            }),
        };
    }
};
