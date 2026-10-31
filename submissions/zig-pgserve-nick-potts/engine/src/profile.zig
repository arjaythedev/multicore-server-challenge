//! GET /api/profiles/:username, batched. Request fields: viewer (int8), username (text).
//!
//! Per member: the user by username (NOT_FOUND when missing) and the viewer's following flag. Members
//! naming the same user share one lookup. The batch is read in stages, each stage's pages loading
//! together: every distinct username's leaf (Bt.leafOf), then the users; every member's follows leaf, then
//! its flag.
//!   head   {"profile":{"username":..,"bio":..,"image":..
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

pub const rels = [_][]const u8{ "users", "username", "follows", "follows_pkey" };

const Profile = struct { id: i64, head: []const u8 };
/// One distinct username in the batch, and its profile or null when no such user.
const Found = struct { name: []const u8, user: ?Profile };

fn key(name: []const u8) Bt.TextKey {
    return Bt.TextKey.of(name, S.schema.username_collation);
}

/// The profile of user `name`, its users_username_key walk starting at `leaf` (Bt.leafOf).
fn lookup(r: *R.Rels, snap: pg.Snapshot, name: []const u8, leaf: u32) ?Profile {
    if (!Bt.fetchAt(&r.users, &r.username, snap, Bt.TextKey, key(name), leaf)) return null;
    const id = r.users.i64At(S.schema.attno("users", "id"));
    var buf = J.Buf.init(256);
    buf.raw("{\"profile\":{");
    E.writeProfileFields(&buf, r);
    return .{ .id = id, .head = buf.slice() };
}

pub fn run(x: *c.EngineExec, r: *R.Rels, snap: pg.Snapshot) void {
    const viewers = x.params[0];
    const names = x.params[1];
    const n: usize = @intCast(x.nreq);
    const seen = A.alloc(Found, n);
    const of = A.alloc(*const Found, n);
    var nseen: usize = 0;
    for (0..n) |i| {
        const name = pg.text(names.texts[i]);
        of[i] = for (seen[0..nseen]) |*e| {
            if (std.mem.eql(u8, e.name, name)) break e;
        } else blk: {
            seen[nseen] = .{ .name = name, .user = null };
            nseen += 1;
            break :blk &seen[nseen - 1];
        };
    }
    const name_leaves = A.alloc(u32, nseen);
    for (seen[0..nseen], name_leaves) |f, *leaf| leaf.* = Bt.leafOf(&r.username, r.users.rel, Bt.TextKey, key(f.name));
    for (seen[0..nseen], name_leaves) |*f, leaf| {
        c.shim_check_interrupts();
        f.user = lookup(r, snap, f.name, leaf);
    }

    const fol_leaves = A.alloc(u32, n);
    for (0..n) |i| {
        const viewer: i64 = @bitCast(viewers.values[i]);
        const u = of[i].user orelse continue;
        fol_leaves[i] = if (viewer == 0) c.InvalidBlockNumber else Bt.leafOf(&r.follows_pkey, r.follows.rel, [2]i64, .{ viewer, u.id });
    }
    for (0..Bt.AIM_STEPS) |s| for (0..n) |i| {
        const viewer: i64 = @bitCast(viewers.values[i]);
        const u = of[i].user orelse continue;
        if (viewer != 0) Bt.aim(&r.follows_pkey, fol_leaves[i], [2]i64, .{ viewer, u.id }, @intCast(s));
    };
    for (0..n) |i| {
        c.shim_check_interrupts();
        const viewer: i64 = @bitCast(viewers.values[i]);
        const u = of[i].user orelse {
            x.out[i] = .{ .status = c.ST_NOT_FOUND, .body = 0 };
            continue;
        };
        var buf = J.Buf.initBytea(u.head.len + 24);
        buf.raw(u.head);
        buf.raw(if (E.followsAt(r, snap, viewer, u.id, fol_leaves[i])) ",\"following\":true}}" else ",\"following\":false}}");
        x.out[i] = .{ .status = c.ST_OK, .body = buf.finishBytea() };
    }
}
