//! The Article object, split by what depends on the viewer.
//!
//! Everything except `favorited` and `author.following` is the same for every viewer, so within one batch
//! execution it is read once per distinct article and written once as JSON fragments; each member then
//! splices those fragments around its own two flags. That is the sharing #7 does with its `enriched`
//! CTE, done here without materialising rows. Fragments live in the execution's memory context and die
//! with it: nothing survives the statement.
//!
//! Byte layout of one Article (SPEC key order, the reference server's):
//!   head   {"slug":..,"title":..,"description":..[,"body":..],"tagList":[..],"createdAt":..,"updatedAt":..
//!   flag   ,"favorited":true|false
//!   mid    ,"favoritesCount":N,"author":{"username":..,"bio":..,"image":..
//!   flag   ,"following":true|false
//!   tail   }}

const std = @import("std");
const c = @import("pg_c");
const pg = @import("pg.zig");
const S = @import("schema.zig");
const J = @import("jsonbuf.zig");
const R = @import("rels.zig");
const A = @import("alloc.zig");
const Bt = @import("btree.zig");
const IdMap = @import("idmap.zig").IdMap;
const Coll = @import("collate.zig");

/// Relations the Article fragments and viewer flags read.
pub const rels = [_][]const u8{ "articles", "articles_pkey", "users", "users_pkey", "article_tags", "at_pkey", "tags", "tags_pkey", "favorites", "fav_article", "fav_pkey", "follows", "follows_pkey" };

pub const Shape = enum { full, list };

/// One article's viewer-independent fragments.
pub const Shared = struct {
    id: i64,
    author_id: i64,
    head: []const u8,
    mid: []const u8,
};

/// A tag's name as stored (its sort key), whether it is plain (collate.zig), and the name as JSON.
const Tag = struct { name: []const u8, plain: bool, json: []const u8 };

fn tagById(r: *R.Rels, snap: pg.Snapshot, id: i32) ?Tag {
    if (!Bt.fetch(&r.tags, &r.tags_pkey, snap, i32, id)) return null;
    const name = A.dupe(r.tags.textAt(S.schema.attno("tags", "name")) orelse pg.ereport("tags.name is NULL"));
    var json = J.Buf.init(name.len + 8);
    J.escapeJson(&json, name);
    return .{ .name = name, .plain = Coll.plain(name), .json = json.slice() };
}

pub fn writeNullableText(buf: *J.Buf, v: ?[]const u8) void {
    if (v) |s| J.escapeJson(buf, s) else buf.raw("null");
}

/// `"username":..,"bio":..,"image":..` from the user just read into r.users.
pub fn writeProfileFields(buf: *J.Buf, r: *R.Rels) void {
    const s = &S.schema;
    buf.raw("\"username\":");
    J.escapeJson(buf, r.users.textAt(s.attno("users", "username")).?);
    buf.raw(",\"bio\":");
    writeNullableText(buf, r.users.textAt(s.attno("users", "bio")));
    buf.raw(",\"image\":");
    writeNullableText(buf, r.users.textAt(s.attno("users", "image")));
}

/// `,"author":{"username":..,"bio":..,"image":..` for user `id` (the Profile up to its viewer flag), its
/// users_pkey walk starting at `leaf` (Bt.leafOf) unless it is null. False if the user is not visible: the
/// reference JOIN drops that row, so the caller does too.
pub fn writeAuthor(buf: *J.Buf, r: *R.Rels, snap: pg.Snapshot, id: i64, leaf: anytype) bool {
    if (!Bt.fetchAt(&r.users, &r.users_pkey, snap, i64, id, leaf)) return false;
    buf.raw(",\"author\":{");
    writeProfileFields(buf, r);
    return true;
}

/// Author fragments (writeAuthor's bytes) by user id for one execution, so an author of several articles
/// is read once. null: the user is not visible.
pub const Authors = struct {
    map: IdMap(?[]const u8),

    pub fn init(capacity_hint: usize) Authors {
        return .{ .map = IdMap(?[]const u8).init(capacity_hint) };
    }

    pub fn get(self: *Authors, r: *R.Rels, snap: pg.Snapshot, id: i64) ?[]const u8 {
        const e = self.map.claim(id);
        if (!e.hit) e.v.* = read(r, snap, id, null);
        return e.v.*;
    }

    /// The fragment of user `id`, its users_pkey walk starting at `leaf` (Bt.leafOf) unless it is null.
    fn read(r: *R.Rels, snap: pg.Snapshot, id: i64, leaf: anytype) ?[]const u8 {
        var buf = J.Buf.init(256);
        return if (writeAuthor(&buf, r, snap, id, leaf)) buf.slice() else null;
    }
};

/// Viewer flags for one member. Viewer 0 (anonymous; no user has id 0) is false for both by construction.
pub const Flags = struct { favorited: bool, following: bool };

/// Whether the link (viewer, id) is visible in a (viewer, id) link index: favorites_pkey, follows_pkey.
/// The walk starts at leaf `start` (Bt.leafOf) unless it is null.
fn probe(tbl: *pg.Table, idx: *pg.Index, snap: pg.Snapshot, viewer: i64, id: i64, start: anytype) bool {
    return Bt.countAt(tbl, idx, snap, [2]i64, .{ viewer, id }, 1, start) > 0;
}

/// The leaves a viewer's two flags on an article are probed from (Bt.leafOf), found ahead of the probes so
/// that several members' leaves load together.
pub const FlagLeaves = struct { fav: u32, fol: u32 };

/// The FlagLeaves of `viewer`'s flags on `a`; for viewer 0 nothing is probed and they are not needed.
pub fn flagLeaves(r: *R.Rels, viewer: i64, a: *const Shared) FlagLeaves {
    if (viewer == 0) return undefined;
    return .{
        .fav = Bt.leafOf(&r.fav_pkey, r.favorites.rel, [2]i64, .{ viewer, a.id }),
        .fol = Bt.leafOf(&r.follows_pkey, r.follows.rel, [2]i64, .{ viewer, a.author_id }),
    };
}

/// Step `step` of Bt.aim for the searches flagsAt makes from `at`.
pub fn aimFlags(r: *R.Rels, viewer: i64, a: *const Shared, at: FlagLeaves, step: u8) void {
    if (viewer == 0) return;
    Bt.aim(&r.fav_pkey, at.fav, [2]i64, .{ viewer, a.id }, step);
    Bt.aim(&r.follows_pkey, at.fol, [2]i64, .{ viewer, a.author_id }, step);
}

/// `viewer`'s flags on `a`, probed from flagLeaves' leaves.
pub fn flagsAt(r: *R.Rels, snap: pg.Snapshot, viewer: i64, a: *const Shared, at: FlagLeaves) Flags {
    if (viewer == 0) return .{ .favorited = false, .following = false };
    return .{
        .favorited = probe(&r.favorites, &r.fav_pkey, snap, viewer, a.id, at.fav),
        .following = probe(&r.follows, &r.follows_pkey, snap, viewer, a.author_id, at.fol),
    };
}

/// Whether article `a`'s slug is `want`. Its head starts with `{"slug":` and the slug as a JSON string,
/// and two strings are equal exactly when their JSON forms are, a JSON string ending at its first
/// unescaped quote.
pub fn hasSlug(a: *const Shared, want: []const u8) bool {
    const prefix = "{\"slug\":";
    var json = J.Buf.init(want.len + 8);
    J.escapeJson(&json, want);
    return std.mem.startsWith(u8, a.head[prefix.len..], json.slice());
}

/// Whether `viewer` follows `followee`, probed from `leaf` (Bt.leafOf of (viewer, followee) on
/// follows_pkey). Viewer 0 (anonymous) follows no one, and its leaf is not read.
pub fn followsAt(r: *R.Rels, snap: pg.Snapshot, viewer: i64, followee: i64, leaf: u32) bool {
    return viewer != 0 and probe(&r.follows, &r.follows_pkey, snap, viewer, followee, leaf);
}

/// A viewer's links with id in [lo, hi] from a (viewer, id) link index, read by one walk, so that a page
/// of flags costs one descent instead of a probe each. Past `cap` links in range the walk gives up and
/// each flag is probed instead: a walk that long costs more than the probes it replaces (a descent is
/// roughly 20 walk steps). Viewer 0 (anonymous) has no links.
pub const Links = struct {
    tbl: *pg.Table,
    idx: *pg.Index,
    viewer: i64,
    ids: ?[]const i64, // ascending; null: probe per id

    /// The walk starts at leaf `start` (leafOf's, for (viewer, lo)) unless it is null.
    pub fn read(tbl: *pg.Table, idx: *pg.Index, snap: pg.Snapshot, viewer: i64, lo: i64, hi: i64, cap: usize, start: anytype) Links {
        var l: Links = .{ .tbl = tbl, .idx = idx, .viewer = viewer, .ids = &.{} };
        if (viewer == 0 or lo > hi) return l;
        l.ids = Bt.valuesAt(tbl, idx, snap, [2]i64, .{ .lo = .{ viewer, lo }, .hi = .{ viewer, hi } }, i64, A.alloc(i64, cap), start);
        return l;
    }

    pub fn has(self: *const Links, snap: pg.Snapshot, id: i64) bool {
        const ids = self.ids orelse return probe(self.tbl, self.idx, snap, self.viewer, id, null);
        var lo: usize = 0;
        var hi = ids.len;
        while (lo < hi) {
            const m = (lo + hi) / 2;
            if (ids[m] < id) lo = m + 1 else hi = m;
        }
        return lo < ids.len and ids[lo] == id;
    }
};

/// Walk budget for links covering `n` items.
pub fn linkCap(n: usize) usize {
    return 16 * n + 16;
}

/// One viewer's flags over a page of articles: favorites and follows each read by one walk over the
/// page's id and author ranges. On the feed every author is followed by construction (the page is drawn
/// from the viewer's follows under the same snapshot), so only favorites are read.
pub const PageFlags = struct {
    favs: Links,
    fols: ?Links,

    /// A page's id and author ranges, which its flags are read over, and the leaves those walks start
    /// from, found ahead (Bt.leafOf) so that several members' leaves load together.
    pub const Ahead = struct { n: usize, ilo: i64, ihi: i64, alo: i64, ahi: i64, fav: u32, fol: u32 };

    pub fn ahead(r: *R.Rels, viewer: i64, page: []const Shared, comptime feed: bool) Ahead {
        var a: Ahead = .{ .n = page.len, .ilo = std.math.maxInt(i64), .ihi = std.math.minInt(i64), .alo = std.math.maxInt(i64), .ahi = std.math.minInt(i64), .fav = undefined, .fol = undefined };
        for (page) |x| {
            a.ilo = @min(a.ilo, x.id);
            a.ihi = @max(a.ihi, x.id);
            a.alo = @min(a.alo, x.author_id);
            a.ahi = @max(a.ahi, x.author_id);
        }
        // Links.read reads nothing for viewer 0 or an empty page
        if (viewer == 0 or page.len == 0) return a;
        a.fav = Bt.leafOf(&r.fav_pkey, r.favorites.rel, [2]i64, .{ viewer, a.ilo });
        if (!feed) a.fol = Bt.leafOf(&r.follows_pkey, r.follows.rel, [2]i64, .{ viewer, a.alo });
        return a;
    }

    /// Step `step` of Bt.aim for the searches read makes from `a`.
    pub fn aim(r: *R.Rels, viewer: i64, a: Ahead, comptime feed: bool, step: u8) void {
        if (viewer == 0 or a.n == 0) return;
        Bt.aim(&r.fav_pkey, a.fav, [2]i64, .{ viewer, a.ilo }, step);
        if (!feed) Bt.aim(&r.follows_pkey, a.fol, [2]i64, .{ viewer, a.alo }, step);
    }

    pub fn read(r: *R.Rels, snap: pg.Snapshot, viewer: i64, a: Ahead, comptime feed: bool) PageFlags {
        const cap = linkCap(a.n);
        return .{
            .favs = Links.read(&r.favorites, &r.fav_pkey, snap, viewer, a.ilo, a.ihi, cap, a.fav),
            .fols = if (feed) null else Links.read(&r.follows, &r.follows_pkey, snap, viewer, a.alo, a.ahi, cap, a.fol),
        };
    }

    pub fn of(self: *const PageFlags, snap: pg.Snapshot, a: *const Shared) Flags {
        return .{
            .favorited = self.favs.has(snap, a.id),
            .following = if (self.fols) |*f| f.has(snap, a.author_id) else true,
        };
    }
};

/// Splices one Article object for a member into buf.
pub fn write(buf: *J.Buf, a: *const Shared, f: Flags) void {
    buf.raw(a.head);
    buf.raw(if (f.favorited) ",\"favorited\":true" else ",\"favorited\":false");
    buf.raw(a.mid);
    buf.raw(if (f.following) ",\"following\":true}}" else ",\"following\":false}}");
}

/// Per-execution memo of article fragments by id, so a batch walks each distinct article once, with the
/// tag names and authors those fragments share.
pub const Memo = struct {
    map: IdMap(?Shared),
    tags: IdMap(?Tag),
    authors: Authors,
    shape: Shape,

    pub fn init(capacity_hint: usize, shape: Shape) Memo {
        return .{
            .map = IdMap(?Shared).init(capacity_hint),
            .tags = IdMap(?Tag).init(16),
            .authors = Authors.init(capacity_hint),
            .shape = shape,
        };
    }

    /// The fragments of article `id`, reading it by id on first use. null = not visible (or author gone).
    pub fn get(self: *Memo, r: *R.Rels, snap: pg.Snapshot, id: i64) ?Shared {
        const e = self.map.claim(id);
        if (!e.hit) e.v.* = self.byId(r, snap, id);
        return e.v.*;
    }

    /// As get, for an article whose heap pointer (its HOT chain's root) an index walk just gave: a miss
    /// reads it there instead of descending articles_pkey. The walk saw it visible under the same snapshot,
    /// so not finding it is an engine bug and an ERROR, never a dropped row.
    pub fn getAt(self: *Memo, r: *R.Rels, snap: pg.Snapshot, id: i64, tid: c.ItemPointerData) ?Shared {
        const e = self.map.claim(id);
        if (!e.hit) {
            if (!r.articles.fetchTid(snap, tid)) pg.ereport("engine list: walked article not found at its heap pointer");
            e.v.* = self.fromRow(r, snap);
        }
        return e.v.*;
    }

    /// As get, for an article just read into r.articles (found by slug): a miss writes the fragments from
    /// that row instead of descending articles_pkey again.
    pub fn getPositioned(self: *Memo, r: *R.Rels, snap: pg.Snapshot, id: i64) ?Shared {
        const e = self.map.claim(id);
        if (!e.hit) e.v.* = self.fromRow(r, snap);
        return e.v.*;
    }

    fn byId(self: *Memo, r: *R.Rels, snap: pg.Snapshot, id: i64) ?Shared {
        if (!Bt.fetch(&r.articles, &r.articles_pkey, snap, i64, id)) return null;
        return self.fromRow(r, snap);
    }

    /// ItemPointerSetInvalid's TID: no heap pointer.
    const no_tid: c.ItemPointerData = .{ .ip_blkid = .{ .bi_hi = 0xffff, .bi_lo = 0xffff }, .ip_posid = 0 };

    /// An article staged by fill: where its fragments go, its heap pointer when a walk gave one, the leaves
    /// its reads start from, and, once its row is read, the head so far and its author's fragment.
    const Pending = struct {
        slot: *?Shared,
        id: i64,
        tid: c.ItemPointerData, // block InvalidBlockNumber: none, read through articles_pkey from art_leaf
        art_leaf: u32 = c.InvalidBlockNumber,
        at_leaf: u32 = undefined,
        fav_leaf: u32 = undefined,
        part: ?Part = null,
        author: *?[]const u8 = undefined,
    };

    /// Reads every article of `ids` the memo lacks, as get, or getAt where `tids` (empty, or one per id)
    /// gives its heap pointer, would read it, but staged over up to 64 articles at a time: first every
    /// index leaf they need is found (Bt.leafOf: at_pkey's for the tags, fav_article's for the count,
    /// articles_pkey's where there is no heap pointer) and their rows requested, then the rows read and
    /// each new author's users_pkey leaf found, then the authors read and the fragments written. Each
    /// stage's pages load together instead of one after another.
    pub fn fill(self: *Memo, r: *R.Rels, snap: pg.Snapshot, ids: []const i64, tids: []const c.ItemPointerData) void {
        var ps: [64]Pending = undefined;
        var i: usize = 0;
        while (i < ids.len) {
            c.shim_check_interrupts();
            self.map.reserve(ps.len);
            var n: usize = 0;
            while (i < ids.len and n < ps.len) : (i += 1) {
                const e = self.map.claim(ids[i]);
                if (e.hit) continue;
                ps[n] = .{ .slot = e.v, .id = ids[i], .tid = if (tids.len > 0) tids[i] else no_tid };
                n += 1;
            }
            self.stage(r, snap, ps[0..n]);
        }
    }

    fn stage(self: *Memo, r: *R.Rels, snap: pg.Snapshot, ps: []Pending) void {
        for (ps) |*p| {
            if (pg.tidBlock(&p.tid) == c.InvalidBlockNumber) p.art_leaf = Bt.leafOf(&r.articles_pkey, r.articles.rel, i64, p.id);
            p.at_leaf = Bt.leafOf(&r.at_pkey, r.article_tags.rel, i64, p.id);
            p.fav_leaf = Bt.leafOf(&r.fav_article, r.favorites.rel, i64, p.id);
        }
        pg.prefetchRows(r.articles.rel, ps);
        for (0..Bt.AIM_STEPS) |s| for (ps) |*p| {
            if (pg.tidBlock(&p.tid) == c.InvalidBlockNumber) Bt.aim(&r.articles_pkey, p.art_leaf, i64, p.id, @intCast(s));
            Bt.aim(&r.at_pkey, p.at_leaf, i64, p.id, @intCast(s));
            Bt.aim(&r.fav_article, p.fav_leaf, i64, p.id, @intCast(s));
        };
        // the rows' line pointers have loaded during the steps above
        for (ps) |*p| if (pg.tidBlock(&p.tid) != c.InvalidBlockNumber) pg.prefetchTuple(r.articles.rel, p.tid);

        self.authors.map.reserve(ps.len);
        var authors: [64]struct { slot: *?[]const u8, id: i64, leaf: u32 } = undefined;
        var na: usize = 0;
        for (ps) |*p| {
            if (pg.tidBlock(&p.tid) != c.InvalidBlockNumber) {
                if (!r.articles.fetchTid(snap, p.tid)) pg.ereport("engine list: walked article not found at its heap pointer");
            } else if (!Bt.fetchAt(&r.articles, &r.articles_pkey, snap, i64, p.id, p.art_leaf)) {
                p.slot.* = null;
                continue;
            }
            p.part = self.begin(r);
            const e = self.authors.map.claim(p.part.?.author_id);
            p.author = e.v;
            if (e.hit) continue;
            authors[na] = .{ .slot = e.v, .id = p.part.?.author_id, .leaf = Bt.leafOf(&r.users_pkey, r.users.rel, i64, p.part.?.author_id) };
            na += 1;
        }

        for (0..Bt.AIM_STEPS) |s| for (authors[0..na]) |a| Bt.aim(&r.users_pkey, a.leaf, i64, a.id, @intCast(s));
        for (authors[0..na]) |a| a.slot.* = Authors.read(r, snap, a.id, a.leaf);
        for (ps) |*p| {
            const part = &(p.part orelse continue);
            self.writeTags(&part.head, r, snap, p.id, p.at_leaf);
            p.slot.* = finish(r, snap, part, p.author.*, p.fav_leaf);
        }
    }

    /// Writes the fragments of the article just read into r.articles. null if the author is gone
    /// (unreachable under one snapshot by the FK).
    fn fromRow(self: *Memo, r: *R.Rels, snap: pg.Snapshot) ?Shared {
        var part = self.begin(r);
        self.writeTags(&part.head, r, snap, part.id, null);
        return finish(r, snap, &part, self.authors.get(r, snap, part.author_id), null);
    }

    /// An article's head up to its tag list, and the columns the rest of its fragments need.
    const Part = struct { id: i64, author_id: i64, created: i64, updated: i64, head: J.Buf };

    /// The Part of the article just read into r.articles.
    fn begin(self: *Memo, r: *R.Rels) Part {
        const s = &S.schema;
        const a = &r.articles;
        var head = J.Buf.init(if (self.shape == .full) 2048 else 512);
        head.raw("{\"slug\":");
        J.escapeJson(&head, a.textAt(s.attno("articles", "slug")).?);
        head.raw(",\"title\":");
        J.escapeJson(&head, a.textAt(s.attno("articles", "title")).?);
        head.raw(",\"description\":");
        J.escapeJson(&head, a.textAt(s.attno("articles", "description")).?);
        if (self.shape == .full) {
            head.raw(",\"body\":");
            J.escapeJson(&head, a.textAt(s.attno("articles", "body")).?);
        }
        head.byte(',');
        return .{
            .id = a.i64At(s.attno("articles", "id")),
            .author_id = a.i64At(s.attno("articles", "author_id")),
            .created = a.i64At(s.attno("articles", "created_at")),
            .updated = a.i64At(s.attno("articles", "updated_at")),
            .head = head,
        };
    }

    /// The fragments of `part`, its tag list written, given its author's fragment (null: the author is not
    /// visible, and neither is the article), its fav_article count starting at `fav_leaf` unless it is null.
    fn finish(r: *R.Rels, snap: pg.Snapshot, part: *Part, author: ?[]const u8, fav_leaf: anytype) ?Shared {
        part.head.raw(",\"createdAt\":");
        J.writeTimestamp(&part.head, part.created);
        part.head.raw(",\"updatedAt\":");
        J.writeTimestamp(&part.head, part.updated);

        const au = author orelse return null;
        var mid = J.Buf.init(au.len + 32);
        mid.raw(",\"favoritesCount\":");
        mid.int(Bt.countAt(&r.favorites, &r.fav_article, snap, i64, part.id, std.math.maxInt(i64), fav_leaf));
        mid.raw(au);
        return .{ .id = part.id, .author_id = part.author_id, .head = part.head.slice(), .mid = mid.slice() };
    }

    /// `"tagList":[...]`, names sorted with varstr_cmp under tags.name's collation (what ORDER BY t.name
    /// does), bytewise where collate.zig allows. Each tag's name is read once per execution.
    /// The at_pkey walk starts at `leaf` (Bt.leafOf) unless it is null.
    fn writeTags(self: *Memo, buf: *J.Buf, r: *R.Rels, snap: pg.Snapshot, article_id: i64, leaf: anytype) void {
        var ids: [64]i32 = undefined;
        const tag_ids = Bt.valuesAt(&r.article_tags, &r.at_pkey, snap, i64, .{ .lo = article_id, .hi = article_id }, i32, &ids, leaf) orelse
            pg.ereport("article has more than 64 tags");
        var tags: [64]Tag = undefined;
        var n: usize = 0;
        for (tag_ids) |tag_id| {
            const e = self.tags.claim(tag_id);
            if (!e.hit) e.v.* = tagById(r, snap, tag_id);
            tags[n] = e.v.* orelse continue;
            n += 1;
        }

        const coll = S.schema.tag_collation;
        const fast = Coll.bytewise(coll);
        const xs = tags[0..n];
        var i: usize = 1;
        while (i < xs.len) : (i += 1) {
            const x = xs[i];
            var j = i;
            while (j > 0 and after(xs[j - 1], x, coll, fast)) : (j -= 1)
                xs[j] = xs[j - 1];
            xs[j] = x;
        }
        buf.raw("\"tagList\":[");
        for (xs, 0..) |t, k| {
            if (k > 0) buf.byte(',');
            buf.raw(t.json);
        }
        buf.byte(']');
    }

    /// Whether tag a sorts after tag b under `coll` (bytewise when `fast` allows and both are plain).
    fn after(a: Tag, b: Tag, coll: c.Oid, fast: bool) bool {
        if (fast and a.plain and b.plain) return std.mem.order(u8, a.name, b.name) == .gt;
        return c.varstr_cmp(a.name.ptr, @intCast(a.name.len), b.name.ptr, @intCast(b.name.len), coll) > 0;
    }
};
