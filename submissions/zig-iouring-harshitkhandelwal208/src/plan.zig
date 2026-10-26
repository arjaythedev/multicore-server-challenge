//! The batch planner. Reads that are waiting together (every kind at once) are answered in two pipelined phases instead of one
//! statement each:
//!
//!   phase A  one lean statement per kind present, taking the batch's DISTINCT keys: capped counts and page rows
//!   phase B  the union of every article phase A returned is enriched ONCE (author, favourite count, tag names), and the
//!            viewers' favourited / following flags are resolved with one `= ANY` range scan per viewer
//!
//! The server then assembles each request's reply in the row layout its handler already parses (api.zig), so the handlers
//! are the same whether a read ran alone, in a per-kind batch, or here. Nothing outlives the batch: every value in a response
//! was read from Postgres while that request was waiting, and only requests already waiting when the batch started share it.
const std = @import("std");
const pg = @import("pg.zig");
const sql = @import("sql.zig");
const api = @import("api.zig");
const server = @import("server.zig");
const bufm = @import("buf.zig");

const Buf = bufm.Buf;
const gpa = bufm.gpa;
const Alloc = std.mem.Allocator;
const Worker = server.Worker;

pub const Taken = struct { stmt: sql.Stmt, it: server.StageItem };

/// What a request is, as far as phase A is concerned.
const Group = enum(u8) { tags, global, tag, author, fav, feed, slug, cmts, prof };
const n_groups = std.meta.fieldNames(Group).len;

fn groupOf(s: sql.Stmt) Group {
    return switch (s) {
        .tags => .tags,
        .list_global => .global,
        .list_tag => .tag,
        .list_author => .author,
        .list_fav => .fav,
        .feed => .feed,
        .article => .slug,
        .comments => .cmts,
        .profile => .prof,
        else => unreachable,
    };
}

/// Distinct keys of one statement argument, numbered from 1 in order of first use.
const Interner = struct {
    map: std.StringHashMapUnmanaged(u32) = .empty,
    n: u32 = 0,

    /// 1-based ordinal of `key` and whether it is new. `key` must outlive the interner.
    fn get(self: *Interner, a: Alloc, key: []const u8) !struct { ord: u32, fresh: bool } {
        const e = try self.map.getOrPut(a, key);
        if (!e.found_existing) {
            self.n += 1;
            e.value_ptr.* = self.n;
            return .{ .ord = self.n, .fresh = true };
        }
        return .{ .ord = e.value_ptr.*, .fresh = false };
    }
};

/// One phase-A row. List statements use c[0..8]: k, id (or the count), author_id, slug, title, description, created_at,
/// updated_at. a_slug adds body (c[8]); a_cmts and a_prof use their own layouts (see sql.zig).
const max_cols = 10;
const Row = struct { c: [max_cols]?[]const u8 };

const PairKey = struct { v: i64, id: i64 };
const Pairs = std.AutoHashMapUnmanaged(PairKey, void);

const GroupState = struct {
    members: std.ArrayList(u32) = .empty, // indices into items
    ckeys: Interner = .{}, // distinct count keys (lists)
    pkeys: Interner = .{}, // distinct pages (lists) / distinct slugs / usernames
    p_text: std.ArrayList([]const u8) = .empty,
    p_lim: std.ArrayList(i64) = .empty,
    p_off: std.ArrayList(i64) = .empty,
    c_text: std.ArrayList([]const u8) = .empty,
    // phase-A results
    rows: std.ArrayList(Row) = .empty,
    counts: []i64 = &.{}, // by count-key ordinal - 1
    // rows grouped by key ordinal (page / slug / username): order[start[k-1] .. start[k]]
    start: []u32 = &.{},
    order: []u32 = &.{},
};

/// Per request: where its count and its page / key live in its group.
const Slot = struct { g: Group, cord: u32 = 0, kord: u32 = 0 };

const Article = struct {
    id: i64,
    author: i64,
    slug: []const u8,
    title: []const u8,
    description: []const u8,
    created: []const u8,
    updated: []const u8,
    username: ?[]const u8 = null,
    bio: ?[]const u8 = null,
    image: ?[]const u8 = null,
    favs: i64 = 0,
    names: std.ArrayList([]const u8) = .empty,
    tag_list: []const u8 = &.{}, // binary text[]
};

pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    items: []server.StageItem,
    stmts: []sql.Stmt,
    slots: []Slot,
    gs: [n_groups]GroupState,
    order: [n_groups]Group = undefined,
    norder: usize = 0,
    phase: u8 = 0,
    abuf: []u8 = &.{},
    // union of articles
    arts: std.ArrayList(Article) = .empty,
    art_ix: std.AutoHashMapUnmanaged(i64, u32) = .empty,
    // viewer flags asked for
    fav_ask: Pairs = .empty,
    fol_ask: Pairs = .empty,
    fav_v: std.ArrayList(i64) = .empty,
    fav_a: std.ArrayList(i64) = .empty,
    fol_v: std.ArrayList(i64) = .empty,
    fol_a: std.ArrayList(i64) = .empty,
    // flags found
    fav_yes: Pairs = .empty,
    fol_yes: Pairs = .empty,
    tags_reply: []const u8 = &.{}, // the shared reply of /api/tags (rows + CommandComplete)

    fn a(self: *Plan) Alloc {
        return self.arena.allocator();
    }
};

pub const Result = enum { send_b, done, failed };

/// Free a finished (or abandoned) plan. `free_text`: the staged items' parameter text is released too.
pub fn destroy(p: *Plan, free_text: bool) void {
    if (free_text) for (p.items) |*it| it.deinit();
    p.arena.deinit();
    gpa.destroy(p);
}

/// Build a plan for `taken` and encode phase A into `w.enc`. Null on allocation failure (the caller keeps the items).
pub fn start(w: *Worker, taken: []const Taken) ?*Plan {
    return startInner(w, taken) catch null;
}

fn startInner(w: *Worker, taken: []const Taken) !*Plan {
    const p = try gpa.create(Plan);
    p.* = .{ .arena = std.heap.ArenaAllocator.init(gpa), .items = &.{}, .stmts = &.{}, .slots = &.{}, .gs = @splat(.{}) };
    errdefer destroy(p, false);
    const al = p.arena.allocator();
    p.items = try al.alloc(server.StageItem, taken.len);
    p.stmts = try al.alloc(sql.Stmt, taken.len);
    p.slots = try al.alloc(Slot, taken.len);
    for (taken, 0..) |t, i| {
        p.items[i] = t.it;
        // Retained text must borrow the plan's item, not the loop capture's inline buffer.
        const it = &p.items[i];
        p.stmts[i] = t.stmt;
        const gk = groupOf(t.stmt);
        const g = &p.gs[@backingInt(gk)];
        try g.members.append(al, @intCast(i));
        var slot = Slot{ .g = gk };
        switch (gk) {
            .tags => {},
            .global => {
                slot.kord = try page(al, g, "", it.limit, it.offset);
            },
            .tag, .author, .fav => {
                const c = try g.ckeys.get(al, it.text());
                if (c.fresh) try g.c_text.append(al, it.text());
                slot.cord = c.ord;
                slot.kord = try page(al, g, it.text(), it.limit, it.offset);
            },
            .feed => {
                const vb = try al.dupe(u8, std.mem.asBytes(&it.viewer));
                const c = try g.ckeys.get(al, vb);
                if (c.fresh) try g.c_text.append(al, vb);
                slot.cord = c.ord;
                slot.kord = try page(al, g, vb, it.limit, it.offset);
            },
            .slug, .cmts, .prof => {
                const k = try g.pkeys.get(al, it.text());
                if (k.fresh) try g.p_text.append(al, it.text());
                slot.kord = k.ord;
            },
        }
        p.slots[i] = slot;
    }
    var e = pg.Enc.init(&w.enc);
    w.enc.reset();
    for (&p.gs, 0..) |*g, gi| {
        if (g.members.items.len == 0) continue;
        const gk: Group = @fromBackingInt(@intCast(gi));
        p.order[p.norder] = gk;
        p.norder += 1;
        switch (gk) {
            .tags => {
                e.bind(sql.id(.tags));
                e.pInt8(0);
                e.exec();
            },
            .global => {
                e.bind(sql.planId(.a_global));
                e.pInt8Array(g.p_lim.items);
                e.pInt8Array(g.p_off.items);
                e.exec();
            },
            .tag, .author, .fav => {
                e.bind(sql.planId(switch (gk) {
                    .tag => .a_tag,
                    .author => .a_author,
                    else => .a_fav,
                }));
                e.pTextArray(g.c_text.items);
                e.pTextArray(g.p_text.items);
                e.pInt8Array(g.p_lim.items);
                e.pInt8Array(g.p_off.items);
                e.exec();
            },
            .feed => {
                const cv = try al.alloc(i64, g.c_text.items.len);
                for (g.c_text.items, 0..) |b, k| cv[k] = std.mem.readInt(i64, b[0..8], .little);
                const pv = try al.alloc(i64, g.p_text.items.len);
                for (g.p_text.items, 0..) |b, k| pv[k] = std.mem.readInt(i64, b[0..8], .little);
                e.bind(sql.planId(.a_feed));
                e.pInt8Array(cv);
                e.pInt8Array(pv);
                e.pInt8Array(g.p_lim.items);
                e.pInt8Array(g.p_off.items);
                e.exec();
            },
            .slug, .cmts, .prof => {
                e.bind(sql.planId(switch (gk) {
                    .slug => .a_slug,
                    .cmts => .a_cmts,
                    else => .a_prof,
                }));
                e.pTextArray(g.p_text.items);
                e.exec();
            },
        }
    }
    if (w.shared.cfg.test_fail_batches) {
        // a Bind to a statement that does not exist: the whole plan errors, as a poisoned request would
        w.enc.putSlice("B\x00\x00\x00\x11\x00s9999\x00\x00\x00\x00\x00\x00\x00");
        w.enc.putSlice("E\x00\x00\x00\x09\x00\x00\x00\x00\x00");
    }
    e.sync();
    return p;
}

/// Ordinal of the page (`text`, limit, offset) in `g`, adding it if new.
fn page(al: Alloc, g: *GroupState, text: []const u8, lim: i32, off: i32) !u32 {
    var kb: [24]u8 = undefined;
    std.mem.writeInt(i64, kb[0..8], lim, .little);
    std.mem.writeInt(i64, kb[8..16], off, .little);
    std.mem.writeInt(u64, kb[16..24], text.len, .little);
    const key = try std.mem.concat(al, u8, &.{ &kb, text });
    const k = try g.pkeys.get(al, key);
    if (k.fresh) {
        try g.p_text.append(al, text);
        try g.p_lim.append(al, lim);
        try g.p_off.append(al, off);
    }
    return k.ord;
}

// ---------------------------------------------------------------------------------------------
// Reading replies
// ---------------------------------------------------------------------------------------------

/// Statement results of a reply, in order: each is the list of its DataRow bodies. Null if the reply holds an error.
fn splitStatements(al: Alloc, batch: []const u8, count: usize) !?[]std.ArrayList([]const u8) {
    const res = try al.alloc(std.ArrayList([]const u8), count);
    for (res) |*r| r.* = .empty;
    var rd = pg.Reader{ .data = batch };
    var s: usize = 0;
    while (rd.next()) |m| {
        switch (m.kind) {
            'E' => return null,
            'D' => {
                if (s >= count) return null;
                try res[s].append(al, m.body);
            },
            'C' => s += 1,
            else => {},
        }
    }
    if (s != count) return null;
    return res;
}

fn rowOf(comptime n: usize, body: []const u8) Row {
    const cs = pg.cols(body, n);
    var r = Row{ .c = @splat(null) };
    inline for (0..n) |i| r.c[i] = cs[i];
    return r;
}

fn i64At(r: *const Row, i: usize) i64 {
    return pg.i64Of(r.c[i].?);
}

fn idDescLess(rows: []const Row, a: u32, b: u32) bool {
    return i64At(&rows[a], 1) > i64At(&rows[b], 1);
}

/// Handle a phase reply. `send_b`: phase B is encoded in `w.enc` for the same connection. `done`: every request was answered.
/// `failed`: the reply holds an error (or memory ran out); nothing was answered, the caller re-runs the requests alone.
pub fn onReply(w: *Worker, p: *Plan, batch: []const u8) Result {
    return onReplyInner(w, p, batch) catch .failed;
}

fn onReplyInner(w: *Worker, p: *Plan, batch: []const u8) !Result {
    const al = p.a();
    if (p.phase == 0) {
        p.abuf = try al.dupe(u8, batch); // the reply buffer is recycled when this returns; B and the assembly still need these bytes
        const sts = (try splitStatements(al, p.abuf, p.norder)) orelse return .failed;
        for (p.order[0..p.norder], 0..) |gk, si| {
            const g = &p.gs[@backingInt(gk)];
            const bodies = sts[si].items;
            switch (gk) {
                .tags => {
                    // the rows of /api/tags as one reply every waiting request is given
                    var b = Buf{};
                    defer b.deinit();
                    for (bodies) |body| {
                        b.put('D');
                        b.putInt(u32, @intCast(4 + body.len), .big);
                        b.putSlice(body);
                    }
                    p.tags_reply = try al.dupe(u8, b.slice());
                },
                .global, .tag, .author, .fav, .feed => try parseList(p, g, gk, bodies),
                .slug => try parseKeyed(p, g, bodies, 9),
                .cmts => try parseKeyed(p, g, bodies, 10),
                .prof => try parseKeyed(p, g, bodies, 5),
            }
        }
        try collect(p);
        if (p.arts.items.len == 0 and p.fav_v.items.len == 0 and p.fol_v.items.len == 0) {
            try assemble(w, p);
            return .done;
        }
        p.phase = 1;
        try encodeB(w, p);
        return .send_b;
    }
    // phase B
    const want_art = p.arts.items.len != 0;
    const want_flags = p.fav_v.items.len != 0 or p.fol_v.items.len != 0;
    const nst: usize = (if (want_art) @as(usize, 3) else 0) + (if (want_flags) @as(usize, 1) else 0);
    const sts = (try splitStatements(al, batch, nst)) orelse return .failed;
    var si: usize = 0;
    if (want_art) {
        for (sts[si].items) |body| {
            const c = pg.cols(body, 4);
            if (p.art_ix.get(pg.i64Of(c[0].?))) |ix| {
                const art = &p.arts.items[ix];
                art.username = if (c[1]) |x| try al.dupe(u8, x) else null;
                art.bio = if (c[2]) |x| try al.dupe(u8, x) else null;
                art.image = if (c[3]) |x| try al.dupe(u8, x) else null;
            }
        }
        si += 1;
        for (sts[si].items) |body| {
            const c = pg.cols(body, 2);
            if (p.art_ix.get(pg.i64Of(c[0].?))) |ix| p.arts.items[ix].favs = pg.i64Of(c[1].?);
        }
        si += 1;
        for (sts[si].items) |body| {
            const c = pg.cols(body, 2);
            if (p.art_ix.get(pg.i64Of(c[0].?))) |ix| try p.arts.items[ix].names.append(al, try al.dupe(u8, c[1].?));
        }
        si += 1;
        for (p.arts.items) |*art| art.tag_list = try encodeTextArray(al, art.names.items);
    }
    if (want_flags) {
        for (sts[si].items) |body| {
            const c = pg.cols(body, 3);
            const key = PairKey{ .v = pg.i64Of(c[1].?), .id = pg.i64Of(c[2].?) };
            if (pg.i64Of(c[0].?) == 0) try p.fav_yes.put(al, key, {}) else try p.fol_yes.put(al, key, {});
        }
    }
    try assemble(w, p);
    return .done;
}

fn parseList(p: *Plan, g: *GroupState, gk: Group, bodies: []const []const u8) !void {
    const al = p.a();
    const ncounts = if (gk == .global) 1 else g.ckeys.n;
    g.counts = try al.alloc(i64, ncounts);
    @memset(g.counts, 0);
    try g.rows.ensureTotalCapacity(al, bodies.len);
    for (bodies) |body| {
        const r = rowOf(8, body);
        const k = i64At(&r, 0);
        if (k <= 0) {
            const ix: usize = if (gk == .global) 0 else @intCast(-k - 1);
            g.counts[ix] = i64At(&r, 1);
            continue;
        }
        g.rows.appendAssumeCapacity(r);
    }
    try groupRows(p, g, g.pkeys.n, true);
}

fn parseKeyed(p: *Plan, g: *GroupState, bodies: []const []const u8, comptime ncols: usize) !void {
    try g.rows.ensureTotalCapacity(p.a(), bodies.len);
    for (bodies) |body| g.rows.appendAssumeCapacity(rowOf(ncols, body));
    try groupRows(p, g, g.pkeys.n, false);
}

/// Group `g.rows` by their key ordinal (column 0), each group newest article first if `sort_desc`.
fn groupRows(p: *Plan, g: *GroupState, nkeys: u32, sort_desc: bool) !void {
    const al = p.a();
    g.start = try al.alloc(u32, nkeys + 1);
    @memset(g.start, 0);
    for (g.rows.items) |*r| g.start[@intCast(i64At(r, 0))] += 1; // counts into slot k (1-based) => prefix gives start of k
    var run: u32 = 0;
    for (g.start) |*s| {
        const c = s.*;
        s.* = run;
        run += c;
    }
    // g.start[k] is now the first position of key ordinal k (1-based); position 0 is unused
    const pos = try al.dupe(u32, g.start);
    g.order = try al.alloc(u32, g.rows.items.len);
    for (g.rows.items, 0..) |*r, i| {
        const k: usize = @intCast(i64At(r, 0));
        g.order[pos[k]] = @intCast(i);
        pos[k] += 1;
    }
    if (sort_desc) {
        var k: usize = 1;
        while (k <= nkeys) : (k += 1) {
            const lo = g.start[k];
            const hi = if (k == nkeys) @as(u32, @intCast(g.order.len)) else g.start[k + 1];
            std.mem.sort(u32, g.order[lo..hi], g.rows.items, idDescLess);
        }
    }
}

fn rowsOf(g: *const GroupState, kord: u32) []const u32 {
    const lo = g.start[kord];
    const hi = if (kord == g.start.len - 1) @as(u32, @intCast(g.order.len)) else g.start[kord + 1];
    return g.order[lo..hi];
}

/// Distinct articles and the (viewer, article) / (viewer, author) pairs whose flags are needed.
fn collect(p: *Plan) !void {
    const al = p.a();
    for (p.slots, 0..) |slot, i| {
        const it = &p.items[i];
        const g = &p.gs[@backingInt(slot.g)];
        switch (slot.g) {
            .tags => {},
            .global, .tag, .author, .fav, .feed, .slug => {
                for (rowsOf(g, slot.kord)) |ri| {
                    const r = &g.rows.items[ri];
                    const id = i64At(r, 1);
                    const e = try p.art_ix.getOrPut(al, id);
                    if (!e.found_existing) {
                        e.value_ptr.* = @intCast(p.arts.items.len);
                        try p.arts.append(al, .{ .id = id, .author = i64At(r, 2), .slug = r.c[3].?, .title = r.c[4].?, .description = r.c[5].?, .created = r.c[6].?, .updated = r.c[7].? });
                    }
                    if (it.viewer != 0) {
                        try ask(al, &p.fav_ask, &p.fav_v, &p.fav_a, it.viewer, id);
                        if (slot.g != .feed) try ask(al, &p.fol_ask, &p.fol_v, &p.fol_a, it.viewer, i64At(r, 2));
                    }
                }
            },
            .cmts => if (it.viewer != 0) {
                for (rowsOf(g, slot.kord)) |ri| {
                    const r = &g.rows.items[ri];
                    if (r.c[6]) |au| try ask(al, &p.fol_ask, &p.fol_v, &p.fol_a, it.viewer, pg.i64Of(au));
                }
            },
            .prof => if (it.viewer != 0) {
                for (rowsOf(g, slot.kord)) |ri| try ask(al, &p.fol_ask, &p.fol_v, &p.fol_a, it.viewer, i64At(&g.rows.items[ri], 1));
            },
        }
    }
}

fn ask(al: Alloc, seen: *Pairs, vs: *std.ArrayList(i64), ids: *std.ArrayList(i64), v: i64, id: i64) !void {
    const e = try seen.getOrPut(al, .{ .v = v, .id = id });
    if (e.found_existing) return;
    try vs.append(al, v);
    try ids.append(al, id);
}

fn encodeB(w: *Worker, p: *Plan) !void {
    var e = pg.Enc.init(&w.enc);
    w.enc.reset();
    if (p.arts.items.len != 0) {
        const al = p.a();
        const ids = try al.alloc(i64, p.arts.items.len);
        const au = try al.alloc(i64, p.arts.items.len);
        for (p.arts.items, 0..) |art, i| {
            ids[i] = art.id;
            au[i] = art.author;
        }
        e.bind(sql.planId(.b_artx));
        e.pInt8Array(ids);
        e.pInt8Array(au);
        e.exec();
        e.bind(sql.planId(.b_fc));
        e.pInt8Array(ids);
        e.exec();
        e.bind(sql.planId(.b_names));
        e.pInt8Array(ids);
        e.exec();
    }
    if (p.fav_v.items.len != 0 or p.fol_v.items.len != 0) {
        e.bind(sql.planId(.b_flags));
        e.pInt8Array(p.fav_v.items);
        e.pInt8Array(p.fav_a.items);
        e.pInt8Array(p.fol_v.items);
        e.pInt8Array(p.fol_a.items);
        e.exec();
    }
    e.sync();
}

/// Binary text[] value of `names` (what the handlers' TextArray reads).
fn encodeTextArray(al: Alloc, names: []const []const u8) ![]const u8 {
    var n: usize = 12;
    if (names.len != 0) n += 8;
    for (names) |s| n += 4 + s.len;
    const out = try al.alloc(u8, n);
    var o: usize = 0;
    const put = struct {
        fn i32_(buf: []u8, at: *usize, v: i32) void {
            std.mem.writeInt(i32, buf[at.*..][0..4], v, .big);
            at.* += 4;
        }
    }.i32_;
    put(out, &o, if (names.len == 0) 0 else 1);
    put(out, &o, 0);
    put(out, &o, pg.oid.text);
    if (names.len != 0) {
        put(out, &o, @intCast(names.len));
        put(out, &o, 1);
        for (names) |s| {
            put(out, &o, @intCast(s.len));
            @memcpy(out[o..][0..s.len], s);
            o += s.len;
        }
    }
    return out;
}

// ---------------------------------------------------------------------------------------------
// Assembling replies
// ---------------------------------------------------------------------------------------------

fn colNull(b: *Buf) void {
    b.putInt(i32, -1, .big);
}

fn colBytes(b: *Buf, v: ?[]const u8) void {
    if (v) |x| {
        b.ensure(4 + x.len);
        b.putInt(i32, @intCast(x.len), .big);
        b.putSlice(x);
    } else colNull(b);
}

fn colI64(b: *Buf, v: i64) void {
    b.putInt(i32, 8, .big);
    b.putInt(i64, v, .big);
}

fn colBool(b: *Buf, v: bool) void {
    b.putInt(i32, 1, .big);
    b.put(@intFromBool(v));
}

fn beginRow(b: *Buf, ncols: u16) usize {
    b.put('D');
    const at = b.len;
    b.putInt(u32, 0, .big);
    b.putInt(u16, ncols, .big);
    return at;
}

fn endRow(b: *Buf, at: usize) void {
    std.mem.writeInt(u32, b.ptr[at..][0..4], @intCast(b.len - at), .big);
}

fn finishReply(b: *Buf) void {
    b.putSlice("C\x00\x00\x00\x0dSELECT 0\x00");
    b.putSlice("Z\x00\x00\x00\x05I");
}

/// The 13 article columns after the count (id ... following) for the row `r` of a list/article statement.
fn articleCols(p: *Plan, b: *Buf, it: *const server.StageItem, art: *const Article, following: ?bool) void {
    colI64(b, art.id);
    colBytes(b, art.slug);
    colBytes(b, art.title);
    colBytes(b, art.description);
    colBytes(b, art.created);
    colBytes(b, art.updated);
    colBytes(b, art.tag_list);
    colI64(b, art.favs);
    colBool(b, it.viewer != 0 and p.fav_yes.contains(.{ .v = it.viewer, .id = art.id }));
    colBytes(b, art.username);
    colBytes(b, art.bio);
    colBytes(b, art.image);
    colBool(b, following orelse (it.viewer != 0 and p.fol_yes.contains(.{ .v = it.viewer, .id = art.author })));
}

fn assemble(w: *Worker, p: *Plan) !void {
    const syn = &w.synth;
    for (p.slots, 0..) |slot, i| {
        const it = &p.items[i];
        const g = &p.gs[@backingInt(slot.g)];
        syn.reset();
        switch (slot.g) {
            .tags => {
                syn.putSlice(p.tags_reply);
            },
            .global, .tag, .author, .fav, .feed => {
                const count = g.counts[if (slot.g == .global) 0 else slot.cord - 1];
                const rows = rowsOf(g, slot.kord);
                if (rows.len == 0) {
                    const at = beginRow(syn, 14);
                    colI64(syn, count);
                    for (0..13) |_| colNull(syn);
                    endRow(syn, at);
                }
                for (rows) |ri| {
                    const r = &g.rows.items[ri];
                    const art = &p.arts.items[p.art_ix.get(i64At(r, 1)).?];
                    const at = beginRow(syn, 14);
                    colI64(syn, count);
                    articleCols(p, syn, it, art, if (slot.g == .feed) true else null);
                    endRow(syn, at);
                }
            },
            .slug => {
                const rows = rowsOf(g, slot.kord);
                if (rows.len != 0) {
                    const r = &g.rows.items[rows[0]];
                    const art = &p.arts.items[p.art_ix.get(i64At(r, 1)).?];
                    const at = beginRow(syn, 14);
                    articleCols(p, syn, it, art, null);
                    colBytes(syn, r.c[8]); // body
                    endRow(syn, at);
                }
            },
            .cmts => {
                for (rowsOf(g, slot.kord)) |ri| {
                    const r = &g.rows.items[ri];
                    const at = beginRow(syn, 8);
                    if (r.c[2] == null) {
                        for (0..8) |_| colNull(syn);
                    } else {
                        colBytes(syn, r.c[2]); // id
                        colBytes(syn, r.c[3]); // body
                        colBytes(syn, r.c[4]); // created_at
                        colBytes(syn, r.c[5]); // updated_at
                        colBytes(syn, r.c[7]); // username
                        colBytes(syn, r.c[8]); // bio
                        colBytes(syn, r.c[9]); // image
                        colBool(syn, it.viewer != 0 and p.fol_yes.contains(.{ .v = it.viewer, .id = pg.i64Of(r.c[6].?) }));
                    }
                    endRow(syn, at);
                }
            },
            .prof => {
                for (rowsOf(g, slot.kord)) |ri| {
                    const r = &g.rows.items[ri];
                    const at = beginRow(syn, 5);
                    colI64(syn, i64At(r, 1));
                    colBytes(syn, r.c[2]);
                    colBytes(syn, r.c[3]);
                    colBytes(syn, r.c[4]);
                    colBool(syn, it.viewer != 0 and p.fol_yes.contains(.{ .v = it.viewer, .id = i64At(r, 1) }));
                    endRow(syn, at);
                }
            },
        }
        finishReply(syn);
        api.onPg(w, it.r, syn.slice());
    }
}

const PlannerTest = struct {
    const Input = struct {
        stmt: sql.Stmt,
        text: []const u8,
        viewer: i64 = 0,
        limit: i32 = 20,
        offset: i32 = 0,
        cord: u32 = 0,
        kord: u32,
    };

    fn expectBorrowed(expected: []const u8, actual: []const u8) !void {
        try std.testing.expectEqual(@intFromPtr(expected.ptr), @intFromPtr(actual.ptr));
        try std.testing.expectEqualStrings(expected, actual);
    }

    fn expectKey(keys: *const Interner, ord: u32, expected: []const u8, borrowed: bool) !void {
        var it = keys.map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != ord) continue;
            if (borrowed) try expectBorrowed(expected, entry.key_ptr.*) else try std.testing.expectEqualStrings(expected, entry.key_ptr.*);
            try std.testing.expectEqual(@as(?u32, ord), keys.map.get(expected));
            return;
        }
        return error.TestExpectedEqual;
    }

    fn check(inputs: []const Input) !void {
        var shared: server.Shared = .{ .cfg = std.mem.zeroes(server.Config), .jwt = undefined, .bc = undefined };
        var w = Worker{ .shared = &shared, .id = 0 };
        defer w.enc.deinit();
        const reqs = try std.testing.allocator.alloc(server.Req, inputs.len);
        defer std.testing.allocator.free(reqs);
        for (reqs) |*r| r.* = .{};
        const taken = try std.testing.allocator.alloc(Taken, inputs.len);
        defer std.testing.allocator.free(taken);
        var initialized: usize = 0;
        defer for (taken[0..initialized]) |*t| t.it.deinit();
        for (inputs, 0..) |input, i| {
            taken[i] = .{ .stmt = input.stmt, .it = server.StageItem.init(&reqs[i], @intCast(i), input.viewer, input.limit, input.offset, input.text) orelse return error.OutOfMemory };
            initialized += 1;
        }
        const p = start(&w, taken) orelse return error.OutOfMemory;
        initialized = 0; // The plan now owns the items, including heap-backed text.
        defer destroy(p, true);
        // Borrowing the caller's items is also wrong, even if their bytes happened to survive start().
        for (taken) |*t| @memset(&t.it.buf, 0xa5);

        for (inputs, 0..) |input, i| {
            const item = &p.items[i];
            const gk = groupOf(input.stmt);
            const g = &p.gs[@backingInt(gk)];
            const filtered = gk == .tag or gk == .author or gk == .fav;
            try std.testing.expectEqual(input.stmt, p.stmts[i]);
            try std.testing.expectEqual(&reqs[i], item.r);
            try std.testing.expectEqualStrings(input.text, item.text());
            try std.testing.expectEqual(input.text.len > 128, item.heap != null);
            try std.testing.expectEqual(input.viewer, item.viewer);
            try std.testing.expectEqual(input.limit, item.limit);
            try std.testing.expectEqual(input.offset, item.offset);
            try std.testing.expectEqual(gk, p.slots[i].g);
            try std.testing.expectEqual(input.cord, p.slots[i].cord);
            try std.testing.expectEqual(input.kord, p.slots[i].kord);

            var first_count = true;
            var first_page = true;
            for (inputs[0..i]) |earlier| {
                if (groupOf(earlier.stmt) != gk) continue;
                if (earlier.cord == input.cord) first_count = false;
                if (earlier.kord == input.kord) first_page = false;
            }
            if (filtered and first_count) {
                try expectBorrowed(item.text(), g.c_text.items[input.cord - 1]);
                try expectKey(&g.ckeys, input.cord, item.text(), true);
            }
            if (first_page) {
                try expectBorrowed(item.text(), g.p_text.items[input.kord - 1]);
                if (filtered) {
                    try std.testing.expectEqual(@as(i64, input.limit), g.p_lim.items[input.kord - 1]);
                    try std.testing.expectEqual(@as(i64, input.offset), g.p_off.items[input.kord - 1]);
                    var key: [24 + 129]u8 = undefined;
                    std.mem.writeInt(i64, key[0..8], input.limit, .little);
                    std.mem.writeInt(i64, key[8..16], input.offset, .little);
                    std.mem.writeInt(u64, key[16..24], input.text.len, .little);
                    @memcpy(key[24..][0..input.text.len], input.text);
                    try expectKey(&g.pkeys, input.kord, key[0 .. 24 + input.text.len], false);
                } else try expectKey(&g.pkeys, input.kord, item.text(), true);
            }
            try std.testing.expectEqualStrings(input.text, g.p_text.items[input.kord - 1]);
            if (filtered) try std.testing.expectEqualStrings(input.text, g.c_text.items[input.cord - 1]);
        }

        var expected = Buf{};
        defer expected.deinit();
        var e = pg.Enc.init(&expected);
        var norder: usize = 0;
        for (&p.gs, 0..) |*g, gi| {
            if (g.members.items.len == 0) continue;
            const gk: Group = @fromBackingInt(@intCast(gi));
            var counts: u32 = 0;
            var pages: u32 = 0;
            var members: usize = 0;
            for (inputs, 0..) |input, i| {
                if (groupOf(input.stmt) != gk) continue;
                counts = @max(counts, input.cord);
                pages = @max(pages, input.kord);
                try std.testing.expectEqual(@as(u32, @intCast(i)), g.members.items[members]);
                members += 1;
            }
            try std.testing.expectEqual(members, g.members.items.len);
            try std.testing.expectEqual(counts, g.ckeys.n);
            try std.testing.expectEqual(counts, g.ckeys.map.count());
            try std.testing.expectEqual(@as(usize, counts), g.c_text.items.len);
            try std.testing.expectEqual(pages, g.pkeys.n);
            try std.testing.expectEqual(pages, g.pkeys.map.count());
            try std.testing.expectEqual(@as(usize, pages), g.p_text.items.len);
            try std.testing.expectEqual(gk, p.order[norder]);
            norder += 1;
            const filtered = gk == .tag or gk == .author or gk == .fav;
            try std.testing.expectEqual(if (filtered) @as(usize, pages) else 0, g.p_lim.items.len);
            try std.testing.expectEqual(g.p_lim.items.len, g.p_off.items.len);
            e.bind(sql.planId(switch (gk) {
                .tag => .a_tag,
                .author => .a_author,
                .fav => .a_fav,
                .slug => .a_slug,
                .cmts => .a_cmts,
                .prof => .a_prof,
                else => unreachable,
            }));
            if (filtered) e.pTextArray(g.c_text.items);
            e.pTextArray(g.p_text.items);
            if (filtered) {
                e.pInt8Array(g.p_lim.items);
                e.pInt8Array(g.p_off.items);
            }
            e.exec();
        }
        e.sync();
        try std.testing.expectEqual(norder, p.norder);
        try std.testing.expectEqualSlices(u8, expected.slice(), w.enc.slice());
    }
};

test "planner owns distinct and duplicate text across lookup and filter kinds" {
    try PlannerTest.check(&.{
        .{ .stmt = .article, .text = "slug-alpha", .kord = 1 },
        .{ .stmt = .profile, .text = "alice", .kord = 1 },
        .{ .stmt = .list_tag, .text = "zig", .cord = 1, .kord = 1 },
        .{ .stmt = .comments, .text = "slug-alpha", .kord = 1 },
        .{ .stmt = .list_author, .text = "alice", .cord = 1, .kord = 1 },
        .{ .stmt = .list_fav, .text = "alice", .cord = 1, .kord = 1 },
        .{ .stmt = .article, .text = "slug-bravo", .kord = 2 },
        .{ .stmt = .list_tag, .text = "rust", .cord = 2, .kord = 2 },
        .{ .stmt = .profile, .text = "carol", .kord = 2 },
        .{ .stmt = .comments, .text = "a-longer-slug", .kord = 2 },
        .{ .stmt = .list_author, .text = "carol", .cord = 2, .kord = 2 },
        .{ .stmt = .list_fav, .text = "carol", .cord = 2, .kord = 2 },
        .{ .stmt = .article, .text = "slug-alpha", .viewer = 17, .kord = 1 },
        .{ .stmt = .comments, .text = "slug-alpha", .viewer = 18, .kord = 1 },
        .{ .stmt = .profile, .text = "alice", .viewer = 19, .kord = 1 },
        .{ .stmt = .list_tag, .text = "zig", .viewer = 20, .cord = 1, .kord = 1 },
        .{ .stmt = .list_author, .text = "alice", .limit = 5, .offset = 3, .cord = 1, .kord = 3 },
        .{ .stmt = .list_fav, .text = "alice", .offset = 7, .cord = 1, .kord = 3 },
        .{ .stmt = .list_tag, .text = "zig", .limit = 10, .cord = 1, .kord = 3 },
    });
}

test "planner preserves text identity at the 127 128 129 byte storage boundary" {
    const kinds = [_]sql.Stmt{ .article, .comments, .profile, .list_tag, .list_author, .list_fav };
    const a127: [127]u8 = @splat('a');
    const b128: [128]u8 = @splat('b');
    const c129: [129]u8 = @splat('c');
    const d127: [127]u8 = @splat('d');
    const texts = [_][]const u8{ &a127, &b128, &a127, &c129, &d127, &b128, &c129, &d127 };
    const ords = [_]u32{ 1, 2, 1, 3, 4, 2, 3, 4 };
    var inputs: [kinds.len * texts.len]PlannerTest.Input = undefined;
    for (texts, ords, 0..) |text, ord, ti| {
        for (kinds, 0..) |stmt, ki| {
            const i = ti * kinds.len + ki;
            inputs[i] = .{ .stmt = stmt, .text = text, .viewer = @intCast(i), .cord = if (ki >= 3) ord else 0, .kord = ord };
        }
    }
    try PlannerTest.check(&inputs);
}
