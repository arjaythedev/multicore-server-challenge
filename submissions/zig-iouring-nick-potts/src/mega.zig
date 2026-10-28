//! The mega statement (`sql.mega`, MEGA from branch sql-stack): a drain's mega-able reads as one execution.
//!
//! `encode` binds its six arrays. `Result` keeps the rows as they arrive, since a read's rows take their shared
//! columns from entity rows that may come later. A list read's page arrives as one row of arrays and is expanded
//! into one row per article here, with the viewer flags. At the end it hands each read its rows in the column
//! layout of the read's own statement, filled and sorted as that statement returns them, so the API writes the same
//! JSON.
const std = @import("std");
const sql = @import("sql.zig");
const pg = @import("pg.zig");
const Query = @import("db.zig").Query;

const gpa = std.heap.smp_allocator;
const ncols = sql.mega.cols.len;
const page = sql.mega.page;

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
        if (c.len[page.ids] < 0) return m.rows.append(gpa, c);
        try m.expand(c);
    }

    /// A list read's page row, with the page's article ids and their authors and the viewer's favorites and
    /// followees among them as arrays, becomes one row per article: the id from the ids array, favorited and
    /// following as a byte each appended after the row, the rest NULL as on the page row. A NULL followees array
    /// means every author is followed (the feed).
    fn expand(m: *Result, p: Cols) !void {
        const ids = try m.array(&p, page.ids);
        const aus = try m.array(&p, page.aus);
        const fa = try m.array(&p, page.fa);
        const fw: ?Array = if (p.len[page.fw] < 0) null else try m.array(&p, page.fw);
        if (aus.n != ids.n) return error.BadMegaPage;
        const flags: u32 = @intCast(m.data.items.len);
        try m.data.appendNTimes(gpa, 0, 2 * ids.n);
        for (0..ids.n) |i| {
            var c = p;
            c.off[page.id] = ids.at(i);
            c.len[page.id] = 8;
            const fav = flags + 2 * @as(u32, @intCast(i));
            m.data.items[fav] = @intFromBool(m.has(fa, m.at(ids.at(i))));
            m.data.items[fav + 1] = @intFromBool(if (fw) |w| m.has(w, m.at(aus.at(i))) else true);
            c.off[page.favorited] = fav;
            c.len[page.favorited] = 1;
            c.off[page.following] = fav + 1;
            c.len[page.following] = 1;
            try m.rows.append(gpa, c);
        }
    }

    /// A one-dimensional int8[] without NULLs in `data`: 20 header bytes (12 when empty), then 4 length bytes and 8
    /// value bytes per element.
    const Array = struct {
        off: u32,
        n: u32,

        fn at(a: Array, i: usize) u32 {
            return a.off + 20 + 12 * @as(u32, @intCast(i)) + 4;
        }
    };

    fn array(m: *const Result, c: *const Cols, col: usize) !Array {
        const len = c.len[col];
        if (len < 12) return error.BadMegaArray;
        const b = m.data.items[c.off[col]..][0..@intCast(len)];
        if (std.mem.readInt(i32, b[0..4], .big) == 0) return .{ .off = c.off[col], .n = 0 };
        if (len < 20 or std.mem.readInt(i32, b[0..4], .big) != 1 or std.mem.readInt(i32, b[4..8], .big) != 0) return error.BadMegaArray;
        const n = std.mem.readInt(i32, b[12..16], .big);
        if (n < 0 or 20 + 12 * n != len) return error.BadMegaArray;
        return .{ .off = c.off[col], .n = @intCast(n) };
    }

    fn at(m: *const Result, off: u32) i64 {
        return std.mem.readInt(i64, m.data.items[off..][0..8], .big);
    }

    fn has(m: *const Result, a: Array, v: i64) bool {
        for (0..a.n) |i| if (m.at(a.at(i)) == v) return true;
        return false;
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
                const col = sql.mega.keys[t];
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
            if (m.int(c, sql.mega.keys[spec.fill - 1])) |key| {
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
const Cell = union(enum) { int: i64, text: []const u8, boolean: bool, tags: []const []const u8, ints: []const i64 };

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
        testReq(.article_by_slug, &.{ .{ .int = 7 }, .{ .text = "how-to" } }),
        testReq(.list_feed, &.{ .{ .int = 7 }, .{ .int = 10 }, .{ .int = 5 }, .{ .int = 15 } }),
        testReq(.article_by_id, &.{ .{ .int = 3 }, .{ .int = 42 } }),
        testReq(.list_all, &.{ .{ .int = 0 }, .{ .int = 20 }, .{ .int = 0 } }),
        testReq(.list_author, &.{ .{ .int = 0 }, .{ .int = 20 }, .{ .int = 0 }, .{ .text = "jake" } }),
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
        \\2 6 5 7 1 3
        \\- 7 7 3 - -
        \\20 - 10 42 20 20
        \\40 - 5 - 0 0
        \\- - 15 - - -
        \\'dragons' 'how-to' - - - 'jake'
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
            .ints => |xs| if (xs.len == 0) {
                try w(&b, i32, 12);
                for ([_]i32{ 0, 0, @intFromEnum(sql.Oid.int8) }) |h| try w(&b, i32, h);
            } else {
                try w(&b, i32, @intCast(20 + 12 * xs.len));
                for ([_]i32{ 1, 0, @intFromEnum(sql.Oid.int8), @intCast(xs.len), 1 }) |h| try w(&b, i32, h);
                for (xs) |x| {
                    try w(&b, i32, 8);
                    try w(&b, i64, x);
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
        testReq(.article_by_slug, &.{ .{ .int = 0 }, .{ .text = "missing" } }),
        testReq(.list_author, &.{ .{ .int = 0 }, .{ .int = 20 }, .{ .int = 0 }, .{ .text = "nobody" } }),
        testReq(.article_by_id, &.{ .{ .int = 4 }, .{ .int = 9 } }),
    };
    var ptrs: [reqs.len]*Query = undefined;
    for (&reqs, &ptrs) |*r, *p| p.* = r;

    var m: Result = .{};
    // The reads' own rows first, unsorted; every entity row after them.
    try addRow(&m, 1, &.{ .{ 0, .{ .int = 2 } }, .{ 1, .{ .int = 5 } }, .{ 10, .{ .boolean = false } }, .{ 14, .{ .boolean = true } } });
    try addRow(&m, 4, &.{ .{ 1, .{ .int = 9 } }, .{ 10, .{ .boolean = true } }, .{ 14, .{ .boolean = false } } });
    try addRow(&m, 1, &.{ .{ 0, .{ .int = 2 } }, .{ 1, .{ .int = 9 } }, .{ 10, .{ .boolean = true } }, .{ 14, .{ .boolean = false } } });
    try addRow(&m, 3, &.{ .{ 0, .{ .int = 0 } }, .{ 10, .{ .boolean = false } }, .{ 14, .{ .boolean = false } } });
    try addRow(&m, -1, &.{ .{ 1, .{ .int = 9 } }, .{ 2, .{ .text = "s9" } }, .{ 3, .{ .text = "T9" } }, .{ 4, .{ .text = "D9" } }, .{ 5, .{ .text = "B9" } }, .{ 6, .{ .int = 90 } }, .{ 7, .{ .int = 91 } }, .{ 8, .{ .tags = &.{ "a", "b" } } }, .{ 9, .{ .int = 3 } }, .{ 11, .{ .text = "amy" } } });
    try addRow(&m, -1, &.{ .{ 1, .{ .int = 5 } }, .{ 2, .{ .text = "s5" } }, .{ 3, .{ .text = "T5" } }, .{ 4, .{ .text = "D5" } }, .{ 6, .{ .int = 50 } }, .{ 7, .{ .int = 51 } }, .{ 8, .{ .tags = &.{} } }, .{ 9, .{ .int = 0 } }, .{ 11, .{ .text = "bob" } }, .{ 12, .{ .text = "hi" } } });

    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    try m.deliver(&ptrs, Recorder{ .out = &got });
    try testing.expectEqualStrings(
        \\list_all 2 9 's9' 'T9' 'D9' 90 91 [a,b] 3 t 'amy' - - f
        \\list_all 2 5 's5' 'T5' 'D5' 50 51 [] 0 f 'bob' 'hi' - t
        \\list_all done
        \\article_by_slug done
        \\list_author 0 - - - - - - - - f - - - f
        \\list_author done
        \\article_by_id 9 's9' 'T9' 'D9' 'B9' 90 91 [a,b] 3 t 'amy' - - f
        \\article_by_id done
        \\
    , got.items);
}

test "add expands a page row into one row per article, with the viewer's flags from the page's arrays" {
    var reqs = [_]Query{
        testReq(.list_all, &.{ .{ .int = 7 }, .{ .int = 20 }, .{ .int = 0 } }),
        testReq(.list_feed, &.{ .{ .int = 7 }, .{ .int = 10 }, .{ .int = 0 }, .{ .int = 10 } }),
        testReq(.list_tag, &.{ .{ .int = 0 }, .{ .int = 20 }, .{ .int = 0 }, .{ .text = "nothing" } }),
    };
    var ptrs: [reqs.len]*Query = undefined;
    for (&reqs, &ptrs) |*r, *p| p.* = r;
    var m: Result = .{};
    // ids 9 and 5 are by author 1, who the viewer follows; the viewer favorited 5; 7 has no entity row.
    try addRow(&m, 1, &.{ .{ 0, .{ .int = 3 } }, .{ 15, .{ .ints = &.{ 5, 9, 7 } } }, .{ 16, .{ .ints = &.{ 1, 1, 2 } } }, .{ 17, .{ .ints = &.{5} } }, .{ 18, .{ .ints = &.{1} } } });
    // The feed's followees array is NULL: every author is followed.
    try addRow(&m, 2, &.{ .{ 0, .{ .int = 1 } }, .{ 15, .{ .ints = &.{9} } }, .{ 16, .{ .ints = &.{1} } }, .{ 17, .{ .ints = &.{} } } });
    // An empty page: NULL arrays, one row with the count.
    try addRow(&m, 3, &.{.{ 0, .{ .int = 0 } }});
    try addRow(&m, -1, &.{ .{ 1, .{ .int = 9 } }, .{ 2, .{ .text = "s9" } }, .{ 3, .{ .text = "T9" } }, .{ 4, .{ .text = "D9" } }, .{ 5, .{ .text = "B9" } }, .{ 6, .{ .int = 90 } }, .{ 7, .{ .int = 91 } }, .{ 8, .{ .tags = &.{ "a", "b" } } }, .{ 9, .{ .int = 3 } }, .{ 11, .{ .text = "amy" } } });
    try addRow(&m, -1, &.{ .{ 1, .{ .int = 5 } }, .{ 2, .{ .text = "s5" } }, .{ 3, .{ .text = "T5" } }, .{ 4, .{ .text = "D5" } }, .{ 6, .{ .int = 50 } }, .{ 7, .{ .int = 51 } }, .{ 8, .{ .tags = &.{} } }, .{ 9, .{ .int = 0 } }, .{ 11, .{ .text = "amy" } } });
    try testing.expectEqual(7, m.rows.items.len);

    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    try m.deliver(&ptrs, Recorder{ .out = &got });
    try testing.expectEqualStrings(
        \\list_all 3 9 's9' 'T9' 'D9' 90 91 [a,b] 3 f 'amy' - - t
        \\list_all 3 7 - - - - - - - f - - - f
        \\list_all 3 5 's5' 'T5' 'D5' 50 51 [] 0 t 'amy' - - t
        \\list_all done
        \\list_feed 1 9 's9' 'T9' 'D9' 90 91 [a,b] 3 f 'amy' - - t
        \\list_feed done
        \\list_tag 0 - - - - - - - - - - - - -
        \\list_tag done
        \\
    , got.items);
}

test "add refuses a page whose arrays are not one-dimensional int8 without NULLs, or of different lengths" {
    var m: Result = .{};
    try testing.expectError(error.BadMegaPage, addRow(&m, 1, &.{ .{ 0, .{ .int = 2 } }, .{ 15, .{ .ints = &.{ 5, 9 } } }, .{ 16, .{ .ints = &.{1} } }, .{ 17, .{ .ints = &.{} } }, .{ 18, .{ .ints = &.{} } } }));
    // A text[] where an int8[] is expected: the element type is not checked, but the lengths do not add up.
    try testing.expectError(error.BadMegaArray, addRow(&m, 1, &.{ .{ 0, .{ .int = 1 } }, .{ 15, .{ .tags = &.{"x"} } }, .{ 16, .{ .ints = &.{1} } }, .{ 17, .{ .ints = &.{} } }, .{ 18, .{ .ints = &.{} } } }));
    try testing.expectEqual(0, m.rows.items.len);
}

test "deliver refuses an entity type other than the article" {
    var reqs = [_]Query{testReq(.list_all, &.{ .{ .int = 0 }, .{ .int = 20 }, .{ .int = 0 } })};
    var ptrs: [reqs.len]*Query = undefined;
    for (&reqs, &ptrs) |*r, *p| p.* = r;
    var m: Result = .{};
    try addRow(&m, -3, &.{.{ 0, .{ .int = 0 } }});
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    try testing.expectError(error.MegaOrdinal, m.deliver(&ptrs, Recorder{ .out = &got }));
}
