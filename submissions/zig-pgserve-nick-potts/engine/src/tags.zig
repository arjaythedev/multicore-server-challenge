//! GET /api/tags, batched. A request's one field is not read.
//!
//! Every member gets the same bytes: all tag names in tags_name_key order, which is `ORDER BY name`
//! under the column's collation (the btree compares with the same varstr_cmp). Built once per execution
//! and shared by every row.
//!   {"tags":[..]}

const c = @import("pg_c");
const pg = @import("pg.zig");
const J = @import("jsonbuf.zig");
const R = @import("rels.zig");
const Bt = @import("btree.zig");

pub const rels = [_][]const u8{ "tags", "tags_name" };

pub fn run(x: *c.EngineExec, r: *R.Rels, snap: pg.Snapshot) void {
    var buf = J.Buf.initBytea(4096);
    buf.raw("{\"tags\":[");
    // index-only: names come from tags_name_key's tuples; the heap is read only for pages the visibility
    // map does not mark all-visible, as IndexOnlyNext does
    var names = struct {
        buf: *J.Buf,
        first: bool = true,

        pub fn entry(self: *@This(), name: Bt.Text, _: c.ItemPointerData) bool {
            if (!self.first) self.buf.byte(',');
            self.first = false;
            J.escapeJson(self.buf, pg.detoastText(@intFromPtr(name.ptr)));
            return false;
        }
    }{ .buf = &buf };
    Bt.visible(&r.tags, &r.tags_name, snap, void, null, Bt.Text, .forward, &names);
    buf.raw("]}");
    const body = buf.finishBytea();
    for (0..@as(usize, @intCast(x.nreq))) |i| x.out[i] = .{ .status = c.ST_OK, .body = body };
}
