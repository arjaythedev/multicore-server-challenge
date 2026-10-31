//! A per-execution map from a positive id to a value, so the members of one batch share work by id
//! (an article's fragments, an article's comment thread, a tag's name). Open addressing over a power-of-two
//! table kept at most half full, doubling when it would pass that; ids are positive, so 0 marks an empty
//! slot. Lives in the execution's memory context and dies with it.

const c = @import("pg_c");

pub fn IdMap(comptime V: type) type {
    return struct {
        ids: []i64,
        vals: []V,
        len: usize = 0,

        const Self = @This();

        pub fn init(capacity_hint: usize) Self {
            var n: usize = 16;
            while (n < capacity_hint * 2) n *= 2;
            const ids: [*]i64 = @ptrCast(@alignCast(c.shim_palloc0(n * @sizeOf(i64))));
            const vals: [*]V = @ptrCast(@alignCast(c.shim_palloc(n * @sizeOf(V))));
            return .{ .ids = ids[0..n], .vals = vals[0..n] };
        }

        /// The value slot for `id`. `hit` is false the first time: the id is now claimed and the caller
        /// must fill `v` before the next claim, which may move every slot.
        pub fn claim(self: *Self, id: i64) struct { v: *V, hit: bool } {
            if (2 * (self.len + 1) > self.ids.len) self.grow();
            const k = self.slot(id);
            if (self.ids[k] == id) return .{ .v = &self.vals[k], .hit = true };
            self.ids[k] = id;
            self.len += 1;
            return .{ .v = &self.vals[k], .hit = false };
        }

        /// Room for `n` more claims without moving any slot.
        pub fn reserve(self: *Self, n: usize) void {
            while (2 * (self.len + n) > self.ids.len) self.grow();
        }

        /// The slot holding `id`, or the empty slot where it belongs.
        fn slot(self: *const Self, id: i64) usize {
            const mask = self.ids.len - 1;
            var h: usize = @intCast((@as(u64, @bitCast(id)) *% 0x9E3779B97F4A7C15) >> 32);
            while (true) : (h +%= 1) {
                const k = h & mask;
                if (self.ids[k] == id or self.ids[k] == 0) return k;
            }
        }

        fn grow(self: *Self) void {
            const old = self.*;
            self.* = init(old.ids.len);
            for (old.ids, old.vals) |id, v| {
                if (id == 0) continue;
                const k = self.slot(id);
                self.ids[k] = id;
                self.vals[k] = v;
            }
            self.len = old.len;
        }
    };
}

test "IdMap keeps every id's value across growth" {
    const std = @import("std");
    var m = IdMap(i64).init(1);
    var id: i64 = 1;
    while (id <= 1000) : (id += 1) {
        const e = m.claim(id * 7919);
        try std.testing.expect(!e.hit);
        e.v.* = id;
    }
    try std.testing.expectEqual(@as(usize, 1000), m.len);
    try std.testing.expect(m.ids.len >= 2000);
    id = 1;
    while (id <= 1000) : (id += 1) {
        const e = m.claim(id * 7919);
        try std.testing.expect(e.hit);
        try std.testing.expectEqual(id, e.v.*);
    }
}
