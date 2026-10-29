//! Single-statement, batch-owned article entities and narrow request headers.
//! Row slices borrow the PG receive buffer until all responses have been rendered.
const std = @import("std");
const pg = @import("pg.zig");
const sql = @import("sql.zig");
const server = @import("server.zig");
const plan = @import("plan.zig");
const api = @import("api.zig");
const jw = @import("jw.zig");
const gpa = @import("buf.zig").gpa;

const Row = [18]?[]const u8;
const Entities = std.AutoHashMapUnmanaged(i64, Row);

pub const Batch = struct {
    arena: std.heap.ArenaAllocator,
    items: []server.StageItem,
    stmts: []sql.Stmt,
};

pub fn kind(stmt: sql.Stmt) ?i32 {
    return switch (stmt) {
        .list_global => 1,
        .list_tag => 2,
        .list_author => 3,
        .list_fav => 4,
        .feed => 5,
        .article => 6,
        .profile => 7,
        .tags => 8,
        else => null,
    };
}

pub fn start(w: *server.Worker, taken: []const plan.Taken) ?*Batch {
    const b = gpa.create(Batch) catch return null;
    b.* = .{ .arena = std.heap.ArenaAllocator.init(gpa), .items = &.{}, .stmts = &.{} };

    const a = b.arena.allocator();
    const n = taken.len;
    b.items = a.alloc(server.StageItem, n) catch {
        destroy(b, false);
        return null;
    };
    b.stmts = a.alloc(sql.Stmt, n) catch {
        destroy(b, false);
        return null;
    };
    const kinds = a.alloc(i32, n) catch {
        destroy(b, false);
        return null;
    };
    const viewers = a.alloc(i64, n) catch {
        destroy(b, false);
        return null;
    };
    const limits = a.alloc(i32, n) catch {
        destroy(b, false);
        return null;
    };
    const offsets = a.alloc(i32, n) catch {
        destroy(b, false);
        return null;
    };
    const texts = a.alloc([]const u8, n) catch {
        destroy(b, false);
        return null;
    };
    for (taken, 0..) |t, i| {
        b.items[i] = t.it;
        b.stmts[i] = t.stmt;
        kinds[i] = kind(t.stmt) orelse {
            destroy(b, false);
            return null;
        };
        viewers[i] = t.it.viewer;
        limits[i] = t.it.limit;
        offsets[i] = t.it.offset;
        texts[i] = b.items[i].text();
    }
    w.enc.reset();
    var e = pg.Enc.init(&w.enc);
    e.bind(sql.packed_id);
    e.pInt4Array(kinds);
    e.pInt8Array(viewers);
    e.pInt4Array(limits);
    e.pInt4Array(offsets);
    e.pTextArray(texts);
    e.exec();
    if (w.shared.cfg.test_fail_batches) {
        w.enc.putSlice("B\x00\x00\x00\x11\x00s9999\x00\x00\x00\x00\x00\x00\x00");
        w.enc.putSlice("E\x00\x00\x00\x09\x00\x00\x00\x00\x00");
    }
    e.sync();
    return b;
}

pub fn destroy(b: *Batch, free_items: bool) void {
    if (free_items) for (b.items) |*it| it.deinit();
    b.arena.deinit();
    gpa.destroy(b);
}

fn decode(body: []const u8) !Row {
    if (body.len < 2 or std.mem.readInt(u16, body[0..2], .big) != 18) return error.Protocol;
    var row: Row = undefined;
    var pos: usize = 2;
    for (&row) |*c| {
        if (body.len - pos < 4) return error.Protocol;
        const n = pg.i32Of(body[pos..]);
        pos += 4;
        if (n == -1) {
            c.* = null;
            continue;
        }
        if (n < 0 or @as(usize, @intCast(n)) > body.len - pos) return error.Protocol;
        c.* = body[pos..][0..@intCast(n)];
        pos += @intCast(n);
    }
    if (pos != body.len) return error.Protocol;
    return row;
}

fn num(row: Row, col: usize) !i64 {
    const bytes = row[col] orelse return error.Protocol;
    if (bytes.len != 8) return error.Protocol;
    return pg.i64Of(bytes);
}

fn ids(row: Row, col: usize) !pg.Int8Array {
    return pg.Int8Array.init(row[col] orelse return error.Protocol);
}

/// Validate the entire reply before freeing any request: a malformed/failed batch
/// can then be retried in isolation without double responses or dangling requests.
pub fn onReply(w: *server.Worker, b: *Batch, bytes: []const u8) bool {
    onReplyInner(w, b, bytes) catch return false;
    return true;
}

fn onReplyInner(w: *server.Worker, b: *Batch, bytes: []const u8) !void {
    const a = b.arena.allocator();
    var entities: Entities = .empty;
    const headers = try a.alloc(?Row, b.items.len);
    @memset(headers, null);
    var tags: ?[]const u8 = null;
    var rd: pg.Reader = .{ .data = bytes };
    var ready = false;
    while (rd.next()) |m| {
        if (m.kind == 'E') return error.QueryFailed;
        if (m.kind == 'Z') ready = m.body.len == 1 and m.body[0] == 'I';
        if (m.kind != 'D') continue;
        const row = try decode(m.body);
        const ord = try num(row, 0);
        if (ord == 0) {
            const id = try num(row, 2);
            _ = try num(row, 3);
            _ = try num(row, 7);
            _ = try num(row, 8);
            _ = try num(row, 11);
            for ([_]usize{ 4, 5, 6, 10, 12 }) |col| if (row[col] == null) return error.Protocol;
            const entry = try entities.getOrPut(a, id);
            if (entry.found_existing) return error.Protocol;
            entry.value_ptr.* = row;
        } else if (ord == -1) {
            if (tags != null or row[10] == null) return error.Protocol;
            tags = row[10];
        } else {
            if (ord < 1 or ord > b.items.len) return error.Protocol;
            const index: usize = @intCast(ord - 1);
            if (headers[index] != null) return error.Protocol;
            headers[index] = row;
        }
    }
    if (!ready) return error.Protocol;
    for (headers, b.stmts) |maybe, stmt| {
        const h = maybe orelse return error.Protocol;
        const count = try num(h, 1);
        if (count < 0 or count > 1000) return error.Protocol;
        var page = try ids(h, 15);
        _ = try ids(h, 16);
        _ = try ids(h, 17);
        var n: usize = 0;
        while (page.next()) |id| {
            const art = entities.get(id) orelse return error.Protocol;
            if (stmt == .article and art[9] == null) return error.Protocol;
            n += 1;
        }
        if (stmt == .article and (n > 1 or n != count)) return error.Protocol;
        if (stmt == .profile and count != 0) {
            _ = try num(h, 3);
            if (h[12] == null) return error.Protocol;
        }
        if (stmt == .tags and tags == null) return error.Protocol;
    }
    // No fallible operations below this point. Every borrowed entity remains live
    // until the last dependent response has transferred its own rendered allocation.
    for (headers, b.items, b.stmts) |maybe, it, stmt| {
        const h = maybe.?;
        const r = it.r;
        const count = pg.i64Of(h[1].?);
        w.beginBody();
        if ((stmt == .article or stmt == .profile) and count == 0) {
            api.notFound(w, r, if (stmt == .article) "article not found" else "profile not found");
            continue;
        }
        if (stmt == .tags) {
            w.out.putSlice("{\"tags\":[");
            var names = pg.TextArray.init(tags.?);
            var first = true;
            while (names.next()) |name| {
                if (!first) w.out.put(',');
                first = false;
                jw.str(&w.out, name);
            }
            w.out.putSlice("]}");
        } else if (stmt == .profile) {
            w.out.putSlice("{\"profile\":");
            const following = (pg.Int8Array.init(h[17].?) catch unreachable).contains(pg.i64Of(h[3].?));
            api.writeProfile(w, h[12].?, h[13], h[14], following);
            w.out.put('}');
        } else {
            const full = stmt == .article;
            w.out.putSlice(if (full) "{\"article\":" else "{\"articles\":[");
            var page = pg.Int8Array.init(h[15].?) catch unreachable;
            const favs = pg.Int8Array.init(h[16].?) catch unreachable;
            const follows = pg.Int8Array.init(h[17].?) catch unreachable;
            var first = true;
            while (page.next()) |id| {
                if (!first) w.out.put(',');
                first = false;
                const row = entities.get(id).?;
                const yes: [1]u8 = .{1};
                const no: [1]u8 = .{0};
                const c: [14]?[]const u8 = .{ row[2], row[4], row[5], row[6], row[7], row[8], row[10], row[11], if (favs.contains(id)) &yes else &no, row[12], row[13], row[14], if (stmt == .feed or follows.contains(pg.i64Of(row[3].?))) &yes else &no, row[9] };
                api.writeArticle(w, &c, full);
            }
            if (!full) {
                w.out.putSlice("],\"articlesCount\":");
                jw.putInt(&w.out, count);
            }
            w.out.put('}');
        }
        api.doneReq(w, r, 200);
    }
}

test "packed decoder rejects short and wrong-width rows" {
    try std.testing.expectError(error.Protocol, decode(""));
    try std.testing.expectError(error.Protocol, decode("\x00\x11"));
    try std.testing.expectError(error.Protocol, decode("\x00\x12"));
    try std.testing.expectEqual(@as(?i32, null), kind(.comments));
    try std.testing.expectEqual(@as(?i32, 5), kind(.feed));
}
