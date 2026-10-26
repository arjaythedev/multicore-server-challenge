//! Thin Zig wrappers over Postgres relations, heap access and buffers, and the row reads the engine does
//! itself. Everything here reads live tuples under the batch snapshot.

const std = @import("std");
const c = @import("pg_c");
const A = @import("alloc.zig");

pub const Oid = u32;
pub const Datum = usize;
pub const Relation = c.Relation;
pub const Snapshot = c.Snapshot;

pub inline fn ereport(msg: [*:0]const u8) noreturn {
    c.shim_ereport_str(msg);
}

/// A text request field's bytes (inside the marker's packed parameter).
pub inline fn text(t: c.EngineText) []const u8 {
    return t.ptr[0..t.len];
}

pub inline fn detoastText(d: Datum) []const u8 {
    const flat = c.shim_detoast(d);
    var len: i32 = 0;
    const p = c.shim_text_ptr(flat, &len);
    return p[0..@intCast(len)];
}

/// A heap relation (rels.zig keeps it open) and what one execution reads of it: the heap block last read,
/// and the row fetchTid last found there, read in place. The block stays pinned until another block of the
/// table is read or the table closes, and the pin keeps the row where it is (moving a tuple on a page
/// takes a cleanup lock, which waits for every pin), so a row is read with no lock and no copy, as heapam's
/// slots read it. The row read lasts until the next fetchTid or visibleOn on the same table.
pub const Table = struct {
    rel: Relation,
    /// Whether heap pages may be read without their lock (peekedHeap): a WAL-logged table, a lock word
    /// lockWordKnown has checked, and no serializable transaction (whose reads heap_hot_search_buffer
    /// records as predicate locks).
    peek: bool,
    buf: c.Buffer = c.InvalidBuffer,
    /// The visibility-map page last read for this table, kept pinned until close, its map block and its
    /// bytes: every index walk over the table reads the map, and one map page covers 32,672 heap pages.
    vm: c.Buffer = c.InvalidBuffer,
    vm_blk: u32 = c.InvalidBlockNumber,
    vm_map: [*]const u8 = undefined,
    /// The row fetchTid found: its tuple, where its attributes' bytes start, each attribute's offset
    /// from there, which are NULL (bit i for attribute i + 1), and how many the tuple stores (a row
    /// written before an ADD COLUMN stores fewer; the rest read as getmissingattr gives them).
    tup: c.HeapTupleData = undefined,
    data: [*]const u8 = undefined,
    off: [MAX_ATTNO]u16 = undefined,
    nulls: u32 = 0,
    stored: usize = 0,

    /// The highest attribute number the engine reads (schema.zig refuses a column past it).
    pub const MAX_ATTNO = 16;
    const MAP_HEADER = 24; // MAXALIGN(SizeOfPageHeaderData): the map's bytes follow
    const HEAPBLOCKS_PER_PAGE: u32 = (c.BLCKSZ - MAP_HEADER) * 4; // two bits per heap block
    const TUPLE_HEADER = @offsetOf(c.HeapTupleHeaderData, "_t_bits"); // SizeofHeapTupleHeader: the null bitmap follows

    pub fn of(rel: Relation) Table {
        return .{
            .rel = rel,
            .peek = rel.*.rd_rel.*.relpersistence == c.RELPERSISTENCE_PERMANENT and lockWordKnown() and
                c.XactIsoLevel != c.XACT_SERIALIZABLE,
        };
    }
    pub fn close(self: *Table) void {
        if (self.vm != c.InvalidBuffer) c.ReleaseBuffer(self.vm);
        if (self.buf != c.InvalidBuffer) c.ReleaseBuffer(self.buf);
    }
    /// The version of the row at `tid` (an index entry's heap pointer) visible to `snap`, found along its
    /// HOT chain as heapam's index fetch finds it, then read in place. The chain is read without the
    /// block's lock when hint bits decide it (peekedHeap), else under the block's share lock.
    pub fn fetchTid(self: *Table, snap: Snapshot, tid: c.ItemPointerData) bool {
        // heapam prunes a block when it moves there; finding it already pinned, it moves nothing
        if (self.moveTo(tidBlock(&tid), tid.ip_posid)) c.heap_page_prune_opt(self.rel, self.buf);
        const found = (if (self.peeks(snap)) self.peekTid(snap, tid) else null) orelse found: {
            var t = tid;
            c.LockBuffer(self.buf, c.BUFFER_LOCK_SHARE);
            const f = c.heap_hot_search_buffer(&t, self.rel, self.buf, snap, &self.tup, null, true);
            c.LockBuffer(self.buf, c.BUFFER_LOCK_UNLOCK);
            break :found f;
        };
        if (found) self.deform();
        return found;
    }
    inline fn peeks(self: *const Table, snap: Snapshot) bool {
        return self.peek and snap.*.snapshot_type == c.SNAPSHOT_MVCC;
    }
    /// fetchTid's chain search without the lock: null when the read cannot be trusted or the hint bits do
    /// not decide it.
    fn peekTid(self: *Table, snap: Snapshot, tid: c.ItemPointerData) ?bool {
        var r: struct {
            snap: Snapshot,
            root: u16,
            hit: Hot = undefined,
            fn read(rd: *@This(), page: [*]const u8) bool {
                rd.hit = hotSearch(page, rd.root, rd.snap) orelse return false;
                return true;
            }
        } = .{ .snap = snap, .root = tid.ip_posid };
        if (!peekedHeap(self.buf, &r)) return null;
        if (r.hit.off == 0) return false;
        self.tup = .{
            .t_len = r.hit.len,
            .t_self = .{ .ip_blkid = tid.ip_blkid, .ip_posid = r.hit.off },
            .t_tableOid = self.rel.*.rd_id,
            .t_data = @ptrCast(@alignCast(@constCast(pageOf(self.buf) + r.hit.at))),
        };
        return true;
    }
    /// Finds where each stored attribute of the row starts, as slot_deform_heap_tuple does: in order,
    /// each aligned per the tuple descriptor, a NULL taking no bytes, a varlena with a 1-byte header
    /// (never a zero byte, where padding always is) unaligned.
    fn deform(self: *Table) void {
        const h = self.tup.t_data;
        const hp: [*]const u8 = @ptrCast(h);
        const atts = self.rel.*.rd_att.*.compact_attrs();
        const n = @min(@as(usize, h.*.t_infomask2 & @as(u16, c.HEAP_NATTS_MASK)), MAX_ATTNO);
        const nullable = h.*.t_infomask & @as(u16, c.HEAP_HASNULL) != 0;
        const bits = hp + TUPLE_HEADER;
        const tp = hp + h.*.t_hoff;
        var nulls: u32 = 0;
        var off: usize = 0;
        for (0..n) |i| {
            if (nullable and bits[i >> 3] & (@as(u8, 1) << @intCast(i & 7)) == 0) {
                nulls |= @as(u32, 1) << @intCast(i);
                continue;
            }
            const a = atts[i];
            if (a.attlen > 0 or tp[off] == 0) off = std.mem.alignForward(usize, off, a.attalignby);
            self.off[i] = @intCast(off);
            off += if (a.attlen > 0) @as(usize, @intCast(a.attlen)) else varSize(tp + off);
        }
        self.data = tp;
        self.nulls = nulls;
        self.stored = n;
    }
    /// Which of `entries` (index entries on heap block `blk`, each `.tid` the root of a HOT chain) have a
    /// version visible to `snap`, into `ok`. The block is read under one share lock for all of them, and
    /// no row is read: an index-only read needs visibility, not the tuple. The block stays pinned as
    /// fetchTid's does, so one heap pin per table serves both.
    pub fn visibleOn(self: *Table, snap: Snapshot, blk: u32, entries: anytype, ok: []bool) void {
        _ = self.moveTo(blk, if (entries.len > 0) entries[0].tid.ip_posid else 1);
        if (self.peeks(snap)) {
            var r: struct {
                snap: Snapshot,
                entries: @TypeOf(entries),
                ok: []bool,
                fn read(rd: *@This(), page: [*]const u8) bool {
                    for (rd.entries, rd.ok) |*e, *o| o.* = (hotSearch(page, e.tid.ip_posid, rd.snap) orelse return false).off != 0;
                    return true;
                }
            } = .{ .snap = snap, .entries = entries, .ok = ok };
            if (peekedHeap(self.buf, &r)) return;
        }
        c.LockBuffer(self.buf, c.BUFFER_LOCK_SHARE);
        for (entries, ok) |*e, *o| {
            var tid = e.tid;
            var tuple: c.HeapTupleData = undefined;
            o.* = c.heap_hot_search_buffer(&tid, self.rel, self.buf, snap, &tuple, null, true);
        }
        c.LockBuffer(self.buf, c.BUFFER_LOCK_UNLOCK);
    }
    /// Pins heap block `blk` unless it is pinned already; true when it moved.
    fn moveTo(self: *Table, blk: u32, row: u16) bool {
        if (self.buf != c.InvalidBuffer) {
            if (c.BufferGetBlockNumber(self.buf) == blk) return false;
            c.ReleaseBuffer(self.buf);
        }
        self.buf = readBuffer(self.rel, blk, .{ .row = row });
        return true;
    }
    /// VM_ALL_VISIBLE for heap block `blk`. The bit is read off the pinned map page, unlocked, as
    /// visibilitymap_get_status reads it (a one-byte read is atomic); that runs only to pin another page.
    pub inline fn allVisible(self: *Table, blk: u32) bool {
        return self.allVisibleHere(blk) orelse self.allVisibleOther(blk);
    }
    /// allVisible off the pinned map page only: null when `blk`'s bit is on another (or none is pinned).
    pub inline fn allVisibleHere(self: *Table, blk: u32) ?bool {
        if (blk / HEAPBLOCKS_PER_PAGE != self.vm_blk) return null;
        const i = blk % HEAPBLOCKS_PER_PAGE;
        return (self.vm_map[MAP_HEADER + i / 4] >> @intCast(i % 4 * 2)) & c.VISIBILITYMAP_ALL_VISIBLE != 0;
    }
    /// Pins map page `blk / HEAPBLOCKS_PER_PAGE`, through vm_hints first, then reads the bit.
    noinline fn allVisibleOther(self: *Table, blk: u32) bool {
        const map_blk = blk / HEAPBLOCKS_PER_PAGE;
        if (self.vm != c.InvalidBuffer) c.ReleaseBuffer(self.vm);
        self.vm = c.InvalidBuffer;
        const loc = self.rel.*.rd_locator;
        const h = &vm_hints[(loc.relNumber +% map_blk) % vm_hints.len];
        if (h.rel == loc.relNumber and h.blk == map_blk and c.ReadRecentBuffer(loc, c.VISIBILITYMAP_FORKNUM, map_blk, h.buf)) self.vm = h.buf;
        // with the page pinned this only reads the bit; otherwise it reads the page, as for any first read
        const all = c.VM_ALL_VISIBLE(self.rel, blk, &self.vm);
        if (self.vm == c.InvalidBuffer) {
            self.vm_blk = c.InvalidBlockNumber;
        } else {
            self.vm_blk = map_blk;
            self.vm_map = pageOf(self.vm);
            h.* = .{ .rel = loc.relNumber, .blk = map_blk, .buf = self.vm };
        }
        return all;
    }
    /// The bytes of attribute `attno` of the row, or null when it is NULL.
    inline fn at(self: *Table, attno: i16) ?[*]const u8 {
        const i: usize = @intCast(attno - 1);
        if (i >= self.stored) return self.missing(attno);
        if (self.nulls >> @intCast(i) & 1 != 0) return null;
        return self.data + self.off[i];
    }
    /// An attribute the row does not store: its ADD COLUMN default or NULL, as getmissingattr gives it,
    /// by value for an int8 or int4 (Datum, stored here) and by reference for text.
    noinline fn missing(self: *Table, attno: i16) ?[*]const u8 {
        var isnull = false;
        const d = c.getmissingattr(self.rel.*.rd_att, attno, &isnull);
        if (isnull) return null;
        if (self.rel.*.rd_att.*.compact_attrs()[@intCast(attno - 1)].attlen > 0) {
            const v = A.alloc(Datum, 1);
            v[0] = d;
            return @ptrCast(v.ptr);
        }
        return @ptrFromInt(d);
    }
    pub inline fn i64At(self: *Table, attno: i16) i64 {
        const p = self.at(attno) orelse return 0;
        return std.mem.readInt(i64, p[0..8], .little);
    }
    pub inline fn i32At(self: *Table, attno: i16) i32 {
        const p = self.at(attno) orelse return 0;
        return std.mem.readInt(i32, p[0..4], .little);
    }
    /// Text attribute as bytes, or null when NULL. Inline values point into the pinned page; compressed
    /// or out-of-line ones are detoasted into the execution's memory.
    pub inline fn textAt(self: *Table, attno: i16) ?[]const u8 {
        const p = self.at(attno) orelse return null;
        if (p[0] & 1 == 1) {
            if (p[0] != 1) return p[1 .. p[0] >> 1]; // 1-byte header: the length includes it
        } else if (p[0] & 2 == 0) {
            return p[4 .. std.mem.readInt(u32, p[0..4], .little) >> 2]; // 4-byte header, not compressed
        }
        return detoastText(@intFromPtr(p));
    }
};

/// VARSIZE_ANY: a varlena's length, header included. A heap tuple stores only on-disk TOAST pointers,
/// after a 2-byte header (VARHDRSZ_EXTERNAL: its 0x01 and the tag).
fn varSize(p: [*]const u8) usize {
    if (p[0] == 1) {
        if (p[1] != c.VARTAG_ONDISK) ereport("engine: unexpected TOAST pointer in a heap tuple");
        return 2 + @sizeOf(c.varatt_external);
    }
    if (p[0] & 1 == 1) return p[0] >> 1;
    return std.mem.readInt(u32, p[0..4], .little) >> 2;
}

/// An index (rels.zig keeps it open) and what btree.zig's walks keep of it for one execution.
pub const Index = struct {
    rel: Relation,
    /// btree.zig's descents: the root they start from, and from the second descent on the internal
    /// pages they read, kept pinned until close. Descents of one execution start at the same root and
    /// mostly cross the same few internal pages; the execution's snapshot keeps any of them that is
    /// deleted meanwhile from being recycled. An index descended once keeps nothing: past 8 pins a
    /// backend's private refcounts spill into a hash table, and every buffer access pays for that.
    root: u32 = c.InvalidBlockNumber,
    descents: u32 = 0,
    pins: [8]Pin = undefined,
    npins: u8 = 0,
    /// The leaf the last walk ended on, kept pinned until the next walk ends elsewhere or close: walks of
    /// one execution often end on the same leaf (the tags of consecutive articles, their favorites), and a
    /// walk that starts there takes the pin over instead of pinning again.
    leaf: c.Buffer = c.InvalidBuffer,
    leaf_blk: u32 = c.InvalidBlockNumber,
    /// Whether walks may read pages without their lock (btree.zig's peeked): only when every
    /// change to the index's pages sets the page LSN, which a WAL-logged (permanent) index's do, and the
    /// lock word reads as lockWordKnown checked.
    peek: bool,

    pub const Pin = struct { blk: u32, buf: c.Buffer };

    pub fn of(rel: Relation) Index {
        return .{ .rel = rel, .peek = rel.*.rd_rel.*.relpersistence == c.RELPERSISTENCE_PERMANENT and lockWordKnown() };
    }
    pub fn close(self: *Index) void {
        for (self.pins[0..self.npins]) |p| c.ReleaseBuffer(p.buf);
        if (self.leaf != c.InvalidBuffer) c.ReleaseBuffer(self.leaf);
        self.leaf = c.InvalidBuffer;
        self.leaf_blk = c.InvalidBlockNumber;
    }
};

/// The shared buffer each page last read sat in, kept per backend: per relation file, an array indexed by
/// block and grown to the highest block read. readBuffer tries that buffer first with ReadRecentBuffer,
/// which pins it only if its tag still names the page, and so skips the buffer-mapping hash and its
/// partition lock. Only buffer numbers are kept, never page contents: every read still reads the page as
/// it is now. One array per file has no conflicts: a direct-mapped table of 65,536 pages missed on reads
/// worth 44% of read time under the replay's 2.5 GB database.
const Hints = struct { rel: c.RelFileNumber = c.InvalidRelFileNumber, bufs: []c.Buffer = &.{} };
var hint_files: [64]Hints = @splat(.{});
var nhint_files: usize = 0;
/// Blocks past this go without a hint (a 128 GB relation; its array would be 64 MB).
const MAX_HINTED: u32 = 1 << 24;

/// Relation file `rel`'s hint array: the slot its number picks, unless another file took that slot first.
inline fn hintsOf(rel: c.RelFileNumber) *Hints {
    const h = &hint_files[rel % hint_files.len];
    return if (h.rel == rel) h else claimHints(rel);
}

/// hintsOf past the first slot: the file's slot further on, claimed on first use. Once 48 files have one
/// (relations rewritten over and over in one backend's life), every array is dropped and claimed again.
noinline fn claimHints(rel: c.RelFileNumber) *Hints {
    var i: usize = rel % hint_files.len;
    while (true) : (i = (i + 1) % hint_files.len) {
        const h = &hint_files[i];
        if (h.rel == rel) return h;
        if (h.rel != c.InvalidRelFileNumber) continue;
        if (nhint_files == 48) {
            for (&hint_files) |*f| if (f.bufs.len > 0) c.pfree(f.bufs.ptr);
            hint_files = @splat(.{});
            nhint_files = 0;
            return claimHints(rel);
        }
        h.rel = rel;
        nhint_files += 1;
        return h;
    }
}

/// Grows `h` to hold block `blk`, the new slots empty.
fn growHints(h: *Hints, blk: u32) void {
    const n = @max(@as(usize, blk) + 1, h.bufs.len * 2, 1024);
    const raw = if (h.bufs.len == 0)
        c.MemoryContextAllocZero(c.TopMemoryContext, n * @sizeOf(c.Buffer))
    else
        c.repalloc(h.bufs.ptr, n * @sizeOf(c.Buffer));
    const p: [*]c.Buffer = @ptrCast(@alignCast(raw));
    @memset(p[h.bufs.len..n], c.InvalidBuffer);
    h.bufs = p[0..n];
}

const Hint = struct { rel: c.RelFileNumber, blk: u32, buf: c.Buffer };
/// The same for visibility-map pages, which Table.allVisibleOther reads: a relation has one map page per
/// 32,672 heap pages, read once per execution that walks the relation.
var vm_hints: [64]Hint = @splat(.{ .rel = c.InvalidRelFileNumber, .blk = 0, .buf = c.InvalidBuffer });

/// lwlock.c's LW_VAL_EXCLUSIVE: the value an exclusive holder adds to an LWLock's state word, which lwlock.c
/// keeps to itself. lockWordKnown checks it once per backend.
const LW_VAL_EXCLUSIVE: u32 = c.MAX_BACKENDS + 1;
var lock_word: ?bool = null;

/// Whether an LWLock's state word reads as LW_VAL_EXCLUSIVE says: tried on a lock of the engine's own,
/// held exclusive (the bit set) and then shared (the bit clear, one sharer counted).
fn lockWordKnown() bool {
    if (lock_word) |k| return k;
    var lk: c.LWLock = undefined;
    c.LWLockInitialize(&lk, c.LWTRANCHE_BUFFER_CONTENT);
    _ = c.LWLockAcquire(&lk, c.LW_EXCLUSIVE);
    const ex = @atomicLoad(u32, &lk.state.value, .monotonic);
    c.LWLockRelease(&lk);
    _ = c.LWLockAcquire(&lk, c.LW_SHARED);
    const sh = @atomicLoad(u32, &lk.state.value, .monotonic);
    c.LWLockRelease(&lk);
    const k = ex & LW_VAL_EXCLUSIVE != 0 and sh & LW_VAL_EXCLUSIVE == 0 and sh & c.MAX_BACKENDS == 1;
    lock_word = k;
    return k;
}

/// Whether shared buffer `buf`'s content lock is held exclusive right now (an acquire load of its state).
pub inline fn lockedExclusive(buf: c.Buffer) bool {
    const lock = &c.BufferDescriptors[@intCast(buf - 1)].bufferdesc.content_lock;
    return @atomicLoad(u32, &lock.state.value, .acquire) & LW_VAL_EXCLUSIVE != 0;
}

/// BufferGetPage, inline: translate-c's copy is a call, and walks take a page address for every page and
/// heap block. A pinned buffer's page stays at this address. Only for shared buffers, the only kind the
/// engine reads: its relations are in schema public, where no temporary relation can be.
pub inline fn pageOf(buf: c.Buffer) [*]u8 {
    return c.BufferBlocks + @as(usize, @intCast(buf - 1)) * c.BLCKSZ;
}

/// The lines of a page its reader needs first: a btree page's header and special space, or a heap page's
/// header and the line pointer of row `row`.
pub const First = union(enum) { index, row: u16 };

/// ReadBuffer for a page of `rel`'s main fork, through the hints. With a hint, the lines `first` names are
/// requested before the pin, so they load while the pin waits on the buffer's descriptor instead of after
/// it. A hint gone stale costs those loads.
pub fn readBuffer(rel: Relation, blk: u32, first: First) c.Buffer {
    const loc = rel.*.rd_locator;
    const h = hintsOf(loc.relNumber);
    if (blk < h.bufs.len) {
        const hint = h.bufs[blk];
        if (hint != c.InvalidBuffer) {
            const p = pageOf(hint);
            @prefetch(p, .{});
            switch (first) {
                .index => @prefetch(p + c.BLCKSZ - 64, .{}),
                // SizeOfPageHeaderData, then 4 bytes per line pointer
                .row => |row| @prefetch(p + 24 + 4 * (@as(usize, row) -| 1), .{}),
            }
            if (c.ReadRecentBuffer(loc, c.MAIN_FORKNUM, blk, hint)) return hint;
        }
    }
    return readUnhinted(rel, h, blk);
}

/// readBuffer without a usable hint: ReadBuffer, and the buffer it gives becomes the block's hint.
noinline fn readUnhinted(rel: Relation, h: *Hints, blk: u32) c.Buffer {
    if (blk >= h.bufs.len and blk < MAX_HINTED) growHints(h, blk);
    const buf = c.ReadBuffer(rel, blk);
    if (blk < h.bufs.len) h.bufs[blk] = buf;
    return buf;
}

/// Starts the loads that reading the heap rows at `items` (TIDs, or entries with a `.tid`) begins with,
/// where the hints know a row's block's buffer: the buffer's descriptor (which the pin and the content
/// lock write) and the page header once per run of rows on a block, and each row's line pointer. A batch
/// of rows prefetched before it is read waits on those misses together instead of one after another.
/// Reads no shared memory: a hint gone stale costs a wasted load.
pub fn prefetchRows(rel: Relation, items: anytype) void {
    const h = hintsOf(rel.*.rd_locator.relNumber);
    var blk: u32 = c.InvalidBlockNumber;
    var page: ?[*]u8 = null;
    for (items) |*it| {
        const tid: *const c.ItemPointerData = if (@TypeOf(it.*) == c.ItemPointerData) it else &it.tid;
        const b = tidBlock(tid);
        if (b != blk) {
            blk = b;
            const buf = if (b < h.bufs.len) h.bufs[b] else c.InvalidBuffer;
            page = if (buf == c.InvalidBuffer) null else pageOf(buf);
            if (page) |p| {
                @prefetch(&c.BufferDescriptors[@intCast(buf - 1)], .{ .rw = .write });
                @prefetch(p, .{});
            }
        }
        // SizeOfPageHeaderData, then 4 bytes per line pointer
        if (page) |p| @prefetch(p + 24 + 4 * (@as(usize, tid.ip_posid) -% 1), .{});
    }
}

/// Starts the loads of the heap row at `tid` itself where the hints know its block's buffer: the first two
/// lines of the tuple its line pointer points at and its last line, which deform reads (the fixed-width
/// columns after a long text). Reads the line pointer, unpinned and unlocked, for the address only: it
/// should have been requested (prefetchRows) far enough ahead to have landed. A stale hint or a line
/// pointer that is not a normal one costs nothing more than wasted loads.
pub fn prefetchTuple(rel: Relation, tid: c.ItemPointerData) void {
    const h = hintsOf(rel.*.rd_locator.relNumber);
    const b = tidBlock(&tid);
    if (b >= h.bufs.len or h.bufs[b] == c.InvalidBuffer) return;
    const p = pageOf(h.bufs[b]);
    const i = @min(@as(usize, tid.ip_posid) -% 1, (c.BLCKSZ - 24) / 4 - 1); // a line pointer inside the page
    const lp = std.mem.readInt(u32, p[24 + 4 * i ..][0..4], .little);
    const off: usize = lp & 0x7fff;
    const len: usize = lp >> 17;
    if ((lp >> 15) & 3 != 1 or off + len > c.BLCKSZ) return; // LP_NORMAL, inside the page
    @prefetch(p + off, .{});
    @prefetch(p + off + 64, .{});
    if (len > 128) @prefetch(p + off + len - 1, .{});
}

/// Starts the loads a btree page's reader begins with, where the hints know block `blk`'s buffer: the
/// buffer's descriptor (which the pin writes), the page header with the first line pointers, and the
/// special space. Reads no shared memory: a hint gone stale costs wasted loads.
pub fn prefetchIndexPage(rel: Relation, blk: u32) void {
    const h = hintsOf(rel.*.rd_locator.relNumber);
    if (blk >= h.bufs.len or h.bufs[blk] == c.InvalidBuffer) return;
    const buf = h.bufs[blk];
    @prefetch(&c.BufferDescriptors[@intCast(buf - 1)], .{ .rw = .write });
    const p = pageOf(buf);
    @prefetch(p, .{});
    @prefetch(p + c.BLCKSZ - 64, .{});
}

/// The page block `blk` of `rel` was last found in, from the hints, neither pinned nor locked: for
/// addresses to request, never for anything a read decides.
pub fn hintedPage(rel: Relation, blk: u32) ?[*]const u8 {
    const h = hintsOf(rel.*.rd_locator.relNumber);
    if (blk >= h.bufs.len or h.bufs[blk] == c.InvalidBuffer) return null;
    return pageOf(h.bufs[blk]);
}

/// Runs `r.read(page)` on pinned heap buffer `buf` without its content lock and says whether what it read
/// can be trusted, as btree.zig's peeked does for index pages (see there for the protocol): every change
/// to a page of a WAL-logged table is made under the exclusive lock and sets the LSN. The pin keeps each
/// tuple where it is (only pruning moves tuples, under a cleanup lock, which waits for every pin). The
/// one change made under a share lock, setting hint bits, only adds what a reader may know either way.
inline fn peekedHeap(buf: c.Buffer, r: anytype) bool {
    comptime std.debug.assert(@import("builtin").cpu.arch == .x86_64);
    const page = pageOf(buf);
    const lsn: *const u64 = @ptrCast(@alignCast(page)); // pd_lsn, the page's first 8 bytes
    if (lockedExclusive(buf)) return false;
    const l1 = @atomicLoad(u64, lsn, .acquire);
    const ok = r.read(page);
    asm volatile ("" ::: .{ .memory = true }); // the page's loads stay before the second look
    return ok and !lockedExclusive(buf) and @atomicLoad(u64, lsn, .acquire) == l1;
}

/// The member of a HOT chain hotSearch found: its offset (0 for none), and where its tuple sits and how
/// long it is.
const Hot = struct { off: u16 = 0, at: u16 = 0, len: u32 = 0 };

/// heap_hot_search_buffer's walk of the HOT chain at offset `root` of heap page `page`, read without its
/// lock: the first member visible to MVCC snapshot `snap`. null when hint bits and the snapshot alone do
/// not decide a member (the locked read decides it, and sets the hints), or when what was read is not a
/// heap page as it could be (a torn read, which the caller's check throws away anyway). Offsets and
/// lengths are clamped to the page, which never changes a valid page's reads.
fn hotSearch(page: [*]const u8, root: u16, snap: Snapshot) ?Hot {
    const u16At = struct {
        fn f(p: [*]const u8, off: usize) u16 {
            return std.mem.readInt(u16, p[off..][0..2], .little);
        }
    }.f;
    // pd_upper 0 is a new page, pd_special short of BLCKSZ not a heap page: both for the locked read
    if (u16At(page, 14) == 0 or u16At(page, 16) != c.BLCKSZ) return null;
    const max_off = (@min(u16At(page, 12), c.BLCKSZ) -| 24) / 4; // pd_lower: the line pointers' end
    var off = root;
    var at_start = true;
    var prev_xmax: c.TransactionId = c.InvalidTransactionId;
    // a chain is no longer than MaxHeapTuplesPerPage: a page header, then a line pointer and a tuple header each
    for (0..(c.BLCKSZ - 24) / (4 + 24)) |_| {
        if (off < 1 or off > max_off) return .{};
        const lp = std.mem.readInt(u32, page[24 + 4 * @as(usize, off - 1) ..][0..4], .little);
        const lp_off: u16 = @intCast(lp & 0x7fff);
        const lp_flags = (lp >> 15) & 3;
        const lp_len = lp >> 17;
        if (lp_flags == c.LP_REDIRECT and at_start) {
            off = lp_off;
            at_start = false;
            continue;
        }
        if (lp_flags != c.LP_NORMAL) return .{};
        // a valid tuple is MAXALIGNed, holds its header and ends on the page
        if (lp_off % 8 != 0 or lp_len < Table.TUPLE_HEADER or @as(u32, lp_off) + lp_len > c.BLCKSZ) return null;
        const t: *const c.HeapTupleHeaderData = @ptrCast(@alignCast(page + lp_off));
        const im = t.t_infomask;
        const im2 = t.t_infomask2;
        if (at_start and im2 & c.HEAP_ONLY_TUPLE != 0) return .{};
        const xmin = t.t_choice.t_heap.t_xmin;
        const xmax = t.t_choice.t_heap.t_xmax;
        if (prev_xmax != c.InvalidTransactionId and
            prev_xmax != (if (im & c.HEAP_XMIN_FROZEN == c.HEAP_XMIN_FROZEN) c.FrozenTransactionId else xmin)) return .{};
        if (hintVisible(im, xmin, xmax, snap) orelse return null) return .{ .off = off, .at = lp_off, .len = lp_len };
        // HeapTupleHeaderIsHotUpdated: updated in place, by an updater that did not abort
        const xmin_invalid = im & (c.HEAP_XMIN_COMMITTED | c.HEAP_XMIN_INVALID) == c.HEAP_XMIN_INVALID;
        if (im2 & c.HEAP_HOT_UPDATED == 0 or im & c.HEAP_XMAX_INVALID != 0 or xmin_invalid) return .{};
        // HeapTupleHeaderGetUpdateXid needs the multixact's members for a multi updater
        if (im & c.HEAP_XMAX_IS_MULTI != 0 and im & c.HEAP_XMAX_LOCK_ONLY == 0) return null;
        off = t.t_ctid.ip_posid;
        at_start = false;
        prev_xmax = xmax;
    }
    return null;
}

/// HeapTupleSatisfiesMVCC for a tuple with infomask `im`, from its hint bits and `snap` alone: null where
/// that function would look up a transaction's status (and set a hint bit), or reach a case this does not
/// take (a multixact deleter, a snapshot that overflowed its subtransactions or was taken in recovery).
inline fn hintVisible(im: u16, xmin: c.TransactionId, xmax: c.TransactionId, snap: Snapshot) ?bool {
    if (im & c.HEAP_XMIN_COMMITTED == 0) return if (im & c.HEAP_XMIN_INVALID != 0) false else null;
    // committed, but maybe not as the snapshot sees it
    if (im & c.HEAP_XMIN_FROZEN != c.HEAP_XMIN_FROZEN and (inSnapshot(xmin, snap) orelse return null)) return false;
    if (im & c.HEAP_XMAX_INVALID != 0) return true;
    // HEAP_XMAX_IS_LOCKED_ONLY: a locker, not a deleter
    if (im & c.HEAP_XMAX_LOCK_ONLY != 0 or im & (c.HEAP_XMAX_IS_MULTI | c.HEAP_LOCK_MASK) == c.HEAP_XMAX_EXCL_LOCK) return true;
    if (im & c.HEAP_XMAX_IS_MULTI != 0 or im & c.HEAP_XMAX_COMMITTED == 0) return null;
    // a committed deleter the snapshot still sees running leaves the row visible
    return inSnapshot(xmax, snap);
}

/// XidInMVCCSnapshot: whether `snap` sees transaction `xid` as still running. null for a snapshot whose
/// subtransactions overflowed or that was taken in recovery, which that function answers from pg_subtrans
/// or the recovery xid list.
inline fn inSnapshot(xid: c.TransactionId, snap: Snapshot) ?bool {
    const s = snap.*;
    if (xidPrecedes(xid, s.xmin)) return false;
    if (!xidPrecedes(xid, s.xmax)) return true;
    if (s.suboverflowed or s.takenDuringRecovery) return null;
    for (s.subxip[0..@intCast(s.subxcnt)]) |x| if (x == xid) return true;
    for (s.xip[0..s.xcnt]) |x| if (x == xid) return true;
    return false;
}

/// TransactionIdPrecedes: modulo-2^32 order for normal ids, plain order when either is special.
inline fn xidPrecedes(a: c.TransactionId, b: c.TransactionId) bool {
    if (a < c.FirstNormalTransactionId or b < c.FirstNormalTransactionId) return a < b;
    return @as(i32, @bitCast(a -% b)) < 0;
}

/// Heap block of an index TID (BlockIdGetBlockNumber; the packed struct defeats translate-c's inline).
pub inline fn tidBlock(tid: *const c.ItemPointerData) u32 {
    const b = tid.*.ip_blkid;
    return (@as(u32, b.bi_hi) << 16) | b.bi_lo;
}
