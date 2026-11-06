//! GET /api/user, batched. Request fields: user id (int8), the token the request presented (text).
//!
//! Per member: the user by id, or NOT_FOUND (the server answers 401). The token is written back as
//! presented, so the body is the finished response.
//!   {"user":{"email":..,"token":..,"username":..,"bio":..,"image":..}}

const c = @import("pg_c");
const pg = @import("pg.zig");
const S = @import("schema.zig");
const J = @import("jsonbuf.zig");
const R = @import("rels.zig");
const Bt = @import("btree.zig");
const E = @import("enrich.zig");

pub const rels = [_][]const u8{ "users", "users_pkey" };

pub fn run(x: *c.EngineExec, r: *R.Rels, snap: pg.Snapshot) void {
    const s = &S.schema;
    const ids = x.params[0];
    const tokens = x.params[1];
    const n: usize = @intCast(x.nreq);
    for (0..n) |i| {
        c.shim_check_interrupts();
        if (!Bt.fetch(&r.users, &r.users_pkey, snap, i64, @bitCast(ids.values[i]))) {
            x.out[i] = .{ .status = c.ST_NOT_FOUND, .body = 0 };
            continue;
        }
        const token = pg.text(tokens.texts[i]);
        var buf = J.Buf.initBytea(token.len + 320);
        buf.raw("{\"user\":{\"email\":");
        J.escapeJson(&buf, r.users.textAt(s.attno("users", "email")).?);
        buf.raw(",\"token\":");
        J.escapeJson(&buf, token);
        buf.byte(',');
        E.writeProfileFields(&buf, r);
        buf.raw("}}");
        x.out[i] = .{ .status = c.ST_OK, .body = buf.finishBytea() };
    }
}
