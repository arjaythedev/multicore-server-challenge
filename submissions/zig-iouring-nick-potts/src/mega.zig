//! The mega statement (`sql.mega`, MEGA from branch sql-stack): a drain's mega-able reads as one execution.
//!
//! `encode` binds its six arrays. `Result` keeps the rows as they arrive, since a read's rows take their shared
//! columns from entity rows that may come later. At the end it hands each read its rows in the column layout of the
//! read's own statement, filled and sorted as that statement returns them, so the API writes the same JSON.
const std = @import("std");
const sql = @import("sql.zig");
const pg = @import("pg.zig");
const Query = @import("db.zig").Query;

const gpa = std.heap.smp_allocator;
const ncols = sql.mega.cols.len;

/// Binds MEGA (prepared as `name`) with one array element per read and executes it. A read's ordinal is its
/// 1-based position in `reads`.
pub fn encode(o: *pg.Out, name: []const u8, reads: []const *Query) void {
    const at = pg.bindBegin(o, name, sql.mega.params.len);
    const kinds = pg.arrayBegin(o, .int4, reads.len);
    for (reads) |r| pg.paramInt4(o, r.stmt.def().mega.?.kind);
    pg.arrayEnd(o, kinds);
    for ([_]sql.Slot{ .v, .i1, .i2, .i3, .t1 }) |slot| {
        const arr = pg.arrayBegin(o, if (slot == .t1) .text else .int8, reads.len);
        for (reads) |r| element(o, r, slot);
        pg.arrayEnd(o, arr);
    }
    pg.bindEnd(o, at);
}

fn element(o: *pg.Out, r: *const Query, slot: sql.Slot) void {
    const k = std.mem.indexOfScalar(sql.Slot, r.stmt.def().mega.?.args, slot) orelse return pg.paramNull(o);
    switch (r.params[k]) {
        .int => |v| if (slot == .v and v == 0) pg.paramNull(o) else pg.paramInt(o, v),
        .text, .raw => |t| pg.paramText(o, t),
        .null => pg.paramNull(o),
    }
}

/// One execution's rows, copied out of the receive buffer. Reused across executions.
pub const Result = struct {
    data: std.ArrayList(u8) = .empty,
    rows: std.ArrayList(Cols) = .empty,
    /// Per entity type, the row of each key.
    entities: [sql.mega.keys.len]std.AutoHashMapUnmanaged(i64, u32) = @splat(.empty),
    /// The reads' own rows, grouped by read in `by_read` with a counting sort over `start`.
    start: std.ArrayList(u32) = .empty,
    by_read: std.ArrayList(u32) = .empty,
    view: std.ArrayList(pg.Row) = .empty,

    /// Where each column lies in `data`.
    const Cols = struct {
        off: [ncols]u32,
        len: [ncols]i32,
    };

    pub fn add(m: *Result, payload: []const u8) !void {
        var row: pg.Row = .{};
        try row.parse(payload);
        if (row.n != ncols) return error.BadMegaRow;
        const base: u32 = @intCast(m.data.items.len);
        try m.data.appendSlice(gpa, payload);
        var c: Cols = undefined;
        for (0..ncols) |i| {
            c.off[i] = base + row.off[i];
            c.len[i] = row.len[i];
        }
        try m.rows.append(gpa, c);
    }

    pub fn reset(m: *Result) void {
        m.data.clearRetainingCapacity();
        m.rows.clearRetainingCapacity();
        for (&m.entities) |*e| e.clearRetainingCapacity();
    }

    /// Hands every read its rows through `sink.row(r, row)`, then calls `sink.done(r)`.
    pub fn deliver(m: *Result, reads: []const *Query, sink: anytype) !void {
        const n = reads.len;
        m.start.clearRetainingCapacity();
        try m.start.appendNTimes(gpa, 0, n + 1);
        for (m.rows.items, 0..) |*c, i| {
            const ord = m.int(c, sql.mega.ordinal) orelse return error.MegaOrdinal;
            if (ord < 0) {
                if (-ord > sql.mega.keys.len) return error.MegaOrdinal;
                const t: usize = @intCast(-ord - 1);
                const col = sql.mega.keys[t] orelse return error.MegaOrdinal;
                const key = m.int(c, col) orelse return error.MegaEntityKey;
                try m.entities[t].put(gpa, key, @intCast(i));
            } else {
                if (ord == 0 or ord > n) return error.MegaOrdinal;
                m.start.items[@intCast(ord)] += 1;
            }
        }
        for (1..n + 1) |k| m.start.items[k] += m.start.items[k - 1];
        try m.by_read.resize(gpa, m.start.items[n]);
        for (m.rows.items, 0..) |*c, i| {
            const ord = m.int(c, sql.mega.ordinal).?;
            if (ord < 0) continue;
            const k: usize = @intCast(ord - 1);
            m.by_read.items[m.start.items[k]] = @intCast(i);
            m.start.items[k] += 1;
        }
        // The placement advanced each read's start to its end, which is the next read's start.
        var first: u32 = 0;
        for (reads, 0..) |r, k| {
            const spec = r.stmt.def().mega.?;
            const end = m.start.items[k];
            m.view.clearRetainingCapacity();
            for (m.by_read.items[first..end]) |i| try m.view.append(gpa, m.assemble(spec, &m.rows.items[i]));
            first = end;
            if (spec.order.len > 0) std.mem.sort(pg.Row, m.view.items, spec.order, newer);
            for (m.view.items) |*row| sink.row(r, row);
            sink.done(r);
        }
    }

    /// Row `c` in the read statement's column layout, each NULL column taken from the entity row `c` points at.
    fn assemble(m: *const Result, spec: sql.Mega, c: *const Cols) pg.Row {
        var e: *const Cols = c;
        if (spec.fill != 0) {
            if (m.int(c, sql.mega.keys[spec.fill - 1].?)) |key| {
                if (m.entities[spec.fill - 1].get(key)) |i| e = &m.rows.items[i];
            }
        }
        var row: pg.Row = .{ .data = m.data.items, .n = @intCast(spec.cols.len) };
        for (spec.cols, 0..) |mc, i| {
            const src = if (c.len[mc] < 0) e else c;
            row.off[i] = src.off[mc];
            row.len[i] = src.len[mc];
        }
        return row;
    }

    fn int(m: *const Result, c: *const Cols, col: usize) ?i64 {
        if (c.len[col] != 8) return null;
        return std.mem.readInt(i64, m.data.items[c.off[col]..][0..8], .big);
    }
};

/// Descending on each column of `order` (int8 or timestamptz), NULL last.
fn newer(order: []const u8, a: pg.Row, b: pg.Row) bool {
    for (order) |col| {
        const x = sortKey(&a, col);
        const y = sortKey(&b, col);
        if (x != y) return x > y;
    }
    return false;
}

fn sortKey(r: *const pg.Row, col: usize) i64 {
    return if (r.len[col] == 8) r.int(col) else std.math.minInt(i64);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const Cell = union(enum) { int: i64, text: []const u8, boolean: bool, tags: []const []const u8 };

fn testReq(stmt: sql.Stmt, params: []const @import("db.zig").Param) Query {
    var r: Query = .{ .stmt = stmt };
    @memcpy(r.params[0..params.len], params);
    return r;
}

/// One 1-D binary array parameter of a Bind, as text: elements separated by spaces, NULL as `-`.
fn readArray(out: *std.ArrayList(u8), b: []const u8, p: *usize) !void {
    const rd = struct {
        fn i32_(s: []const u8, at: *usize) i32 {
            defer at.* += 4;
            return std.mem.readInt(i32, s[at.*..][0..4], .big);
        }
    }.i32_;
    _ = rd(b, p); // parameter length
    try testing.expectEqual(1, rd(b, p));
    try testing.expectEqual(1, rd(b, p));
    const oid: sql.Oid = @enumFromInt(@as(u32, @intCast(rd(b, p))));
    const n = rd(b, p);
    try testing.expectEqual(1, rd(b, p));
    for (0..@intCast(n)) |i| {
        if (i > 0) try out.append(testing.allocator, ' ');
        const len = rd(b, p);
        if (len < 0) {
            try out.append(testing.allocator, '-');
            continue;
        }
        const v = b[p.*..][0..@intCast(len)];
        p.* += @intCast(len);
        switch (oid) {
            .int4 => try out.print(testing.allocator, "{d}", .{std.mem.readInt(i32, v[0..4], .big)}),
            .int8 => try out.print(testing.allocator, "{d}", .{std.mem.readInt(i64, v[0..8], .big)}),
            .text => try out.print(testing.allocator, "'{s}'", .{v}),
            else => return error.UnexpectedOid,
        }
    }
    try out.append(testing.allocator, '\n');
}

test "encode lays reads out as six arrays in order, NULL where a read has no value" {
    var reqs = [_]Query{
        testReq(.list_tag, &.{ .{ .int = 0 }, .{ .int = 20 }, .{ .int = 40 }, .{ .text = "dragons" } }),
        testReq(.user_by_id, &.{.{ .int = 7 }}),
        testReq(.list_feed, &.{ .{ .int = 7 }, .{ .int = 10 }, .{ .int = 5 }, .{ .int = 15 } }),
        testReq(.article_by_id, &.{ .{ .int = 3 }, .{ .int = 42 } }),
        testReq(.tags, &.{}),
        testReq(.profile, &.{ .{ .int = 0 }, .{ .text = "jake" } }),
    };
    var ptrs: [reqs.len]*Query = undefined;
    for (&reqs, &ptrs) |*r, *p| p.* = r;
    var o: pg.Out = .{};
    defer o.deinit();
    encode(&o, "m", &ptrs);
    const b = o.list.items;
    try testing.expectEqual('B', b[0]);
    try testing.expectEqualSlices(u8, "\x00m\x00\x00\x01\x00\x01\x00\x06", b[5..14]);
    var p: usize = 14;
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    for (0..6) |_| try readArray(&got, b, &p);
    try testing.expectEqualStrings(
        \\2 10 5 7 12 9
        \\- 7 7 3 - -
        \\20 - 10 42 - -
        \\40 - 5 - - -
        \\- - 15 - - -
        \\'dragons' - - - - 'jake'
        \\
    , got.items);
    try testing.expectEqualSlices(u8, "\x00\x01\x00\x01E\x00\x00\x00\x09\x00\x00\x00\x00\x00", b[p..]);
}

/// Adds a MEGA row with ordinal `ord`: the given columns, the rest NULL.
fn addRow(m: *Result, ord: i64, cells: []const struct { u8, Cell }) !void {
    var vals: [ncols]?Cell = @splat(null);
    for (cells) |c| vals[c[0]] = c[1];
    vals[sql.mega.ordinal] = .{ .int = ord };
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(testing.allocator);
    const w = struct {
        fn int(l: *std.ArrayList(u8), comptime T: type, v: T) !void {
            var x: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &x, v, .big);
            try l.appendSlice(testing.allocator, &x);
        }
    }.int;
    try w(&b, u16, ncols);
    for (vals) |v| {
        const cell = v orelse {
            try w(&b, i32, -1);
            continue;
        };
        switch (cell) {
            .int => |x| {
                try w(&b, i32, 8);
                try w(&b, i64, x);
            },
            .text => |s| {
                try w(&b, i32, @intCast(s.len));
                try b.appendSlice(testing.allocator, s);
            },
            .boolean => |x| {
                try w(&b, i32, 1);
                try b.append(testing.allocator, @intFromBool(x));
            },
            .tags => |ts| {
                var len: usize = 20;
                for (ts) |t| len += 4 + t.len;
                try w(&b, i32, @intCast(len));
                for ([_]i32{ 1, 0, @intFromEnum(sql.Oid.text), @intCast(ts.len), 1 }) |h| try w(&b, i32, h);
                for (ts) |t| {
                    try w(&b, i32, @intCast(t.len));
                    try b.appendSlice(testing.allocator, t);
                }
            },
        }
    }
    try m.add(b.items);
}

/// Writes each delivered row in its statement's column types, one line per row and `<stmt> done` per read.
const Recorder = struct {
    out: *std.ArrayList(u8),

    pub fn row(s: Recorder, r: *Query, x: *const pg.Row) void {
        s.write(r, x) catch @panic("oom");
    }

    pub fn done(s: Recorder, r: *Query) void {
        s.out.print(testing.allocator, "{s} done\n", .{@tagName(r.stmt)}) catch @panic("oom");
    }

    fn write(s: Recorder, r: *Query, x: *const pg.Row) !void {
        const a = testing.allocator;
        try s.out.appendSlice(a, @tagName(r.stmt));
        for (r.stmt.def().cols, 0..) |oid, i| {
            try s.out.append(a, ' ');
            if (x.isNull(i)) {
                try s.out.append(a, '-');
                continue;
            }
            switch (oid) {
                .int8, .timestamptz => try s.out.print(a, "{d}", .{x.int(i)}),
                .bool => try s.out.appendSlice(a, if (x.boolean(i)) "t" else "f"),
                .text => try s.out.print(a, "'{s}'", .{x.text(i)}),
                .text_array => {
                    try s.out.append(a, '[');
                    var it = x.textArray(i);
                    var first = true;
                    while (it.next()) |t| : (first = false) try s.out.print(a, "{s}{s}", .{ if (first) "" else ",", t });
                    try s.out.append(a, ']');
                },
                else => return error.UnexpectedOid,
            }
        }
        try s.out.append(a, '\n');
    }
};

test "deliver hands each read its own statement's rows, filled from entity rows and sorted" {
    var reqs = [_]Query{
        testReq(.list_all, &.{ .{ .int = 0 }, .{ .int = 20 }, .{ .int = 0 } }),
        testReq(.tags, &.{}),
        testReq(.article_by_slug, &.{ .{ .int = 0 }, .{ .text = "missing" } }),
        testReq(.profile, &.{ .{ .int = 4 }, .{ .text = "bob" } }),
        testReq(.list_author, &.{ .{ .int = 0 }, .{ .int = 20 }, .{ .int = 0 }, .{ .text = "nobody" } }),
        testReq(.article_by_id, &.{ .{ .int = 4 }, .{ .int = 9 } }),
        testReq(.user_by_id, &.{.{ .int = 4 }}),
    };
    var ptrs: [reqs.len]*Query = undefined;
    for (&reqs, &ptrs) |*r, *p| p.* = r;

    var m: Result = .{};
    // The reads' own rows first, unsorted; every entity row after them.
    try addRow(&m, 1, &.{ .{ 0, .{ .int = 2 } }, .{ 1, .{ .int = 5 } }, .{ 10, .{ .boolean = false } }, .{ 14, .{ .boolean = true } } });
    try addRow(&m, 6, &.{ .{ 1, .{ .int = 9 } }, .{ 10, .{ .boolean = true } }, .{ 14, .{ .boolean = false } } });
    try addRow(&m, 1, &.{ .{ 0, .{ .int = 2 } }, .{ 1, .{ .int = 9 } }, .{ 10, .{ .boolean = true } }, .{ 14, .{ .boolean = false } } });
    try addRow(&m, 2, &.{.{ 0, .{ .int = 0 } }});
    try addRow(&m, 4, &.{ .{ 11, .{ .text = "bob" } }, .{ 12, .{ .text = "hi" } }, .{ 14, .{ .boolean = true } } });
    try addRow(&m, 5, &.{ .{ 0, .{ .int = 0 } }, .{ 10, .{ .boolean = false } }, .{ 14, .{ .boolean = false } } });
    try addRow(&m, 7, &.{ .{ 1, .{ .int = 4 } }, .{ 11, .{ .text = "amy" } }, .{ 16, .{ .text = "amy@x" } } });
    try addRow(&m, -1, &.{ .{ 1, .{ .int = 9 } }, .{ 2, .{ .text = "s9" } }, .{ 3, .{ .text = "T9" } }, .{ 4, .{ .text = "D9" } }, .{ 5, .{ .text = "B9" } }, .{ 6, .{ .int = 90 } }, .{ 7, .{ .int = 91 } }, .{ 8, .{ .tags = &.{ "a", "b" } } }, .{ 9, .{ .int = 3 } }, .{ 11, .{ .text = "amy" } } });
    try addRow(&m, -1, &.{ .{ 1, .{ .int = 5 } }, .{ 2, .{ .text = "s5" } }, .{ 3, .{ .text = "T5" } }, .{ 4, .{ .text = "D5" } }, .{ 6, .{ .int = 50 } }, .{ 7, .{ .int = 51 } }, .{ 8, .{ .tags = &.{} } }, .{ 9, .{ .int = 0 } }, .{ 11, .{ .text = "bob" } }, .{ 12, .{ .text = "hi" } } });
    try addRow(&m, -3, &.{ .{ 0, .{ .int = 0 } }, .{ 8, .{ .tags = &.{ "a", "b", "c" } } } });

    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    try m.deliver(&ptrs, Recorder{ .out = &got });
    try testing.expectEqualStrings(
        \\list_all 2 9 's9' 'T9' 'D9' 90 91 [a,b] 3 t 'amy' - - f
        \\list_all 2 5 's5' 'T5' 'D5' 50 51 [] 0 f 'bob' 'hi' - t
        \\list_all done
        \\tags [a,b,c]
        \\tags done
        \\article_by_slug done
        \\profile 'bob' 'hi' - t
        \\profile done
        \\list_author 0 - - - - - - - - f - - - f
        \\list_author done
        \\article_by_id 9 's9' 'T9' 'D9' 'B9' 90 91 [a,b] 3 t 'amy' - - f
        \\article_by_id done
        \\user_by_id 4 'amy' 'amy@x' - -
        \\user_by_id done
        \\
    , got.items);
}

test "deliver refuses an entity type the statement has no key for" {
    var reqs = [_]Query{testReq(.tags, &.{})};
    var ptrs: [reqs.len]*Query = undefined;
    for (&reqs, &ptrs) |*r, *p| p.* = r;
    var m: Result = .{};
    try addRow(&m, -2, &.{.{ 15, .{ .int = 100 } }});
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    try testing.expectError(error.MegaOrdinal, m.deliver(&ptrs, Recorder{ .out = &got }));
}
