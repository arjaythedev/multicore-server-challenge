//! Walks the engine's btree indexes by reading their pages, for loops where nbtree's general scan (scan
//! keys, fmgr comparisons, one call per tuple) costs more than the work.
//!
//! The page format is nbtree's (storage/bufpage.h, access/itup.h, access/nbtree.h): line pointers after
//! a 24-byte header, BTPageOpaqueData in the special space, data items from P_FIRSTDATAKEY, and posting
//! tuples (deduplication) holding several heap TIDs. Locking follows nbtree's own readers: a page is
//! share-locked while its entries are copied out, then only pinned while they are checked against the
//! heap. Moving right follows btpo_next and steps over half-dead and deleted pages (Lehman-Yao). A page
//! of an integer-keyed walk may instead be read without its lock, validated as a seqlock reader
//! validates (peeked), and read again under the lock when that fails.
//!
//! Keys are the index's leading columns: i32 or i64 for the first, [2]i64 for the first two, or a TextKey
//! for a text first column. Every integer key column the engine reads is int4 or int8 under the integer
//! btree opfamily and NOT NULL (schema.zig checks all three), so they compare as machine integers and sit
//! at fixed offsets. A text key compares with varstr_cmp under the index's collation, as bttextcmp does,
//! or bytewise where collate.zig shows that is the same.

const std = @import("std");
const c = @import("pg_c");
const pg = @import("pg.zig");
const Coll = @import("collate.zig");

const HEADER = 24; // SizeOfPageHeaderData; the line pointers follow
const PD_LOWER = 12;
const PD_SPECIAL = 16;
const LP_DEAD = 3;
const BTP_LEAF = 1 << 0;
const BTP_DELETED = 1 << 2;
const BTP_HALF_DEAD = 1 << 4;
const ALT_TID = 0x2000; // INDEX_AM_RESERVED_BIT of t_info
const IS_POSTING = 0x2000; // BT_IS_POSTING, in t_tid's offset number
const OFFSET_MASK = 0x0fff;
const KEY = 8; // MAXALIGN(sizeof(IndexTupleData)): where the first column starts in a tuple with no nulls
const MAX_TIDS = (c.BLCKSZ - HEADER - @sizeOf(c.BTPageOpaqueData)) / 6; // MaxTIDsPerBTreePage

const Page = PageOf(false);
/// A page read without its lock (peeked), possibly mid-change: its geometry is clamped to the page, which
/// never changes a valid page's reads and keeps a torn one from reading outside it.
const PeekPage = PageOf(true);

fn PageOf(comptime clamped: bool) type {
    return struct {
        p: [*]const u8,

        const Self = @This();
        /// Read without the lock: a reader of a page this type says is clamped refuses what only a torn read finds.
        const peeking = clamped;

        fn of(buf: c.Buffer) Self {
            return .{ .p = pg.pageOf(buf) };
        }
        fn u16At(self: Self, off: usize) u16 {
            return std.mem.readInt(u16, self.p[off..][0..2], .little);
        }
        fn opq(self: Self) *const c.BTPageOpaqueData {
            const special = self.u16At(PD_SPECIAL);
            return @ptrCast(@alignCast(self.p + if (clamped) @min(special, c.BLCKSZ - @sizeOf(c.BTPageOpaqueData)) else special));
        }
        fn maxOff(self: Self) u16 {
            const lower = self.u16At(PD_LOWER);
            return (if (clamped) @min(lower, c.BLCKSZ) -| HEADER else lower - HEADER) / 4;
        }
        /// ItemIdData: lp_off:15, lp_flags:2, lp_len:15, from the low bit.
        fn lp(self: Self, off: u16) u32 {
            return std.mem.readInt(u32, self.p[HEADER + (@as(usize, off) - 1) * 4 ..][0..4], .little);
        }
        fn dead(self: Self, off: u16) bool {
            return (self.lp(off) >> 15) & 3 == LP_DEAD;
        }
        /// Item `off`. Clamped: every item ends before the special space (16 bytes) and is at least 8 bytes
        /// long, so none starts past BLCKSZ - 24, and 24 bytes from there (the most an integer key compare
        /// reads) stay in the page.
        fn tuple(self: Self, off: u16) Tuple {
            return self.at(self.lp(off));
        }
        /// The item line pointer `id` points at.
        fn at(self: Self, id: u32) Tuple {
            return .{ .p = self.p + if (clamped) @min(id & 0x7fff, c.BLCKSZ - 24) else id & 0x7fff };
        }
        /// Appends leaf tuple `t`'s entries to `out`: one per heap TID (a posting tuple has several), each
        /// carrying the tuple's value column when V is not void. A Text value is copied into `arena`.
        /// Clamped, false instead when they would not fit in `out` or a posting list would run past the
        /// page, which only a torn read finds (a page holds at most MAX_TIDS).
        fn entries(self: Self, t: Tuple, comptime K: type, comptime V: type, out: *[MAX_TIDS]Entry(V), n: *usize, arena: []u8, used: *usize) bool {
            comptime std.debug.assert(!(clamped and V == Text)); // varSize would trust a torn length
            const val = switch (V) {
                void => {},
                Text => blk: {
                    const v = t.p + valueOffset(K, V);
                    const len = varSize(v);
                    @memcpy(arena[used.*..][0..len], v[0..len]);
                    used.* += len;
                    break :blk arena[used.* - len .. used.*];
                },
                else => t.col(V, valueOffset(K, V)),
            };
            if (!t.posting()) {
                if (clamped and n.* == MAX_TIDS) return false;
                out[n.*] = .{ .tid = tidAt(t.p), .val = val };
                n.* += 1;
                return true;
            }
            const cnt = t.u16At(4) & OFFSET_MASK;
            if (clamped and !self.holds(t, cnt, n.*)) return false;
            const list = t.p + t.block();
            for (0..cnt) |i| out[n.* + i] = .{ .tid = tidAt(list + i * 6), .val = val };
            n.* += cnt;
            return true;
        }
        /// Whether posting tuple `t`'s `cnt` heap TIDs lie inside the page and fit after `n` others.
        fn holds(self: Self, t: Tuple, cnt: usize, n: usize) bool {
            return n + cnt <= MAX_TIDS and (@intFromPtr(t.p) - @intFromPtr(self.p)) + @as(usize, t.block()) + cnt * 6 <= c.BLCKSZ;
        }
        fn rightmost(self: Self) bool {
            return self.opq().btpo_next == c.P_NONE;
        }
        fn ignore(self: Self) bool {
            return self.opq().btpo_flags & (BTP_DELETED | BTP_HALF_DEAD) != 0;
        }
        fn leaf(self: Self) bool {
            return self.opq().btpo_flags & BTP_LEAF != 0;
        }
        /// P_FIRSTDATAKEY: every page but the rightmost of its level starts with its high key.
        fn firstKey(self: Self) u16 {
            return if (self.rightmost()) 1 else 2;
        }
        /// The first item at or after `from` that is not below `key`, or maxOff + 1.
        fn lowerBound(self: Self, from: u16, comptime K: type, key: K) u16 {
            return self.bound(from, K, key, false);
        }
        /// The first item at or after `from` that is above `key`, or maxOff + 1.
        fn upperBound(self: Self, from: u16, comptime K: type, key: K) u16 {
            return self.bound(from, K, key, true);
        }
        /// The first item at or after `from` that is past `key` (upper: above it, else not below it), or
        /// maxOff + 1. An integer key places its first probes by interpolating its first column between
        /// items known to lie either side, where a binary search halves: on a page that is not in cache each
        /// probe is a dependent read, and the engine's keys (ids) spread evenly enough that two or three land
        /// next to the bound. The high key, which the descent's step has just read, is the first upper
        /// anchor. Only the comparisons narrow the range, so a poor guess (or a torn one, peeking) costs
        /// probes, never the answer.
        fn bound(self: Self, from: u16, comptime K: type, key: K, comptime upper: bool) u16 {
            var rd: Read = .{};
            return self.boundBy(from, K, key, upper, &rd).?;
        }
        /// bound, each item read through `rd.tuple(page, off)`; null when that stops the search (Aim).
        fn boundBy(self: Self, from: u16, comptime K: type, key: K, comptime upper: bool, rd: anytype) ?u16 {
            var lo = from;
            var hi = self.maxOff() + 1;
            if (K != TextKey and hi - lo > 8) {
                const want = lead(K, key) +| @intFromBool(upper and K != [2]i64);
                const t0 = rd.tuple(self, lo) orelse return null;
                if (past(K, t0, key, upper)) return lo;
                var al = lo;
                var vl = lead(K, t0);
                lo += 1;
                var ah = hi;
                var vh: i64 = undefined;
                if (self.rightmost()) {
                    const t = rd.tuple(self, hi - 1) orelse return null;
                    if (!past(K, t, key, upper)) return hi;
                    hi -= 1;
                    ah = hi;
                    vh = lead(K, t);
                } else vh = lead(K, rd.tuple(self, 1) orelse return null);
                var probes: u32 = 0;
                while (hi - lo > 4 and probes < 3) : (probes += 1) {
                    const g = guess(lo, hi, al, vl, ah, vh, want);
                    const t = rd.tuple(self, g) orelse return null;
                    if (past(K, t, key, upper)) {
                        hi = g;
                        ah = g;
                        vh = lead(K, t);
                    } else {
                        lo = g + 1;
                        al = g;
                        vl = lead(K, t);
                    }
                }
            }
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (past(K, rd.tuple(self, mid) orelse return null, key, upper)) hi = mid else lo = mid + 1;
            }
            return lo;
        }
        fn leftmost(self: Self) bool {
            return self.opq().btpo_prev == c.P_NONE;
        }
    };
}

/// bound's reader: every item read as it is.
const Read = struct {
    inline fn tuple(_: *Read, page: anytype, off: u16) ?Tuple {
        return page.tuple(off);
    }
};

/// aim's reader: the first `budget` items read (their lines requested by earlier steps), the next one's
/// line requested instead, which stops the search.
const Aim = struct {
    budget: u8,
    n: u8 = 0,

    inline fn tuple(self: *Aim, page: anytype, off: u16) ?Tuple {
        const t = page.tuple(off);
        if (self.n == self.budget) {
            @prefetch(t.p + KEY, .{});
            return null;
        }
        self.n += 1;
        return t;
    }
};

/// Steps of aim: the line pointers, the search's two anchors, then one probe a step.
pub const AIM_STEPS = 6;

/// Step `step` of requesting the lines leaf `blk`'s search for integer key `key` reads (lowerBound from
/// the first data item, as a walk landing there searches), for a batch of searches between leafOf and their
/// walks: each step runs over every search of the batch, so the batch's misses at one depth of the search
/// load together. Step 0 requests the page's line pointers (leafOf's request for the header has landed by
/// then), step 1 the two items the search reads first, each later step replays the search over the items
/// requested so far and requests the next. The page is read through the hints without a pin or lock, for
/// addresses only: a torn or stale page (clamped, as a peek is) costs wasted loads, and the walk reads the
/// page under its own protocol.
pub fn aim(idx: *pg.Index, blk: u32, comptime K: type, key: K, step: u8) void {
    comptime std.debug.assert(K != TextKey);
    const page: PeekPage = .{ .p = pg.hintedPage(idx.rel, blk) orelse return };
    switch (step) {
        0 => {
            const end = HEADER + @as(usize, page.maxOff()) * 4;
            var off: usize = 64;
            while (off < end) : (off += 64) @prefetch(page.p + off, .{});
        },
        1 => {
            const max = page.maxOff();
            if (max < 2) return;
            @prefetch(page.tuple(1).p + KEY, .{});
            @prefetch(page.tuple(2).p + KEY, .{});
            @prefetch(page.tuple(max).p + KEY, .{});
        },
        else => {
            var rd: Aim = .{ .budget = step };
            _ = page.boundBy(page.firstKey(), K, key, false, &rd);
        },
    }
}

/// IndexTupleData: t_tid (bi_hi, bi_lo, ip_posid) then t_info.
const Tuple = struct {
    p: [*]const u8,

    fn u16At(t: Tuple, off: usize) u16 {
        return std.mem.readInt(u16, t.p[off..][0..2], .little);
    }
    /// t_tid's block number: the heap block, a pivot's downlink, or a posting list's offset.
    fn block(t: Tuple) u32 {
        return @as(u32, t.u16At(0)) << 16 | t.u16At(2);
    }
    fn col(t: Tuple, comptime T: type, off: usize) T {
        return std.mem.readInt(T, t.p[off..][0..@sizeOf(T)], .little);
    }
    /// Key columns present. A pivot (high key or downlink) may have had trailing ones truncated away.
    fn natts(t: Tuple) u16 {
        const pivot = t.u16At(6) & ALT_TID != 0 and t.u16At(4) & IS_POSTING == 0;
        return if (pivot) t.u16At(4) & OFFSET_MASK else std.math.maxInt(u16);
    }
    fn posting(t: Tuple) bool {
        return t.u16At(6) & ALT_TID != 0 and t.u16At(4) & IS_POSTING != 0;
    }
};

fn tidAt(p: [*]const u8) c.ItemPointerData {
    var t: c.ItemPointerData = undefined;
    @memcpy(std.mem.asBytes(&t)[0..6], p[0..6]);
    return t;
}

/// A leaf entry: its heap TID and, unless V is void, a column's value (valueOffset says which).
pub fn Entry(comptime V: type) type {
    return struct { tid: c.ItemPointerData, val: V };
}

/// A text column's value: its varlena, any header form, copied off the page (valid during `visit`).
pub const Text = []const u8;

/// Where the value column sits: the first column for a walk with no key type (K void), else the second,
/// past the first at its own alignment (int4 'i', int8 'd').
fn valueOffset(comptime K: type, comptime V: type) usize {
    if (K == void) return KEY;
    const First = if (K == [2]i64) i64 else K;
    return std.mem.alignForward(usize, KEY + @sizeOf(First), if (V == Text) 1 else @alignOf(V));
}

/// VARSIZE_ANY of an in-line varlena: a 1-byte header (short) or a 4-byte one (plain or compressed).
/// Index tuples never hold TOAST pointers.
fn varSize(p: [*]const u8) usize {
    if (p[0] & 1 == 1) {
        if (p[0] == 1) pg.ereport("index tuple holds an external TOAST pointer");
        return p[0] >> 1;
    }
    return std.mem.readInt(u32, p[0..4], .little) >> 2;
}

/// A text key: its bytes, the collation of the index column it is compared with, and whether a plain entry
/// compares with it bytewise (collate.zig: the collation passed its test and the key is plain).
pub const TextKey = struct {
    s: []const u8,
    coll: c.Oid,
    fast: bool,

    pub fn of(s: []const u8, coll: c.Oid) TextKey {
        return .{ .s = s, .coll = coll, .fast = Coll.bytewise(coll) and Coll.plain(s) };
    }
};

/// The bytes of the in-line varlena at `p`, an index tuple's text column: a short or plain value, or a
/// compressed one (index_form_tuple compresses a large value in line), decompressed.
fn textOf(p: [*]const u8) []const u8 {
    if (p[0] & 1 == 1) {
        if (p[0] == 1) pg.ereport("index tuple holds an external TOAST pointer");
        return p[1 .. p[0] >> 1];
    }
    const hdr = std.mem.readInt(u32, p[0..4], .little);
    if (hdr & 3 == 0) return p[4 .. hdr >> 2];
    return pg.detoastText(@intFromPtr(p));
}

/// Entries from `lo` to `hi` inclusive, compared on the key's columns.
pub fn Range(comptime K: type) type {
    return struct { lo: K, hi: K };
}

/// Index order (forward) or its reverse.
pub const Dir = enum { forward, backward };

fn past(comptime K: type, t: Tuple, key: K, comptime upper: bool) bool {
    return if (upper) order(K, t, key) == .gt else order(K, t, key) != .lt;
}

/// An integer key's first column, which bound interpolates on.
fn lead(comptime K: type, v: anytype) i64 {
    const T = if (K == [2]i64) i64 else K;
    return if (@TypeOf(v) == Tuple) v.col(T, KEY) else if (K == [2]i64) v[0] else v;
}

/// Where `want` falls between item `al` (first column `vl`, below the bound) and item `ah` (`vh`, at or
/// past it), assuming the first column grows evenly between them, kept inside the range [lo, hi) still
/// open; the middle when `want` is not strictly inside (vl, vh] or the span is too wide to scale exactly.
inline fn guess(lo: u16, hi: u16, al: u16, vl: i64, ah: u16, vh: i64, want: i64) u16 {
    const mid = lo + (hi - lo) / 2;
    if (!(vl < want and want <= vh)) return mid;
    const d: u64 = @bitCast(want -% vl);
    const span: u64 = @bitCast(vh -% vl);
    if (span >> 50 != 0) return mid;
    const at = al + (d * (ah - al) + span - 1) / span; // d <= span, so at <= ah
    return @intCast(std.math.clamp(at, lo, hi - 1));
}

/// How tuple `t`'s leading columns compare with `key`. Columns past the key's are not compared, so a
/// one-column key is equal to every entry that starts with it. A truncated pivot column is minus infinity.
fn order(comptime K: type, t: Tuple, key: K) std.math.Order {
    if (K == TextKey) {
        const v = textOf(t.p + KEY);
        if (key.fast and Coll.plain(v)) return std.mem.order(u8, v, key.s);
        return std.math.order(c.varstr_cmp(v.ptr, @intCast(v.len), key.s.ptr, @intCast(key.s.len), key.coll), 0);
    }
    if (K == [2]i64) {
        const o = std.math.order(t.col(i64, KEY), key[0]);
        if (o != .eq) return o;
        if (t.natts() < 2) return .lt;
        return std.math.order(t.col(i64, KEY + 8), key[1]);
    }
    return std.math.order(t.col(K, KEY), key);
}

/// A pinned page of a descent; `kept` when its pin belongs to the index's pin cache.
const Held = struct { buf: c.Buffer, kept: bool };

/// Page `blk` pinned, through the execution's pin on it if there is one. Not locked.
fn pinPage(idx: *pg.Index, blk: u32) Held {
    for (idx.pins[0..idx.npins]) |p| if (p.blk == blk) return .{ .buf = p.buf, .kept = true };
    return .{ .buf = pg.readBuffer(idx.rel, blk, .index), .kept = false };
}

/// Share-locks a page pinPage pinned; a page newly read is checked as _bt_getbuf checks it, and its pin
/// goes to the cache if keep takes it.
fn lockPinned(idx: *pg.Index, blk: u32, h: Held) Held {
    c._bt_lockbuf(idx.rel, h.buf, c.BT_READ);
    if (h.kept) return h;
    c._bt_checkpage(idx.rel, h.buf);
    return keep(idx, blk, h.buf);
}

/// _bt_getbuf for a read, with the buffer found through pg.readBuffer.
fn getPage(rel: pg.Relation, blk: u32) c.Buffer {
    const buf = pg.readBuffer(rel, blk, .index);
    c._bt_lockbuf(rel, buf, c.BT_READ);
    c._bt_checkpage(rel, buf);
    return buf;
}

/// The root, read share-locked from where the relcache's copy of the metapage says it is, as _bt_getroot
/// reads it and with the same check that the copy is not stale. _bt_getroot itself when there is no copy
/// or it is stale, which also refreshes it. InvalidBuffer for an empty index.
fn getRoot(idx: *pg.Index, heap: pg.Relation) c.Buffer {
    if (@as(?*const c.BTMetaPageData, @ptrCast(@alignCast(idx.rel.*.rd_amcache)))) |meta| {
        const buf = getPage(idx.rel, meta.btm_fastroot);
        const o = Page.of(buf).opq();
        if (o.btpo_flags & (BTP_DELETED | BTP_HALF_DEAD) == 0 and o.btpo_level == meta.btm_fastlevel and
            o.btpo_prev == c.P_NONE and o.btpo_next == c.P_NONE) return buf;
        c._bt_relbuf(idx.rel, buf);
    }
    return c._bt_getroot(idx.rel, heap, c.BT_READ);
}

/// Hands an internal page's pin to the cache while there is room. Leaf pins are never kept: the walk
/// releases them as it goes, and VACUUM needs leaves unpinned to clean them.
fn keep(idx: *pg.Index, blk: u32, buf: c.Buffer) Held {
    if (idx.descents < 2 or Page.of(buf).leaf() or idx.npins == idx.pins.len) return .{ .buf = buf, .kept = false };
    idx.pins[idx.npins] = .{ .blk = blk, .buf = buf };
    idx.npins += 1;
    return .{ .buf = buf, .kept = true };
}

fn unlockPage(idx: *pg.Index, h: Held) void {
    if (h.kept) c._bt_unlockbuf(idx.rel, h.buf) else c._bt_relbuf(idx.rel, h.buf);
}

/// What a descent does at a page: move right to `right` (a concurrent split left the key there, or the
/// page is being deleted), go down to `down`, stop at this leaf, or nothing (a page being deleted with no
/// right sibling, which a locked read reports as an error).
const Step = union(enum) { right: u32, down: Down, leaf, stuck };
const Down = struct { blk: u32, leaf: bool };

/// The descent's step at `page`, as _bt_search takes it: right while `key` is past the high key
/// (backward, while it is not below it), then the child left of the first pivot >= key (backward, > key).
/// The first data item of an internal page is minus infinity, with no key.
inline fn stepAt(page: anytype, comptime K: type, key: ?K, comptime dir: Dir) Step {
    const keyed = K != void and key != null;
    const back = dir == .backward;
    if (!page.rightmost() and (page.ignore() or if (!keyed) back else if (back) order(K, page.tuple(1), key.?) != .gt else order(K, page.tuple(1), key.?) == .lt))
        return .{ .right = page.opq().btpo_next };
    if (page.ignore()) return .stuck;
    if (page.leaf()) return .leaf;
    const fk = page.firstKey();
    const child = if (!keyed) (if (back) page.maxOff() else fk) else if (back) page.upperBound(fk + 1, K, key.?) - 1 else page.lowerBound(fk + 1, K, key.?) - 1;
    return .{ .down = .{ .blk = page.tuple(child).block(), .leaf = page.opq().btpo_level == 1 } };
}

/// Runs `r.read(page)` on pinned page `buf` without its content lock and says whether what it read can be
/// trusted; when not, the caller reads the page again under the lock, and `read` starts over.
/// A seqlock reader's protocol, with the content lock's exclusive bit and the page LSN as the sequence:
/// every change to a page of a WAL-logged btree is made under the exclusive lock and sets the LSN before
/// the lock is released. The lock word is read, then the LSN, the page, the lock word, the LSN. If no
/// exclusive holder shows either time and the LSN is unchanged, no change overlapped the read: one that
/// began before the first look still held the lock then, one still running at the second look holds it
/// then, and one that began and ended between them set a new LSN before the second look at the lock, so
/// the last read sees it (x86 keeps loads in order, and stores visible in order). PageSetLSN stores the
/// LSN as two halves after the change's own stores, so a first look that catches only one of them still
/// comes after the whole change. What `read` found is then what a share-locked read would find. The one
/// change made under a share lock, _bt_killitems marking an item LP_DEAD, sets one bit of its line
/// pointer, and either value is right, as for a locked reader just before or after it.
///
/// `read` gets a PeekPage, whose clamped geometry keeps a torn read inside the page, and refuses (false)
/// whatever would write past its own buffers. It changes nothing a locked read would not redo, and never
/// compares a text key: varstr_cmp must not see a torn value.
inline fn peeked(buf: c.Buffer, r: anytype) bool {
    comptime std.debug.assert(@import("builtin").cpu.arch == .x86_64);
    const page = PeekPage.of(buf);
    const lsn: *const u64 = @ptrCast(@alignCast(page.p)); // pd_lsn, the page's first 8 bytes
    if (pg.lockedExclusive(buf)) return false;
    const l1 = @atomicLoad(u64, lsn, .acquire);
    // a page _bt_checkpage would refuse (new, or not a btree page) is left to the locked read, which refuses it
    if (page.u16At(PD_SPECIAL) != c.BLCKSZ - @sizeOf(c.BTPageOpaqueData)) return false;
    const ok = r.read(page);
    asm volatile ("" ::: .{ .memory = true }); // the page's loads stay before the second look
    return ok and !pg.lockedExclusive(buf) and @atomicLoad(u64, lsn, .acquire) == l1;
}

/// A descent's step at one page, for peeked: refused at a page being deleted with no right sibling, which
/// the locked read reports.
fn StepRead(comptime K: type, comptime dir: Dir) type {
    return struct {
        key: ?K,
        st: Step = undefined,

        fn read(self: *@This(), page: anytype) bool {
            self.st = stepAt(page, K, self.key, dir);
            return self.st != .stuck;
        }
    };
}

/// Forward, the leaf where entries equal to `key` start (or the one before it), or the leftmost leaf when
/// `key` is null; backward, the leaf where they end, or the rightmost. Pinned and not yet read: its reader
/// takes the descent's last step there (take), since a concurrent split may have moved the key right of
/// it. InvalidBuffer for an empty index. Like _bt_search it moves right while `key` is past a page's high
/// key (backward, while it is not below it), and over pages being deleted. A root that has split since
/// the execution first read it is still the leftmost page of its level, so starting there stays correct.
/// Pages are peeked (integer keys, WAL-logged indexes) and read under their lock only when the peek
/// cannot be trusted.
fn descend(idx: *pg.Index, heap: pg.Relation, comptime K: type, key: ?K, comptime dir: Dir) c.Buffer {
    return switch (descendTo(idx, heap, K, key, dir)) {
        .empty => c.InvalidBuffer,
        .leaf => |blk| pinLeaf(idx, blk),
        .root => |buf| buf,
    };
}

/// Leaf `blk` pinned for a walk: the index's kept leaf (pg.Index.leaf) when it is that page, its pin taken
/// over, else read.
fn pinLeaf(idx: *pg.Index, blk: u32) c.Buffer {
    if (idx.leaf_blk != blk) return pg.readBuffer(idx.rel, blk, .index);
    const buf = idx.leaf;
    idx.leaf = c.InvalidBuffer;
    idx.leaf_blk = c.InvalidBlockNumber;
    return buf;
}

/// The leaf `buf` a walk ended on, pinned and unlocked, kept as the index's leaf in place of the one kept
/// before.
fn keepLeaf(idx: *pg.Index, buf: c.Buffer) void {
    if (idx.leaf != c.InvalidBuffer) c.ReleaseBuffer(idx.leaf);
    idx.leaf = buf;
    idx.leaf_blk = c.BufferGetBlockNumber(buf);
}

/// Where a descent ends: the leaf it lands on, not yet pinned; the root, pinned, when the root is the only
/// level; nothing, in an empty index.
const Landing = union(enum) { empty, leaf: u32, root: c.Buffer };

/// The leaf a forward descent for `key` lands on, as descend finds it, not pinned, with the lines its reader
/// needs first requested (pg.prefetchIndexPage). Walks of several keys known in advance descend for all of
/// them first, so their leaves load together, then walk each from its leaf (visibleFrom).
/// InvalidBlockNumber for an empty index. The block stays a valid start for the rest of the execution: the
/// walk from it takes the descent's last step there, moving right past any split since, and a page deleted
/// meanwhile is not recycled while the execution's snapshot holds back the oldest xmin.
pub fn leafOf(idx: *pg.Index, heap: pg.Relation, comptime K: type, key: K) u32 {
    switch (descendTo(idx, heap, K, key, .forward)) {
        .empty => return c.InvalidBlockNumber,
        .leaf => |blk| {
            pg.prefetchIndexPage(idx.rel, blk);
            return blk;
        },
        .root => |buf| {
            const blk = c.BufferGetBlockNumber(buf);
            c.ReleaseBuffer(buf);
            return blk;
        },
    }
}

fn descendTo(idx: *pg.Index, heap: pg.Relation, comptime K: type, key: ?K, comptime dir: Dir) Landing {
    idx.descents += 1;
    const peeking = K != TextKey and idx.peek;
    var h: Held = undefined;
    var blk: u32 = idx.root;
    var locked = false;
    if (blk == c.InvalidBlockNumber) {
        const buf = getRoot(idx, heap);
        if (buf == c.InvalidBuffer) return .empty;
        blk = c.BufferGetBlockNumber(buf);
        idx.root = blk;
        h = keep(idx, blk, buf);
        locked = true;
    }
    while (true) {
        if (!locked) h = pinPage(idx, blk);
        var r: StepRead(K, dir) = .{ .key = key };
        if (locked or !peeking or !peeked(h.buf, &r)) {
            if (!locked) h = lockPinned(idx, blk, h);
            _ = r.read(Page.of(h.buf));
            if (r.st == .leaf) c._bt_unlockbuf(idx.rel, h.buf) else unlockPage(idx, h);
        } else if (r.st != .leaf and !h.kept and !keep(idx, blk, h.buf).kept) c.ReleaseBuffer(h.buf);
        locked = false;
        switch (r.st) {
            .leaf => return .{ .root = h.buf }, // never a kept pin: keep takes no leaf
            .right => |n| blk = n,
            .down => |d| {
                if (d.leaf) return .{ .leaf = d.blk };
                blk = d.blk;
            },
            .stuck => pg.ereport("btree walk fell off the end of an index"),
        }
    }
}

/// How a leaf reader takes a page: its entries; a step right to `right`, over a half-dead or deleted page
/// or, at the page a descent landed on, to where a concurrent split moved the key; the end of the index,
/// past a half-dead or deleted rightmost page; or stuck, a landing page being deleted with no right
/// sibling (or not a leaf, which only a torn read finds).
const Take = union(enum) { entries, right: u32, end, stuck };

/// How a reader takes leaf `page`: the page a descent landed on (`landing`) as the descent's last step
/// takes it, any other as nbtree's scans step over pages being deleted.
inline fn take(page: anytype, comptime K: type, key: ?K, comptime dir: Dir, landing: bool) Take {
    if (landing) return switch (stepAt(page, K, key, dir)) {
        .leaf => .entries,
        .right => |n| .{ .right = n },
        .down, .stuck => .stuck,
    };
    if (!page.ignore()) return .entries;
    return if (page.rightmost()) .end else .{ .right = page.opq().btpo_next };
}

/// One leaf page of a walk in `dir` order: its entries in range copied into `es` (forward from the low
/// key's lower bound on the landing page, else the first item, until past the high key; backward from the
/// high key's upper bound, or the last item, until below the low key), whether the walk ends with them, and
/// the link it goes on by. Backward, a page's entries are copied in reverse order, except that a posting
/// tuple's (one key's) stay in heap order. `read` starts from nothing each time, so a locked read after a
/// peek that could not be trusted keeps nothing of it.
fn Leaf(comptime K: type, comptime V: type, comptime dir: Dir) type {
    return struct {
        range: ?Range(K),
        landing: bool,
        es: *[MAX_TIDS]Entry(V),
        arena: []u8,
        got: Take = undefined,
        n: usize = 0,
        done: bool = false,
        link: u32 = 0,

        fn read(self: *@This(), page: anytype) bool {
            const keyed = K != void and self.range != null;
            const back = dir == .backward;
            self.n = 0;
            var used: usize = 0;
            self.got = take(page, K, if (keyed) (if (back) self.range.?.hi else self.range.?.lo) else null, dir, self.landing);
            if (self.got != .entries) return self.got != .stuck;
            const first = page.firstKey();
            const max = page.maxOff();
            if (back) {
                self.done = page.leftmost();
                self.link = page.opq().btpo_prev;
                var off = if (self.landing and keyed) page.upperBound(first, K, self.range.?.hi) - 1 else max;
                while (off >= first) : (off -= 1) {
                    const id = page.lp(off);
                    const t = page.at(id);
                    if (keyed and order(K, t, self.range.?.lo) == .lt) {
                        self.done = true;
                        break;
                    }
                    if ((id >> 15) & 3 != LP_DEAD and !page.entries(t, K, V, self.es, &self.n, self.arena, &used)) return false;
                }
            } else {
                self.done = page.rightmost();
                self.link = page.opq().btpo_next;
                var off = if (self.landing and keyed) page.lowerBound(first, K, self.range.?.lo) else first;
                while (off <= max) : (off += 1) {
                    const id = page.lp(off);
                    const t = page.at(id);
                    if (keyed and order(K, t, self.range.?.hi) == .gt) {
                        self.done = true;
                        break;
                    }
                    if ((id >> 15) & 3 != LP_DEAD and !page.entries(t, K, V, self.es, &self.n, self.arena, &used)) return false;
                }
            }
            return true;
        }
    };
}

/// Reads leaf `buf` (pinned) into `r`: peeked when the walk's key and value allow it, else (or when the
/// peek cannot be trusted) under its share lock, checked first as _bt_getbuf checks a page. Only a walk with
/// a key peeks: it takes a few entries from a page, where the lock costs more than the peek's clamped reads,
/// while a walk of the whole index takes every entry of every page. A landing page that leaves the reader
/// stuck is an error, as in a descent.
inline fn readLeaf(idx: *pg.Index, buf: c.Buffer, comptime K: type, comptime V: type, keyed: bool, r: anytype) void {
    if (K != TextKey and V != Text) if (keyed and idx.peek and peeked(buf, r)) return;
    c._bt_lockbuf(idx.rel, buf, c.BT_READ);
    c._bt_checkpage(idx.rel, buf);
    _ = r.read(Page.of(buf));
    c._bt_unlockbuf(idx.rel, buf);
    if (r.got == .stuck) pg.ereport("btree walk fell off the end of an index");
}

/// Walks the leaf entries in `range` (every entry when null) in `dir` order, one page at a time: each
/// page's entries are copied out (Leaf, under readLeaf) and handed to `v.visit` with the page only pinned.
/// `visit` returns true to stop. From the landing leaf's bound on, every entry is in range on that side:
/// forward, the descent left that leaf's high key at or above `lo` and the pages after it hold entries
/// above it; backward, the entries before the bound and the pages left of it are not above `hi`. Backward,
/// the pages left of the landing one come share-locked from prevLeaf.
fn walk(idx: *pg.Index, heap: pg.Relation, comptime K: type, range: ?Range(K), comptime V: type, comptime dir: Dir, v: anytype, start: anytype) void {
    const keyed = K != void and range != null;
    // `start` is null (descend) or a leaf block (leafOf's), told apart at compile time
    var buf = if (@TypeOf(start) == @TypeOf(null))
        descend(idx, heap, K, if (keyed) (if (dir == .backward) range.?.hi else range.?.lo) else null, dir)
    else if (start == c.InvalidBlockNumber) return else pinLeaf(idx, start);
    if (buf == c.InvalidBuffer) return;
    var es: [MAX_TIDS]Entry(V) = undefined;
    var arena: [if (V == Text) c.BLCKSZ else 0]u8 = undefined;
    var landing = true;
    var locked = false;
    while (true) {
        var r: Leaf(K, V, dir) = .{ .range = range, .landing = landing, .es = &es, .arena = &arena };
        if (locked) {
            _ = r.read(Page.of(buf));
            c._bt_unlockbuf(idx.rel, buf);
        } else readLeaf(idx, buf, K, V, keyed, &r);
        switch (r.got) {
            .entries => {},
            .right => |n| {
                c.ReleaseBuffer(buf);
                buf = pg.readBuffer(idx.rel, n, .index);
                continue;
            },
            .end => return keepLeaf(idx, buf),
            .stuck => unreachable,
        }
        const stop = v.visit(es[0..r.n]);
        if (stop or r.done) return keepLeaf(idx, buf);
        const cur = if (dir == .backward) c.BufferGetBlockNumber(buf) else undefined;
        c.ReleaseBuffer(buf);
        landing = false;
        if (dir == .forward) {
            buf = pg.readBuffer(idx.rel, r.link, .index);
        } else {
            buf = prevLeaf(idx, r.link, cur) orelse return;
            locked = true;
        }
    }
}

/// The first live leaf left of `cur`, share-locked, starting from `prev`, the left link `cur` had when it
/// was read; null when there is none. Half-dead pages are stepped over, as nbtree's backward scan steps
/// over them.
fn prevLeaf(idx: *pg.Index, prev: u32, cur: u32) ?c.Buffer {
    var blk = prev;
    var right = cur;
    while (blk != c.P_NONE) {
        const buf = leftOf(idx, blk, right) orelse return null;
        const page = Page.of(buf);
        if (!page.ignore()) return buf;
        right = c.BufferGetBlockNumber(buf);
        blk = page.opq().btpo_prev;
        c._bt_relbuf(idx.rel, buf);
    }
    return null;
}

/// nbtree's _bt_lock_and_validate_left: the page whose right link is `right`, share-locked, found from
/// `blk`, the left link `right` had when it was read; null when `right` has become the leftmost page. If
/// `blk` has split since, the page wanted is a few hops right of it. If not even that finds it, `right`
/// has been deleted (its live right sibling took over its key space, and the walk starts again from that
/// page's left link) or its left sibling has changed again (start again from the new link).
fn leftOf(idx: *pg.Index, from: u32, last: u32) ?c.Buffer {
    var blk = from;
    var right = last;
    var orig = blk;
    while (true) {
        var buf = getPage(idx.rel, blk);
        var tries: u32 = 0;
        while (true) {
            const o = Page.of(buf).opq();
            if (o.btpo_flags & BTP_DELETED == 0 and o.btpo_next == right) return buf;
            if (o.btpo_next == c.P_NONE or tries == 4) break;
            tries += 1;
            blk = o.btpo_next;
            c._bt_relbuf(idx.rel, buf);
            buf = getPage(idx.rel, blk);
        }
        c._bt_relbuf(idx.rel, buf);
        buf = getPage(idx.rel, right);
        var o = Page.of(buf).opq();
        if (o.btpo_flags & BTP_DELETED != 0) {
            while (o.btpo_flags & BTP_DELETED != 0) {
                if (o.btpo_next == c.P_NONE) pg.ereport("btree walk fell off the end of an index");
                right = o.btpo_next;
                c._bt_relbuf(idx.rel, buf);
                buf = getPage(idx.rel, right);
                o = Page.of(buf).opq();
            }
        } else if (o.btpo_prev == orig) pg.ereport("btree walk could not find a page's left sibling");
        if (o.btpo_prev == c.P_NONE) {
            c._bt_relbuf(idx.rel, buf);
            return null;
        }
        blk = o.btpo_prev;
        orig = blk;
        c._bt_relbuf(idx.rel, buf);
    }
}

/// Hands the entries of `idx` (an index on `tbl`) in `range` (every entry when null) that are visible
/// under `snap` to `v.entry(val, tid)`, in index order, until it returns true. `tid` is the entry's own
/// heap pointer, the root of the row's HOT chain.
///
/// Visible is IndexOnlyNext's test: the visibility map marks the heap block all-visible, or else the heap
/// holds a version visible under the snapshot. Each block's bit is read once per page: an entry on the
/// page was inserted after its heap tuple cleared that bit, so one read made after the page was read
/// covers every entry the page held.
pub fn visible(tbl: *pg.Table, idx: *pg.Index, snap: pg.Snapshot, comptime K: type, range: ?Range(K), comptime V: type, comptime dir: Dir, v: anytype) void {
    visibleAt(tbl, idx, snap, K, range, V, dir, v, null);
}

/// visible over `range` (forward, keyed), starting from leaf `start`, which leafOf gave for `range.lo` in
/// the same execution, instead of descending.
pub fn visibleFrom(tbl: *pg.Table, idx: *pg.Index, snap: pg.Snapshot, comptime K: type, range: Range(K), comptime V: type, v: anytype, start: u32) void {
    visibleAt(tbl, idx, snap, K, range, V, .forward, v, start);
}

fn visibleAt(tbl: *pg.Table, idx: *pg.Index, snap: pg.Snapshot, comptime K: type, range: ?Range(K), comptime V: type, comptime dir: Dir, v: anytype, start: anytype) void {
    const Pages = struct {
        tbl: *pg.Table,
        snap: pg.Snapshot,
        v: @TypeOf(v),

        fn visit(self: *@This(), es: []const Entry(V)) bool {
            var blk: u32 = c.InvalidBlockNumber;
            var all = false;
            var i: usize = 0;
            while (i < es.len) : (i += 1) {
                const e = &es[i];
                const b = pg.tidBlock(&e.tid);
                if (b != blk) {
                    blk = b;
                    all = self.tbl.allVisible(b);
                }
                if (!all) {
                    i += self.offVisible(es[i..], b) orelse return true;
                    continue;
                }
                if (self.v.entry(e.val, e.tid)) return true;
            }
            return false;
        }

        /// The run of entries at the start of `es` on heap block `b`, which is not all-visible: checked
        /// under one lock of the block, the visible ones handed on. Returns the entries the run held past
        /// the first, or null when the visitor stopped. Out of line, so the all-visible loop stays as small
        /// as it is with no such path.
        noinline fn offVisible(self: *@This(), es: []const Entry(V), b: u32) ?usize {
            var j: usize = 1;
            while (j < es.len and pg.tidBlock(&es[j].tid) == b) j += 1;
            pg.prefetchRows(self.tbl.rel, es[0..j]);
            for (es[0..j]) |e| pg.prefetchTuple(self.tbl.rel, e.tid);
            var ok: [MAX_TIDS]bool = undefined;
            self.tbl.visibleOn(self.snap, b, es[0..j], ok[0..j]);
            for (es[0..j], ok[0..j]) |*e, vis| if (vis and self.v.entry(e.val, e.tid)) return null;
            return j - 1;
        }
    };
    var p: Pages = .{ .tbl = tbl, .snap = snap, .v = v };
    walk(idx, tbl.rel, K, range, V, dir, &p, start);
}

/// Reads into `tbl` each row of `tbl` in `range` of `idx` visible under `snap`, in index order, and calls
/// `v.row()` on it until that returns true.
pub fn rows(tbl: *pg.Table, idx: *pg.Index, snap: pg.Snapshot, comptime K: type, range: Range(K), v: anytype) void {
    rowsAt(tbl, idx, snap, K, range, v, null);
}

/// rows, starting from leaf `start` (leafOf's, for `range.lo`, in this execution) unless it is null.
pub fn rowsAt(tbl: *pg.Table, idx: *pg.Index, snap: pg.Snapshot, comptime K: type, range: Range(K), v: anytype, start: anytype) void {
    const Pages = struct {
        tbl: *pg.Table,
        snap: pg.Snapshot,
        v: @TypeOf(v),

        fn visit(self: *@This(), es: []const Entry(void)) bool {
            pg.prefetchRows(self.tbl.rel, es);
            // each row's tuple requested a few rows ahead of its read, its line pointer by then loaded
            const ahead = 4;
            for (es[0..@min(ahead, es.len)]) |e| pg.prefetchTuple(self.tbl.rel, e.tid);
            for (es, 0..) |e, i| {
                if (i + ahead < es.len) pg.prefetchTuple(self.tbl.rel, es[i + ahead].tid);
                if (self.tbl.fetchTid(self.snap, e.tid) and self.v.row()) return true;
            }
            return false;
        }
    };
    var p: Pages = .{ .tbl = tbl, .snap = snap, .v = v };
    walk(idx, tbl.rel, K, range, void, .forward, &p, start);
}

/// Entries of `idx` (an index on `tbl`) visible under `snap` that equal `key`, or all entries when `key`
/// is null, counted up to `cap`. The walk is walk's, but an entry on a heap block the visibility map marks
/// all-visible is counted on the page as it is read, without being copied out; only the others are, and
/// the heap is checked for them with the page only pinned, as visible checks them. The map bit is read
/// after the entry, as visible reads it. The tally stops at `cap`, mid-page.
pub fn count(tbl: *pg.Table, idx: *pg.Index, snap: pg.Snapshot, comptime K: type, key: ?K, cap: i64) i64 {
    return countAt(tbl, idx, snap, K, key, cap, null);
}

/// count, starting from leaf `start` (leafOf's, for `key`, in this execution) unless it is null.
pub fn countAt(tbl: *pg.Table, idx: *pg.Index, snap: pg.Snapshot, comptime K: type, key: ?K, cap: i64, start: anytype) i64 {
    var buf = if (@TypeOf(start) == @TypeOf(null))
        descend(idx, tbl.rel, K, key, .forward)
    else if (start == c.InvalidBlockNumber) return 0 else pinLeaf(idx, start);
    if (buf == c.InvalidBuffer) return 0;
    var rest: [MAX_TIDS]Entry(void) = undefined;
    var ta: Tally = .{ .tbl = tbl, .cap = cap, .rest = &rest };
    var landing = true;
    while (true) {
        var r: Counting(K) = .{ .key = key, .landing = landing, .ta = &ta, .before = ta.n };
        readLeaf(idx, buf, K, void, K != void and key != null, &r);
        switch (r.got) {
            .entries => {},
            .right => |n| {
                c.ReleaseBuffer(buf);
                buf = pg.readBuffer(idx.rel, n, .index);
                continue;
            },
            .end => {
                keepLeaf(idx, buf);
                return ta.n;
            },
            .stuck => unreachable,
        }
        // a count reads its range to the end (or the cap): the next leaf loads while this one's heap checks run
        if (!r.done and ta.n < cap) pg.prefetchIndexPage(idx.rel, r.next);
        if (ta.m > 0 and ta.n < cap) ta.n += countOffVisible(tbl, snap, rest[0..ta.m]);
        if (ta.n >= cap or r.done) {
            keepLeaf(idx, buf);
            return @min(ta.n, cap);
        }
        c.ReleaseBuffer(buf);
        buf = pg.readBuffer(idx.rel, r.next, .index);
        landing = false;
    }
}

/// One leaf page of count, taken as walk takes it: each entry equal to the key tallied, from the count
/// `before` it. Like Leaf's, `read` starts the page's tally over each time.
fn Counting(comptime K: type) type {
    return struct {
        key: ?K,
        landing: bool,
        ta: *Tally,
        before: i64,
        got: Take = undefined,
        done: bool = false,
        next: u32 = 0,

        fn read(self: *@This(), page: anytype) bool {
            const peeking = @TypeOf(page).peeking;
            const keyed = K != void and self.key != null;
            const ta = self.ta;
            ta.n = self.before;
            ta.m = 0;
            ta.blk = c.InvalidBlockNumber; // the map is read again for each page, as visible reads it
            self.got = take(page, K, self.key, .forward, self.landing);
            if (self.got != .entries) return self.got != .stuck;
            self.done = page.rightmost();
            self.next = page.opq().btpo_next;
            var off = if (self.landing and keyed) page.lowerBound(page.firstKey(), K, self.key.?) else page.firstKey();
            const max = page.maxOff();
            while (off <= max) : (off += 1) {
                const id = page.lp(off);
                const t = page.at(id);
                if (keyed and order(K, t, self.key.?) == .gt) {
                    self.done = true;
                    break;
                }
                if ((id >> 15) & 3 == LP_DEAD) continue;
                if (!t.posting()) {
                    if (ta.add(t.p, peeking) orelse return false) return true;
                } else {
                    const cnt = t.u16At(4) & OFFSET_MASK;
                    if (peeking and !page.holds(t, cnt, 0)) return false;
                    const list = t.p + t.block();
                    for (0..cnt) |i| if (ta.add(list + i * 6, peeking) orelse return false) return true;
                }
            }
            return true;
        }
    };
}

/// count's tally of one leaf page: an entry on a heap block the visibility map marks all-visible is
/// counted, any other is kept in `rest` for the heap.
const Tally = struct {
    tbl: *pg.Table,
    cap: i64,
    rest: *[MAX_TIDS]Entry(void),
    n: i64 = 0,
    m: usize = 0,
    blk: u32 = c.InvalidBlockNumber,
    all: bool = false,

    /// Adds the heap TID at `p`; true once the count reaches the cap. Peeking, null where the page must be
    /// read under its lock instead: the TID's map bit is not on the pinned map page, which only a locked read
    /// may pin, or `rest` is full, which only a torn read finds.
    inline fn add(self: *Tally, p: [*]const u8, comptime peeking: bool) ?bool {
        const b = (Tuple{ .p = p }).block();
        if (b != self.blk) {
            self.blk = b;
            self.all = if (peeking) (self.tbl.allVisibleHere(b) orelse return null) else self.tbl.allVisible(b);
        }
        if (!self.all) {
            if (peeking and self.m == MAX_TIDS) return null;
            self.rest[self.m] = .{ .tid = tidAt(p), .val = {} };
            self.m += 1;
            return false;
        }
        self.n += 1;
        return self.n == self.cap;
    }
};

/// How many of `es` (entries on heap blocks not all-visible) have a version visible under `snap`, one
/// locked read per run of entries on a block.
noinline fn countOffVisible(tbl: *pg.Table, snap: pg.Snapshot, es: []const Entry(void)) i64 {
    pg.prefetchRows(tbl.rel, es);
    // the tuples, whose headers the visibility checks read, once their line pointers have loaded
    for (es) |e| pg.prefetchTuple(tbl.rel, e.tid);
    var ok: [MAX_TIDS]bool = undefined;
    var n: i64 = 0;
    var i: usize = 0;
    while (i < es.len) {
        const b = pg.tidBlock(&es[i].tid);
        var j = i + 1;
        while (j < es.len and pg.tidBlock(&es[j].tid) == b) j += 1;
        tbl.visibleOn(snap, b, es[i..j], ok[i..j]);
        for (ok[i..j]) |vis| n += @intFromBool(vis);
        i = j;
    }
    return n;
}

/// The second column of the entries in `range` visible under `snap`, in index order, written to `out`;
/// null when there are more than fit.
pub fn values(tbl: *pg.Table, idx: *pg.Index, snap: pg.Snapshot, comptime K: type, range: Range(K), comptime V: type, out: []V) ?[]V {
    return valuesAt(tbl, idx, snap, K, range, V, out, null);
}

/// values, starting from leaf `start` (leafOf's, for `range.lo`, in this execution) unless it is null.
pub fn valuesAt(tbl: *pg.Table, idx: *pg.Index, snap: pg.Snapshot, comptime K: type, range: Range(K), comptime V: type, out: []V, start: anytype) ?[]V {
    var v = struct {
        out: []V,
        n: usize = 0,
        full: bool = false,

        fn entry(self: *@This(), val: V, _: c.ItemPointerData) bool {
            if (self.n == self.out.len) {
                self.full = true;
                return true;
            }
            self.out[self.n] = val;
            self.n += 1;
            return false;
        }
    }{ .out = out };
    visibleAt(tbl, idx, snap, K, range, V, .forward, &v, start);
    return if (v.full) null else out[0..v.n];
}

/// Reads into `tbl` the row visible under `snap` whose unique key in `idx` is `key`; false if there is
/// none. Every entry with the key is tried in turn (a row's dead versions keep theirs until vacuum), as
/// index_getnext_slot does.
pub fn fetch(tbl: *pg.Table, idx: *pg.Index, snap: pg.Snapshot, comptime K: type, key: K) bool {
    return fetchAt(tbl, idx, snap, K, key, null);
}

/// fetch, starting from leaf `start` (leafOf's, for `key`, in this execution) unless it is null.
pub fn fetchAt(tbl: *pg.Table, idx: *pg.Index, snap: pg.Snapshot, comptime K: type, key: K, start: anytype) bool {
    var v = struct {
        found: bool = false,

        fn row(self: *@This()) bool {
            self.found = true;
            return true;
        }
    }{};
    rowsAt(tbl, idx, snap, K, .{ .lo = key, .hi = key }, &v, start);
    return v.found;
}

/// A btree page of `keys` (ascending) as nbtree lays one out: line pointers after the header, tuples
/// placed down from the special space in a shuffled order, a high key at item 1 unless rightmost.
fn testPage(comptime K: type, mem: *align(8) [c.BLCKSZ]u8, keys: []const K, high: ?K, rnd: std.Random) Page {
    @memset(mem, 0);
    const width = KEY + @sizeOf(if (K == [2]i64) [2]i64 else K);
    const size = std.mem.alignForward(usize, width, 8);
    const items = keys.len + @intFromBool(high != null);
    var order_: [MAX_TIDS]u16 = undefined;
    for (0..items) |i| order_[i] = @intCast(i);
    rnd.shuffle(u16, order_[0..items]);
    const special = c.BLCKSZ - @sizeOf(c.BTPageOpaqueData);
    var upper: usize = special;
    for (order_[0..items]) |i| {
        upper -= size;
        const k: K = if (high) |h| (if (i == 0) h else keys[i - 1]) else keys[i];
        const t = mem[upper..][0..size];
        std.mem.writeInt(u16, t[6..8], @intCast(size), .little);
        if (K == [2]i64) {
            std.mem.writeInt(i64, t[KEY..][0..8], k[0], .little);
            std.mem.writeInt(i64, t[KEY + 8 ..][0..8], k[1], .little);
        } else std.mem.writeInt(K, t[KEY..][0..@sizeOf(K)], k, .little);
        const lp: u32 = @as(u32, @intCast(upper)) | 1 << 15 | @as(u32, @intCast(size)) << 17;
        std.mem.writeInt(u32, mem[HEADER + i * 4 ..][0..4], lp, .little);
    }
    std.debug.assert(upper >= HEADER + items * 4);
    std.mem.writeInt(u16, mem[PD_LOWER..][0..2], @intCast(HEADER + items * 4), .little);
    std.mem.writeInt(u16, mem[PD_SPECIAL..][0..2], special, .little);
    const o: *c.BTPageOpaqueData = @ptrCast(@alignCast(mem[special..]));
    o.btpo_flags = BTP_LEAF;
    o.btpo_next = if (high != null) 7 else c.P_NONE;
    return .{ .p = mem };
}

fn testKey(comptime K: type, rnd: std.Random, shape: u8, i: usize) i64 {
    _ = K;
    return switch (shape) {
        0 => @intCast(1000 + i), // dense, as serial ids
        1 => @intCast(1000 + i * 7 + rnd.uintLessThan(usize, 7)), // sparse, even
        2 => @intCast(1000 + i / 40), // long runs of one key, as a hot article's favorites
        3 => @as(i64, 1) << @intCast(@min(i / 8, 60)), // skewed
        else => std.math.maxInt(i64) - 3000 + @as(i64, @intCast(i)), // at the type's edge
    };
}

fn checkBounds(comptime K: type, rnd: std.Random) !void {
    var mem: [c.BLCKSZ]u8 align(8) = undefined;
    var keys: [400]K = undefined;
    for (0..300) |_| {
        const shape = rnd.uintLessThan(u8, if (K == i32) 4 else 5);
        const n = rnd.uintLessThan(usize, if (K == [2]i64) 280 else 400); // what fits in a page
        for (0..n) |i| {
            const v = testKey(K, rnd, shape, i);
            keys[i] = if (K == [2]i64) .{ v, @intCast(i) } else @intCast(if (K == i32) @min(v, std.math.maxInt(i32)) else v);
        }
        const rightmost = rnd.boolean();
        const last = if (n > 0) keys[n - 1] else if (K == [2]i64) [2]i64{ 0, 0 } else 0;
        const high: ?K = if (rightmost) null else last;
        const page = testPage(K, &mem, keys[0..n], high, rnd);
        const from = page.firstKey();
        for (0..60) |_| {
            const probe: K = if (n > 0 and rnd.boolean()) keys[rnd.uintLessThan(usize, n)] else if (K == [2]i64)
                .{ testKey(K, rnd, shape, rnd.uintLessThan(usize, n + 2)) - 1, @intCast(rnd.uintLessThan(usize, n + 2)) }
            else
                @intCast(@min(testKey(K, rnd, shape, rnd.uintLessThan(usize, n + 2)) - 1, if (K == i32) std.math.maxInt(i32) else std.math.maxInt(i64)));
            inline for (.{ false, true }) |upper| {
                var want: u16 = page.maxOff() + 1;
                var off = from;
                while (off <= page.maxOff()) : (off += 1) if (past(K, page.tuple(off), probe, upper)) {
                    want = off;
                    break;
                };
                try std.testing.expectEqual(want, page.bound(from, K, probe, upper));
            }
        }
    }
}

test "bound finds what a linear scan finds, for every key shape and spread" {
    var prng = std.Random.DefaultPrng.init(42);
    try checkBounds(i64, prng.random());
    try checkBounds(i32, prng.random());
    try checkBounds([2]i64, prng.random());
}
