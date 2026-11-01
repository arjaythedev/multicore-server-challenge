//! pgengine: the Zig engine loaded into Postgres 18.
//!
//! The engine owns the domain model, the batched index walks and the byte-exact response encoders.
//! The thin C shim (shim/) owns module magic, error longjmp, plan-node construction and the handful of
//! Postgres macros that Zig's translate-c cannot render. See shim/pgengine.h for the boundary.

const std = @import("std");
const c = @import("pg_c");
const schema = @import("schema.zig");
const pg = @import("pg.zig");
const article = @import("article.zig");
const list = @import("list.zig");
const comments = @import("comments.zig");
const profile = @import("profile.zig");
const user = @import("user.zig");
const tags = @import("tags.zig");
const R = @import("rels.zig");
const E = @import("enrich.zig");

comptime {
    _ = @import("serve.zig");
}

pub const VERSION = "0.4.0";

export fn engine_version() callconv(.c) [*:0]const u8 {
    return VERSION;
}

export fn engine_validate_schema() callconv(.c) ?[*:0]const u8 {
    return schema.resolve();
}

/// Set by the relcache callback when any relation the engine reads (or every relation) is invalidated.
/// The next execution re-resolves and re-verifies the schema before touching a table.
var stale = false;

export fn engine_relcache_inval(relid: u32) callconv(.c) void {
    if (relid == 0) {
        stale = true;
        return;
    }
    for (schema.schema.rel) |o| if (o == relid) {
        stale = true;
        return;
    };
    for (schema.schema.idx) |o| if (o == relid) {
        stale = true;
        return;
    };
}

/// From its first execution on, the backend holds AccessShareLock on every relation the engine reads at
/// session level, and those relations open (rels.zig, with NoLock): no lock-table entry, fast-path slot,
/// invalidation check or relcache lookup per relation per execution, and nothing to release at commit.
/// Invalidations are still read at every transaction start. While an engine backend is connected, nothing
/// that conflicts with AccessShareLock (DROP, TRUNCATE, ALTER TABLE, VACUUM FULL, REINDEX) can run on
/// those relations. An aborted transaction releases session locks with its own, and the relations are
/// closed with them, so the next execution takes both again.
var locked = false;
var held: schema.Schema = .{};

fn sessionLocks(comptime lock: bool) void {
    inline for (.{ &held.rel, &held.idx }) |oids| for (oids) |oid| {
        var id: c.LockRelId = .{ .relId = oid, .dbId = c.MyDatabaseId };
        if (lock) c.LockRelationIdForSession(&id, c.AccessShareLock) else c.UnlockRelationIdForSession(&id, c.AccessShareLock);
    };
}

/// The relations rels.zig holds open go with the locks.
export fn engine_session_locks_released() callconv(.c) void {
    R.closeAll();
    locked = false;
}

export fn engine_session_unlock() callconv(.c) void {
    R.closeAll();
    if (!locked) return;
    sessionLocks(false);
    locked = false;
}

export fn engine_exec(x: *c.EngineExec) callconv(.c) void {
    while (stale or !locked) {
        if (stale) {
            stale = false;
            if (schema.resolve()) |why| {
                stale = true;
                c.shim_ereport_schema(why);
            }
            if (locked and !std.meta.eql(held, schema.schema)) engine_session_unlock();
        }
        if (!locked) {
            held = schema.schema;
            sessionLocks(true);
            locked = true;
            // a change committed before the locks were granted marks the schema stale here
            c.AcceptInvalidationMessages();
        }
    }
    if (!R.isOpen()) R.openAll(&held);
    const snap: pg.Snapshot = @ptrCast(@alignCast(x.snapshot));
    if (x.endpoint == c.EP_MEGA) return mega(x, snap);
    switch (x.endpoint) {
        inline 0...c.EP_MEGA - 1 => |e| serve(endpoints[e].rels, endpoints[e].run, endpoints[e].lead, x, snap),
        else => unreachable, // the shim only plans the endpoints it names
    }
}

/// Each endpoint's relations, run and leading arguments, by endpoint id.
const endpoints = .{
    .{ .rels = article.rels, .run = article.run, .lead = .{} },
    .{ .rels = list.rels(.all), .run = list.run, .lead = .{list.Filter.all} },
    .{ .rels = list.rels(.tag), .run = list.run, .lead = .{list.Filter.tag} },
    .{ .rels = list.rels(.author), .run = list.run, .lead = .{list.Filter.author} },
    .{ .rels = list.rels(.favorited), .run = list.run, .lead = .{list.Filter.favorited} },
    .{ .rels = list.rels(.feed), .run = list.run, .lead = .{list.Filter.feed} },
    .{ .rels = comments.rels, .run = comments.run, .lead = .{} },
    .{ .rels = profile.rels, .run = profile.run, .lead = .{} },
    .{ .rels = user.rels, .run = user.run, .lead = .{} },
    .{ .rels = tags.rels, .run = tags.run, .lead = .{} },
};

comptime {
    std.debug.assert(endpoints.len == c.EP_MEGA);
}

/// engine_mega: a batch of every endpoint's requests, which the shim split by endpoint (x.subs). Every
/// relation is set up once, each endpoint runs over its own requests, the list endpoints share one memo
/// of article fragments, and each request's output is gathered back into input order.
fn mega(x: *c.EngineExec, snap: pg.Snapshot) void {
    const all = comptime std.meta.fieldNames(R.Rels);
    var r = R.Rels.open(all);
    defer r.close(all);
    const subs: [*]c.EngineExec = @ptrCast(x.subs);
    var lists = E.Memo.init(@intCast(x.nreq), .list);
    inline for (endpoints, 0..) |e, k| {
        const sub = &subs[k];
        if (sub.nreq > 0) {
            if (comptime e.lead.len == 1 and @TypeOf(e.lead[0]) == list.Filter)
                list.runWith(e.lead[0], &lists, sub, &r, snap)
            else
                @call(.auto, e.run, e.lead ++ .{ sub, &r, snap });
        }
    }
    for (0..@intCast(x.nreq)) |i| x.out[i] = subs[@intCast(x.kind[i])].out[@intCast(x.pos[i])];
}

/// Sets up the endpoint's relations, runs it over the batch, releases what the run kept.
inline fn serve(comptime need: anytype, comptime run: anytype, comptime lead: anytype, x: *c.EngineExec, snap: pg.Snapshot) void {
    var r = R.Rels.open(need);
    defer r.close(need);
    @call(.auto, run, lead ++ .{ x, &r, snap });
}
