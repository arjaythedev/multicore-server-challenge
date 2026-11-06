//! The schema the engine reads, as data, and its resolution against the live catalog.
//!
//! `spec` is schema.sql restated: every table the engine touches, each column it reads with its type,
//! nullability and (for text) whether it must carry the database's default collation, and every index
//! it walks with its exact key columns and sort direction. `resolve` checks the live `public` schema
//! against it column by column and index by index. Any difference is a reason string; the shim turns
//! that into an ERROR at load, so a connection with a moved or retyped column never starts.
//!
//! Attribute numbers come from the catalog, not from schema.sql's column order, so the hot path reads
//! `schema.articles.slug` and never assumes a position.

const c = @import("pg_c");
const std = @import("std");
const Coll = @import("collate.zig");
const pg = @import("pg.zig");

const INT8 = 20;
const INT4 = 23;
const TEXT = 25;
const TIMESTAMPTZ = 1184;
const DEFAULT_COLLATION = 100;
const BTREE_AM = 403;
const HEAP_AM = 2; // HEAP_TABLE_AM_OID: btree.zig checks visibility with heap_hot_search_buffer
const INTEGER_BTREE_FAMILY = 1976;
const TEXT_BTREE_FAMILY = 1994; // text_ops: bttextcmp, varstr_cmp under the column's collation

const Col = struct { name: [:0]const u8, typ: u32, notnull: bool };

fn col(name: [:0]const u8, typ: u32, notnull: bool) Col {
    return .{ .name = name, .typ = typ, .notnull = notnull };
}

const Table = struct { name: [:0]const u8, cols: []const Col };

/// Index key column with its direction. `desc` mirrors pg_index.indoption bit 0.
const Key = struct { col: [:0]const u8, desc: bool = false };
const Index = struct { name: [:0]const u8, table: [:0]const u8, keys: []const Key };

const tables = [_]Table{
    .{ .name = "users", .cols = &.{
        col("id", INT8, true),     col("username", TEXT, true), col("email", TEXT, true),
        col("password_hash", TEXT, true), col("bio", TEXT, false), col("image", TEXT, false),
        col("created_at", TIMESTAMPTZ, true),
    } },
    .{ .name = "follows", .cols = &.{
        col("follower_id", INT8, true), col("followee_id", INT8, true), col("created_at", TIMESTAMPTZ, true),
    } },
    .{ .name = "articles", .cols = &.{
        col("id", INT8, true),     col("slug", TEXT, true),     col("author_id", INT8, true),
        col("title", TEXT, true),  col("description", TEXT, true), col("body", TEXT, true),
        col("created_at", TIMESTAMPTZ, true), col("updated_at", TIMESTAMPTZ, true),
    } },
    .{ .name = "tags", .cols = &.{ col("id", INT4, true), col("name", TEXT, true) } },
    .{ .name = "article_tags", .cols = &.{ col("article_id", INT8, true), col("tag_id", INT4, true) } },
    .{ .name = "favorites", .cols = &.{
        col("user_id", INT8, true), col("article_id", INT8, true), col("created_at", TIMESTAMPTZ, true),
    } },
    .{ .name = "comments", .cols = &.{
        col("id", INT8, true),        col("article_id", INT8, true), col("author_id", INT8, true),
        col("body", TEXT, true),      col("created_at", TIMESTAMPTZ, true), col("updated_at", TIMESTAMPTZ, true),
    } },
};

const indexes = [_]Index{
    .{ .name = "users_pkey", .table = "users", .keys = &.{.{ .col = "id" }} },
    .{ .name = "users_username_key", .table = "users", .keys = &.{.{ .col = "username" }} },
    .{ .name = "follows_pkey", .table = "follows", .keys = &.{ .{ .col = "follower_id" }, .{ .col = "followee_id" } } },
    .{ .name = "articles_pkey", .table = "articles", .keys = &.{.{ .col = "id" }} },
    .{ .name = "articles_slug_key", .table = "articles", .keys = &.{.{ .col = "slug" }} },
    .{ .name = "articles_author_idx", .table = "articles", .keys = &.{ .{ .col = "author_id" }, .{ .col = "id", .desc = true } } },
    .{ .name = "tags_pkey", .table = "tags", .keys = &.{.{ .col = "id" }} },
    .{ .name = "tags_name_key", .table = "tags", .keys = &.{.{ .col = "name" }} },
    .{ .name = "article_tags_pkey", .table = "article_tags", .keys = &.{ .{ .col = "article_id" }, .{ .col = "tag_id" } } },
    .{ .name = "article_tags_tag_idx", .table = "article_tags", .keys = &.{ .{ .col = "tag_id" }, .{ .col = "article_id" } } },
    .{ .name = "favorites_pkey", .table = "favorites", .keys = &.{ .{ .col = "user_id" }, .{ .col = "article_id" } } },
    .{ .name = "favorites_article_idx", .table = "favorites", .keys = &.{.{ .col = "article_id" }} },
    .{ .name = "comments_article_idx", .table = "comments", .keys = &.{ .{ .col = "article_id" }, .{ .col = "created_at", .desc = true }, .{ .col = "id", .desc = true } } },
};

/// Resolved per backend at load. The hot path reads OIDs and attnums from here by name.
pub const Schema = struct {
    rel: [tables.len]u32 = undefined,
    idx: [indexes.len]u32 = undefined,
    att: [tables.len][8]i16 = undefined,
    /// Collation of tags.name, used to sort tagList exactly as `ORDER BY t.name` does.
    tag_collation: u32 = 0,
    /// Collation of the slug and username index keys, used to build equality scan keys.
    slug_collation: u32 = 0,
    username_collation: u32 = 0,
    tagname_collation: u32 = 0,

    pub fn attno(self: *const Schema, comptime table: []const u8, comptime column: []const u8) i16 {
        const t = comptime tableIndex(table);
        return self.att[t][comptime colIndex(t, column)];
    }
};

pub var schema: Schema = .{};

pub fn tableIndex(comptime name: []const u8) usize {
    inline for (tables, 0..) |t, i| if (comptime std.mem.eql(u8, t.name, name)) return i;
    @compileError("unknown table " ++ name);
}
pub fn indexIndex(comptime name: []const u8) usize {
    inline for (indexes, 0..) |x, i| if (comptime std.mem.eql(u8, x.name, name)) return i;
    @compileError("unknown index " ++ name);
}
fn colIndex(comptime t: usize, comptime name: []const u8) usize {
    inline for (tables[t].cols, 0..) |cc, i| if (comptime std.mem.eql(u8, cc.name, name)) return i;
    @compileError("unknown column " ++ name);
}

var reason_buf: [512]u8 = undefined;

fn fail(comptime fmt: []const u8, args: anytype) [*:0]const u8 {
    const s = std.mem.printSentinel(&reason_buf, fmt, args, 0) catch "schema mismatch (reason truncated)";
    return s.ptr;
}

fn attrName(a: *const c.ShimAttr) []const u8 {
    return std.mem.sliceTo(&a.name, 0);
}

/// Checks the live schema against `spec` and fills `schema`. Returns null, or why it refuses.
pub fn resolve() ?[*:0]const u8 {
    for (tables, 0..) |t, ti| {
        const oid = c.shim_relid(t.name.ptr);
        if (oid == 0) return fail("table public.{s} does not exist", .{t.name});
        if (!c.shim_can_select(oid)) return fail("no SELECT privilege on table public.{s}", .{t.name});
        schema.rel[ti] = oid;
        const rel = c.shim_rel_open(oid);
        defer c.shim_rel_close(rel);
        const am = @as(c.Relation, @ptrCast(@alignCast(rel))).*.rd_rel.*.relam;
        if (am != HEAP_AM) return fail("table {s} has access method {d}, want heap", .{ t.name, am });
        const natts: usize = @intCast(c.shim_rel_natts(rel));
        var live: [16]c.ShimAttr = undefined;
        var nlive: usize = 0;
        var i: c_int = 0;
        while (i < natts) : (i += 1) {
            var a: c.ShimAttr = undefined;
            c.shim_rel_attr(rel, i, &a);
            if (a.typid == 0) continue; // dropped column
            if (nlive == live.len) return fail("table {s} has more than 16 columns", .{t.name});
            live[nlive] = a;
            nlive += 1;
        }
        if (nlive != t.cols.len)
            return fail("table {s} has {d} columns, schema.sql has {d}", .{ t.name, nlive, t.cols.len });
        for (t.cols, 0..) |want, ci| {
            const got = for (live[0..nlive]) |*a| {
                if (std.mem.eql(u8, attrName(a), want.name)) break a;
            } else return fail("column {s}.{s} is missing", .{ t.name, want.name });
            if (got.typid != want.typ)
                return fail("column {s}.{s} has type oid {d}, want {d}", .{ t.name, want.name, got.typid, want.typ });
            if (got.notnull != want.notnull)
                return fail("column {s}.{s} NOT NULL is {}, want {}", .{ t.name, want.name, got.notnull, want.notnull });
            if (want.typ == TEXT and got.collation != DEFAULT_COLLATION)
                return fail("column {s}.{s} has collation {d}, want the database default", .{ t.name, want.name, got.collation });
            if (got.attnum > pg.Table.MAX_ATTNO) // pg.Table reads a row's first MAX_ATTNO attributes
                return fail("column {s}.{s} is attribute {d}, past the engine's {d}", .{ t.name, want.name, got.attnum, pg.Table.MAX_ATTNO });
            schema.att[ti][ci] = @intCast(got.attnum);
        }
    }
    for (indexes, 0..) |x, xi| {
        const oid = c.shim_relid(x.name.ptr);
        if (oid == 0) return fail("index public.{s} does not exist", .{x.name});
        schema.idx[xi] = oid;
        var info: c.ShimIndexInfo = undefined;
        c.shim_index_info(oid, &info);
        const ti = for (tables, 0..) |t, i| {
            if (std.mem.eql(u8, t.name, x.table)) break i;
        } else unreachable;
        if (info.indrelid != schema.rel[ti])
            return fail("index {s} is not on table {s}", .{ x.name, x.table });
        if (info.relam != BTREE_AM)
            return fail("index {s} has access method {d}, want btree", .{ x.name, info.relam });
        if (info.indnatts != x.keys.len)
            return fail("index {s} has {d} key columns, want {d}", .{ x.name, info.indnatts, x.keys.len });
        for (x.keys, 0..) |k, ki| {
            const ci = for (tables[ti].cols, 0..) |cc, i| {
                if (std.mem.eql(u8, cc.name, k.col)) break i;
            } else unreachable;
            if (info.indkey[ki] != schema.att[ti][ci])
                return fail("index {s} key {d} is attnum {d}, want {s} (attnum {d})", .{ x.name, ki + 1, info.indkey[ki], k.col, schema.att[ti][ci] });
            const typ = tables[ti].cols[ci].typ;
            if ((typ == INT4 or typ == INT8) and info.opfamily[ki] != INTEGER_BTREE_FAMILY)
                return fail("index {s} key {s} has operator family {d}, want integer_ops", .{ x.name, k.col, info.opfamily[ki] });
            if (typ == TEXT and info.opfamily[ki] != TEXT_BTREE_FAMILY)
                return fail("index {s} key {s} has operator family {d}, want text_ops", .{ x.name, k.col, info.opfamily[ki] });
            const desc = (info.indoption[ki] & 1) != 0;
            if (desc != k.desc)
                return fail("index {s} key {s} DESC is {}, want {}", .{ x.name, k.col, desc, k.desc });
        }
        if (std.mem.eql(u8, x.name, "articles_slug_key")) schema.slug_collation = info.collation0;
        if (std.mem.eql(u8, x.name, "users_username_key")) schema.username_collation = info.collation0;
        if (std.mem.eql(u8, x.name, "tags_name_key")) schema.tagname_collation = info.collation0;
    }
    schema.tag_collation = schema.tagname_collation;
    // collate.zig's test runs once per backend per collation: here, rather than in a request's first compare
    for ([_]u32{ schema.slug_collation, schema.username_collation, schema.tagname_collation }) |coll| _ = Coll.bytewise(coll);
    return null;
}

test "spec is self-consistent" {
    inline for (indexes) |x| {
        const ti = comptime tableIndex(x.table);
        inline for (x.keys) |k| _ = comptime colIndex(ti, k.col);
    }
}
