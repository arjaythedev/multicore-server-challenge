//! The batched comments statement (`sql/BATCH_COMMENTS_LIST_SET.sql`) reads each distinct thread of a drain once.
//!
//! It returns two kinds of rows, told apart by the last column. A request row (ordinal k > 0) names its leader, the
//! first request in the drain for the same article, and carries the viewer's followee ids. A thread row (-n, where n
//! requests share the thread) is one comment of the leader's thread, newest first, with its author id and the
//! constants false and true. Every request row comes before any thread row. `Fan` hands each thread row to every
//! request that shares it, in COMMENTS_LIST_SET's columns, with `following` pointing at the true or the false
//! constant by that request's own followees. A request whose article does not exist gets no rows, as alone.
const std = @import("std");
const pg = @import("pg.zig");
const sql = @import("sql.zig");
const Query = @import("db.zig").Query;

const gpa = std.heap.smp_allocator;

/// The batched statement's columns: COMMENTS_LIST_SET's eight, then true, author id, followee ids, leader, ordinal.
pub const cols = [_]sql.Oid{ .int8, .text, .timestamptz, .timestamptz, .text, .text, .text, .bool, .bool, .int8, .int8_array, .int8, .int8 };
const following = 7;
const yes = 8;
const author = 9;
const followees = 10;
const leader = 11;
const end = 0xffff_ffff;

/// One execution's requests, filled from its request rows. Reused across executions.
pub const Fan = struct {
    /// Per request (0-based), the next request sharing its leader's thread.
    next: std.ArrayList(u32) = .empty,
    /// Per leader, the requests chained to it so far, itself included.
    count: std.ArrayList(u32) = .empty,
    /// Per request, its followee ids in `ids`.
    span: std.ArrayList([2]u32) = .empty,
    ids: std.ArrayList(i64) = .empty,

    pub fn reset(f: *Fan) void {
        f.next.clearRetainingCapacity();
        f.count.clearRetainingCapacity();
        f.span.clearRetainingCapacity();
        f.ids.clearRetainingCapacity();
    }

    /// Takes one row of the execution for `members`; hands thread rows on through `sink.row(r, row)`.
    pub fn row(f: *Fan, x: *pg.Row, members: []const *Query, sink: anytype) !void {
        if (x.n != cols.len) return error.ThreadColumns;
        if (f.next.items.len != members.len) {
            try f.next.appendNTimes(gpa, end, members.len);
            try f.count.appendNTimes(gpa, 0, members.len);
            try f.span.appendNTimes(gpa, .{ 0, 0 }, members.len);
        }
        const ord = x.int(cols.len - 1);
        const lead = x.int(leader);
        if (lead < 1 or lead > members.len) return error.ThreadLeader;
        const l: usize = @intCast(lead - 1);
        if (ord > 0) {
            if (ord < lead or ord > members.len) return error.ThreadOrdinal;
            const k: usize = @intCast(ord - 1);
            const start: u32 = @intCast(f.ids.items.len);
            var it = x.textArray(followees);
            while (it.next()) |v| try f.ids.append(gpa, std.mem.readInt(i64, v[0..8], .big));
            f.span.items[k] = .{ start, @intCast(f.ids.items.len) };
            if (k != l) {
                f.next.items[k] = f.next.items[l];
                f.next.items[l] = @intCast(k);
            }
            f.count.items[l] += 1;
            return;
        }
        if (ord == 0 or -ord != f.count.items[l]) return error.ThreadBeforeRequests;
        const by: ?i64 = if (x.isNull(author)) null else x.int(author);
        const no = x.off[following];
        const sure = x.off[yes];
        x.n = yes;
        var k: u32 = @intCast(l);
        while (k != end) : (k = f.next.items[k]) {
            const s = f.span.items[k];
            const follows = if (by) |a| std.mem.indexOfScalar(i64, f.ids.items[s[0]..s[1]], a) != null else false;
            x.off[following] = if (follows) sure else no;
            sink.row(members[k], x);
        }
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

const Cell = union(enum) { int: i64, text: []const u8, boolean: bool, ids: []const i64 };

/// A row of the batched statement with ordinal `ord` and leader `lead`: the given columns, the rest NULL.
fn rowBytes(b: *std.ArrayList(u8), ord: i64, lead: i64, cells: []const struct { u8, Cell }) !void {
    var vals: [cols.len]?Cell = @splat(null);
    for (cells) |c| vals[c[0]] = c[1];
    vals[leader] = .{ .int = lead };
    vals[cols.len - 1] = .{ .int = ord };
    if (ord < 0) {
        vals[following] = .{ .boolean = false };
        vals[yes] = .{ .boolean = true };
    }
    const a = testing.allocator;
    const w = struct {
        fn int(l: *std.ArrayList(u8), comptime T: type, v: T) !void {
            var x: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &x, v, .big);
            try l.appendSlice(testing.allocator, &x);
        }
    }.int;
    b.clearRetainingCapacity();
    try w(b, u16, cols.len);
    for (vals) |v| {
        const cell = v orelse {
            try w(b, i32, -1);
            continue;
        };
        switch (cell) {
            .int => |x| {
                try w(b, i32, 8);
                try w(b, i64, x);
            },
            .text => |s| {
                try w(b, i32, @intCast(s.len));
                try b.appendSlice(a, s);
            },
            .boolean => |x| {
                try w(b, i32, 1);
                try b.append(a, @intFromBool(x));
            },
            .ids => |ids| {
                try w(b, i32, @intCast(if (ids.len == 0) 12 else 20 + 12 * ids.len));
                if (ids.len == 0) {
                    for ([_]i32{ 0, 0, @intFromEnum(sql.Oid.int8) }) |h| try w(b, i32, h);
                    continue;
                }
                for ([_]i32{ 1, 0, @intFromEnum(sql.Oid.int8), @intCast(ids.len), 1 }) |h| try w(b, i32, h);
                for (ids) |id| {
                    try w(b, i32, 8);
                    try w(b, i64, id);
                }
            },
        }
    }
}

/// Writes each delivered row as `<request> <comment id or -> <body or -> <following>`.
const Recorder = struct {
    out: *std.ArrayList(u8),
    reqs: []const Query,

    pub fn row(s: Recorder, r: *Query, x: *const pg.Row) void {
        const k = (@intFromPtr(r) - @intFromPtr(s.reqs.ptr)) / @sizeOf(Query);
        s.out.print(testing.allocator, "r{d} ", .{k + 1}) catch @panic("oom");
        if (x.n != 8) @panic("columns");
        if (x.isNull(0)) {
            s.out.print(testing.allocator, "- - {s}\n", .{if (x.boolean(7)) "t" else "f"}) catch @panic("oom");
            return;
        }
        s.out.print(testing.allocator, "{d} '{s}' {s}\n", .{ x.int(0), x.text(1), if (x.boolean(7)) "t" else "f" }) catch @panic("oom");
    }
};

fn feed(f: *Fan, b: *std.ArrayList(u8), ptrs: []const *Query, rec: Recorder, ord: i64, lead: i64, cells: []const struct { u8, Cell }) !void {
    try rowBytes(b, ord, lead, cells);
    var x: pg.Row = .{};
    try x.parse(b.items);
    try f.row(&x, ptrs, rec);
}

test "each request sharing a thread gets its rows in order, with its own following" {
    var reqs: [5]Query = @splat(.{ .stmt = .comments_list_set });
    var ptrs: [reqs.len]*Query = undefined;
    for (&reqs, &ptrs) |*r, *p| p.* = r;
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(testing.allocator);
    const rec: Recorder = .{ .out = &got, .reqs = &reqs };
    var f: Fan = .{};
    defer {
        f.next.deinit(gpa);
        f.count.deinit(gpa);
        f.span.deinit(gpa);
        f.ids.deinit(gpa);
    }
    // Requests 1, 3 and 4 read article A (leader 1), request 2 reads B, which has no comments; request 5's article
    // does not exist, so it has no row.
    try feed(&f, &b, &ptrs, rec, 3, 1, &.{.{ followees, .{ .ids = &.{ 7, 9 } } }});
    try feed(&f, &b, &ptrs, rec, 1, 1, &.{.{ followees, .{ .ids = &.{} } }});
    try feed(&f, &b, &ptrs, rec, 2, 2, &.{.{ followees, .{ .ids = &.{9} } }});
    try feed(&f, &b, &ptrs, rec, 4, 1, &.{.{ followees, .{ .ids = &.{8} } }});
    try feed(&f, &b, &ptrs, rec, -3, 1, &.{ .{ 0, .{ .int = 12 } }, .{ 1, .{ .text = "new" } }, .{ author, .{ .int = 9 } } });
    try feed(&f, &b, &ptrs, rec, -3, 1, &.{ .{ 0, .{ .int = 11 } }, .{ 1, .{ .text = "old" } }, .{ author, .{ .int = 8 } } });
    try feed(&f, &b, &ptrs, rec, -1, 2, &.{});
    var mine: std.ArrayList(u8) = .empty;
    defer mine.deinit(testing.allocator);
    for (1..5) |k| {
        var lines = std.mem.splitScalar(u8, got.items, '\n');
        while (lines.next()) |l| if (l.len > 0 and l[1] - '0' == k) {
            try mine.appendSlice(testing.allocator, l);
            try mine.append(testing.allocator, '\n');
        };
    }
    try testing.expectEqualStrings(
        \\r1 12 'new' f
        \\r1 11 'old' f
        \\r2 - - f
        \\r3 12 'new' t
        \\r3 11 'old' f
        \\r4 12 'new' f
        \\r4 11 'old' t
        \\
    , mine.items);
    f.reset();
    // A thread row before all of its requests' rows is refused, not answered short.
    try feed(&f, &b, &ptrs, rec, 1, 1, &.{.{ followees, .{ .ids = &.{} } }});
    try testing.expectError(error.ThreadBeforeRequests, feed(&f, &b, &ptrs, rec, -2, 1, &.{.{ 0, .{ .int = 1 } }}));
}
