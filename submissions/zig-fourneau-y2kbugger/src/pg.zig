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
//! the shard serves.

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
    text_array = 1009,
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
};

pub const TextArray = struct {
    bytes: []const u8,
    count: u32,
    at: usize,

    fn parse(bytes: []const u8) TextArray {
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
    queue: []*Waiter,
    queue_head: u32 = 0,
    queue_count: u32 = 0,
    broken: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: Io, fd: linux.fd_t, statements: []const Statement) !Connection {
        return .{
            .io = io,
            .fd = fd,
            .statements = statements,
            .output = .{ try alloc_untouched(gpa, output_bytes), try alloc_untouched(gpa, output_bytes) },
            .input = try alloc_untouched(gpa, input_bytes),
            .queue = try gpa.alloc(*Waiter, queue_max),
        };
    }

    /// Requests in flight: what a pool balances on.
    pub fn load(connection: *const Connection) u32 {
        return connection.queue_count;
    }

    /// The reader fiber's body: answers, in order, to their requests, until
    /// the connection fails; then every request waiting fails with it.
    pub fn read_loop(connection: *Connection) void {
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
        const waiter = connection.queue[connection.queue_head];
        switch (kind) {
            'D' => {
                const room = waiter.rows.len - waiter.rows_used;
                if (body.len + 4 > room) {
                    if (waiter.failure == null) waiter.failure = .overflow;
                    return;
                }
                const at = waiter.rows[waiter.rows_used..];
                std.mem.writeInt(u32, at[0..4], @intCast(body.len), .native);
                @memcpy(at[4..][0..body.len], body);
                waiter.rows_used += @intCast(4 + body.len);
            },
            'C' => {
                if (waiter.statements == group_statements_max) return error.Protocol;
                waiter.ends[waiter.statements] = waiter.rows_used;
                waiter.statements += 1;
            },
            'E' => if (waiter.failure == null) {
                waiter.failure = .{ .sql = sqlstate(body) };
            },
            'Z' => {
                connection.queue_head = @intCast((connection.queue_head + 1) % connection.queue.len);
                connection.queue_count -= 1;
                waiter.done = true;
                _ = Evented.unpark(connection.io, &waiter.parked);
            },
            // ParseComplete, BindComplete, CloseComplete, NoData,
            // PortalSuspended, EmptyQueryResponse: nothing to keep.
            '1', '2', '3', 'n', 's', 'I' => {},
            else => return error.Protocol,
        }
    }

    fn fail_all(connection: *Connection) void {
        connection.broken = true;
        log.err("connection lost: {d} requests failed", .{connection.queue_count});
        for (0..connection.queue_count) |_| {
            const waiter = connection.queue[connection.queue_head];
            connection.queue_head = @intCast((connection.queue_head + 1) % connection.queue.len);
            waiter.failure = .broken;
            waiter.done = true;
            _ = Evented.unpark(connection.io, &waiter.parked);
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

/// A group being written: its Binds and Executes, then `wait`.
pub const Query = struct {
    connection: *Connection,
    waiter: Waiter,
    /// Where the group starts in the output, to take it back if it fails.
    start: u32,
    overflow: bool = false,

    pub fn init(connection: *Connection, rows: []u8) Query {
        return .{
            .connection = connection,
            .waiter = .{ .rows = rows },
            .start = connection.output_used[connection.filling],
        };
    }

    /// Bind and Execute one statement with its parameters.
    pub fn run(query: *Query, statement: u16, params: []const Param) void {
        const connection = query.connection;
        assert(statement < connection.statements.len);
        assert(params.len == connection.statements[statement].params.len);
        var out = query.writer();
        // Bind: the unnamed portal, the statement, every parameter binary,
        // every result binary.
        const bind = out.begin('B');
        out.byte(0);
        out.statement_name(statement);
        out.int16(1);
        out.int16(1);
        out.int16(@intCast(params.len));
        for (params) |param| out.param(param);
        out.int16(1);
        out.int16(1);
        out.end(bind);
        const execute = out.begin('E');
        out.byte(0);
        out.int32(0);
        out.end(execute);
        query.keep(out);
    }

    /// Sync, send, and wait for the answers: the group's transaction is
    /// committed (or rolled back) when this returns.
    pub fn wait(query: *Query) Results {
        const connection = query.connection;
        var out = query.writer();
        const sync = out.begin('S');
        out.end(sync);
        query.keep(out);
        if (connection.broken) query.waiter.failure = .broken;
        if (query.overflow or connection.queue_count == connection.queue.len) {
            if (query.waiter.failure == null) query.waiter.failure = .overflow;
        }
        if (query.waiter.failure != null) {
            // Never sent: take the group back.
            connection.output_used[connection.filling] = query.start;
            return .{ .waiter = &query.waiter };
        }
        const tail = (connection.queue_head + connection.queue_count) % connection.queue.len;
        connection.queue[tail] = &query.waiter;
        connection.queue_count += 1;
        connection.flush();
        if (!query.waiter.done) Evented.park(connection.io, &query.waiter.parked);
        assert(query.waiter.done);
        return .{ .waiter = &query.waiter };
    }

    fn writer(query: *Query) Writer {
        const connection = query.connection;
        const index = connection.filling;
        return .{
            .buffer = connection.output[index],
            .used = connection.output_used[index],
            .overflow = query.overflow,
        };
    }

    fn keep(query: *Query, out: Writer) void {
        const connection = query.connection;
        query.overflow = out.overflow;
        connection.output_used[connection.filling] = @intCast(out.used);
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

    fn param(out: *Writer, value: Param) void {
        switch (value) {
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
                out.int32(@intCast(@intFromEnum(Oid.text)));
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
/// rules allow it): no JIT, no parallel workers, generic plans.
const session_settings = [_][2][]const u8{
    .{ "client_encoding", "UTF8" },
    .{ "TimeZone", "UTC" },
    .{ "DateStyle", "ISO" },
    .{ "jit", "off" },
    .{ "max_parallel_workers_per_gather", "0" },
    .{ "plan_cache_mode", "force_generic_plan" },
};

/// Connect, authenticate (trust or SCRAM-SHA-256), and prepare every
/// statement as `s<index>`: blocking system calls.
pub fn connect_blocking(url: Url, statements: []const Statement) !linux.fd_t {
    const fd: linux.fd_t = @intCast(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    if (fd < 0) return error.Socket;
    errdefer _ = linux.close(fd);
    const address: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, url.port),
        .addr = @bitCast(url.host),
    };
    const connected = linux.connect(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.in));
    if (linux.errno(connected) != .SUCCESS) return error.Connect;
    const one: u32 = 1;
    _ = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, std.mem.asBytes(&one), 4);
    var stream: Blocking = .{ .fd = fd };
    try stream.startup(url);
    try stream.authenticate(url);
    try stream.prepare(statements);
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
            const result = linux.write(stream.fd, bytes[sent..].ptr, bytes.len - sent);
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
            for (statement.params) |oid| out.int32(@intCast(@intFromEnum(oid)));
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
