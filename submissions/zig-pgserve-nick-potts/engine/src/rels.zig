//! The tables and indexes the read engine walks, held open for the backend's life, the per-execution state
//! of the ones each endpoint reads, plus the slug lookup shared by every endpoint that takes a `:slug`.

const std = @import("std");
const c = @import("pg_c");
const pg = @import("pg.zig");
const S = @import("schema.zig");
const Bt = @import("btree.zig");

/// Catalog name of each index field. A table field is named after its table.
const index_names = .{
    .slug = "articles_slug_key",
    .articles_pkey = "articles_pkey",
    .articles_author = "articles_author_idx",
    .users_pkey = "users_pkey",
    .username = "users_username_key",
    .at_pkey = "article_tags_pkey",
    .at_tag = "article_tags_tag_idx",
    .tags_pkey = "tags_pkey",
    .tags_name = "tags_name_key",
    .fav_pkey = "favorites_pkey",
    .fav_article = "favorites_article_idx",
    .follows_pkey = "follows_pkey",
    .comments_article = "comments_article_idx",
};

pub const Rels = struct {
    articles: pg.Table,
    users: pg.Table,
    article_tags: pg.Table,
    tags: pg.Table,
    favorites: pg.Table,
    follows: pg.Table,
    comments: pg.Table,
    slug: pg.Index,
    articles_pkey: pg.Index,
    articles_author: pg.Index,
    users_pkey: pg.Index,
    username: pg.Index,
    at_pkey: pg.Index,
    at_tag: pg.Index,
    tags_pkey: pg.Index,
    tags_name: pg.Index,
    fav_pkey: pg.Index,
    fav_article: pg.Index,
    follows_pkey: pg.Index,
    comments_article: pg.Index,
    /// Sets up just the relations named in `need` (field names); the other fields stay undefined and are
    /// never touched.
    pub fn open(comptime need: anytype) Rels {
        var r: Rels = undefined;
        inline for (need) |f| {
            if (@TypeOf(@field(r, f)) == pg.Table)
                @field(r, f) = pg.Table.of(held.tables[comptime S.tableIndex(f)])
            else
                @field(r, f) = pg.Index.of(held.indexes[comptime S.indexIndex(@field(index_names, f))]);
        }
        return r;
    }

    pub fn close(self: *Rels, comptime need: anytype) void {
        inline for (need) |f| @field(self, f).close();
    }
};

/// Every table and index in schema.zig, open for the backend's life under a resource owner of the
/// engine's own, in schema order. An execution reads these pointers instead of opening and closing each
/// relation it reads, which cost a relcache lookup and a resource-owner entry apiece. engine.zig opens
/// them once its session locks are held and closes them whenever the locks go (abort, a schema change,
/// backend exit), so none is held open without its lock. A relcache entry held open is rebuilt in place
/// by an invalidation, so a pointer stays good.
var held: struct {
    tables: [S.schema.rel.len]pg.Relation = undefined,
    indexes: [S.schema.idx.len]pg.Relation = undefined,
    ntables: usize = 0,
    nindexes: usize = 0,
} = .{};
var owner: c.ResourceOwner = null;

pub fn isOpen() bool {
    return held.nindexes == held.indexes.len;
}

/// Opens every relation of `s` under the engine's resource owner, with NoLock: the caller holds the locks.
pub fn openAll(s: *const S.Schema) void {
    if (owner == null) owner = c.ResourceOwnerCreate(null, "pgengine");
    const prev = c.CurrentResourceOwner;
    c.CurrentResourceOwner = owner;
    for (s.rel) |oid| {
        held.tables[held.ntables] = @ptrCast(@alignCast(c.shim_table_open(oid)));
        held.ntables += 1;
    }
    for (s.idx) |oid| {
        held.indexes[held.nindexes] = @ptrCast(@alignCast(c.shim_index_open(oid)));
        held.nindexes += 1;
    }
    c.CurrentResourceOwner = prev;
}

/// Closes what openAll opened, all of it or as far as it got.
pub fn closeAll() void {
    const prev = c.CurrentResourceOwner;
    c.CurrentResourceOwner = owner;
    for (held.tables[0..held.ntables]) |rel| c.shim_close(rel, false);
    for (held.indexes[0..held.nindexes]) |rel| c.shim_close(rel, true);
    held.ntables = 0;
    held.nindexes = 0;
    c.CurrentResourceOwner = prev;
}

/// The article id a SPEC slug carries: every slug is SLUGIFY(title) || '-' || id, written by Postgres's
/// int8 output (no sign, no leading zeros). Returns null for anything else.
pub fn slugId(slug: []const u8) ?i64 {
    var i = slug.len;
    while (i > 0 and slug[i - 1] >= '0' and slug[i - 1] <= '9') i -= 1;
    const digits = slug[i..];
    if (digits.len == 0 or digits.len > 18 or digits[0] == '0' or i == 0 or slug[i - 1] != '-') return null;
    var v: i64 = 0;
    for (digits) |d| v = v * 10 + (d - '0');
    return v;
}

/// Reads into r.articles the article whose slug is exactly `want`. Tries the id the slug
/// carries through articles_pkey (an int8 descent) and accepts it only if the stored slug is byte-equal,
/// which under the column's deterministic collation is slug equality. Otherwise walks articles_slug_key,
/// so a slug that does not end in its own id is still found exactly.
pub fn findBySlug(r: *Rels, snap: pg.Snapshot, want: []const u8) bool {
    return findBySlugAt(r, snap, want, null);
}

/// findBySlug, its articles_pkey walk starting at `leaf` (slugLeaf's, in this execution) unless it is null.
pub fn findBySlugAt(r: *Rels, snap: pg.Snapshot, want: []const u8, leaf: anytype) bool {
    const s = &S.schema;
    if (slugId(want)) |id| {
        if (Bt.fetchAt(&r.articles, &r.articles_pkey, snap, i64, id, leaf)) {
            if (std.mem.eql(u8, r.articles.textAt(s.attno("articles", "slug")).?, want)) return true;
        }
    }
    return Bt.fetch(&r.articles, &r.slug, snap, Bt.TextKey, Bt.TextKey.of(want, s.slug_collation));
}

/// The articles_pkey leaf (Bt.leafOf) of the id slug `want` carries, found ahead of findBySlugAt so that
/// several slugs' leaves load together; InvalidBlockNumber when it carries none.
pub fn slugLeaf(r: *Rels, want: []const u8) u32 {
    const id = slugId(want) orelse return c.InvalidBlockNumber;
    return Bt.leafOf(&r.articles_pkey, r.articles.rel, i64, id);
}

/// The id of the article with this slug, visible under the snapshot, or null, its articles_pkey walk
/// starting at `leaf` (slugLeaf's) unless it is null. Used by endpoints that need only the id (comments).
pub fn articleIdBySlug(r: *Rels, snap: pg.Snapshot, slug: []const u8, leaf: anytype) ?i64 {
    const s = &S.schema;
    if (!findBySlugAt(r, snap, slug, leaf)) return null;
    return r.articles.i64At(s.attno("articles", "id"));
}

test "slugId reads the id suffix SPEC slugs carry" {
    try std.testing.expectEqual(@as(?i64, 42), slugId("how-to-train-42"));
    try std.testing.expectEqual(@as(?i64, 1), slugId("x-1"));
    try std.testing.expectEqual(@as(?i64, null), slugId("no-suffix"));
    try std.testing.expectEqual(@as(?i64, null), slugId("leading-zero-042"));
    try std.testing.expectEqual(@as(?i64, null), slugId("123"));
    try std.testing.expectEqual(@as(?i64, null), slugId("dash-"));
    try std.testing.expectEqual(@as(?i64, null), slugId(""));
}
