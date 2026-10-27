//! Optional homogeneous array mutations, always enclosed by the caller's durable
//! BEGIN/COMMIT. Original member encodings remain available for rollback + isolation.
const std = @import("std");
const pg = @import("pg.zig");
const sql = @import("sql.zig");
const I8 = pg.oid.int8;
const TX = pg.oid.text;
const I8A = pg.oid.int8_array;
const TA = pg.oid.text_array;

pub const base_id: u16 = sql.packed_id + 1;
const r = "WITH r AS MATERIALIZED (SELECT * FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY r(p1,p2,i)), ";
const users = "u AS MATERIALIZED (SELECT u.* FROM (SELECT DISTINCT p2 FROM r) k JOIN users u ON u.username=k.p2), ";
const articles = "a0 AS MATERIALIZED (SELECT a.* FROM (SELECT DISTINCT p2 FROM r) k JOIN articles a ON a.slug=k.p2), ";
const author = " JOIN users u ON u.id=a.author_id ";
const tags = "ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id=at.tag_id WHERE at.article_id=a.id ORDER BY t.name)";
const fields = "a.id,a.slug,a.title,a.description,a.created_at,a.updated_at," ++ tags ++ ",";
const tail = ",u.username,u.bio,u.image,EXISTS(SELECT 1 FROM follows f WHERE f.follower_id=r.p1 AND f.followee_id=a.author_id),a.body";
fn favorite(comptime add: bool) []const u8 {
    // Reconcile distinct targeted viewers once per article, including conflicts
    // committed outside this snapshot, rather than counting actual RETURNING rows.
    const delta = "delta AS MATERIALIZED (SELECT a0.id,count(DISTINCT x.p1) FILTER(WHERE " ++
        (if (add) "NOT " else "") ++
        "EXISTS(SELECT 1 FROM favorites f WHERE f.user_id=x.p1 AND f.article_id=a0.id)) AS n " ++
        "FROM r x JOIN a0 ON a0.slug=x.p2 GROUP BY a0.id), ";
    return r ++ articles ++ delta ++ (if (add)
        "ins AS (INSERT INTO favorites(user_id,article_id) SELECT DISTINCT r.p1,a0.id FROM r JOIN a0 ON a0.slug=r.p2 ORDER BY r.p1,a0.id ON CONFLICT DO NOTHING RETURNING article_id) "
    else
        "del AS (DELETE FROM favorites f USING r,a0 WHERE f.user_id=r.p1 AND f.article_id=a0.id AND a0.slug=r.p2 RETURNING f.article_id) ") ++
        "SELECT r.i," ++ fields ++ "(SELECT count(*) FROM favorites f WHERE f.article_id=a.id)" ++
        (if (add) "+" else "-") ++ "(SELECT d.n FROM delta d WHERE d.id=a.id)" ++ (if (add) ",true" else ",false") ++ tail ++
        " FROM r JOIN a0 a ON a.slug=r.p2" ++ author ++ "ORDER BY r.i";
}

pub const defs = [_]sql.Def{
    .{ .sql = r ++ users ++ "ins AS (INSERT INTO follows(follower_id,followee_id) SELECT DISTINCT r.p1,u.id FROM r JOIN u ON u.username=r.p2 ORDER BY r.p1,u.id ON CONFLICT DO NOTHING) SELECT r.i,u.username,u.bio,u.image FROM r JOIN u ON u.username=r.p2 ORDER BY r.i", .params = &.{ I8A, TA } },
    .{ .sql = r ++ users ++ "del AS (DELETE FROM follows f USING r,u WHERE f.follower_id=r.p1 AND f.followee_id=u.id AND u.username=r.p2) SELECT r.i,u.username,u.bio,u.image FROM r JOIN u ON u.username=r.p2 ORDER BY r.i", .params = &.{ I8A, TA } },
    .{ .sql = favorite(true), .params = &.{ I8A, TA } },
    .{ .sql = favorite(false), .params = &.{ I8A, TA } },
    .{ .sql = "WITH r AS MATERIALIZED (SELECT r.*,nextval(pg_get_serial_sequence('comments','id')) AS cid FROM unnest($1::int8[],$2::text[],$3::text[]) WITH ORDINALITY r(p1,p2,p3,i)), " ++ articles ++
        "ins AS (INSERT INTO comments(id,article_id,author_id,body) SELECT r.cid,a0.id,r.p1,r.p3 FROM r JOIN a0 ON a0.slug=r.p2 RETURNING id,body,created_at,updated_at,author_id) " ++
        "SELECT r.i,c.id,c.body,c.created_at,c.updated_at,u.username,u.bio,u.image FROM r JOIN ins c ON c.id=r.cid JOIN users u ON u.id=c.author_id ORDER BY r.i", .params = &.{ I8A, TA, TA } },
};

pub fn resultOids(comptime index: usize) []const u32 {
    return switch (index) {
        0, 1 => &.{ I8, TX, TX, TX },
        2, 3 => &([_]u32{I8} ++ sql.resultOids(sql.id(.article))[0..14].*),
        4 => &.{ I8, I8, TX, 1184, 1184, TX, TX, TX },
        else => unreachable,
    };
}

fn kind(k: @import("api.zig").Kind) ?u16 {
    return switch (k) {
        .follow => 0,
        .unfollow => 1,
        .favorite => 2,
        .unfavorite => 3,
        .comment_create => 4,
        else => null,
    };
}

/// Decode our own Enc's first Bind. Nulls/extra statements are not array eligible.
fn params(bytes: []const u8, n: usize) ?[3][]const u8 {
    if (bytes.len < 16 or bytes[0] != 'B' or bytes[5] != 0) return null;
    var pos = (std.mem.indexOfScalarPos(u8, bytes, 6, 0) orelse return null) + 1;
    if (bytes.len - pos < 6 or std.mem.readInt(u16, bytes[pos..][0..2], .big) != 1 or std.mem.readInt(u16, bytes[pos + 2 ..][0..2], .big) != 1 or std.mem.readInt(u16, bytes[pos + 4 ..][0..2], .big) != n) return null;
    pos += 6;
    var values: [3][]const u8 = @splat("");
    for (values[0..n]) |*value| {
        if (bytes.len - pos < 4) return null;
        const len = pg.i32Of(bytes[pos..]);
        pos += 4;
        if (len < 0 or len > bytes.len - pos) return null;
        value.* = bytes[pos..][0..@intCast(len)];
        pos += @intCast(len);
    }
    if (values[0].len != 8) return null;
    return values;
}

pub fn encode(e: *pg.Enc, members: anytype) bool {
    if (members.len < 2) return false;
    const index = kind(members[0].r.kind) orelse return false;
    var viewers: [128]i64 = undefined;
    var keys: [128][]const u8 = undefined;
    var bodies: [128][]const u8 = undefined;
    for (members, 0..) |*m, i| {
        if (m.k != 1 or kind(m.r.kind) != index) return false;
        const p = params(m.slice(), if (index == 4) 3 else 2) orelse return false;
        viewers[i] = pg.i64Of(p[0]);
        keys[i] = p[1];
        bodies[i] = p[2];
    }
    e.bind(base_id + index);
    e.pInt8Array(viewers[0..members.len]);
    e.pTextArray(keys[0..members.len]);
    if (index == 4) e.pTextArray(bodies[0..members.len]);
    e.exec();
    return true;
}
