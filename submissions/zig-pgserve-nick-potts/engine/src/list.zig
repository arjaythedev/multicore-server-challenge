//! GET /api/articles (filters none/tag/author/favorited) and GET /api/articles/feed, batched.
//!
//! Each member yields `{"articles":[Article without body],"articlesCount":N}`: a page newest-first by id,
//! cut to limit/offset, and a count capped at 1000 (SPEC's `LIMIT 1000` inside the count). An unknown tag
//! or user is an empty list with count 0, never 404.
//!
//! One index walk gives both the page and the capped count: the filter's index is walked in newest-first
//! order, the first offset+limit ids are the page, and the walk keeps counting visible entries to 1000.
//! Within a batch, members with the same filter key share that walk (taken to the furthest end any of them
//! needs), and article enrichment is shared by id. Viewer flags are per member.
//!
//! Request fields: viewer, limit, offset (int8); the keyed filters add the name (text).

const std = @import("std");
const c = @import("pg_c");
const pg = @import("pg.zig");
const S = @import("schema.zig");
const J = @import("jsonbuf.zig");
const R = @import("rels.zig");
const E = @import("enrich.zig");
const A = @import("alloc.zig");
const Bt = @import("btree.zig");

const CAP: i64 = 1000;

pub const Filter = enum { all, tag, author, favorited, feed };

pub fn rels(comptime filter: Filter) []const []const u8 {
    return &(E.rels ++ switch (filter) {
        .all => [_][]const u8{},
        .tag => [_][]const u8{ "at_tag", "tags_name" },
        .author => [_][]const u8{ "articles_author", "username" },
        .favorited => [_][]const u8{"username"},
        .feed => [_][]const u8{"articles_author"},
    });
}

/// The result of walking one filter key: the first ids newest-first, and the capped count. When the walk
/// was over an index on articles, `tids` holds each id's heap pointer (else it is empty), so the page is
/// read at those pointers instead of through articles_pkey.
const Walk = struct { ids: []const i64, tids: []const c.ItemPointerData, count: i64 };

/// The page and the capped count of one filter key, from the index whose first column is the key (the
/// whole index when `key` is null). The first `end` visible entries in `dir` order (which must be
/// newest-first for this index) come from btree.visible, collecting the article id each entry holds after
/// the key (the key itself for articles_pkey). When that walk fills `end` short of CAP, btree.count counts
/// the key's entries again from the leaf pages. Both start at leaf `start` (Bt.leafOf's, for `key`, in a
/// forward walk) unless it is null.
fn walkIndex(tbl: *pg.Table, idx: *pg.Index, snap: pg.Snapshot, comptime K: type, key: ?K, comptime dir: Bt.Dir, end: usize, comptime on_articles: bool, start: anytype) Walk {
    var top = struct {
        ids: []i64,
        tids: []c.ItemPointerData,
        seen: usize = 0,

        /// `tid` is the entry's own pointer, the HOT chain's root, where enrichment's heap read starts.
        pub fn entry(self: *@This(), id: i64, tid: c.ItemPointerData) bool {
            self.ids[self.seen] = id;
            if (on_articles) self.tids[self.seen] = tid;
            self.seen += 1;
            return self.seen == self.ids.len;
        }
    }{ .ids = A.alloc(i64, end), .tids = A.alloc(c.ItemPointerData, if (on_articles) end else 0) };
    if (@TypeOf(start) == @TypeOf(null))
        Bt.visible(tbl, idx, snap, K, if (key) |k| .{ .lo = k, .hi = k } else null, i64, dir, &top)
    else
        Bt.visibleFrom(tbl, idx, snap, K, .{ .lo = key.?, .hi = key.? }, i64, &top, start);
    const seen = top.seen;
    const count = if (seen < end or seen >= CAP) @min(@as(i64, @intCast(seen)), CAP) else Bt.countAt(tbl, idx, snap, K, key, CAP, start);
    return .{ .ids = top.ids[0..seen], .tids = top.tids[0..if (on_articles) seen else 0], .count = count };
}

/// The feed's top `end` ids (descending) with their heap pointers, and the capped count, fed one
/// followee's articles at a time, newest first.
const FeedTop = struct {
    top: []i64,
    tids: []c.ItemPointerData,
    len: usize = 0,
    count: i64 = 0,

    /// True once the count is capped and the followee's next article cannot enter the top.
    pub fn entry(self: *FeedTop, aid: i64, tid: c.ItemPointerData) bool {
        const end = self.top.len;
        const improves = self.len < end or aid > self.top[self.len - 1];
        if (self.count >= CAP and !improves) return true;
        if (self.count < CAP) self.count += 1;
        if (improves) {
            var pos: usize = if (self.len < end) self.len else end - 1;
            if (self.len < end) self.len += 1;
            while (pos > 0 and self.top[pos - 1] < aid) : (pos -= 1) {
                self.top[pos] = self.top[pos - 1];
                self.tids[pos] = self.tids[pos - 1];
            }
            self.top[pos] = aid;
            self.tids[pos] = tid;
        }
        return false;
    }
};

/// Feed for one viewer: the newest `end` ids across all followees (each followee's articles_author_idx is
/// newest-first), and the capped count of all their articles. One walk per followee serves both: it stops
/// once the count is capped and the followee's next id cannot enter the top `end`. The followees are read
/// first and every followee's leaf found (Bt.leafOf) before any is walked, so the leaves, each a page no
/// other followee shares, load together instead of one after another. The followees' walk starts at leaf
/// `start` (Bt.leafOf's, for `viewer` on follows_pkey).
fn walkFeed(r: *R.Rels, snap: pg.Snapshot, viewer: i64, end: usize, start: u32) Walk {
    var f: FeedTop = .{ .top = A.alloc(i64, end), .tids = A.alloc(c.ItemPointerData, end) };
    var followees = struct {
        ids: std.ArrayListUnmanaged(i64) = .empty,

        pub fn entry(self: *@This(), followee: i64, _: c.ItemPointerData) bool {
            self.ids.append(A.palloc, followee) catch unreachable;
            return false;
        }
    }{};
    Bt.visibleFrom(&r.follows, &r.follows_pkey, snap, i64, .{ .lo = viewer, .hi = viewer }, i64, &followees, start);
    const ids = followees.ids.items;
    const leaves = A.alloc(u32, ids.len);
    for (ids, leaves) |id, *leaf| leaf.* = Bt.leafOf(&r.articles_author, r.articles.rel, i64, id);
    for (0..Bt.AIM_STEPS) |s| for (ids, leaves) |id, leaf| Bt.aim(&r.articles_author, leaf, i64, id, @intCast(s));
    for (ids, leaves) |id, leaf| Bt.visibleFrom(&r.articles, &r.articles_author, snap, i64, .{ .lo = id, .hi = id }, i64, &f, leaf);
    return .{ .ids = f.top[0..f.len], .tids = f.tids[0..f.len], .count = f.count };
}

/// One member's request after parsing: which shared walk it reads, and its slice of it.
const Member = struct { viewer: i64, limit: usize, offset: usize, group: usize };

/// The positions of member `m`'s page in its group's walk.
fn pageOf(groups: []const Group, m: Member) struct { lo: usize, hi: usize, len: usize } {
    const n = groups[m.group].walk.ids.len;
    const lo = @min(m.offset, n);
    const hi = @min(m.offset + m.limit, n);
    return .{ .lo = lo, .hi = hi, .len = hi - lo };
}

/// A distinct filter key in the batch. `key` is the resolved id (tag/author/favoriter/viewer), or null
/// when the name matched nothing. `end` is the furthest offset+limit any member of the group needs.
const Group = struct { key: ?i64, end: usize, walk: Walk = undefined };

/// The index a name filter's names are looked up in, and the name's key there.
fn nameIndex(comptime filter: Filter, r: *R.Rels) *pg.Index {
    return if (filter == .tag) &r.tags_name else &r.username;
}

fn nameTextKey(comptime filter: Filter, name: []const u8) Bt.TextKey {
    return Bt.TextKey.of(name, if (filter == .tag) S.schema.tagname_collation else S.schema.username_collation);
}

/// The id `name` resolves to, its lookup starting at `leaf` (Bt.leafOf's of nameTextKey on nameIndex).
fn nameKey(comptime filter: Filter, r: *R.Rels, snap: pg.Snapshot, name: []const u8, leaf: u32) ?i64 {
    const tbl = if (filter == .tag) &r.tags else &r.users;
    if (!Bt.fetchAt(tbl, nameIndex(filter, r), snap, Bt.TextKey, nameTextKey(filter, name), leaf)) return null;
    return if (filter == .tag) tbl.i32At(S.schema.attno("tags", "id")) else tbl.i64At(S.schema.attno("users", "id"));
}

/// The leaf group `g`'s walk starts from, found ahead (Bt.leafOf) where the walk is a forward one over a
/// key: author's articles, a feed viewer's follows. InvalidBlockNumber for the rest, which descend.
fn startOf(comptime filter: Filter, r: *R.Rels, g: Group) u32 {
    const key = g.key orelse return c.InvalidBlockNumber;
    return switch (filter) {
        .author => Bt.leafOf(&r.articles_author, r.articles.rel, i64, key),
        .feed => Bt.leafOf(&r.follows_pkey, r.follows.rel, i64, key),
        else => c.InvalidBlockNumber,
    };
}

fn walkGroup(comptime filter: Filter, r: *R.Rels, snap: pg.Snapshot, g: *Group, start: u32) void {
    const key = g.key orelse {
        g.walk = .{ .ids = &.{}, .tids = &.{}, .count = 0 };
        return;
    };
    g.walk = switch (filter) {
        .all => walkIndex(&r.articles, &r.articles_pkey, snap, void, null, .backward, g.end, true, null),
        .tag => walkIndex(&r.article_tags, &r.at_tag, snap, i32, @intCast(key), .backward, g.end, false, null),
        .favorited => walkIndex(&r.favorites, &r.fav_pkey, snap, i64, key, .backward, g.end, false, null),
        // articles_author_idx is (author_id, id DESC): forward is newest-first.
        .author => walkIndex(&r.articles, &r.articles_author, snap, i64, key, .forward, g.end, true, start),
        .feed => walkFeed(r, snap, key, g.end, start),
    };
}

pub fn run(comptime filter: Filter, x: *c.EngineExec, r: *R.Rels, snap: pg.Snapshot) void {
    runWith(filter, null, x, r, snap);
}

/// run, with the article fragments in `shared` when given: engine_mega serves every list endpoint of its
/// batch from one memo, so an article on pages of several endpoints is read once.
pub fn runWith(comptime filter: Filter, shared: ?*E.Memo, x: *c.EngineExec, r: *R.Rels, snap: pg.Snapshot) void {
    const n: usize = @intCast(x.nreq);
    const members = A.alloc(Member, n);
    var groups: std.ArrayListUnmanaged(Group) = .empty;
    // the batch's distinct names, so a tag or user named by several members is looked up once
    var names: std.ArrayListUnmanaged(struct { name: []const u8, group: usize }) = .empty;

    for (0..n) |i| {
        const viewer: i64 = @bitCast(x.params[0].values[i]);
        const limit: i64 = @bitCast(x.params[1].values[i]);
        const offset: i64 = @bitCast(x.params[2].values[i]);
        if (limit < 1 or limit > 100 or offset < 0) pg.ereport("engine list: limit must be 1..100 and offset >= 0");
        const lim: usize = @intCast(limit);
        const off: usize = @intCast(offset);
        const g: usize = switch (filter) {
            .all => blk: {
                if (groups.items.len == 0) groups.append(A.palloc, .{ .key = 0, .end = 0 }) catch unreachable;
                break :blk 0;
            },
            .feed => blk: {
                for (groups.items, 0..) |gr, gi| if (gr.key.? == viewer) break :blk gi;
                groups.append(A.palloc, .{ .key = viewer, .end = 0 }) catch unreachable;
                break :blk groups.items.len - 1;
            },
            .tag, .author, .favorited => blk: {
                const name = pg.text(x.params[3].texts[i]);
                for (names.items) |e| if (std.mem.eql(u8, e.name, name)) break :blk e.group;
                // two names can resolve to the same id only if they are equal, so one group per name;
                // its key is looked up below
                groups.append(A.palloc, .{ .key = null, .end = 0 }) catch unreachable;
                names.append(A.palloc, .{ .name = name, .group = groups.items.len - 1 }) catch unreachable;
                break :blk groups.items.len - 1;
            },
        };
        groups.items[g].end = @max(groups.items[g].end, off + lim);
        members[i] = .{ .viewer = viewer, .limit = lim, .offset = off, .group = g };
    }

    // every name's leaf found (Bt.leafOf) before any name is looked up, then every group's first leaf
    // before any group is walked, so each stage's leaves load together
    if (filter == .tag or filter == .author or filter == .favorited) {
        const leaves = A.alloc(u32, names.items.len);
        for (names.items, leaves) |e, *leaf| leaf.* = Bt.leafOf(nameIndex(filter, r), if (filter == .tag) r.tags.rel else r.users.rel, Bt.TextKey, nameTextKey(filter, e.name));
        for (names.items, leaves) |e, leaf| groups.items[e.group].key = nameKey(filter, r, snap, e.name, leaf);
    }
    const starts = A.alloc(u32, groups.items.len);
    for (groups.items, starts) |g, *start| start.* = startOf(filter, r, g);
    var total: usize = 0;
    for (groups.items, starts) |*g, start| {
        c.shim_check_interrupts();
        walkGroup(filter, r, snap, g, start);
        total += g.walk.ids.len;
    }

    var own: E.Memo = undefined;
    const memo = shared orelse own: {
        own = E.Memo.init(total, .list);
        break :own &own;
    };
    // every member's page is read into the memo first, in one Memo.fill, so the reads of articles on
    // different members' pages are staged together
    var want: usize = 0;
    for (members) |m| want += pageOf(groups.items, m).len;
    const ids = A.alloc(i64, want);
    const tids = A.alloc(c.ItemPointerData, if (filter == .tag or filter == .favorited) 0 else want);
    var at: usize = 0;
    for (members) |m| {
        const w = groups.items[m.group].walk;
        const p = pageOf(groups.items, m);
        @memcpy(ids[at..][0..p.len], w.ids[p.lo..p.hi]);
        if (tids.len > 0) @memcpy(tids[at..][0..p.len], w.tids[p.lo..p.hi]);
        at += p.len;
    }
    memo.fill(r, snap, ids, tids);

    // then every member's page is gathered and its flags' leaves found, before any flags are read
    const arts = A.alloc(E.Shared, want);
    const pages = A.alloc([]const E.Shared, n);
    const aheads = A.alloc(E.PageFlags.Ahead, n);
    at = 0;
    for (members, pages, aheads) |m, *page, *ahead| {
        const w = groups.items[m.group].walk;
        const p = pageOf(groups.items, m);
        const from = at;
        for (p.lo..p.hi) |k| {
            // a page id whose article (or author) is gone is dropped, as the reference JOIN drops it
            const a = if (w.tids.len > 0) memo.getAt(r, snap, w.ids[k], w.tids[k]) else memo.get(r, snap, w.ids[k]);
            arts[at] = a orelse continue;
            at += 1;
        }
        page.* = arts[from..at];
        ahead.* = E.PageFlags.ahead(r, m.viewer, page.*, filter == .feed);
    }
    for (0..Bt.AIM_STEPS) |s| for (members, aheads) |m, ahead| E.PageFlags.aim(r, m.viewer, ahead, filter == .feed, @intCast(s));

    for (members, pages, aheads, 0..) |m, page, ahead, i| {
        c.shim_check_interrupts();
        const w = groups.items[m.group].walk;
        const f = E.PageFlags.read(r, snap, m.viewer, ahead, filter == .feed);
        var buf = J.Buf.initBytea(64 + page.len * 640);
        buf.raw("{\"articles\":[");
        for (page, 0..) |*a, k| {
            if (k > 0) buf.byte(',');
            E.write(&buf, a, f.of(snap, a));
        }
        buf.raw("],\"articlesCount\":");
        buf.int(w.count);
        buf.byte('}');
        x.out[i] = .{ .status = c.ST_OK, .body = buf.finishBytea() };
    }
}
