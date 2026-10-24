//! A PostgreSQL client for one shard: the wire protocol (version 3), its
//! statements prepared once per connection, every parameter and result in
//! binary, and requests pipelined.
//!
//! A request writes its whole group of messages (a Bind and an Execute per
//! statement, then one Sync: one implicit transaction) into the
//! connection's output between two waits, so groups never interleave; it
//! queues itself and parks. The connection's reader fiber reads the
//! answers in order, copies each group's rows into its request's buffer,
//! and unparks the request at the group's ReadyForQuery. No lock, no
//! futex: a shard is one thread (fourneau's server), and so is everything
//! here. Startup (connect, authenticate, prepare) blocks: it runs before
//! the shard serves, and again only for a connection that broke.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const Io = std.Io;
const Evented = @import("zig_io_evented");
const scram = @import("scram.zig");

const log = std.log.scoped(.pg);

pub const Oid = enum(u32) {
    bool = 16,
    int8 = 20,
    int4 = 23,
    text = 25,
    int4_array = 1007,
    text_array = 1009,
    int8_array = 1016,
    timestamptz = 1184,
};

pub const Statement = struct {
    sql: []const u8,
    params: []const Oid,
};

pub const Param = union(enum) {
    null,
    int8: i64,
    int4: i32,
    text: []const u8,
    text_array: []const []const u8,
    int4_array: []const i32,
    int8_array: []const i64,
};

/// Requests a batch holds at most. Past ~10 a statement's own cost is all
/// but gone (52.7 us of Postgres per request at 32, 53.4 at 10, 161 one
/// at a time; the article by slug), but a request past a full batch waits
/// a whole statement more. A box shard's load on an aged database filled
/// 32 at 52k users (the article 31.8 a batch): 64 took p95 from 160 ms to
/// 90. At 56k every batch of 64 was full: 128 (119.6) took p95 from 215
/// to 195, 14.39k req/s to 14.55k, Postgres from 185 us a request to 180.
pub const batch_max = 128;

/// A group's requests: one; or a batch of reads, whose rows each name
/// their request by their first column (an int4, its index into
/// `waiters`), taken off as the row is kept (`tagged`); or a sequence of
/// requests' statements, `statements[w]` of them for waiter `w`, in order,
/// all in the group's one transaction (writes: one commit for all).
pub const Batch = struct {
    waiters: [batch_max]*Waiter = undefined,
    count: u8 = 0,
    tagged: bool = false,
    statements: [batch_max]u8 = undefined,
    /// The waiter whose statements are being answered (a sequence).
    cursor: u8 = 0,
};

/// Called when a connection has nothing in flight: the shard's batches go
/// out on it.
pub const Idle = struct {
    context: *anyopaque,
    function: *const fn (context: *anyopaque, connection: *Connection) void,
};

/// One statement of a group, and its parameters.
pub const Call = struct {
    statement: u16,
    params: []const Param,
};

/// Statements a request's group holds at most.
pub const group_statements_max = 8;
/// Requests a connection holds in flight at most.
const queue_max = 1024;
/// Each of a connection's two output buffers.
const output_bytes = 1 << 20;
const input_bytes = 1 << 20;

pub const Failure = union(enum) {
    /// The server's error: its SQLSTATE (23505 is a unique violation).
    sql: [5]u8,
    /// The connection is gone, or answered what this client cannot read.
    broken,
    /// The group's rows did not fit the request's buffer, or its messages
    /// the connection's output.
    overflow,

    pub fn unique_violation(failure: Failure) bool {
        return failure == .sql and std.mem.eql(u8, &failure.sql, "23505");
    }
};

/// A request waiting for its group's answers, on its fiber's stack.
pub const Waiter = struct {
    parked: Evented.Parked = .{},
    done: bool = false,
    /// Each row as its length (u32, native) and the DataRow's body.
    rows: []u8,
    rows_used: u32 = 0,
    /// Where each statement's rows end in `rows`: one per CommandComplete.
    ends: [group_statements_max]u32 = undefined,
    statements: u8 = 0,
    failure: ?Failure = null,
};

/// The answers to a group: each statement's rows, in order.
pub const Results = struct {
    waiter: *const Waiter,

    pub fn rows(results: Results, statement: u8) Rows {
        const waiter = results.waiter;
        assert(statement < waiter.statements);
        const start = if (statement == 0) 0 else waiter.ends[statement - 1];
        return .{ .bytes = waiter.rows[start..waiter.ends[statement]] };
    }
};

pub const Rows = struct {
    bytes: []const u8,
    at: usize = 0,

    pub fn next(rows: *Rows) ?Row {
        if (rows.at == rows.bytes.len) return null;
        const length = std.mem.readInt(u32, rows.bytes[rows.at..][0..4], .native);
        const body = rows.bytes[rows.at + 4 ..][0..length];
        rows.at += 4 + length;
        return Row.parse(body);
    }

    pub fn first(rows: Rows) ?Row {
        var copy = rows;
        return copy.next();
    }
};

pub const columns_max = 16;

/// A row's columns in binary: null is null.
pub const Row = struct {
    columns: [columns_max]?[]const u8 = undefined,
    count: u16,

    fn parse(body: []const u8) Row {
        var row: Row = .{ .count = std.mem.readInt(u16, body[0..2], .big) };
        assert(row.count <= columns_max);
        var at: usize = 2;
        for (row.columns[0..row.count]) |*column| {
            const length = std.mem.readInt(i32, body[at..][0..4], .big);
            at += 4;
            if (length < 0) {
                column.* = null;
                continue;
            }
            column.* = body[at..][0..@intCast(length)];
            at += @intCast(length);
        }
        assert(at == body.len);
        return row;
    }

    pub fn text(row: Row, index: usize) []const u8 {
        return row.columns[index].?;
    }

    pub fn text_or_null(row: Row, index: usize) ?[]const u8 {
        return row.columns[index];
    }

    pub fn int8(row: Row, index: usize) i64 {
        return std.mem.readInt(i64, row.columns[index].?[0..8], .big);
    }

    pub fn boolean(row: Row, index: usize) bool {
        return row.columns[index].?[0] != 0;
    }

    /// Microseconds since 2000-01-01T00:00:00Z.
    pub fn timestamp(row: Row, index: usize) i64 {
        return std.mem.readInt(i64, row.columns[index].?[0..8], .big);
    }

    /// A one-dimensional text[] in binary: its elements, none null.
    pub fn text_array(row: Row, index: usize) TextArray {
        return TextArray.parse(row.columns[index].?);
    }

    /// A one-dimensional int4[] in binary: its elements, none null.
    pub fn int4_array(row: Row, index: usize) Int4Array {
        return Int4Array.parse(row.columns[index].?);
    }
};

pub const Int4Array = struct {
    bytes: []const u8,
    count: u32,
    at: usize,

    pub fn parse(bytes: []const u8) Int4Array {
        const dimensions = std.mem.readInt(i32, bytes[0..4], .big);
        if (dimensions == 0) return .{ .bytes = bytes, .count = 0, .at = bytes.len };
        assert(dimensions == 1);
        const count = std.mem.readInt(i32, bytes[12..16], .big);
        assert(bytes.len == 20 + 8 * @as(usize, @intCast(count)));
        return .{ .bytes = bytes, .count = @intCast(count), .at = 20 };
    }

    pub fn next(array: *Int4Array) ?i32 {
        if (array.at == array.bytes.len) return null;
        const length = std.mem.readInt(i32, array.bytes[array.at..][0..4], .big);
        assert(length == 4); // tag ids are never null
        const value = std.mem.readInt(i32, array.bytes[array.at + 4 ..][0..4], .big);
        array.at += 8;
        return value;
    }

    pub fn contains(array: Int4Array, value: i32) bool {
        var copy = array;
        while (copy.next()) |element| if (element == value) return true;
        return false;
    }
};

pub const TextArray = struct {
    bytes: []const u8,
    count: u32,
    at: usize,

    pub fn parse(bytes: []const u8) TextArray {
        const dimensions = std.mem.readInt(i32, bytes[0..4], .big);
        if (dimensions == 0) return .{ .bytes = bytes, .count = 0, .at = bytes.len };
        assert(dimensions == 1);
        const count = std.mem.readInt(i32, bytes[12..16], .big);
        return .{ .bytes = bytes, .count = @intCast(count), .at = 20 };
    }

    pub fn next(array: *TextArray) ?[]const u8 {
        if (array.at == array.bytes.len) return null;
        const length = std.mem.readInt(i32, array.bytes[array.at..][0..4], .big);
        assert(length >= 0); // tag names are never null
        const element = array.bytes[array.at + 4 ..][0..@intCast(length)];
        array.at += 4 + @as(usize, @intCast(length));
        return element;
    }
};

/// Pages from the allocator, left untouched: a safe build's `alloc` writes
/// 0xAA over every byte, which makes every page resident at startup.
pub fn alloc_untouched(gpa: std.mem.Allocator, bytes: usize) ![]u8 {
    assert(bytes > 0);
    const raw = gpa.rawAlloc(bytes, .fromByteUnits(std.heap.page_size_min), @returnAddress()) orelse
        return error.OutOfMemory;
    return raw[0..bytes];
}

/// One connection, after startup: owned by its shard's thread.
pub const Connection = struct {
    io: Io,
    fd: linux.fd_t,
    /// Where it connects again when it breaks.
    url: Url,
    /// Statements by their index into the program's table: `s<index>`.
    statements: []const Statement,
    /// Two buffers: requests append to the one filling while the other is
    /// written, so one write carries every group made meanwhile.
    output: [2][]u8,
    output_used: [2]u32 = .{ 0, 0 },
    filling: u1 = 0,
    writing: bool = false,
    input: []u8,
    input_start: u32 = 0,
    input_end: u32 = 0,
    queue: []*Batch,
    queue_head: u32 = 0,
    queue_count: u32 = 0,
    broken: bool = false,
    idle: ?Idle = null,
    /// The batch in flight, for a connection the shard's batches use: one
    /// at a time.
    batch: Batch = .{},
    /// The batches' own mark: the kind it last ran (batch.zig).
    last_kind: u8 = std.math.maxInt(u8),

    pub fn init(gpa: std.mem.Allocator, io: Io, fd: linux.fd_t, url: Url, statements: []const Statement) !Connection {
        return .{
            .io = io,
            .fd = fd,
            .url = url,
            .statements = statements,
            .output = .{ try alloc_untouched(gpa, output_bytes), try alloc_untouched(gpa, output_bytes) },
            .input = try alloc_untouched(gpa, input_bytes),
            .queue = try gpa.alloc(*Batch, queue_max),
        };
    }

    /// Send a group for a batch (`batch.tagged`: each row names its
    /// waiter): its calls, then Sync. False: it could not be sent, and
    /// every waiter has its failure already.
    pub fn send(connection: *Connection, batch: *Batch, calls: []const Call) bool {
        return connection.send_parts(batch, calls, &.{});
    }

    /// As `send`, the calls followed by messages encoded already (each a
    /// request's `Encoded`), all before the one Sync.
    pub fn send_parts(connection: *Connection, batch: *Batch, calls: []const Call, parts: []const []const u8) bool {
        assert(batch.count > 0);
        const index = connection.filling;
        const start = connection.output_used[index];
        var out: Writer = .{ .buffer = connection.output[index], .used = start };
        for (calls) |call| out.call(connection.statements, call);
        for (parts) |part| out.bytes(part);
        const sync = out.begin('S');
        out.end(sync);
        var failure: ?Failure = null;
        if (out.overflow or connection.queue_count == connection.queue.len) failure = .overflow;
        if (connection.broken) failure = .broken;
        if (failure) |failed| {
            for (batch.waiters[0..batch.count]) |waiter| {
                waiter.failure = failed;
                waiter.done = true;
                _ = Evented.unpark(connection.io, &waiter.parked);
            }
            return false;
        }
        connection.output_used[index] = @intCast(out.used);
        const tail = (connection.queue_head + connection.queue_count) % connection.queue.len;
        connection.queue[tail] = batch;
        connection.queue_count += 1;
        connection.flush();
        return true;
    }

    /// Requests in flight: what a pool balances on.
    pub fn load(connection: *const Connection) u32 {
        return connection.queue_count;
    }

    /// The reader fiber's body, for good: answers, in order, to their
    /// requests, until the connection fails; then every request waiting
    /// fails with it, and the connection is made again (a backend gone, a
    /// Postgres restarted), its batches failing at once meanwhile.
    pub fn read_loop(connection: *Connection) void {
        // Bounded only to say so: it serves for good.
        for (0..std.math.maxInt(u64)) |_| {
            connection.read_until_broken();
            connection.reconnect() catch return; // canceled
            if (connection.idle) |idle| idle.function(idle.context, connection);
        } else unreachable;
    }

    /// Connect again, a second between tries, once no fiber writes to the
    /// old descriptor (its number may come back as the new one's).
    fn reconnect(connection: *Connection) error{Canceled}!void {
        assert(connection.broken);
        assert(connection.queue_count == 0);
        const second: Io.Duration = .fromSeconds(1);
        _ = linux.shutdown(connection.fd, linux.SHUT.RDWR);
        // Bounded only to say so: a writer's write fails once shut.
        for (0..std.math.maxInt(u64)) |_| {
            if (!connection.writing) break;
            try connection.io.sleep(.fromMilliseconds(1), .awake);
        } else unreachable;
        _ = linux.close(connection.fd);
        connection.output_used = .{ 0, 0 };
        connection.input_start = 0;
        connection.input_end = 0;
        // Bounded only to say so: Postgres may be gone for a while. At once
        // first: a backend ended alone leaves Postgres up.
        for (0..std.math.maxInt(u64)) |_| {
            const fd = connect_blocking(connection.url, connection.statements) catch |err| {
                log.err("reconnect: {t}", .{err});
                try connection.io.sleep(second, .awake);
                continue;
            };
            connection.fd = fd;
            connection.broken = false;
            log.err("reconnected", .{});
            return;
        } else unreachable;
    }

    fn read_until_broken(connection: *Connection) void {
        // Bounded only to say so: it reads until the connection fails.
        for (0..std.math.maxInt(u64)) |_| {
            connection.dispatch() catch break;
            if (connection.input_start == connection.input_end) {
                connection.input_start = 0;
                connection.input_end = 0;
            } else if (connection.input_end == connection.input.len) {
                const rest = connection.input[connection.input_start..connection.input_end];
                std.mem.copyForwards(u8, connection.input[0..rest.len], rest);
                connection.input_start = 0;
                connection.input_end = @intCast(rest.len);
                if (rest.len == connection.input.len) break; // a message larger than the buffer
            }
            const got = read_some(connection.io, connection.fd, connection.input[connection.input_end..]) catch break;
            if (got == 0) break;
            connection.input_end += @intCast(got);
        } else unreachable;
        connection.fail_all();
    }

    /// Every whole message in the input, to the request at the queue's head.
    fn dispatch(connection: *Connection) error{Protocol}!void {
        // Bounded: each pass consumes a message of the input.
        for (0..connection.input.len) |_| {
            const available = connection.input[connection.input_start..connection.input_end];
            if (available.len < 5) return;
            const length = std.mem.readInt(u32, available[1..5], .big);
            if (length < 4) return error.Protocol;
            if (available.len < 1 + length) return;
            const body = available[5 .. 1 + length];
            connection.input_start += @intCast(1 + length);
            try connection.take(available[0], body);
        } else unreachable;
    }

    fn take(connection: *Connection, kind: u8, body: []const u8) error{Protocol}!void {
        switch (kind) {
            // Notices, parameter changes, notifications: nobody's answer.
            'N', 'S', 'A' => return,
            else => {},
        }
        if (connection.queue_count == 0) return error.Protocol;
        const batch = connection.queue[connection.queue_head];
        const waiters = batch.waiters[0..batch.count];
        switch (kind) {
            'D' => if (batch.tagged) {
                // The tag: a non-null int4, the first column.
                if (body.len < 10) return error.Protocol;
                const count = std.mem.readInt(u16, body[0..2], .big);
                const length = std.mem.readInt(i32, body[2..6], .big);
                if (count == 0 or length != 4) return error.Protocol;
                const tag = std.mem.readInt(i32, body[6..10], .big);
                if (tag < -1 or tag >= batch.count) return error.Protocol;
                var header: [2]u8 = undefined;
                std.mem.writeInt(u16, &header, count - 1, .big);
                // -1: the statement's own row, every request's (the feed's tags).
                if (tag == -1) {
                    for (waiters) |waiter| keep_row(waiter, &header, body[10..]);
                } else {
                    keep_row(waiters[@intCast(tag)], &header, body[10..]);
                }
            } else {
                if (batch.cursor >= batch.count) return error.Protocol;
                keep_row(waiters[batch.cursor], body[0..2], body[2..]);
            },
            'C' => if (batch.tagged) {
                for (waiters) |waiter| {
                    if (waiter.statements == group_statements_max) return error.Protocol;
                    waiter.ends[waiter.statements] = waiter.rows_used;
                    waiter.statements += 1;
                }
            } else {
                if (batch.cursor >= batch.count) return error.Protocol;
                const waiter = waiters[batch.cursor];
                if (waiter.statements == group_statements_max) return error.Protocol;
                waiter.ends[waiter.statements] = waiter.rows_used;
                waiter.statements += 1;
                if (waiter.statements == batch.statements[batch.cursor]) batch.cursor += 1;
            },
            'E' => {
                const state = sqlstate(body);
                for (waiters) |waiter| {
                    if (waiter.failure == null) waiter.failure = .{ .sql = state };
                }
            },
            'Z' => {
                connection.queue_head = @intCast((connection.queue_head + 1) % connection.queue.len);
                connection.queue_count -= 1;
                for (waiters) |waiter| {
                    waiter.done = true;
                    _ = Evented.unpark(connection.io, &waiter.parked);
                }
                if (connection.queue_count == 0) {
                    if (connection.idle) |idle| idle.function(idle.context, connection);
                }
            },
            // ParseComplete, BindComplete, CloseComplete, NoData,
            // PortalSuspended, EmptyQueryResponse: nothing to keep.
            '1', '2', '3', 'n', 's', 'I' => {},
            else => return error.Protocol,
        }
    }

    fn fail_all(connection: *Connection) void {
        connection.broken = true;
        log.err("connection lost: {d} groups failed", .{connection.queue_count});
        for (0..connection.queue_count) |_| {
            const batch = connection.queue[connection.queue_head];
            connection.queue_head = @intCast((connection.queue_head + 1) % connection.queue.len);
            for (batch.waiters[0..batch.count]) |waiter| {
                waiter.failure = .broken;
                waiter.done = true;
                _ = Evented.unpark(connection.io, &waiter.parked);
            }
        }
        connection.queue_count = 0;
    }

    /// Send what waits, unless a fiber is sending already: it sends until
    /// nothing waits, ours included.
    fn flush(connection: *Connection) void {
        if (connection.writing) return;
        connection.writing = true;
        defer connection.writing = false;
        // Bounded: each pass sends a buffer filled while the last was sent.
        for (0..std.math.maxInt(u32)) |_| {
            const index = connection.filling;
            const used = connection.output_used[index];
            if (used == 0) return;
            connection.filling ^= 1;
            assert(connection.output_used[connection.filling] == 0);
            write_all(connection.io, connection.fd, connection.output[index][0..used]) catch {
                connection.broken = true;
                // The reader sees the failure too, and fails every waiter.
                _ = linux.shutdown(connection.fd, linux.SHUT.RDWR);
            };
            connection.output_used[index] = 0;
        } else unreachable;
    }
};

/// A row into its waiter's buffer: its length, then the DataRow's body
/// with `header` (the column count) in place of its own.
fn keep_row(waiter: *Waiter, header: []const u8, columns: []const u8) void {
    assert(header.len == 2);
    const length = header.len + columns.len;
    const room = waiter.rows.len - waiter.rows_used;
    if (length + 4 > room) {
        if (waiter.failure == null) waiter.failure = .overflow;
        return;
    }
    const at = waiter.rows[waiter.rows_used..];
    std.mem.writeInt(u32, at[0..4], @intCast(length), .native);
    @memcpy(at[4..6], header);
    @memcpy(at[6..][0..columns.len], columns);
    waiter.rows_used += @intCast(4 + length);
}

/// A request's statements, encoded once (Binds and Executes, no Sync):
/// what a sequence of requests carries, and what a request sent again alone
/// sends again.
pub const Encoded = struct {
    out: Writer,
    statements: u8 = 0,

    pub fn init(buffer: []u8) Encoded {
        return .{ .out = .{ .buffer = buffer, .used = 0 } };
    }

    pub fn run(encoded: *Encoded, statements: []const Statement, statement: u16, params: []const Param) void {
        assert(encoded.statements < group_statements_max);
        encoded.out.call(statements, .{ .statement = statement, .params = params });
        encoded.statements += 1;
    }

    pub fn bytes(encoded: *const Encoded) ?[]const u8 {
        if (encoded.out.overflow) return null;
        return encoded.out.buffer[0..encoded.out.used];
    }
};

/// Messages into a buffer: past its end, nothing more is written and
/// `overflow` says so.
const Writer = struct {
    buffer: []u8,
    used: usize,
    overflow: bool = false,

    fn bytes(out: *Writer, data: []const u8) void {
        if (out.overflow or out.buffer.len - out.used < data.len) {
            out.overflow = true;
            return;
        }
        @memcpy(out.buffer[out.used..][0..data.len], data);
        out.used += data.len;
    }

    fn byte(out: *Writer, value: u8) void {
        out.bytes(&.{value});
    }

    fn int16(out: *Writer, value: i16) void {
        var data: [2]u8 = undefined;
        std.mem.writeInt(i16, &data, value, .big);
        out.bytes(&data);
    }

    fn int32(out: *Writer, value: i32) void {
        var data: [4]u8 = undefined;
        std.mem.writeInt(i32, &data, value, .big);
        out.bytes(&data);
    }

    fn cstring(out: *Writer, text: []const u8) void {
        assert(std.mem.indexOfScalar(u8, text, 0) == null);
        out.bytes(text);
        out.byte(0);
    }

    fn statement_name(out: *Writer, statement: u16) void {
        var name: [8]u8 = undefined;
        out.cstring(std.fmt.bufPrint(&name, "s{d}", .{statement}) catch unreachable);
    }

    /// A message's type and a length to fill in at `end`.
    fn begin(out: *Writer, kind: u8) usize {
        out.byte(kind);
        const at = out.used;
        out.int32(0);
        return at;
    }

    fn end(out: *Writer, at: usize) void {
        if (out.overflow) return;
        const length: i32 = @intCast(out.used - at);
        std.mem.writeInt(i32, out.buffer[at..][0..4], length, .big);
    }

    /// Bind and Execute: the unnamed portal, every parameter binary, every
    /// result binary.
    fn call(out: *Writer, statements: []const Statement, value: Call) void {
        assert(value.statement < statements.len);
        assert(value.params.len == statements[value.statement].params.len);
        const bind = out.begin('B');
        out.byte(0);
        out.statement_name(value.statement);
        out.int16(1);
        out.int16(1);
        out.int16(@intCast(value.params.len));
        for (value.params) |item| out.param(item);
        out.int16(1);
        out.int16(1);
        out.end(bind);
        const execute = out.begin('E');
        out.byte(0);
        out.int32(0);
        out.end(execute);
    }

    /// A one-dimensional array of fixed-size elements, none null.
    fn fixed_array(out: *Writer, comptime T: type, oid: Oid, items: []const T) void {
        const element_bytes = @sizeOf(T);
        const header_bytes: usize = if (items.len == 0) 12 else 20;
        out.int32(@intCast(header_bytes + items.len * (4 + element_bytes)));
        out.int32(if (items.len == 0) 0 else 1);
        out.int32(0); // no nulls
        out.int32(@intCast(@backingInt(oid)));
        if (items.len > 0) {
            out.int32(@intCast(items.len));
            out.int32(1); // lower bound
        }
        for (items) |item| {
            out.int32(element_bytes);
            var data: [element_bytes]u8 = undefined;
            std.mem.writeInt(T, &data, item, .big);
            out.bytes(&data);
        }
    }

    fn param(out: *Writer, value: Param) void {
        switch (value) {
            .int4_array => |items| out.fixed_array(i32, .int4, items),
            .int8_array => |items| out.fixed_array(i64, .int8, items),
            .null => out.int32(-1),
            .int8 => |number| {
                out.int32(8);
                var data: [8]u8 = undefined;
                std.mem.writeInt(i64, &data, number, .big);
                out.bytes(&data);
            },
            .int4 => |number| {
                out.int32(4);
                out.int32(number);
            },
            .text => |text| {
                out.int32(@intCast(text.len));
                out.bytes(text);
            },
            .text_array => |items| {
                const at = out.used;
                out.int32(0);
                const dimensions: i32 = if (items.len == 0) 0 else 1;
                out.int32(dimensions);
                out.int32(0); // no nulls
                out.int32(@intCast(@backingInt(Oid.text)));
                if (items.len > 0) {
                    out.int32(@intCast(items.len));
                    out.int32(1); // lower bound
                }
                for (items) |item| {
                    out.int32(@intCast(item.len));
                    out.bytes(item);
                }
                if (!out.overflow) {
                    const length: i32 = @intCast(out.used - at - 4);
                    std.mem.writeInt(i32, out.buffer[at..][0..4], length, .big);
                }
            },
        }
    }
};

/// The 'C' field of an ErrorResponse: its SQLSTATE.
fn sqlstate(body: []const u8) [5]u8 {
    var at: usize = 0;
    // Bounded: each pass consumes a field.
    for (0..body.len + 1) |_| {
        if (at >= body.len or body[at] == 0) break;
        const code = body[at];
        const value_end = std.mem.indexOfScalarPos(u8, body, at + 1, 0) orelse break;
        const value = body[at + 1 .. value_end];
        if (code == 'C' and value.len == 5) return value[0..5].*;
        if (code == 'M') log.debug("server error: {s}", .{value});
        at = value_end + 1;
    } else unreachable;
    return "XX000".*;
}

fn read_some(io: Io, fd: linux.fd_t, buffer: []u8) !usize {
    var parts = [_][]u8{buffer};
    const result = try io.operate(.{ .net_read = .{ .socket_handle = fd, .data = &parts } });
    return (try result.net_read).data_len;
}

fn write_all(io: Io, fd: linux.fd_t, bytes: []const u8) !void {
    var sent: usize = 0;
    // Bounded: each pass writes a byte or fails.
    for (0..bytes.len + 1) |_| {
        if (sent == bytes.len) return;
        const result = try io.operate(.{ .net_write = .{
            .socket_handle = fd,
            .header = "",
            .data = &.{bytes[sent..]},
        } });
        const written = try result.net_write;
        if (written == 0) return error.Disconnected;
        sent += written;
    } else unreachable;
}

// ---------- startup: blocking, before the shard serves ----------

pub const Url = struct {
    user: []const u8,
    password: []const u8,
    host: [4]u8,
    port: u16,
    database: []const u8,
};

/// `postgres://user:password@host:port/database`, the host an IPv4 address
/// or `localhost`. No percent-escapes: the box's URL has none.
pub fn parse_url(text: []const u8) !Url {
    const rest = if (std.mem.startsWith(u8, text, "postgres://"))
        text["postgres://".len..]
    else if (std.mem.startsWith(u8, text, "postgresql://"))
        text["postgresql://".len..]
    else
        return error.UrlScheme;
    const at = std.mem.lastIndexOfScalar(u8, rest, '@') orelse return error.UrlNoUser;
    const credentials = rest[0..at];
    const location = rest[at + 1 ..];
    const colon = std.mem.indexOfScalar(u8, credentials, ':');
    const slash = std.mem.indexOfScalar(u8, location, '/') orelse return error.UrlNoDatabase;
    const host_port = location[0..slash];
    var database = location[slash + 1 ..];
    if (std.mem.indexOfScalar(u8, database, '?')) |query| database = database[0..query];
    const port_colon = std.mem.lastIndexOfScalar(u8, host_port, ':');
    const host_text = if (port_colon) |index| host_port[0..index] else host_port;
    const port: u16 = if (port_colon) |index|
        try std.fmt.parseInt(u16, host_port[index + 1 ..], 10)
    else
        5432;
    const host: [4]u8 = if (std.mem.eql(u8, host_text, "localhost"))
        .{ 127, 0, 0, 1 }
    else
        (try std.Io.net.Ip4Address.parse(host_text, port)).bytes;
    return .{
        .user = if (colon) |index| credentials[0..index] else credentials,
        .password = if (colon) |index| credentials[index + 1 ..] else "",
        .host = host,
        .port = port,
        .database = database,
    };
}

/// Session settings sent at startup, on our own connections only (the
/// rules allow it): no JIT, no parallel workers, generic plans (each
/// statement's is as good as a custom one, and planning per execution is
/// skipped), no Memoize (a generic plan of a page put one on the users
/// join, which clears a hash table every execution).
const session_settings = [_][2][]const u8{
    .{ "client_encoding", "UTF8" },
    .{ "TimeZone", "UTC" },
    .{ "DateStyle", "ISO" },
    .{ "jit", "off" },
    .{ "max_parallel_workers_per_gather", "0" },
    .{ "plan_cache_mode", "force_generic_plan" },
    .{ "enable_memoize", "off" },
};

/// Connect, authenticate (trust or SCRAM-SHA-256), and prepare every
/// statement as `s<index>`: blocking system calls.
/// At startup, before the shard serves: 15 tries a second apart, so a
/// Postgres just restarted on a cold page cache (its first statements read
/// the catalog from disk) or not yet listening is waited for, not a crash.
/// A refused connect fails at once; one that hangs, after 2 s.
pub fn connect_at_start(url: Url, statements: []const Statement) !linux.fd_t {
    const tries = 15;
    for (0..tries) |attempt| {
        return connect_blocking(url, statements) catch |err| {
            log.err("connect at start, try {d} of {d}: {t}", .{ attempt + 1, tries, err });
            if (attempt + 1 == tries) return err;
            const second: linux.timespec = .{ .sec = 1, .nsec = 0 };
            _ = linux.nanosleep(&second, null);
            continue;
        };
    }
    unreachable;
}

pub fn connect_blocking(url: Url, statements: []const Statement) !linux.fd_t {
    const fd: linux.fd_t = @intCast(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    if (fd < 0) return error.Socket;
    errdefer _ = linux.close(fd);
    const address: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, url.port),
        .addr = @bitCast(url.host),
    };
    // Bounded: a Postgres that accepts and never answers (a reconnect runs
    // on the shard's thread) stalls it seconds, not for good.
    const timeout: linux.timeval = .{ .sec = 2, .usec = 0 };
    const none: linux.timeval = .{ .sec = 0, .usec = 0 };
    for ([_]u32{ linux.SO.RCVTIMEO, linux.SO.SNDTIMEO }) |option| {
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, option, std.mem.asBytes(&timeout), @sizeOf(linux.timeval));
    }
    const connected = linux.connect(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.in));
    if (linux.errno(connected) != .SUCCESS) return error.Connect;
    const one: u32 = 1;
    _ = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, std.mem.asBytes(&one), 4);
    var stream: Blocking = .{ .fd = fd };
    try stream.startup(url);
    try stream.authenticate(url);
    try stream.prepare(statements);
    for ([_]u32{ linux.SO.RCVTIMEO, linux.SO.SNDTIMEO }) |option| {
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, option, std.mem.asBytes(&none), @sizeOf(linux.timeval));
    }
    return fd;
}

/// A connection before its shard serves: plain blocking reads and writes.
const Blocking = struct {
    fd: linux.fd_t,
    buffer: [16 * 1024]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    out: [64 * 1024]u8 = undefined,

    fn send(stream: *Blocking, bytes: []const u8) !void {
        var sent: usize = 0;
        for (0..bytes.len + 1) |_| {
            if (sent == bytes.len) return;
            // No SIGPIPE if Postgres has closed it: an error, as the ring's sends.
            const result = linux.sendto(stream.fd, bytes[sent..].ptr, bytes.len - sent, linux.MSG.NOSIGNAL, null, 0);
            if (linux.errno(result) != .SUCCESS or result == 0) return error.Write;
            sent += result;
        } else unreachable;
    }

    /// The next whole message: its type and body.
    fn receive(stream: *Blocking) !struct { u8, []const u8 } {
        for (0..stream.buffer.len + 1) |_| {
            const available = stream.buffer[stream.start..stream.end];
            if (available.len >= 5) {
                const length = std.mem.readInt(u32, available[1..5], .big);
                if (length < 4 or length + 1 > stream.buffer.len) return error.Protocol;
                if (available.len >= 1 + length) {
                    stream.start += 1 + length;
                    return .{ available[0], available[5 .. 1 + length] };
                }
            }
            if (stream.start > 0) {
                std.mem.copyForwards(u8, stream.buffer[0..available.len], available);
                stream.start = 0;
                stream.end = available.len;
            }
            const result = linux.read(stream.fd, stream.buffer[stream.end..].ptr, stream.buffer.len - stream.end);
            if (linux.errno(result) != .SUCCESS or result == 0) return error.Read;
            stream.end += result;
        } else unreachable;
    }

    fn startup(stream: *Blocking, url: Url) !void {
        var out: Writer = .{ .buffer = &stream.out, .used = 0 };
        out.int32(0);
        out.int32(196608); // protocol 3.0
        out.cstring("user");
        out.cstring(url.user);
        out.cstring("database");
        out.cstring(url.database);
        for (session_settings) |setting| {
            out.cstring(setting[0]);
            out.cstring(setting[1]);
        }
        out.byte(0);
        assert(!out.overflow);
        std.mem.writeInt(i32, stream.out[0..4], @intCast(out.used), .big);
        try stream.send(stream.out[0..out.used]);
    }

    fn authenticate(stream: *Blocking, url: Url) !void {
        var client: scram.Client = undefined;
        // Bounded: authentication is a few messages, then ReadyForQuery.
        for (0..64) |_| {
            const kind, const body = try stream.receive();
            switch (kind) {
                'R' => try stream.authentication(url, &client, body),
                'E' => {
                    log.err("startup refused: SQLSTATE {s}", .{sqlstate(body)});
                    return error.StartupRefused;
                },
                'Z' => return,
                'S', 'K', 'N' => {},
                else => return error.Protocol,
            }
        } else return error.Protocol;
    }

    fn authentication(stream: *Blocking, url: Url, client: *scram.Client, body: []const u8) !void {
        const code = std.mem.readInt(u32, body[0..4], .big);
        switch (code) {
            0 => {}, // AuthenticationOk
            10 => { // SASL: the mechanisms offered
                if (std.mem.indexOf(u8, body[4..], "SCRAM-SHA-256\x00") == null) {
                    return error.NoScram;
                }
                var random: [scram.nonce_random_bytes]u8 = undefined;
                const got = linux.getrandom(&random, random.len, 0);
                if (got != random.len) return error.Random;
                client.init(url.password, &random);
                var first_buffer: [256]u8 = undefined;
                const first = try client.first(&first_buffer);
                var out: Writer = .{ .buffer = &stream.out, .used = 0 };
                const message = out.begin('p');
                out.cstring("SCRAM-SHA-256");
                out.int32(@intCast(first.len));
                out.bytes(first);
                out.end(message);
                try stream.send(stream.out[0..out.used]);
            },
            11 => { // SASLContinue: the server's first message
                var final_buffer: [512]u8 = undefined;
                const final = try client.final(body[4..], &final_buffer);
                var out: Writer = .{ .buffer = &stream.out, .used = 0 };
                const message = out.begin('p');
                out.bytes(final);
                out.end(message);
                try stream.send(stream.out[0..out.used]);
            },
            12 => try client.verify(body[4..]), // SASLFinal
            else => {
                log.err("authentication method {d} is not supported", .{code});
                return error.AuthenticationMethod;
            },
        }
    }

    fn prepare(stream: *Blocking, statements: []const Statement) !void {
        var out: Writer = .{ .buffer = &stream.out, .used = 0 };
        for (statements, 0..) |statement, index| {
            const message = out.begin('P');
            out.statement_name(@intCast(index));
            out.cstring(statement.sql);
            out.int16(@intCast(statement.params.len));
            for (statement.params) |oid| out.int32(@intCast(@backingInt(oid)));
            out.end(message);
        }
        const sync = out.begin('S');
        out.end(sync);
        if (out.overflow) return error.StatementsTooLarge;
        try stream.send(stream.out[0..out.used]);
        var failed = false;
        var parsed: usize = 0;
        for (0..statements.len + 64) |_| {
            const kind, const body = try stream.receive();
            switch (kind) {
                '1' => parsed += 1,
                'E' => {
                    failed = true;
                    log.err("statement s{d} refused: SQLSTATE {s}: {s}", .{ parsed, sqlstate(body), message_of(body) });
                },
                'Z' => break,
                'N', 'S' => {},
                else => return error.Protocol,
            }
        } else return error.Protocol;
        if (failed or parsed != statements.len) return error.PrepareFailed;
    }
};

fn message_of(body: []const u8) []const u8 {
    var at: usize = 0;
    for (0..body.len + 1) |_| {
        if (at >= body.len or body[at] == 0) break;
        const value_end = std.mem.indexOfScalarPos(u8, body, at + 1, 0) orelse break;
        if (body[at] == 'M') return body[at + 1 .. value_end];
        at = value_end + 1;
    } else unreachable;
    return "";
}

test "pg: a URL's parts" {
    const url = try parse_url("postgres://conduit:conduit@127.0.0.1:5432/conduit");
    try std.testing.expectEqualStrings("conduit", url.user);
    try std.testing.expectEqualStrings("conduit", url.password);
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, url.host);
    try std.testing.expectEqual(5432, url.port);
    try std.testing.expectEqualStrings("conduit", url.database);
}

test "pg: a binary text[] parameter reads back as the server sends it" {
    var buffer: [256]u8 = undefined;
    var out: Writer = .{ .buffer = &buffer, .used = 0 };
    out.param(.{ .text_array = &.{ "ab", "c" } });
    // The parameter's length, then the array as `TextArray` reads it.
    var array = TextArray.parse(buffer[4..out.used]);
    try std.testing.expectEqual(2, array.count);
    try std.testing.expectEqualStrings("ab", array.next().?);
    try std.testing.expectEqualStrings("c", array.next().?);
    try std.testing.expect(array.next() == null);
}
