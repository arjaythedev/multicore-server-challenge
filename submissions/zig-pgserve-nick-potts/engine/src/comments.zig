//! GET /api/articles/:slug/comments, batched. Request fields: viewer (int8), slug (text).
//!
//! Per member: the article id by slug (NOT_FOUND when missing), then the newest 100 comments in
//! comments_article_idx order (article_id, created_at DESC, id DESC), each with its author's profile and
//! the viewer's following flag. Members reading the same article share one walk of its thread.
//!
//! Byte layout of one Comment (the reference server's key order):
//!   head   {"id":N,"createdAt":..,"updatedAt":..,"body":..,"author":{"username":..,"bio":..,"image":..
//!   flag   ,"following":true|false
//!   tail   }}

const std = @import("std");
const c = @import("pg_c");
const pg = @import("pg.zig");
const S = @import("schema.zig");
const J = @import("jsonbuf.zig");
const R = @import("rels.zig");
const E = @import("enrich.zig");
const A = @import("alloc.zig");
const Bt = @import("btree.zig");
const IdMap = @import("idmap.zig").IdMap;

pub const rels = [_][]const u8{ "articles", "articles_pkey", "slug", "comments", "comments_article", "users", "users_pkey", "follows", "follows_pkey" };

const LIMIT = 100;

const Comment = struct { author_id: i64, head: []const u8 };
/// `lo`..`hi` spans the comment authors' ids, the range a viewer's follows are read over.
const Thread = struct { items: []const Comment, bytes: usize, lo: i64, hi: i64 };

/// The newest LIMIT comments of an article whose author is visible (the reference JOIN drops the rest
/// and keeps counting toward its LIMIT), as viewer-independent fragments. Staged, a comment's author is
/// left for readThread to write after the walk (`bufs` holds each head so far); serial, it is written
/// here, and a comment whose author is not visible is skipped.
const ThreadReader = struct {
    r: *R.Rels,
    snap: pg.Snapshot,
    staged: bool,
    items: []Comment,
    bufs: []J.Buf,
    n: usize = 0,
    bytes: usize = 0,
    lo: i64 = std.math.maxInt(i64),
    hi: i64 = std.math.minInt(i64),

    /// The comment just read into r.comments. True once LIMIT are read.
    pub fn row(self: *ThreadReader) bool {
        const s = &S.schema;
        const cm = &self.r.comments;
        const author_id = cm.i64At(s.attno("comments", "author_id"));
        const body = cm.textAt(s.attno("comments", "body")).?;
        var buf = J.Buf.init(body.len + 320);
        buf.raw("{\"id\":");
        buf.int(cm.i64At(s.attno("comments", "id")));
        buf.raw(",\"createdAt\":");
        J.writeTimestamp(&buf, cm.i64At(s.attno("comments", "created_at")));
        buf.raw(",\"updatedAt\":");
        J.writeTimestamp(&buf, cm.i64At(s.attno("comments", "updated_at")));
        buf.raw(",\"body\":");
        J.escapeJson(&buf, body);
        if (self.staged) {
            self.bufs[self.n] = buf;
        } else {
            if (!E.writeAuthor(&buf, self.r, self.snap, author_id, null)) return false;
            self.bytes += buf.len;
        }
        self.items[self.n] = .{ .author_id = author_id, .head = buf.slice() };
        self.lo = @min(self.lo, author_id);
        self.hi = @max(self.hi, author_id);
        self.n += 1;
        return self.n == LIMIT;
    }
};

/// A thread the batch reads: where it goes, and, through its stages, its comments_article leaf and its
/// comments with their authors' users_pkey leaves.
const Pending = struct { id: i64, slot: *Thread, leaf: u32 = undefined, t: ThreadReader = undefined, leaves: []u32 = &.{} };

/// The batch's threads read in stages, each stage's pages loading together instead of one thread or one
/// comment after another: every thread's comments_article leaf is found (Bt.leafOf), then the threads'
/// comments read without their authors, then every author's users_pkey leaf found, then the authors
/// written.
fn readThreads(r: *R.Rels, snap: pg.Snapshot, ps: []Pending) void {
    for (ps) |*p| p.leaf = Bt.leafOf(&r.comments_article, r.comments.rel, i64, p.id);
    for (0..Bt.AIM_STEPS) |s| for (ps) |p| Bt.aim(&r.comments_article, p.leaf, i64, p.id, @intCast(s));
    for (ps) |*p| {
        c.shim_check_interrupts();
        p.t = .{ .r = r, .snap = snap, .staged = true, .items = A.alloc(Comment, LIMIT), .bufs = A.alloc(J.Buf, LIMIT) };
        Bt.rowsAt(&r.comments, &r.comments_article, snap, i64, .{ .lo = p.id, .hi = p.id }, &p.t, p.leaf);
    }
    for (ps) |*p| {
        p.leaves = A.alloc(u32, p.t.n);
        for (p.t.items[0..p.t.n], p.leaves) |it, *leaf| leaf.* = Bt.leafOf(&r.users_pkey, r.users.rel, i64, it.author_id);
    }
    for (0..Bt.AIM_STEPS) |s| for (ps) |p| for (p.t.items[0..p.t.n], p.leaves) |it, leaf| Bt.aim(&r.users_pkey, leaf, i64, it.author_id, @intCast(s));
    for (ps) |*p| p.slot.* = withAuthors(r, snap, p);
}

/// Pending thread `p`'s authors written from their leaves.
fn withAuthors(r: *R.Rels, snap: pg.Snapshot, p: *Pending) Thread {
    const t = &p.t;
    const items = t.items[0..t.n];
    for (items, t.bufs[0..t.n], p.leaves) |*it, *buf, leaf| {
        // A comment whose author is not visible is dropped and the next one counts toward LIMIT, which
        // only the serial read can do. Under one snapshot the foreign key on author_id rules it out.
        if (!E.writeAuthor(buf, r, snap, it.author_id, leaf)) return readSerial(r, snap, p.id);
        it.head = buf.slice();
        t.bytes += buf.len;
    }
    return .{ .items = items, .bytes = t.bytes, .lo = t.lo, .hi = t.hi };
}

fn readSerial(r: *R.Rels, snap: pg.Snapshot, article_id: i64) Thread {
    var t: ThreadReader = .{ .r = r, .snap = snap, .staged = false, .items = A.alloc(Comment, LIMIT), .bufs = &.{} };
    Bt.rows(&r.comments, &r.comments_article, snap, i64, .{ .lo = article_id, .hi = article_id }, &t);
    return .{ .items = t.items[0..t.n], .bytes = t.bytes, .lo = t.lo, .hi = t.hi };
}

/// The batch is read in stages, as readThreads reads its threads: every slug's articles_pkey leaf is found
/// (R.slugLeaf), then the articles read; then the threads; then each member's follows leaf, then its
/// follows walked and its comments written.
pub fn run(x: *c.EngineExec, r: *R.Rels, snap: pg.Snapshot) void {
    const viewers = x.params[0];
    const slugs = x.params[1];
    const n: usize = @intCast(x.nreq);

    const slug_leaves = A.alloc(u32, n);
    for (0..n) |i| slug_leaves[i] = R.slugLeaf(r, pg.text(slugs.texts[i]));
    const ids = A.alloc(?i64, n);
    for (0..n) |i| {
        c.shim_check_interrupts();
        ids[i] = R.articleIdBySlug(r, snap, pg.text(slugs.texts[i]), slug_leaves[i]);
    }

    // init(n) leaves room for n claims, so no claim moves a slot a Pending holds
    var threads = IdMap(Thread).init(n);
    const ps = A.alloc(Pending, n);
    var np: usize = 0;
    for (ids) |maybe| {
        const id = maybe orelse continue;
        const e = threads.claim(id);
        if (e.hit) continue;
        ps[np] = .{ .id = id, .slot = e.v };
        np += 1;
    }
    readThreads(r, snap, ps[0..np]);

    const fol_leaves = A.alloc(u32, n);
    for (0..n) |i| {
        const id = ids[i] orelse continue;
        const viewer: i64 = @bitCast(viewers.values[i]);
        const t = threads.claim(id).v.*;
        fol_leaves[i] = if (viewer == 0 or t.lo > t.hi) c.InvalidBlockNumber else Bt.leafOf(&r.follows_pkey, r.follows.rel, [2]i64, .{ viewer, t.lo });
    }
    for (0..Bt.AIM_STEPS) |s| for (0..n) |i| {
        const id = ids[i] orelse continue;
        const viewer: i64 = @bitCast(viewers.values[i]);
        const t = threads.claim(id).v.*;
        if (viewer != 0 and t.lo <= t.hi) Bt.aim(&r.follows_pkey, fol_leaves[i], [2]i64, .{ viewer, t.lo }, @intCast(s));
    };

    for (0..n) |i| {
        c.shim_check_interrupts();
        const viewer: i64 = @bitCast(viewers.values[i]);
        const id = ids[i] orelse {
            x.out[i] = .{ .status = c.ST_NOT_FOUND, .body = 0 };
            continue;
        };
        const t = threads.claim(id).v.*;
        const fols = E.Links.read(&r.follows, &r.follows_pkey, snap, viewer, t.lo, t.hi, E.linkCap(t.items.len), fol_leaves[i]);
        var buf = J.Buf.initBytea(t.bytes + t.items.len * 24 + 16);
        buf.raw("{\"comments\":[");
        for (t.items, 0..) |cmt, k| {
            if (k > 0) buf.byte(',');
            buf.raw(cmt.head);
            buf.raw(if (fols.has(snap, cmt.author_id)) ",\"following\":true}}" else ",\"following\":false}}");
        }
        buf.raw("]}");
        x.out[i] = .{ .status = c.ST_OK, .body = buf.finishBytea() };
    }
}
