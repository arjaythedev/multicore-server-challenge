//! Reads in batches: a statement's own cost in Postgres (Bind, executor
//! start and end, the transaction) is most of a cheap read's, so reads of
//! one kind waiting together go out as one statement, each request a row
//! of `unnest`ed parameters and its rows tagged with its index (sql.zig's
//! batched statements). Each request is still its own execution of its
//! query, in the statement's snapshot, while it is served; nothing outlives
//! the statement.
//!
//! No timer: a read waits in its kind's queue only while every read
//! connection has a batch in flight. A connection that finishes its batch
//! sends the kind whose oldest read has waited longest, all of it (32 at
//! most). At low load every batch is one read and nothing waits; under load
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
    tags,
    list_all,
    list_tag,
    list_author,
    list_favorited,
    feed,
};

const kinds_count = @typeInfo(Kind).@"enum".field_names.len;

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

    /// Queue the read, send what can go, and wait for its answers.
    pub fn read(reads: *Reads, kind: Kind, pending: *Pending) pg.Results {
        pending.sequence = reads.sequence;
        reads.sequence += 1;
        pending.next = null;
        const queue = &reads.queues[@intFromEnum(kind)];
        if (queue.tail) |tail| tail.next = pending else queue.head = pending;
        queue.tail = pending;
        queue.count += 1;
        reads.dispatch();
        if (!pending.waiter.done) Evented.park(reads.io, &pending.waiter.parked);
        assert(pending.waiter.done);
        return .{ .waiter = &pending.waiter };
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
            const connection = reads.idle_connection() orelse {
                if (reads.all_broken()) reads.fail_all();
                return;
            };
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
                best = @enumFromInt(index);
            }
        }
        return best;
    }

    fn idle_connection(reads: *Reads) ?*pg.Connection {
        for (reads.connections) |*connection| {
            if (!connection.broken and connection.load() == 0) return connection;
        }
        return null;
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
        const queue = &reads.queues[@intFromEnum(kind)];
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
                return .{ .statement = @intFromEnum(statement), .params = params };
            }
        }.of;
        _ = switch (kind) {
            .article => connection.send(batch, &.{call(.batch_article, &.{ i, v, k })}),
            .comments => connection.send(batch, &.{
                call(.batch_article_exists, &.{ i, k }),
                call(.batch_comments, &.{ i, v, k }),
            }),
            .profile => connection.send(batch, &.{call(.batch_profile, &.{ i, v, k })}),
            .user => connection.send(batch, &.{call(.batch_user, &.{ i, v })}),
            .tags => connection.send(batch, &.{call(.batch_tags, &.{i})}),
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
