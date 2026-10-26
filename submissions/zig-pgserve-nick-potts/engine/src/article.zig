//! GET /api/articles/:slug, batched. One output row per request, in request order.
//!
//! Per member: the article by slug, then its shared fragments (tags, favorites count, author) and the
//! viewer's two flags. Members asking for the same article within a batch share one walk of it.
//!
//! The batch is read in stages, so that each stage's pages load together instead of one member after
//! another: every article its slug's id names, through Memo.fill; then every viewer's flag leaves
//! (E.flagLeaves); then the flags, member by member.

const std = @import("std");
const c = @import("pg_c");
const pg = @import("pg.zig");
const J = @import("jsonbuf.zig");
const R = @import("rels.zig");
const S = @import("schema.zig");
const E = @import("enrich.zig");
const A = @import("alloc.zig");
const Bt = @import("btree.zig");

pub const rels = E.rels ++ [_][]const u8{"slug"};

/// The article whose slug is exactly `want`, as R.findBySlug finds it: the article the slug's id names
/// (which fill put in the memo) when its slug is `want`, else the one articles_slug_key gives. null when
/// none is visible (or its author is gone).
fn find(memo: *E.Memo, r: *R.Rels, snap: pg.Snapshot, want: []const u8) ?E.Shared {
    if (R.slugId(want)) |id| if (memo.get(r, snap, id)) |a| if (E.hasSlug(&a, want)) return a;
    const s = &S.schema;
    if (!Bt.fetch(&r.articles, &r.slug, snap, Bt.TextKey, Bt.TextKey.of(want, s.slug_collation))) return null;
    return memo.getPositioned(r, snap, r.articles.i64At(s.attno("articles", "id")));
}

pub fn run(x: *c.EngineExec, r: *R.Rels, snap: pg.Snapshot) void {
    const viewers = x.params[0];
    const slugs = x.params[1];
    const n: usize = @intCast(x.nreq);
    var memo = E.Memo.init(n, .full);

    const ids = A.alloc(i64, n);
    var m: usize = 0;
    for (0..n) |i| if (R.slugId(pg.text(slugs.texts[i]))) |id| {
        ids[m] = id;
        m += 1;
    };
    memo.fill(r, snap, ids[0..m], &.{});

    const got = A.alloc(?E.Shared, n);
    const leaves = A.alloc(E.FlagLeaves, n);
    for (0..n) |i| {
        c.shim_check_interrupts();
        got[i] = find(&memo, r, snap, pg.text(slugs.texts[i]));
        if (got[i]) |*a| leaves[i] = E.flagLeaves(r, @bitCast(viewers.values[i]), a);
    }
    for (0..Bt.AIM_STEPS) |s| for (0..n) |i| if (got[i]) |*a| E.aimFlags(r, @bitCast(viewers.values[i]), a, leaves[i], @intCast(s));

    for (0..n) |i| {
        const a = &(got[i] orelse {
            x.out[i] = .{ .status = c.ST_NOT_FOUND, .body = 0 };
            continue;
        });
        var buf = J.Buf.initBytea(a.head.len + a.mid.len + 64);
        buf.raw("{\"article\":");
        E.write(&buf, a, E.flagsAt(r, snap, @bitCast(viewers.values[i]), a, leaves[i]));
        buf.byte('}');
        x.out[i] = .{ .status = c.ST_OK, .body = buf.finishBytea() };
    }
}
