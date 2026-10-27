//! The event loop: one thread per worker, each with its own io_uring, SO_REUSEPORT listener, connection table and
//! Postgres connections. Nothing on the request path is shared between workers.
//!
//! Idle keep-alive connections cost one 64-byte table slot (indexed by fd) plus the kernel socket: receive buffers
//! come from a shared provided-buffer ring and are only attached to a connection while a request is incomplete.
const std = @import("std");
const linux = std.os.linux;
const IoUring = linux.IoUring;
const sys = @import("sys.zig");
const http = @import("http.zig");
const pg = @import("pg.zig");
const jwt = @import("jwt.zig");
const bcrypt = @import("bcrypt.zig");
const bcpool = @import("bcpool.zig");
const api = @import("api.zig");
const sql = @import("sql.zig");
const Buf = @import("buf.zig").Buf;
const gpa = @import("buf.zig").gpa;
const Scratch = @import("scratch.zig").Scratch;

const plan = @import("plan.zig");
const pack = @import("packed.zig");
const hubm = @import("hub.zig");
const mutations = @import("mutation.zig");
const log = std.log.scoped(.server);

pub const Config = struct {
    host: [4]u8,
    port: u16,
    db: pg.Config,
    secret: []const u8,
    threads: u32,
    hub: ?*hubm.Hub = null,
    coordinator: bool = false,
    pg_read: u32, // connections per worker
    pg_write: u32,
    pg_depth: u32, // standalone and grouped write depth
    read_depth: u32, // independent read depth, allowing coalescing experiments without changing writes
    packed_reads: bool,
    ack_delay: bool,
    gzip_mode: u32, // 0 identity; 1 save bytes; 2 save TCP segments
    gzip_min: u32,
    comments_shared_pct: u32,
    send_zc_min: u32,
    write_group_max: u32,
    write_window_us: u32,
    write_arrays: bool,
    batch_max: u32, // reads of one kind that may run as one statement (1 = no batching)
    read_window_us: u32, // staged reads wait up to this long for company before they are sent (0 = send at once)
    read_hold_min: u32, // ... unless this many are staged already
    plan_min: u32, // this many staged reads (of any kind) are answered by the two-phase planner instead of per kind (0 = never)
    plan_max: u32, // reads per planned batch
    plan_split: bool, // share the staged reads over the connections with room, instead of one plan taking up to plan_max
    adaptive_window: bool, // dynamic read window scaling under load
    send_zc: bool, // zero-copy network sends via IORING_OP_SEND_ZC
    pin_cpus: bool, // pin worker threads/processes to CPUs
    bc_threads: u32,
    bc_lanes: u32,
    bc_wait_ms: u32,
    bc_auto: bool,
    bc_idle_ms: u32,
    bc_stale_ms: u32,
    stats: bool,
    no_pbuf: bool, // test hook: use the poll + recv path even when provided buffer rings work
    test_fail_groups: bool, // test hook: poison every multi-member write group so the retry path runs
    test_fail_batches: bool, // test hook: poison every multi-member read batch so the retry path runs
};

pub const Shared = struct {
    cfg: Config,
    jwt: jwt.Key,
    bc: bcpool.Pool,
    ready: u32 = 0, // workers that finished start-up
};

pub const Class = enum(u1) { read, write };

// ---------------------------------------------------------------------------------------------
// Requests in flight
// ---------------------------------------------------------------------------------------------

pub const Req = struct {
    next: ?*Req = null,
    fd: i32 = 0,
    gen: u32 = 0,
    kind: api.Kind = .tags,
    keep_alive: bool = true,
    tok_len: u8 = 0,
    remote_owner: u16 = std.math.maxInt(u16),
    remote_token: u64 = 0,
    viewer: i64 = 0,
    aux: u64 = 0,
    blob: []u8 = &.{},
    tok: [max_token]u8 = undefined,

    pub const max_token = 192;

    pub fn setToken(self: *Req, t: []const u8) void {
        self.tok_len = @intCast(t.len);
        @memcpy(self.tok[0..t.len], t);
    }

    pub fn token(self: *const Req) []const u8 {
        return self.tok[0..self.tok_len];
    }
};

// ---------------------------------------------------------------------------------------------
// Connections
// ---------------------------------------------------------------------------------------------

const Conn = struct {
    gen: u32 = 0,
    open: bool = false,
    busy: bool = false,
    close_after: bool = false,
    recv_live: bool = false,
    send_live: bool = false,
    closing: bool = false,
    eof: bool = false, // the peer closed its sending side; finish what is in flight, then close
    tracked: bool = false, // listed in Worker.partials
    since: u32 = 0, // seconds (worker clock) at which an incomplete request started waiting
    pend: [*]u8 = undefined,
    pend_len: u32 = 0, // end of the buffered bytes
    pend_off: u32 = 0, // start of the bytes not yet parsed (requests are consumed from the front without moving the rest)
    pend_cap: u32 = 0,
    out: [*]u8 = undefined,
    out_len: u32 = 0,
    out_off: u32 = 0,
    out_cap: u32 = 0,
    zc_waiting: bool = false,
    send_zc: bool = false,
    shutdown_live: bool = false,
    ack_live: bool = false,
    gzip: bool = false,
    identity: bool = true,
    mss: u16 = 1448,

    fn completeSend(self: *Conn, res: i32, flags: u32) bool {
        const was_zc = self.send_zc;
        self.send_live = false;
        self.send_zc = false;
        if (flags & linux.IORING_CQE_F_MORE != 0) self.zc_waiting = true;
        if (res > 0) self.out_off += @intCast(res);
        return was_zc;
    }
};

const max_pend = http.max_body + http.max_head + 4096;

// user_data layout: tag (8) | gen (24) | index (32)
const Tag = enum(u8) { accept = 1, recv, poll, send, pg_recv, pg_send, event, close, shut, timer, hold, hold_cancel, cancel, write_hold, ack, hub };

inline fn ud(tag: Tag, gen: u32, idx: u32) u64 {
    return (@as(u64, @backingInt(tag)) << 56) | (@as(u64, gen & 0xffffff) << 32) | idx;
}

// ---------------------------------------------------------------------------------------------
// Postgres connections
// ---------------------------------------------------------------------------------------------

const max_depth_cap = 64;

const prepare_list = blk: {
    var out: [sql.prepared.len]pg.Prep = undefined;
    for (sql.prepared, 0..) |x, i| out[i] = .{ .id = x.id, .sql = x.sql, .params = x.params, .results = sql.resultOids(x.id) };
    break :blk out;
};

const max_group = 128;

/// One write request inside a group commit: its encoded statements (with their own trailing Sync, used if the group
/// has to be retried member by member) and how many statements it contributes.
const Member = struct {
    r: *Req,
    k: u8,
    buf: [256]u8 = undefined,
    len: u16 = 0,
    heap: ?[]u8 = null,

    pub fn init(r: *Req, k: u8, bytes: []const u8) ?Member {
        var m = Member{
            .r = r,
            .k = k,
        };
        if (bytes.len <= 256) {
            @memcpy(m.buf[0..bytes.len], bytes);
            m.len = @intCast(bytes.len);
            m.heap = null;
        } else {
            m.heap = gpa.dupe(u8, bytes) catch return null;
        }
        return m;
    }

    pub fn slice(self: *const Member) []const u8 {
        if (self.heap) |h| return h else return self.buf[0..self.len];
    }

    pub fn deinit(self: *Member) void {
        if (self.heap) |h| gpa.free(h);
        self.heap = null;
    }
};

const WRec = struct {
    n: u32,
    array: bool = false,
    m: [max_group]Member,
};

const PgConn = struct {
    fd: i32 = -1,
    gen: u32 = 0,
    class: Class = .read,
    alive: bool = false,
    sending: bool = false,
    recving: bool = false,
    rs: pg.Stream = undefined,
    wa: Buf = .{}, // in flight (immutable while `sending`)
    ws: Buf = .{}, // staging
    wsent: usize = 0,
    q: [max_depth_cap]usize = undefined, // tagged request/record pointer; 0 is an internal ROLLBACK
    qh: u32 = 0,
    depth: u32 = 0,
    ginflight: bool = false, // a group commit is in flight on this (write) connection
    staged: std.ArrayList(Member) = .empty, // writes waiting for the in-flight group to commit
    wrec: WRec = undefined,
    last_stmt: ?sql.Stmt = null,
    staged_since: u64 = 0,
};

const Queued = struct { r: *Req, bytes: []u8 };

const Fifo = struct {
    items: []Queued = &.{},
    head: usize = 0,
    len: usize = 0,

    fn push(self: *Fifo, q: Queued) void {
        if (self.len == self.items.len) {
            const ncap = if (self.items.len == 0) 256 else self.items.len * 2;
            const n = gpa.alloc(Queued, ncap) catch @panic("out of memory");
            for (0..self.len) |i| n[i] = self.items[(self.head + i) % self.items.len];
            if (self.items.len != 0) gpa.free(self.items);
            self.items = n;
            self.head = 0;
        }
        self.items[(self.head + self.len) % self.items.len] = q;
        self.len += 1;
    }

    fn pop(self: *Fifo) ?Queued {
        if (self.len == 0) return null;
        const q = self.items[self.head];
        self.head = (self.head + 1) % self.items.len;
        self.len -= 1;
        return q;
    }
};

/// A read request waiting to be sent: its parameters, kept until a connection has room (so same-kind requests can be
/// merged into one statement).
pub const StageItem = struct {
    r: *Req,
    seq: u64,
    viewer: i64,
    limit: i32,
    offset: i32,
    buf: [128]u8 = undefined,
    len: u16 = 0,
    heap: ?[]u8 = null,
    single_only: bool = false,

    pub fn init(r: *Req, seq: u64, viewer: i64, limit: i32, offset: i32, s: []const u8) ?StageItem {
        var it = StageItem{
            .r = r,
            .seq = seq,
            .viewer = viewer,
            .limit = limit,
            .offset = offset,
        };
        if (s.len <= 128) {
            @memcpy(it.buf[0..s.len], s);
            it.len = @intCast(s.len);
            it.heap = null;
        } else {
            it.heap = gpa.dupe(u8, s) catch return null;
            it.len = @intCast(s.len);
        }
        return it;
    }

    pub fn text(self: *const StageItem) []const u8 {
        if (self.heap) |h| return h else return self.buf[0..self.len];
    }

    pub fn deinit(self: *StageItem) void {
        if (self.heap) |h| gpa.free(h);
        self.heap = null;
    }
};

pub const ReadArgs = struct { viewer: i64 = 0, limit: i32 = 0, offset: i32 = 0, text: []const u8 = "" };

const Stage = struct {
    items: []StageItem = &.{},
    head: usize = 0,
    len: usize = 0,

    fn push(self: *Stage, it: StageItem) void {
        if (self.len == self.items.len) {
            const ncap = if (self.items.len == 0) 64 else self.items.len * 2;
            const n = gpa.alloc(StageItem, ncap) catch @panic("out of memory");
            for (0..self.len) |i| n[i] = self.items[(self.head + i) % self.items.len];
            if (self.items.len != 0) gpa.free(self.items);
            self.items = n;
            self.head = 0;
        }
        self.items[(self.head + self.len) % self.items.len] = it;
        self.len += 1;
    }

    fn front(self: *const Stage) *const StageItem {
        return &self.items[self.head];
    }

    /// Number of items at the front (at most `max`) that may be batched together (none is marked single-only).
    fn batchableRun(self: *const Stage, max: usize) usize {
        var k: usize = 0;
        while (k < self.len and k < max) : (k += 1) {
            if (self.items[(self.head + k) % self.items.len].single_only) break;
        }
        return k;
    }

    fn pop(self: *Stage) StageItem {
        const it = self.items[self.head];
        self.head = (self.head + 1) % self.items.len;
        self.len -= 1;
        return it;
    }
};

/// Which parameters a batchable read takes: (viewer [, limit, offset] [, text]).
fn shapeLo(k: sql.Stmt) bool {
    return switch (k) {
        .list_global, .list_tag, .list_author, .list_fav, .feed => true,
        else => false,
    };
}

fn shapeText(k: sql.Stmt) bool {
    return switch (k) {
        .list_tag, .list_author, .list_fav, .article, .comments, .profile => true,
        else => false,
    };
}

fn isBatchable(k: sql.Stmt) bool {
    inline for (sql.batchable) |b| if (b == k) return true;
    return false;
}

const max_batch = 256;
const sync_len = 5;

const BatchRec = struct {
    n: u32,
    /// All requests share one statement's reply (`tags`: viewer-independent, so one run serves every waiting request).
    fanout: bool = false,
    reqs: [max_batch]*Req,
    /// The requests' parameters, kept (text owned) until the reply: if the statement fails, each request is re-run alone.
    items: [max_batch]StageItem,
    stmt: sql.Stmt,

    fn encode(self: *const BatchRec, e: *pg.Enc) void {
        var viewers: [max_batch]i64 = undefined;
        var limits: [max_batch]i32 = undefined;
        var offsets: [max_batch]i32 = undefined;
        var texts: [max_batch][]const u8 = undefined;
        for (self.items[0..self.n], 0..) |*it, i| {
            viewers[i] = it.viewer;
            limits[i] = it.limit;
            offsets[i] = it.offset;
            // Inline text must be borrowed from the stored item, not a loop-local copy.
            texts[i] = it.text();
        }
        e.bind(sql.batchId(self.stmt));
        e.pInt8Array(viewers[0..self.n]);
        if (shapeLo(self.stmt)) {
            e.pInt4Array(limits[0..self.n]);
            e.pInt4Array(offsets[0..self.n]);
        }
        if (shapeText(self.stmt)) e.pTextArray(texts[0..self.n]);
        e.exec();
    }
};

fn readWindowNs(cfg: *const Config, staged: usize, has_idle_pg: bool) u64 {
    const window_ns = @as(u64, cfg.read_window_us) * std.time.ns_per_us;
    if (!cfg.adaptive_window) return window_ns;
    // Batch what is already waiting, rather than leaving an idle backend behind a timer.
    if (has_idle_pg or staged >= cfg.read_hold_min) return 0;
    const adaptive_ns: u64 = if (staged >= 1024)
        10 * std.time.ns_per_ms
    else if (staged >= 512)
        25 * std.time.ns_per_ms
    else if (staged >= 256)
        35 * std.time.ns_per_ms
    else if (staged >= 128)
        50 * std.time.ns_per_ms
    else
        window_ns;
    return @min(window_ns, adaptive_ns);
}

// ---------------------------------------------------------------------------------------------
// Worker
// ---------------------------------------------------------------------------------------------

const buf_size = 2048;
const n_bufs = 16384;
const bgid = 1;
const quick_ack_zero: i32 = 0;
const slab_size = 4096;
const slab_pool_cap = 256;

pub const Worker = struct {
    shared: *Shared,
    id: usize,
    ring: IoUring = undefined,
    listener: i32 = -1,
    conns: []Conn = &.{},
    now: i64 = 0, // wall clock, seconds: only for token expiry
    mono: u32 = 0, // monotonic seconds: timeouts are measured on this, so a clock step cannot expire or extend one
    out: Buf = .{},
    response_pool: @import("buf.zig").Pool = .{},
    gzip_encoder: @import("gzip.zig").Encoder = .{},
    zip: Buf = .{},
    gzip_mode: u32 = 0,
    gzip_min: u32 = 1024,
    ack_enabled: bool = false,
    enc: Buf = .{},
    scratch: Scratch = undefined,
    free_reqs: ?*Req = null,
    slabs: [slab_pool_cap][*]u8 = undefined,
    slab_count: usize = 0,
    send_zc_enabled: bool = false, // detected capability is worker-local; Shared.cfg stays immutable
    send_zc_min: u32 = 256,
    batch_rec_pool: [64]*BatchRec = undefined,
    batch_rec_count: usize = 0,
    pgs: []PgConn = &.{},
    n_read: usize = 0,
    rr: [2]usize = .{ 0, 0 },
    fifo: [2]Fifo = .{ .{}, .{} },
    stages: [sql.defs.len]Stage = @splat(.{}),
    staged: usize = 0,
    seq: u64 = 0,
    synth: Buf = .{},
    sink: bcpool.Sink = .{},
    efd_val: u64 = 0,
    hub_val: u64 = 0,
    ipc_data: Buf = .{},
    ipc_reply: Buf = .{},
    // provided-buffer ring (null => poll + recv fallback)
    pbuf_ring: ?[*]linux.io_uring_buf = null,
    pbuf_mem: [*]u8 = undefined,
    pbuf_tail: u16 = 0,
    scratch_rx: []u8 = &.{},
    accept_live: bool = false,
    rc_busy: u32 = 0, // a reconnect thread is running (atomic)
    rc_fd: i32 = -1, // a connected, prepared socket waiting for the loop to adopt (atomic)
    partials: std.ArrayList(i32) = .empty,
    tick: linux.kernel_timespec = .{ .sec = 1, .nsec = 0 },
    // Keep two timeout payloads: a timeout may still be completing while a shorter
    // replacement is submitted, so its timespec must not be overwritten.
    hold_ts: [2]linux.kernel_timespec = @splat(.{ .sec = 0, .nsec = 0 }),
    hold_armed: bool = false,
    hold_gen: u32 = 0,
    hold_deadline: u64 = 0,
    staged_since: u64 = 0, // nowNs() when `staged` last went from 0
    write_hold_ts: linux.kernel_timespec = .{ .sec = 0, .nsec = 0 },
    write_hold_armed: bool = false,
    stats: struct { reqs: u64 = 0, pg_batches: u64 = 0, fifo_max: usize = 0, batched_reqs: u64 = 0, batches: u64 = 0, zc_nomem: u64 = 0, send_errors: u64 = 0, array_groups: u64 = 0 } = .{},

    // ---- small helpers ----------------------------------------------------------------------

    pub fn beginBody(self: *Worker) void {
        if (self.out.cap == 0) {
            const mem = if (self.slab_count != 0) blk: {
                self.slab_count -= 1;
                break :blk self.slabs[self.slab_count][0..slab_size];
            } else self.response_pool.take(slab_size);
            self.out = .{ .ptr = mem.ptr, .cap = mem.len, .pool = &self.response_pool };
        }
        self.out.len = 0;
        self.out.ensure(http.head_room + 1024);
        self.out.len = http.head_room;
    }

    fn sqe(self: *Worker) *linux.io_uring_sqe {
        while (true) {
            return self.ring.get_sqe() catch {
                _ = self.ring.submit() catch {};
                continue;
            };
        }
    }

    pub fn newReq(self: *Worker, fd: i32, gen: u32, kind: api.Kind, keep_alive: bool, viewer: i64) *Req {
        const r = self.free_reqs orelse blk: {
            // refill: a slab of requests
            const n = 128;
            const slab = gpa.alloc(Req, n) catch @panic("out of memory");
            for (slab[1..]) |*x| {
                x.* = .{};
                x.next = self.free_reqs;
                self.free_reqs = x;
            }
            slab[0] = .{};
            break :blk &slab[0];
        };
        if (self.free_reqs == r) self.free_reqs = r.next;
        r.* = .{ .fd = fd, .gen = gen, .kind = kind, .keep_alive = keep_alive, .viewer = viewer };
        return r;
    }

    pub fn freeReq(self: *Worker, r: *Req) void {
        if (r.blob.len != 0) gpa.free(r.blob);
        r.blob = &.{};
        r.next = self.free_reqs;
        self.free_reqs = r;
    }

    pub fn allocBatchRec(self: *Worker) ?*BatchRec {
        if (self.batch_rec_count > 0) {
            self.batch_rec_count -= 1;
            return self.batch_rec_pool[self.batch_rec_count];
        }
        return gpa.create(BatchRec) catch null;
    }

    pub fn freeBatchRec(self: *Worker, rec: *BatchRec) void {
        if (self.batch_rec_count < self.batch_rec_pool.len) {
            self.batch_rec_pool[self.batch_rec_count] = rec;
            self.batch_rec_count += 1;
        } else {
            gpa.destroy(rec);
        }
    }

    // ---- sending responses ------------------------------------------------------------------

    pub fn negotiateEncoding(self: *Worker, fd: i32, gzip: bool, identity: bool) void {
        const c = &self.conns[@intCast(fd)];
        c.gzip = gzip;
        c.identity = identity;
    }

    pub fn finishResponse(self: *Worker, fd: i32, gen: u32, code: u16, keep_alive: bool) void {
        const c = &self.conns[@intCast(fd)];
        if (!c.open or c.gen != gen) return;
        var response_code = code;
        var body_len = self.out.len - http.head_room;
        var compressed = false;
        if (self.gzip_mode != 0 and c.gzip and code != 204 and (body_len >= self.gzip_min or !c.identity)) {
            if (self.gzip_encoder.encode(self.out.slice()[http.head_room..], &self.zip, http.head_room)) |z| {
                const mss = @max(@as(usize, 536), c.mss);
                const saves = if (self.gzip_mode == 1) z.len < body_len else (z.len + 200 + mss - 1) / mss < (body_len + 200 + mss - 1) / mss;
                if (saves or !c.identity) {
                    const old = self.out;
                    self.out = self.zip;
                    self.zip = old;
                    body_len = z.len;
                    compressed = true;
                }
            }
        }
        if (code != 204 and !c.identity and !compressed) {
            response_code = 406;
            body_len = 0;
        }
        const resp = http.finishEncodedResponse(self.out.slice(), body_len, response_code, keep_alive, compressed, self.gzip_mode != 0 or !c.identity);
        self.sendOwned(fd, gen, resp, keep_alive);
        if (self.zip.cap > 4 * 1024 * 1024) {
            self.zip.deinit();
            self.zip.pool = &self.response_pool;
        }
    }

    /// Transfer the rendering allocation, including its unused header prefix, to the send lifetime.
    pub fn sendOwned(self: *Worker, fd: i32, gen: u32, resp: []const u8, keep_alive: bool) void {
        const c = &self.conns[@intCast(fd)];
        if (!c.open or c.gen != gen) return;
        std.debug.assert(c.out_cap == 0);
        const start = @intFromPtr(resp.ptr) - @intFromPtr(self.out.ptr);
        c.out = self.out.ptr;
        c.out_off = @intCast(start);
        c.out_len = @intCast(start + resp.len);
        c.out_cap = @intCast(self.out.cap);
        self.out = .{};
        c.close_after = !keep_alive;
        self.stats.reqs += 1;
        self.submitSend(fd, c, true);
    }

    /// Used for externally owned bytes; ordinary API rendering uses sendOwned.
    pub fn sendCopy(self: *Worker, fd: i32, gen: u32, resp: []const u8, keep_alive: bool) void {
        const ufd: usize = @intCast(fd);
        const c = &self.conns[ufd];
        if (!c.open or c.gen != gen) return;

        const owned: []u8 = if (resp.len <= slab_size and self.slab_count > 0) blk: {
            self.slab_count -= 1;
            break :blk self.slabs[self.slab_count][0..slab_size];
        } else if (resp.len <= slab_size) blk: {
            const m = gpa.alloc(u8, slab_size) catch {
                self.closeConn(fd);
                return;
            };
            break :blk m;
        } else blk: {
            const m = gpa.alloc(u8, resp.len) catch {
                self.closeConn(fd);
                return;
            };
            break :blk m;
        };

        @memcpy(owned[0..resp.len], resp);
        c.out = owned.ptr;
        c.out_len = @intCast(resp.len);
        c.out_cap = @intCast(owned.len);
        c.out_off = 0;
        c.close_after = !keep_alive;
        self.stats.reqs += 1;
        self.submitSend(fd, c, true);
    }

    fn submitSend(self: *Worker, fd: i32, c: *Conn, allow_zc: bool) void {
        const s = self.sqe();
        const to_send = (c.out + c.out_off)[0 .. c.out_len - c.out_off];
        c.send_zc = allow_zc and self.send_zc_enabled and to_send.len >= self.send_zc_min and !c.zc_waiting;
        if (c.send_zc) {
            s.prep_send_zc(fd, to_send, linux.MSG.NOSIGNAL, 0);
        } else {
            s.prep_send(fd, to_send, linux.MSG.NOSIGNAL);
        }
        s.user_data = ud(.send, c.gen, @intCast(fd));
        c.send_live = true;
    }

    fn onSend(self: *Worker, fd: i32, gen: u32, res: i32, flags: u32) void {
        const c = &self.conns[@intCast(fd)];
        if (c.gen & 0xffffff != gen) return;

        if (flags & linux.IORING_CQE_F_NOTIF != 0) {
            c.zc_waiting = false;
            self.finishSend(fd, c);
            return;
        }

        // MORE promises a release notification even on partial or failed sends.
        const was_zc = c.completeSend(res, flags);
        if (res <= 0) {
            const err_num = -res;
            const unsupported = err_num == @as(i32, @backingInt(linux.E.OPNOTSUPP)) or err_num == @as(i32, @backingInt(linux.E.INVAL));
            const no_memory = err_num == @as(i32, @backingInt(linux.E.NOMEM));
            if (was_zc and (unsupported or no_memory)) {
                if (unsupported) self.send_zc_enabled = false;
                if (no_memory) {
                    self.stats.zc_nomem += 1;
                    if (self.stats.zc_nomem == 1) log.warn("SEND_ZC returned ENOMEM; falling back to copied SEND", .{});
                }
                // ZC page accounting can exhaust MEMLOCK without breaking the socket.
                // Retry once without ZC; a failed copied attempt follows the normal close path.
                if (c.open) {
                    self.submitSend(fd, c, false);
                    return;
                }
            }
            if (c.open) self.stats.send_errors += 1;
            self.closeConn(fd);
            self.finishSend(fd, c);
            return;
        }
        if (c.out_off < c.out_len and c.open) {
            self.submitSend(fd, c, false);
            return;
        }
        self.finishSend(fd, c);
    }

    fn finishSend(self: *Worker, fd: i32, c: *Conn) void {
        // A tail SEND and the original SEND_ZC notification may complete in either order.
        if (c.send_live or c.zc_waiting) return;
        self.freeOut(c);
        if (!c.open or c.closing) {
            self.maybeFinishClose(fd);
            return;
        }
        c.busy = false;
        if (c.close_after) {
            self.closeConn(fd);
            return;
        }
        if (self.ack_enabled and !c.ack_live and !c.eof) {
            const s = self.sqe();
            s.prep_cmd_sock(.SETSOCKOPT, fd, linux.IPPROTO.TCP, linux.TCP.QUICKACK, @intFromPtr(&quick_ack_zero), @sizeOf(i32));
            s.user_data = ud(.ack, c.gen, @intCast(fd));
            c.ack_live = true;
        }
        if (c.pend_len != 0) self.parsePend(fd, c);
        if (c.eof and c.open and !c.busy) self.closeConn(fd);
    }

    fn freeOut(self: *Worker, c: *Conn) void {
        if (c.zc_waiting or c.send_live) return;
        if (c.out_cap == slab_size and self.slab_count < slab_pool_cap) {
            self.slabs[self.slab_count] = c.out;
            self.slab_count += 1;
        } else if (c.out_cap != 0) {
            self.response_pool.release(c.out[0..c.out_cap]);
        }
        c.out_len = 0;
        c.out_off = 0;
        c.out_cap = 0;
    }

    // ---- connection lifecycle ---------------------------------------------------------------

    fn onAccept(self: *Worker, res: i32, flags: u32) void {
        if (flags & linux.IORING_CQE_F_MORE == 0) self.accept_live = false;
        if (res < 0) return;
        const fd = res;
        if (@as(usize, @intCast(fd)) >= self.conns.len) {
            const s = self.sqe();
            s.prep_close(fd);
            s.user_data = ud(.close, 0, 0);
            return;
        }
        // Linux normally inherits this from the listener, but set it on the
        // accepted socket as well.  A small HTTP reply must never wait for a
        // delayed ACK because an inherited listener option was not honoured.
        const one: c_int = 1;
        _ = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, @ptrCast(&one), @sizeOf(c_int));
        const c = &self.conns[@intCast(fd)];
        c.* = .{ .gen = c.gen +% 1, .open = true };
        if (self.gzip_mode == 2) {
            var mss: i32 = 1448;
            var len: linux.socklen_t = @sizeOf(i32);
            if (sys.errnoOf(linux.getsockopt(fd, linux.IPPROTO.TCP, linux.TCP.MAXSEG, @ptrCast(&mss), &len)) == .SUCCESS)
                c.mss = @intCast(std.math.clamp(mss, 536, 65535));
        }
        self.armRecv(fd, c);
    }

    fn armRecv(self: *Worker, fd: i32, c: *Conn) void {
        const s = self.sqe();
        if (self.pbuf_ring != null) {
            s.prep_rw(.RECV, fd, 0, 0, 0);
            s.ioprio |= linux.IORING_RECV_MULTISHOT;
            s.flags |= linux.IOSQE_BUFFER_SELECT;
            s.buf_index = bgid;
            s.user_data = ud(.recv, c.gen, @intCast(fd));
        } else {
            s.prep_poll_add(fd, linux.POLL.IN | 0x2000);
            s.len = linux.IORING_POLL_ADD_MULTI;
            s.user_data = ud(.poll, c.gen, @intCast(fd));
        }
        c.recv_live = true;
    }

    fn closeConn(self: *Worker, fd: i32) void {
        const c = &self.conns[@intCast(fd)];
        if (!c.open) return;
        c.open = false;
        c.closing = true;
        if (c.pend_cap != 0) gpa.free(c.pend[0..c.pend_cap]);
        c.pend_len = 0;
        c.pend_off = 0;
        c.pend_cap = 0;
        if (self.pbuf_ring == null and c.recv_live) {
            // Poll + recv fallback: a multishot poll does not end on shutdown, so remove it explicitly (its final
            // completion carries this connection's generation and is ignored).
            const rm = self.sqe();
            rm.prep_poll_remove(ud(.poll, c.gen, @intCast(fd)));
            rm.user_data = ud(.cancel, 0, 0);
            c.recv_live = false;
        }
        if (c.recv_live or c.send_live) {
            // SHUTDOWN can resolve its numeric fd on an async worker; keep it open until the CQE.
            const s = self.sqe();
            s.prep_rw(.SHUTDOWN, fd, 0, 0, 0);
            s.len = linux.SHUT.RDWR;
            s.user_data = ud(.shut, c.gen, @intCast(fd));
            c.shutdown_live = true;
        }
        self.maybeFinishClose(fd);
    }

    fn onAck(self: *Worker, fd: i32, gen: u32, res: i32) void {
        const c = &self.conns[@intCast(fd)];
        if (c.gen & 0xffffff != gen) return;
        c.ack_live = false;
        if (res == -@as(i32, @backingInt(linux.E.INVAL)) or res == -@as(i32, @backingInt(linux.E.OPNOTSUPP)) or res == -@as(i32, @backingInt(linux.E.NOSYS))) {
            if (self.ack_enabled) log.info("async TCP_QUICKACK unavailable; disabling ACK delay", .{});
            self.ack_enabled = false;
        }
        self.maybeFinishClose(fd);
    }

    fn onShutdown(self: *Worker, fd: i32, gen: u32) void {
        const c = &self.conns[@intCast(fd)];
        if (c.gen & 0xffffff != gen) return;
        // Failure also retires the operation: its fd lookup is finished.
        c.shutdown_live = false;
        self.maybeFinishClose(fd);
    }

    fn maybeFinishClose(self: *Worker, fd: i32) void {
        const c = &self.conns[@intCast(fd)];
        if (!c.closing or c.recv_live or c.send_live or c.zc_waiting or c.shutdown_live or c.ack_live) return;
        self.freeOut(c);
        c.closing = false;
        c.busy = false;
        const s = self.sqe();
        s.prep_close(fd);
        s.user_data = ud(.close, 0, 0);
    }

    // ---- receiving --------------------------------------------------------------------------

    fn returnBuf(self: *Worker, bid: u16) void {
        const ring = self.pbuf_ring.?;
        const idx = self.pbuf_tail & (n_bufs - 1);
        ring[idx].addr = @intFromPtr(self.pbuf_mem + @as(usize, bid) * buf_size);
        ring[idx].len = buf_size;
        ring[idx].bid = bid;
        self.pbuf_tail +%= 1;
    }

    fn publishBufs(self: *Worker) void {
        const br: *linux.io_uring_buf_ring = @ptrCast(self.pbuf_ring.?);
        @atomicStore(u16, &br.tail, self.pbuf_tail, .release);
    }

    fn onRecv(self: *Worker, fd: i32, gen: u32, res: i32, flags: u32) void {
        const has_buf = flags & linux.IORING_CQE_F_BUFFER != 0;
        const bid: u16 = @intCast(flags >> linux.IORING_CQE_BUFFER_SHIFT);
        const c = &self.conns[@intCast(fd)];
        const stale = c.gen & 0xffffff != gen;
        if (!stale and flags & linux.IORING_CQE_F_MORE == 0) c.recv_live = false;
        defer if (has_buf) self.returnBuf(bid);
        if (stale) return;
        if (res > 0 and c.open) {
            const data = (self.pbuf_mem + @as(usize, bid) * buf_size)[0..@intCast(res)];
            self.onData(fd, c, data);
        }
        if (res == 0 and c.open and c.busy) {
            c.eof = true; // half-close: the response to the request in flight is still owed
        } else if (res <= 0 and c.open) {
            const err: linux.E = @fromBackingInt(@intCast(@as(u16, @intCast(-res))));
            if (res == 0 or (err != .NOBUFS and err != .AGAIN and err != .INTR)) {
                self.closeConn(fd);
            } else if (!c.recv_live) {
                self.armRecv(fd, c); // out of provided buffers: try again
            }
        } else if (c.open and !c.recv_live) {
            self.armRecv(fd, c);
        } else if (!c.open) {
            self.maybeFinishClose(fd);
        }
    }

    fn onPoll(self: *Worker, fd: i32, gen: u32, res: i32, flags: u32) void {
        const c = &self.conns[@intCast(fd)];
        if (c.gen & 0xffffff != gen) return;
        if (flags & linux.IORING_CQE_F_MORE == 0) c.recv_live = false;
        if (!c.open) {
            self.maybeFinishClose(fd);
            return;
        }
        if (res < 0) {
            self.closeConn(fd);
            return;
        }
        // Multishot poll is edge-triggered: unread bytes need not produce another CQE.
        while (c.open) {
            const rc = linux.recvfrom(fd, self.scratch_rx.ptr, self.scratch_rx.len, linux.MSG.DONTWAIT, null, null);
            switch (sys.errnoOf(rc)) {
                .SUCCESS => {
                    if (rc == 0) {
                        if (c.busy) c.eof = true else self.closeConn(fd);
                        break;
                    }
                    self.onData(fd, c, self.scratch_rx[0..rc]);
                },
                .AGAIN => break,
                .INTR => continue,
                else => {
                    self.closeConn(fd);
                    return;
                },
            }
        }
        if (c.open and !c.recv_live) self.armRecv(fd, c);
    }

    /// New bytes from the socket.
    fn onData(self: *Worker, fd: i32, c: *Conn, data: []const u8) void {
        if (c.pend_len == 0 and !c.busy) {
            const used = self.parseLoop(fd, c, data);
            if (used < data.len and c.open) self.stash(fd, c, data[used..]);
        } else {
            self.stash(fd, c, data);
            if (!c.busy and c.open) self.parsePend(fd, c);
        }
    }

    fn stash(self: *Worker, fd: i32, c: *Conn, data: []const u8) void {
        const live = c.pend_len - c.pend_off; // bytes waiting to be parsed
        if (live + data.len > max_pend) {
            self.closeConn(fd);
            return;
        }
        if (c.pend_len + data.len > c.pend_cap) {
            if (c.pend_off >= c.pend_cap / 2 and live + data.len <= c.pend_cap) {
                // at least half of the buffer is already consumed: slide the rest down (every byte moves at most
                // once per half buffer consumed, so the cost stays linear)
                std.mem.copyForwards(u8, c.pend[0..live], c.pend[c.pend_off..c.pend_len]);
                c.pend_off = 0;
                c.pend_len = @intCast(live);
            } else {
                var ncap: usize = @max(512, c.pend_cap);
                while (ncap < live + data.len) ncap *= 2;
                const m = gpa.alloc(u8, ncap) catch {
                    self.closeConn(fd);
                    return;
                };
                if (live != 0) @memcpy(m[0..live], c.pend[c.pend_off..c.pend_len]);
                if (c.pend_cap != 0) gpa.free(c.pend[0..c.pend_cap]);
                c.pend = m.ptr;
                c.pend_cap = @intCast(ncap);
                c.pend_off = 0;
                c.pend_len = @intCast(live);
            }
        }
        @memcpy(c.pend[c.pend_len..][0..data.len], data);
        if (live == 0) c.since = self.mono;
        c.pend_len += @intCast(data.len);
        if (!c.tracked) {
            c.tracked = true;
            self.partials.append(gpa, fd) catch {};
        }
    }

    /// Close connections that have held an incomplete request for too long (slow or stalled clients), so they cannot
    /// pin memory indefinitely. Runs from the 1 s timer.
    fn sweepPartials(self: *Worker) void {
        const limit_s = 30;
        const now = self.mono;
        var i: usize = 0;
        while (i < self.partials.items.len) {
            const fd = self.partials.items[i];
            const c = &self.conns[@intCast(fd)];
            var drop = !c.open or c.pend_len == 0;
            if (!drop and !c.busy and now -% c.since > limit_s) {
                self.closeConn(fd);
                drop = true;
            }
            if (drop) {
                c.tracked = false;
                _ = self.partials.swapRemove(i);
            } else i += 1;
        }
    }

    fn parsePend(self: *Worker, fd: i32, c: *Conn) void {
        const data = c.pend[c.pend_off..c.pend_len];
        const used = self.parseLoop(fd, c, data);
        if (!c.open) return;
        if (used >= data.len) {
            gpa.free(c.pend[0..c.pend_cap]);
            c.pend_len = 0;
            c.pend_off = 0;
            c.pend_cap = 0;
        } else if (used > 0) {
            // the requests before the tail were consumed: the tail is a new request, whose wait starts now
            c.pend_off += @intCast(used);
            c.since = self.mono;
        }
    }

    /// Parse and dispatch as many complete requests as `data` holds (one at a time). Returns bytes consumed.
    fn parseLoop(self: *Worker, fd: i32, c: *Conn, data: []const u8) usize {
        var off: usize = 0;
        while (!c.busy and off < data.len and c.open) {
            self.scratch.reset();
            const rest = data[off..];
            const head = switch (http.parseHead(rest)) {
                .need_more => break,
                .bad => |code| {
                    self.badRequest(fd, c, code);
                    return data.len;
                },
                .ok => |h| h,
            };
            const body = switch (http.takeBody(&head, rest[head.head_len..], &self.scratch)) {
                .need_more => break,
                .bad => |code| {
                    self.badRequest(fd, c, code);
                    return data.len;
                },
                .ok => |b| b,
            };
            off += head.head_len + body.consumed;
            c.busy = true;
            api.handle(self, fd, c.gen, head, body.data);
        }
        return off;
    }

    fn badRequest(self: *Worker, fd: i32, c: *Conn, code: u16) void {
        c.busy = true;
        self.beginBody();
        self.out.putSlice("{\"errors\":{\"body\":[\"bad request\"]}}");
        const body_len = self.out.len - http.head_room;
        const resp = http.finishResponse(self.out.ptr[0..self.out.len], body_len, code, false);
        self.sendOwned(fd, c.gen, resp, false);
    }

    // ---- Postgres pool ----------------------------------------------------------------------

    fn classRange(self: *const Worker, class: Class) struct { lo: usize, hi: usize } {
        return switch (class) {
            .read => .{ .lo = 0, .hi = self.n_read },
            .write => .{ .lo = self.n_read, .hi = self.pgs.len },
        };
    }

    /// Queue an encoded batch (Bind/Execute.../Sync) for `r`; the reply is delivered to `api.onPg`.
    pub fn pgSubmit(self: *Worker, class: Class, r: *Req, bytes: []const u8) void {
        if (class == .read and self.shared.cfg.hub != null and !self.shared.cfg.coordinator) {
            return self.askHub(r, .{ .format = 1 }, bytes);
        }
        const range = self.classRange(class);
        const cap = if (class == .read) self.shared.cfg.read_depth else self.shared.cfg.pg_depth;
        // least-loaded live connection with room; rotate the start so ties spread out
        var best: ?*PgConn = null;
        const n = range.hi - range.lo;
        if (n != 0) {
            var i: usize = 0;
            const start = self.rr[@backingInt(class)];
            while (i < n) : (i += 1) {
                const p = &self.pgs[range.lo + (start + i) % n];
                // A group may need ROLLBACK; never pipeline unrelated writes behind its outcome.
                if (!p.alive or p.ginflight or p.depth >= cap) continue;
                if (best == null or p.depth < best.?.depth) best = p;
            }
            self.rr[@backingInt(class)] = (start + 1) % n;
        }
        if (best) |p| {
            self.pgPush(p, @intFromPtr(r), bytes);
            return;
        }
        var any_alive = false;
        for (self.pgs[range.lo..range.hi]) |*p| any_alive = any_alive or p.alive;
        if (!any_alive) return api.onPgFailure(self, r);
        const copy = gpa.dupe(u8, bytes) catch return api.onPgFailure(self, r);
        const f = &self.fifo[@backingInt(class)];
        f.push(.{ .r = r, .bytes = copy });
        if (f.len > self.stats.fifo_max) self.stats.fifo_max = f.len;
    }

    fn pgPush(self: *Worker, p: *PgConn, token: usize, bytes: []const u8) void {
        const cap = if (p.class == .read) self.shared.cfg.read_depth else self.shared.cfg.pg_depth;
        std.debug.assert(p.depth < cap and p.depth < max_depth_cap);
        p.ws.putSlice(bytes);
        p.q[(p.qh + p.depth) % max_depth_cap] = token;
        p.depth += 1;
        if (!p.sending) self.pgFlush(p);
    }

    fn pgFlush(self: *Worker, p: *PgConn) void {
        if (!p.alive or p.ws.len == 0 or p.sending) return;
        const t = p.wa;
        p.wa = p.ws;
        p.ws = t;
        p.ws.reset();
        p.wsent = 0;
        p.sending = true;
        const idx: u32 = @intCast(p - self.pgs.ptr);
        const s = self.sqe();
        s.prep_send(p.fd, p.wa.slice(), linux.MSG.NOSIGNAL);
        s.user_data = ud(.pg_send, p.gen, idx);
    }

    fn onPgSend(self: *Worker, idx: u32, gen: u32, res: i32) void {
        const p = &self.pgs[idx];
        if (p.gen & 0xffffff != gen) return;
        p.sending = false;
        if (!p.alive) return self.pgFinishClose(p);
        if (res <= 0) return self.pgFail(p);
        p.wsent += @intCast(res);
        if (p.wsent < p.wa.len) {
            p.sending = true;
            const s = self.sqe();
            s.prep_send(p.fd, p.wa.slice()[p.wsent..], linux.MSG.NOSIGNAL);
            s.user_data = ud(.pg_send, p.gen, idx);
            return;
        }
        p.wa.reset();
        p.wsent = 0;
        if (p.ws.len != 0) self.pgFlush(p);
    }

    fn pgArmRecv(self: *Worker, p: *PgConn) void {
        if (p.recving or !p.alive) return;
        const space = p.rs.space(16 * 1024);
        const s = self.sqe();
        s.prep_recv(p.fd, space, 0);
        s.user_data = ud(.pg_recv, p.gen, @intCast(p - self.pgs.ptr));
        p.recving = true;
    }

    fn onPgRecv(self: *Worker, idx: u32, gen: u32, res: i32) void {
        const p = &self.pgs[idx];
        if (p.gen & 0xffffff != gen) return;
        p.recving = false;
        if (!p.alive) return self.pgFinishClose(p);
        if (res <= 0) return self.pgFail(p);
        p.rs.received(@intCast(res));
        while (p.rs.nextBatch()) |batch| {
            if (p.depth == 0) {
                log.err("unexpected postgres batch", .{});
                p.rs.done();
                continue;
            }
            const token = p.q[p.qh];
            p.qh = (p.qh + 1) % max_depth_cap;
            p.depth -= 1;
            self.stats.pg_batches += 1;
            if (token == 0) {
                if (batch[batch.len - 1] != 'I') {
                    p.rs.done();
                    self.pgFail(p);
                    return;
                }
            } else switch (token & 7) {
                0 => api.onPg(self, @ptrFromInt(token), batch),
                1 => self.onBatchReply(@ptrFromInt(token & ~@as(usize, 7)), batch),
                2 => self.onGroupReply(p, @ptrFromInt(token & ~@as(usize, 7)), batch),
                3 => self.onPlanReply(p, @ptrFromInt(token & ~@as(usize, 7)), batch),
                4 => self.onPackedReply(@ptrFromInt(token & ~@as(usize, 7)), batch),
                else => unreachable,
            }
            p.rs.done();
        }
        self.pgDrain(self.classOf(p));
        self.flushReads();
        self.pgArmRecv(p);
    }

    fn classOf(self: *const Worker, p: *const PgConn) Class {
        _ = self;
        return p.class;
    }

    /// Move queued batches onto connections that have room.
    fn pgDrain(self: *Worker, class: Class) void {
        const f = &self.fifo[@backingInt(class)];
        const range = self.classRange(class);
        const cap = if (class == .read) self.shared.cfg.read_depth else self.shared.cfg.pg_depth;
        while (f.len != 0) {
            var best: ?*PgConn = null;
            for (self.pgs[range.lo..range.hi]) |*p| {
                if (!p.alive or p.ginflight or p.depth >= cap) continue;
                if (best == null or p.depth < best.?.depth) best = p;
            }
            const p = best orelse return;
            const q = f.pop().?;
            self.pgPush(p, @intFromPtr(q.r), q.bytes);
            gpa.free(q.bytes);
        }
        if (class == .write) {
            for (self.pgs[range.lo..range.hi]) |*p| self.sendGroup(p);
        }
    }

    fn pgFail(self: *Worker, p: *PgConn) void {
        if (!p.alive) return;
        if (!@import("builtin").is_test) log.err("postgres connection {d} lost", .{@as(usize, @intCast(p - self.pgs.ptr))});
        p.alive = false;
        // Wake pending I/O without releasing the numeric fd or its buffers. Queued SQEs
        // can still resolve this descriptor until their send/receive CQEs have retired.
        _ = linux.shutdown(p.fd, linux.SHUT.RDWR);
        // Fail what was in flight on this connection; nothing is replayed (a write may have committed).
        var i: u32 = 0;
        while (i < p.depth) : (i += 1) self.failToken(p.q[(p.qh + i) % max_depth_cap]);
        p.depth = 0;
        p.qh = 0;
        p.ginflight = false;
        for (p.staged.items) |*mem| {
            api.onPgFailure(self, mem.r);
            mem.deinit();
        }
        p.staged.clearRetainingCapacity();
        p.ws.reset();
        self.pgFinishClose(p);
        // Anything waiting for this class can still be served by the surviving connections, else it fails.
        const range = self.classRange(p.class);
        var any = false;
        for (self.pgs[range.lo..range.hi]) |*x| any = any or x.alive;
        if (!any) {
            const f = &self.fifo[@backingInt(p.class)];
            while (f.pop()) |q| {
                gpa.free(q.bytes);
                api.onPgFailure(self, q.r);
            }
        }
    }

    fn pgFinishClose(self: *Worker, p: *PgConn) void {
        _ = self;
        if (p.alive or p.sending or p.recving or p.fd < 0) return;
        _ = linux.close(p.fd);
        p.fd = -1;
        p.wa.reset();
        p.wsent = 0;
        p.rs.start = 0;
        p.rs.scan = 0;
        p.rs.end = 0;
    }

    /// Dead Postgres connections are replaced by a helper thread, so a slow or stalled server cannot freeze the loop;
    /// the loop adopts the finished socket from `onEvent` after the failed socket's I/O retires.
    fn pgReconnect(self: *Worker) void {
        var dead = false;
        for (self.pgs) |*p| dead = dead or (!p.alive and p.fd < 0 and !p.sending and !p.recving);
        if (!dead) return;
        if (@cmpxchgStrong(u32, &self.rc_busy, 0, 1, .acq_rel, .monotonic) != null) return;
        const t = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, Worker.reconnectMain, .{self}) catch {
            @atomicStore(u32, &self.rc_busy, 0, .release);
            return;
        };
        t.detach();
    }

    fn reconnectMain(self: *Worker) void {
        if (pg.connect(self.shared.cfg.db)) |fd| {
            if (pg.prepareAll(fd, &prepare_list)) {
                pg.clearTimeouts(fd);
                setNonblock(fd);
                @atomicStore(i32, &self.rc_fd, fd, .release);
                var one: u64 = 1;
                _ = linux.write(self.sink.efd, std.mem.asBytes(&one), 8);
                return;
            } else |_| _ = linux.close(fd);
        } else |_| {}
        @atomicStore(u32, &self.rc_busy, 0, .release);
    }

    fn adoptReconnected(self: *Worker, fd: i32) void {
        for (self.pgs) |*p| {
            if (p.alive or p.fd >= 0 or p.sending or p.recving) continue;
            p.fd = fd;
            p.gen +%= 1;
            p.alive = true;
            log.info("postgres connection re-established", .{});
            self.pgArmRecv(p);
            self.pgDrain(p.class);
            self.flushReads();
            return;
        }
        _ = linux.close(fd);
    }

    fn failToken(self: *Worker, token: usize) void {
        if (token == 0) return;
        switch (token & 7) {
            0 => api.onPgFailure(self, @ptrFromInt(token)),
            1 => {
                const rec: *BatchRec = @ptrFromInt(token & ~@as(usize, 3));
                for (rec.reqs[0..rec.n]) |r| api.onPgFailure(self, r);
                if (!rec.fanout) for (rec.items[0..rec.n]) |*it| it.deinit();
                self.freeBatchRec(rec);
            },
            2 => {
                const rec: *WRec = @ptrFromInt(token & ~@as(usize, 3));
                for (rec.m[0..rec.n]) |*mem| {
                    api.onPgFailure(self, mem.r);
                    mem.deinit();
                }
            },
            3 => {
                const rec: *plan.Plan = @ptrFromInt(token & ~@as(usize, 7));
                for (rec.items) |it| api.onPgFailure(self, it.r);
                plan.destroy(rec, true);
            },
            4 => {
                const rec: *pack.Batch = @ptrFromInt(token & ~@as(usize, 7));
                for (rec.items) |it| api.onPgFailure(self, it.r);
                pack.destroy(rec, true);
            },
            else => unreachable,
        }
    }

    // ---- staged (batchable) reads ---------------------------------------------------------------

    /// Queue a read; it is sent when a connection has room, merged with waiting reads of the same kind.
    pub fn readSubmit(self: *Worker, stmt: sql.Stmt, r: *Req, a: ReadArgs) void {
        if (self.shared.cfg.hub != null and !self.shared.cfg.coordinator) {
            return self.askHub(r, .{ .stmt = @backingInt(stmt), .viewer = a.viewer, .limit = a.limit, .offset = a.offset }, a.text);
        }
        self.seq += 1;
        const it = StageItem.init(r, self.seq, a.viewer, a.limit, a.offset, a.text) orelse return api.onPgFailure(self, r);
        if (self.staged == 0) self.staged_since = sys.nowNs();
        self.stages[@backingInt(stmt)].push(it);
        self.staged += 1;
    }

    fn bestReadConn(self: *Worker, hint: ?sql.Stmt) ?*PgConn {
        const cap = self.shared.cfg.read_depth;
        const n = self.n_read;
        if (n == 0) return null;
        var min_conn: ?*PgConn = null;
        var min_depth: u32 = std.math.maxInt(u32);
        var affinity_conn: ?*PgConn = null;

        var i: usize = 0;
        const start = self.rr[0];
        while (i < n) : (i += 1) {
            const p = &self.pgs[(start + i) % n];
            if (!p.alive or p.depth >= cap) continue;
            if (p.depth < min_depth) {
                min_depth = p.depth;
                min_conn = p;
            }
            if (hint != null and p.last_stmt == hint.? and affinity_conn == null) {
                affinity_conn = p;
            }
        }
        self.rr[0] = (start + 1) % n;

        // If a connection has warm query cache affinity and its depth is within slack of the minimum, prefer it.
        const slack: u32 = 2;
        if (affinity_conn) |ac| {
            if (ac.depth == min_depth or (min_depth != 0 and ac.depth <= min_depth + slack)) {
                return ac;
            }
        }
        return min_conn;
    }

    fn cancelHold(self: *Worker) void {
        if (!self.hold_armed) return;
        const old = ud(.hold, self.hold_gen, 0);
        const e = self.sqe();
        e.prep_timeout_remove(old, 0);
        e.user_data = ud(.hold_cancel, self.hold_gen, 0);
        self.hold_armed = false;
        self.hold_deadline = 0;
    }

    /// Arm the hold timer at `deadline`, replacing it only when the new window
    /// is sooner.  This is what makes an adaptive window actually contract.
    fn armHold(self: *Worker, deadline: u64) void {
        if (self.hold_armed and deadline >= self.hold_deadline) return;
        self.cancelHold();
        self.hold_gen +%= 1;
        const ts = &self.hold_ts[self.hold_gen & 1];
        const left = deadline -| sys.nowNs();
        ts.* = .{ .sec = @intCast(left / std.time.ns_per_s), .nsec = @intCast(left % std.time.ns_per_s) };
        const e = self.sqe();
        e.prep_timeout(ts, 0, 0);
        e.user_data = ud(.hold, self.hold_gen, 0);
        self.hold_armed = true;
        self.hold_deadline = deadline;
    }

    /// Send staged reads to connections with room, oldest kind first.
    pub fn flushReads(self: *Worker) void {
        if (self.staged == 0) return;
        if (self.shared.cfg.coordinator and self.shared.cfg.hub.?.blocked()) return;
        var has_idle_pg = false;
        for (self.pgs[0..self.n_read]) |*p| {
            if (p.alive and p.depth == 0) {
                has_idle_pg = true;
                break;
            }
        }
        const effective_window_ns = readWindowNs(&self.shared.cfg, self.staged, has_idle_pg);

        if (effective_window_ns != 0 and self.staged < self.shared.cfg.read_hold_min) {
            // Young and few: wait for company. One timeout wakes the loop when the oldest has waited the window out.
            const waited = sys.nowNs() -| self.staged_since;
            if (waited < effective_window_ns) {
                self.armHold(self.staged_since + effective_window_ns);
                return;
            }
        }
        self.cancelHold();
        const batch_max = @min(self.shared.cfg.batch_max, max_batch);
        while (self.staged != 0) {
            var any_alive = false;
            for (self.pgs[0..self.n_read]) |*x| any_alive = any_alive or x.alive;
            if (!any_alive) {
                // nothing can serve them: fail everything staged
                for (&self.stages) |*st| {
                    while (st.len != 0) {
                        var it = st.pop();
                        it.deinit();
                        api.onPgFailure(self, it.r);
                    }
                }
                self.staged = 0;
                return;
            }
            if (self.shared.cfg.plan_min != 0 and self.staged >= self.shared.cfg.plan_min) {
                switch (self.startPlan()) {
                    .started => continue,
                    .no_conn => return,
                    .declined => {},
                }
            }
            // oldest waiting kind
            var kind: usize = 0;
            var best_seq: u64 = std.math.maxInt(u64);
            for (&self.stages, 0..) |*st, k| {
                if (st.len != 0 and st.front().seq < best_seq) {
                    best_seq = st.front().seq;
                    kind = k;
                }
            }
            const st = &self.stages[kind];
            const stmt: sql.Stmt = @fromBackingInt(@intCast(kind));
            const p = self.bestReadConn(stmt) orelse return;
            p.last_stmt = stmt;
            const n: usize = if (st.front().single_only) 1 else if (isBatchable(stmt) or stmt == .tags) st.batchableRun(batch_max) else 1;
            self.enc.reset();
            var e = pg.Enc.init(&self.enc);
            if (stmt == .tags and n > 1) {
                // One execution answers all of them: they were all waiting before it started, and nothing is kept after.
                const rec = self.allocBatchRec() orelse return;
                rec.n = @intCast(n);
                rec.fanout = true;
                rec.stmt = .tags;
                for (0..n) |i| {
                    var it = st.pop();
                    rec.reqs[i] = it.r;
                    it.deinit();
                }
                self.staged -= n;
                e.bind(sql.id(.tags));
                e.pInt8(0);
                e.exec();
                e.sync();
                self.pgPush(p, @intFromPtr(rec) | 1, self.enc.slice());
            } else if (n == 1) {
                var it = st.pop();
                self.staged -= 1;
                e.bind(sql.id(stmt));
                e.pInt8(it.viewer);
                if (shapeLo(stmt)) {
                    e.pInt4(it.limit);
                    e.pInt4(it.offset);
                }
                if (shapeText(stmt)) e.pText(it.text());
                e.exec();
                e.sync();
                it.deinit();
                self.pgPush(p, @intFromPtr(it.r), self.enc.slice());
            } else {
                const rec = self.allocBatchRec() orelse return;
                rec.n = @intCast(n);
                rec.fanout = false; // create() does not apply field defaults
                rec.stmt = stmt;
                for (0..n) |i| {
                    rec.items[i] = st.pop();
                    rec.reqs[i] = rec.items[i].r;
                }
                self.staged -= n;
                rec.encode(&e);
                if (self.shared.cfg.test_fail_batches) {
                    // a Bind to a statement that does not exist: the whole batch errors, as a poisoned request would
                    self.enc.putSlice("B\x00\x00\x00\x11\x00s9999\x00\x00\x00\x00\x00\x00\x00");
                    self.enc.putSlice("E\x00\x00\x00\x09\x00\x00\x00\x00\x00");
                }
                e.sync();
                self.pgPush(p, @intFromPtr(rec) | 1, self.enc.slice());
            }
        }
    }

    const PlanStart = enum { started, no_conn, declined };

    /// Answer every staged read (all kinds) with one planned batch: see plan.zig.
    fn startPlan(self: *Worker) PlanStart {
        const p = self.bestReadConn(null) orelse return .no_conn;
        p.last_stmt = null;
        var taken: std.ArrayList(plan.Taken) = .empty;
        defer taken.deinit(gpa);
        var kept: std.ArrayList(plan.Taken) = .empty; // single-only retries stay on the per-kind path
        defer kept.deinit(gpa);
        // How many reads this plan takes. Without a split it takes up to the cap, so one connection gets the whole backlog
        // and the others sit idle; with a split the staged reads are shared over the connections that have room.
        const cap: usize = self.shared.cfg.plan_max;
        var want: usize = cap;
        if (self.shared.cfg.plan_split) {
            const free = self.freeReadConns();
            want = std.math.clamp((self.staged + free - 1) / free, @as(usize, self.shared.cfg.plan_min), cap);
        }
        const share_comments = self.sharedComments();
        // Oldest first across eligible kinds; dedicated comments and isolated retries remain independent.
        while (taken.items.len < want) {
            var best: ?usize = null;
            var best_seq: u64 = std.math.maxInt(u64);
            for (&self.stages, 0..) |*st, k| {
                if (st.len != 0 and st.front().seq < best_seq) {
                    best_seq = st.front().seq;
                    best = k;
                }
            }
            const k = best orelse break;
            const stmt: sql.Stmt = @fromBackingInt(@intCast(k));
            const it = self.stages[k].pop();
            const t = plan.Taken{ .stmt = stmt, .it = it };
            if (it.single_only or (self.shared.cfg.packed_reads and pack.kind(stmt) == null) or (stmt == .comments and !share_comments))
                kept.append(gpa, t) catch return self.unstage(&taken, &kept)
            else
                taken.append(gpa, t) catch return self.unstage(&taken, &kept);
        }
        if (taken.items.len < self.shared.cfg.plan_min) return self.unstage(&taken, &kept);
        const token: usize = if (self.shared.cfg.packed_reads) blk: {
            const rec = pack.start(self, taken.items) orelse return self.unstage(&taken, &kept);
            break :blk @intFromPtr(rec) | 4;
        } else blk: {
            const rec = plan.start(self, taken.items) orelse return self.unstage(&taken, &kept);
            break :blk @intFromPtr(rec) | 3;
        };
        for (kept.items) |t| self.stages[@backingInt(t.stmt)].push(t.it);
        self.staged -= taken.items.len;
        self.pgPush(p, token, self.enc.slice());
        return .started;
    }

    fn sharedComments(self: *Worker) bool {
        const st = &self.stages[@backingInt(sql.Stmt.comments)];
        const n = @min(st.len, self.shared.cfg.plan_max);
        if (n < 2) return false;
        var keys: std.StringHashMapUnmanaged(void) = .empty;
        defer keys.deinit(gpa);
        for (0..n) |i| {
            const it = &st.items[(st.head + i) % st.items.len];
            keys.put(gpa, it.text(), {}) catch return false;
        }
        return keys.count() * 100 <= n * self.shared.cfg.comments_shared_pct;
    }

    fn onPackedReply(self: *Worker, rec: *pack.Batch, batch: []const u8) void {
        if (pack.onReply(self, rec, batch)) {
            self.stats.batched_reqs += rec.items.len;
            self.stats.batches += 1;
            pack.destroy(rec, true);
        } else {
            log.warn("planned batch failed (packed); retrying its {d} requests one by one", .{rec.items.len});
            for (rec.items, rec.stmts) |it, stmt| {
                var again = it;
                again.single_only = true;
                self.stages[@backingInt(stmt)].push(again);
                self.staged += 1;
            }
            pack.destroy(rec, false);
        }
    }

    /// Read connections that are alive and have room for another batch.
    fn freeReadConns(self: *Worker) usize {
        var n: usize = 0;
        for (self.pgs[0..self.n_read]) |*p| {
            if (p.alive and p.depth < self.shared.cfg.read_depth) n += 1;
        }
        return @max(n, 1);
    }

    /// Put taken reads back on their stages (the plan was not started).
    fn unstage(self: *Worker, taken: *std.ArrayList(plan.Taken), kept: *std.ArrayList(plan.Taken)) PlanStart {
        for (taken.items) |t| self.stages[@backingInt(t.stmt)].push(t.it);
        for (kept.items) |t| self.stages[@backingInt(t.stmt)].push(t.it);
        return .declined;
    }

    fn onPlanReply(self: *Worker, p: *PgConn, rec: *plan.Plan, batch: []const u8) void {
        switch (plan.onReply(self, rec, batch)) {
            .send_b => self.pgPush(p, @intFromPtr(rec) | 3, self.enc.slice()),
            .done => {
                self.stats.batched_reqs += rec.items.len;
                self.stats.batches += 1;
                plan.destroy(rec, true);
            },
            .failed => {
                // Run every member alone: a request that cannot be answered fails by itself instead of taking the batch down.
                log.warn("planned batch failed; retrying its {d} requests one by one", .{rec.items.len});
                for (rec.items, rec.stmts) |it, stmt| {
                    var again = it;
                    again.single_only = true;
                    self.stages[@backingInt(stmt)].push(again);
                    self.staged += 1;
                }
                plan.destroy(rec, false);
            },
        }
    }

    /// Reply to a batched statement: rows are tagged with the request's 1-based ordinal in their first column.
    /// Each request gets a synthetic single-statement reply (rows without that column) so handlers are unchanged.
    fn onBatchReply(self: *Worker, rec: *BatchRec, batch: []const u8) void {
        defer self.freeBatchRec(rec);
        self.stats.batched_reqs += rec.n;
        self.stats.batches += 1;
        if (rec.fanout) {
            for (rec.reqs[0..rec.n]) |r| api.onPg(self, r, batch);
            return;
        }
        var errored = false;
        var scan = pg.Reader{ .data = batch };
        while (scan.next()) |m| {
            if (m.kind == 'E') errored = true;
        }
        if (errored) {
            // Run every member alone: a request that cannot be answered fails by itself instead of taking the batch down.
            log.warn("batched statement failed; retrying its {d} requests one by one", .{rec.n});
            for (rec.items[0..rec.n]) |it| {
                var again = it;
                again.single_only = true;
                self.stages[@backingInt(rec.stmt)].push(again);
                self.staged += 1;
            }
            return;
        }
        defer for (rec.items[0..rec.n]) |*it| it.deinit();
        self.deliverOrdinals(rec.reqs[0..rec.n], batch);
    }

    fn deliverOrdinals(self: *Worker, reqs: []const *Req, batch: []const u8) void {
        var rd = pg.Reader{ .data = batch };
        var pending: ?pg.Msg = null;
        const syn = &self.synth;
        var idx: u32 = 0;
        while (idx < reqs.len) : (idx += 1) {
            syn.reset();
            const want: i64 = @as(i64, idx) + 1;
            while (true) {
                const m = pending orelse (rd.next() orelse break);
                pending = null;
                if (m.kind != 'D') continue;
                const ord = std.mem.readInt(i64, m.body[6..14], .big);
                if (ord != want) {
                    pending = m;
                    break;
                }
                const rest = m.body[14..];
                const ncols = std.mem.readInt(u16, m.body[0..2], .big) - 1;
                syn.put('D');
                syn.putInt(u32, @intCast(4 + 2 + rest.len), .big);
                syn.putInt(u16, ncols, .big);
                syn.putSlice(rest);
            }
            syn.putSlice("C\x00\x00\x00\x0dSELECT 0\x00");
            syn.putSlice("Z\x00\x00\x00\x05I");
            api.onPg(self, reqs[idx], syn.slice());
        }
    }

    // ---- group commit for writes ------------------------------------------------------------------

    /// Queue a write. While a transaction is committing on a write connection, further writes wait and then go out
    /// together as ONE transaction (one WAL flush for all of them). If that transaction fails, nothing was committed,
    /// and every member is retried on its own. `k` is the number of statements in `bytes`.
    pub fn writeSubmit(self: *Worker, r: *Req, bytes: []const u8, k: u8) void {
        const range = self.classRange(.write);
        var best: ?*PgConn = null;
        var best_load: usize = std.math.maxInt(usize);
        for (self.pgs[range.lo..range.hi]) |*p| {
            if (!p.alive) continue;
            const load = (if (p.ginflight) @as(usize, 1000) else 0) + p.staged.items.len;
            if (load < best_load) {
                best_load = load;
                best = p;
            }
        }
        const p = best orelse return api.onPgFailure(self, r);
        const mem = Member.init(r, k, bytes) orelse return api.onPgFailure(self, r);
        if (p.staged.items.len == 0) p.staged_since = sys.nowNs();
        p.staged.append(gpa, mem) catch {
            var m = mem;
            m.deinit();
            return api.onPgFailure(self, r);
        };
        if (!p.ginflight) self.sendGroup(p);
    }

    fn sendGroup(self: *Worker, p: *PgConn) void {
        if (!p.alive or p.ginflight or p.depth >= self.shared.cfg.pg_depth) return;
        const cap = std.math.clamp(self.shared.cfg.write_group_max, 1, max_group);
        const n = @min(p.staged.items.len, cap);
        if (n == 0) return;
        const deadline = p.staged_since + @as(u64, self.shared.cfg.write_window_us) * std.time.ns_per_us;
        const now = sys.nowNs();
        if (n < cap and now < deadline) {
            if (!self.write_hold_armed) {
                const left = deadline - now;
                self.write_hold_ts = .{ .sec = @intCast(left / std.time.ns_per_s), .nsec = @intCast(left % std.time.ns_per_s) };
                const s = self.sqe();
                s.prep_timeout(&self.write_hold_ts, 0, 0);
                s.user_data = ud(.write_hold, 0, 0);
                self.write_hold_armed = true;
            }
            return;
        }
        const rec = &p.wrec;
        rec.n = @intCast(n);
        self.enc.reset();
        var e = pg.Enc.init(&self.enc);
        // A Sync only ends an extended-protocol cycle; it is not a database
        // commit.  Keep every grouped write in one real transaction so a 2xx
        // response makes its effects visible to the following request.
        e.bind(sql.id(.tx_begin));
        e.exec();
        for (0..n) |i| rec.m[i] = p.staged.items[i];
        rec.array = self.shared.cfg.write_arrays and mutations.encode(&e, rec.m[0..n]);
        if (rec.array) self.stats.array_groups += 1;
        if (!rec.array) for (rec.m[0..n]) |*m| {
            const bytes = m.slice();
            self.enc.putSlice(bytes[0 .. bytes.len - sync_len]);
        };
        if (self.shared.cfg.test_fail_groups and n >= 2) {
            // Bind to a statement that does not exist: the server answers with an error and rolls the group back.
            self.enc.putSlice("B\x00\x00\x00\x11\x00s9999\x00\x00\x00\x00\x00\x00\x00");
            self.enc.putSlice("E\x00\x00\x00\x09\x00\x00\x00\x00\x00");
        }
        e.bind(sql.id(.tx_commit));
        e.exec();
        e.sync();
        const rest = p.staged.items.len - n;
        std.mem.copyForwards(Member, p.staged.items[0..rest], p.staged.items[n..]);
        p.staged.shrinkRetainingCapacity(rest);
        p.ginflight = true;
        self.pgPush(p, @intFromPtr(rec) | 2, self.enc.slice());
    }

    fn onGroupReply(self: *Worker, p: *PgConn, rec: *WRec, batch: []const u8) void {
        p.ginflight = false;
        var errored = false;
        var scan = pg.Reader{ .data = batch };
        while (scan.next()) |m| {
            if (m.kind == 'E') errored = true;
        }
        if (errored) {
            // Extended-protocol errors skip COMMIT until Sync, leaving the transaction aborted.
            // Queue ROLLBACK before any retries or later groups can reuse this connection.
            log.warn("write group failed; rolling back and retrying its {d} requests one by one", .{rec.n});
            self.pgPush(p, 0, "Q\x00\x00\x00\x0dROLLBACK\x00");
            for (rec.m[0..rec.n]) |*mem| {
                self.soloWrite(mem.r, mem.slice());
                mem.deinit();
            }
        } else if (rec.array) {
            var reqs: [max_group]*Req = undefined;
            for (rec.m[0..rec.n], 0..) |m, i| reqs[i] = m.r;
            self.deliverOrdinals(reqs[0..rec.n], batch);
            for (rec.m[0..rec.n]) |*m| m.deinit();
        } else {
            var rd = pg.Reader{ .data = batch };
            var start: usize = 0;
            var idx: usize = 0;
            var seen: u32 = 0;
            var began = false;
            const syn = &self.synth;
            while (idx < rec.n) {
                const m = rd.next() orelse break;
                if (m.kind != 'C') continue;
                if (!began) {
                    // Exclude BEGIN from every synthetic member reply.  The
                    // full batch has already reached ReadyForQuery, so the
                    // COMMIT below it completed before a response is sent.
                    began = true;
                    start = rd.pos;
                    continue;
                }
                seen += 1;
                if (seen < rec.m[idx].k) continue;
                syn.reset();
                syn.putSlice(batch[start..rd.pos]);
                syn.putSlice("Z\x00\x00\x00\x05I");
                start = rd.pos;
                seen = 0;
                var mem = rec.m[idx];
                idx += 1;
                api.onPg(self, mem.r, syn.slice());
                mem.deinit();
            }
            while (idx < rec.n) : (idx += 1) { // reply shorter than expected: should not happen
                api.onPgFailure(self, rec.m[idx].r);
                rec.m[idx].deinit();
            }
        }
        self.pgDrain(.write);
    }

    /// One write as its own transaction (unique-violation-prone statements and group retries).
    pub fn soloWrite(self: *Worker, r: *Req, bytes: []const u8) void {
        self.pgSubmit(.write, r, bytes);
    }

    // ---- bcrypt -----------------------------------------------------------------------------

    pub fn bcryptSubmit(self: *Worker, r: *Req, kind: bcpool.Kind, password: []const u8, parsed: ?bcrypt.Parsed) void {
        var job: bcpool.Job = .{
            .kind = kind,
            .cost = 10,
            .plen = @intCast(password.len),
            .password = undefined,
            .salt = undefined,
            .expect = undefined,
            .tag = @intFromPtr(r),
            .sink = &self.sink,
        };
        @memcpy(job.password[0..password.len], password);
        if (parsed) |p| {
            job.cost = p.cost;
            job.salt = p.salt;
            job.expect = p.hash;
        } else {
            sys.randomBytes(&job.salt);
        }
        if (!self.shared.bc.submit(job)) api.onPgFailure(self, r);
    }

    fn onEvent(self: *Worker) void {
        var done: [64]bcpool.Done = undefined;
        while (true) {
            const n = self.sink.take(&done);
            if (n == 0) break;
            for (done[0..n]) |d| {
                const r: *Req = @ptrFromInt(d.tag);
                api.onBcrypt(self, r, d);
            }
        }
        const rfd = @atomicLoad(i32, &self.rc_fd, .acquire);
        if (rfd >= 0) {
            @atomicStore(i32, &self.rc_fd, -1, .release);
            self.adoptReconnected(rfd);
            @atomicStore(u32, &self.rc_busy, 0, .release);
        }
        self.armEvent();
    }

    fn armEvent(self: *Worker) void {
        const s = self.sqe();
        s.prep_read(self.sink.efd, std.mem.asBytes(&self.efd_val), 0);
        s.user_data = ud(.event, 0, 0);
    }

    // ---- service-wide read transport --------------------------------------------------------

    fn askHub(self: *Worker, r: *Req, input: hubm.Header, bytes: []const u8) void {
        const h = self.shared.cfg.hub.?;
        const c = &h.channels[self.id];
        if (c.ask_sender.bytes + bytes.len > 16 * 1024 * 1024 or c.ask_sender.pending.items.len - c.ask_sender.head >= 65536) return api.onPgFailure(self, r);
        var header = input;
        header.token = @intFromPtr(r);
        header.kind = @backingInt(r.kind);
        c.ask_sender.send(c.ask, h.efd, header, bytes);
    }

    pub fn proxyReply(self: *Worker, r: *Req, format: u8, code: u16, bytes: []const u8) void {
        const c = &self.shared.cfg.hub.?.channels[r.remote_owner];
        c.answer_sender.send(c.answer, c.efd, .{ .token = r.remote_token, .format = format, .code = code }, bytes);
        self.freeReq(r);
    }

    pub fn proxyBody(self: *Worker, r: *Req, code: u16) void {
        self.proxyReply(r, 1, code, self.out.slice()[http.head_room..]);
    }

    fn armHub(self: *Worker) void {
        const h = self.shared.cfg.hub orelse return;
        const fd = if (self.shared.cfg.coordinator) h.efd else h.channels[self.id].efd;
        const s = self.sqe();
        s.prep_read(fd, std.mem.asBytes(&self.hub_val), 0);
        s.user_data = ud(.hub, 0, 0);
    }

    fn onHub(self: *Worker) void {
        const h = self.shared.cfg.hub.?;
        var header: hubm.Header = undefined;
        if (self.shared.cfg.coordinator) {
            for (h.channels) |*c| c.answer_sender.flush(c.answer, c.efd);
            for (h.channels, 0..) |*c, owner| {
                if (h.blocked()) break;
                var consumed = false;
                var records: usize = 0;
                while (records < 512) : (records += 1) {
                    const part = c.ask.pop(&self.ipc_data, &header) orelse break;
                    consumed = true;
                    c.input.putSlice(part);
                    if (header.more != 0) continue;
                    const r = self.newReq(-1, 0, @fromBackingInt(@intCast(header.kind)), true, header.viewer);
                    r.remote_owner = @intCast(owner);
                    r.remote_token = header.token;
                    if (header.format == 1) self.pgSubmit(.read, r, c.input.slice()) else self.readSubmit(@fromBackingInt(@intCast(header.stmt)), r, .{ .viewer = header.viewer, .limit = header.limit, .offset = header.offset, .text = c.input.slice() });
                    c.input.reset();
                }
                if (records == 512) hubm.notify(h.efd);
                if (consumed) hubm.notify(c.efd); // room for the HTTP producer's pending asks
            }
        } else {
            const c = &h.channels[self.id];
            c.ask_sender.flush(c.ask, h.efd);
            var consumed = false;
            while (c.answer.pop(&self.ipc_data, &header)) |part| {
                consumed = true;
                self.ipc_reply.putSlice(part);
                if (header.more != 0) continue;
                const r: *Req = @ptrFromInt(header.token);
                switch (header.format) {
                    0 => api.onPg(self, r, self.ipc_reply.slice()),
                    1 => {
                        self.beginBody();
                        self.out.putSlice(self.ipc_reply.slice());
                        api.doneReq(self, r, header.code);
                    },
                    else => api.onPgFailure(self, r),
                }
                self.ipc_reply.reset();
            }
            if (consumed) hubm.notify(h.efd); // room for pending drain replies
        }
        self.armHub();
    }

    // ---- main loop --------------------------------------------------------------------------

    fn armAccept(self: *Worker) void {
        const s = self.sqe();
        s.prep_multishot_accept(self.listener, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
        s.user_data = ud(.accept, 0, 0);
        self.accept_live = true;
    }

    fn armTimer(self: *Worker) void {
        const s = self.sqe();
        s.prep_timeout(&self.tick, 0, 0);
        s.user_data = ud(.timer, 0, 0);
    }

    fn dispatch(self: *Worker, cqe: linux.io_uring_cqe) void {
        const tag: Tag = @fromBackingInt(@intCast(@as(u8, @intCast(cqe.user_data >> 56))));
        const gen: u32 = @intCast((cqe.user_data >> 32) & 0xffffff);
        const idx: u32 = @truncate(cqe.user_data);
        switch (tag) {
            .recv => self.onRecv(@intCast(idx), gen, cqe.res, cqe.flags),
            .poll => self.onPoll(@intCast(idx), gen, cqe.res, cqe.flags),
            .send => self.onSend(@intCast(idx), gen, cqe.res, cqe.flags),
            .ack => self.onAck(@intCast(idx), gen, cqe.res),
            .shut => self.onShutdown(@intCast(idx), gen),
            .accept => self.onAccept(cqe.res, cqe.flags),
            .pg_recv => self.onPgRecv(idx, gen, cqe.res),
            .pg_send => self.onPgSend(idx, gen, cqe.res),
            .event => self.onEvent(),
            .hub => self.onHub(),
            .hold => if (gen == self.hold_gen) {
                self.hold_armed = false;
                self.hold_deadline = 0;
            },
            .hold_cancel => {},
            .write_hold => {
                self.write_hold_armed = false;
                for (self.pgs[self.n_read..]) |*p| self.sendGroup(p);
            },
            .timer => {
                if (self.listener >= 0 and !self.accept_live) self.armAccept();
                self.pgReconnect();
                self.sweepPartials();
                if (self.shared.cfg.stats) self.printStats();
                self.armTimer();
            },
            .close, .cancel => {},
        }
    }

    fn printStats(self: *Worker) void {
        if (self.shared.cfg.coordinator) {
            for (self.shared.cfg.hub.?.channels, 0..) |c, i| std.debug.print("[hub{d}] ask={d}/{d} answer={d}/{d}\n", .{ i, @atomicLoad(u64, &c.ask.state.head, .acquire), @atomicLoad(u64, &c.ask.state.tail, .acquire), @atomicLoad(u64, &c.answer.state.head, .acquire), @atomicLoad(u64, &c.answer.state.tail, .acquire) });
        }
        if (self.shared.cfg.write_arrays) std.debug.print("[mutations{d}] array_groups={d}\n", .{ self.id, self.stats.array_groups });
        std.debug.print("[w{d}] reqs={d} pg_syncs={d} batched_reqs={d} in {d} statements fifo_max={d} zc_nomem={d} send_errors={d}\n", .{ self.id, self.stats.reqs, self.stats.pg_batches, self.stats.batched_reqs, self.stats.batches, self.stats.fifo_max, self.stats.zc_nomem, self.stats.send_errors });
    }

    fn run(self: *Worker) void {
        var cqes: [256]linux.io_uring_cqe = undefined;
        while (true) {
            _ = self.ring.submit_and_wait(1) catch |e| switch (e) {
                error.SignalInterrupt => continue,
                // Out of kernel resources / completion queue full: drain what has completed, then retry.
                error.SystemResources, error.CompletionQueueOvercommitted => {},
                else => {
                    log.err("io_uring_enter: {s}", .{@errorName(e)});
                    std.process.exit(1);
                },
            };
            self.now = sys.nowUnix();
            self.mono = monoSecs();
            while (true) {
                const n = self.ring.copy_cqes(&cqes, 0) catch 0;
                if (n == 0) break;
                for (cqes[0..n]) |cqe| self.dispatch(cqe);
                self.flushReads();
                if (self.pbuf_ring != null) self.publishBufs();
            }
        }
    }
};

// ---------------------------------------------------------------------------------------------
// Start-up
// ---------------------------------------------------------------------------------------------

fn monoSecs() u32 {
    return @intCast((sys.nowNs() / 1_000_000_000) & 0x7fffffff);
}

fn setNonblock(fd: i32) void {
    const fl = linux.fcntl(fd, linux.F.GETFL, 0);
    _ = linux.fcntl(fd, linux.F.SETFL, fl | @as(usize, 1 << @bitOffsetOf(linux.O, "NONBLOCK")));
}

fn initRing() !IoUring {
    const flag_sets = [_]u32{
        linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_DEFER_TASKRUN | linux.IORING_SETUP_CQSIZE,
        linux.IORING_SETUP_COOP_TASKRUN | linux.IORING_SETUP_CQSIZE,
        linux.IORING_SETUP_CQSIZE,
        0,
    };
    var last: anyerror = error.ArgumentsInvalid;
    for (flag_sets) |fl| {
        var p = std.mem.zeroInit(linux.io_uring_params, .{ .flags = fl });
        if (fl & linux.IORING_SETUP_CQSIZE != 0) p.cq_entries = 65536;
        if (IoUring.init_params(4096, &p)) |r| return r else |e| last = e;
    }
    return last;
}

fn setupPbufRing(w: *Worker) void {
    const ring_bytes = n_bufs * @sizeOf(linux.io_uring_buf);
    const rmem = sys.mapAnon(ring_bytes) catch return;
    var reg = std.mem.zeroInit(linux.io_uring_buf_reg, .{ .ring_addr = @intFromPtr(rmem.ptr), .ring_entries = n_bufs, .bgid = bgid });
    const rc = linux.io_uring_register(w.ring.fd, .REGISTER_PBUF_RING, &reg, 1);
    if (sys.errnoOf(rc) != .SUCCESS) {
        log.warn("provided buffer rings unavailable ({s}); using poll + recv", .{@tagName(sys.errnoOf(rc))});
        sys.unmap(rmem);
        return;
    }
    const bmem = sys.mapAnon(n_bufs * buf_size) catch return;
    w.pbuf_mem = bmem.ptr;
    w.pbuf_ring = @ptrCast(@alignCast(rmem.ptr));
    w.pbuf_tail = 0;
    for (0..n_bufs) |i| w.returnBuf(@intCast(i));
    w.publishBufs();
}

fn makeListener(cfg: *const Config) !i32 {
    const s = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
    if (sys.errnoOf(s) != .SUCCESS) return error.SocketFailed;
    const fd: i32 = @intCast(s);
    const one: c_int = 1;
    inline for (.{ .{ linux.SOL.SOCKET, linux.SO.REUSEADDR }, .{ linux.SOL.SOCKET, linux.SO.REUSEPORT }, .{ linux.IPPROTO.TCP, linux.TCP.NODELAY }, .{ linux.SOL.SOCKET, linux.SO.KEEPALIVE }, .{ linux.IPPROTO.TCP, linux.TCP.DEFER_ACCEPT } }) |o| {
        _ = linux.setsockopt(fd, o[0], o[1], @ptrCast(&one), @sizeOf(c_int));
    }
    // Accepted sockets inherit these: probe idle peers after 10 min, so vanished clients do not hold sockets forever.
    const idle: c_int = 600;
    const intvl: c_int = 60;
    const cnt: c_int = 5;
    _ = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.KEEPIDLE, @ptrCast(&idle), @sizeOf(c_int));
    _ = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.KEEPINTVL, @ptrCast(&intvl), @sizeOf(c_int));
    _ = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.KEEPCNT, @ptrCast(&cnt), @sizeOf(c_int));
    var sa: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, cfg.port), .addr = @bitCast(cfg.host) };
    if (sys.errnoOf(linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return error.BindFailed;
    if (sys.errnoOf(linux.listen(fd, 65535)) != .SUCCESS) return error.ListenFailed;
    return fd;
}

pub fn workerMain(shared: *Shared, id: usize) void {
    workerInit(shared, id) catch |e| {
        log.err("worker {d} failed to start: {s}", .{ id, @errorName(e) });
        std.process.exit(1);
    };
}

fn workerInit(shared: *Shared, id: usize) !void {
    const cfg = &shared.cfg;
    if (cfg.pin_cpus) {
        const cpus = @max(1, sys.cpuCount());
        sys.pinCpu(id % cpus);
    }
    const w = try gpa.create(Worker);
    w.* = .{ .shared = shared, .id = id, .send_zc_enabled = cfg.send_zc, .send_zc_min = cfg.send_zc_min };
    w.gzip_mode = cfg.gzip_mode;
    w.gzip_min = cfg.gzip_min;
    w.ack_enabled = cfg.ack_delay;
    w.zip = .{ .pool = &w.response_pool };
    w.scratch = try Scratch.init(64 * 1024);
    w.out = .{ .pool = &w.response_pool };
    w.enc = try Buf.init(16 * 1024);
    w.scratch_rx = try gpa.alloc(u8, 64 * 1024);
    w.ring = try initRing();
    if (!cfg.no_pbuf and !cfg.coordinator) setupPbufRing(w);
    w.now = sys.nowUnix();
    w.mono = monoSecs();

    // connection table, indexed by fd (lazily committed by the kernel)
    var rl: linux.rlimit = undefined;
    _ = linux.getrlimit(.NOFILE, &rl);
    rl.cur = rl.max;
    _ = linux.setrlimit(.NOFILE, &rl);
    const nfds: usize = @intCast(@min(rl.max, 1 << 21));
    if (!cfg.coordinator) {
        const cmem = try sys.mapAnon(nfds * @sizeOf(Conn));
        w.conns = @as([*]Conn, @ptrCast(@alignCast(cmem.ptr)))[0..nfds];
    }

    // Postgres connections, prepared, then switched to non-blocking
    const total = cfg.pg_read + cfg.pg_write;
    w.pgs = try gpa.alloc(PgConn, total);
    w.n_read = cfg.pg_read;
    w.synth = try Buf.init(64 * 1024);
    for (w.pgs, 0..) |*p, i| {
        const fd = try pg.connect(cfg.db);
        try pg.prepareAll(fd, &prepare_list);
        pg.clearTimeouts(fd);
        setNonblock(fd);
        p.* = .{ .fd = fd, .class = if (i < cfg.pg_read) .read else .write, .alive = true };
        p.rs = try pg.Stream.init(64 * 1024);
        p.wa = try Buf.init(8192);
        p.ws = try Buf.init(8192);
    }

    // completion mailbox for bcrypt
    const efd = linux.eventfd(0, linux.EFD.CLOEXEC);
    if (sys.errnoOf(efd) != .SUCCESS) return error.EventfdFailed;
    w.sink.efd = @intCast(efd);

    if (!cfg.coordinator) {
        w.listener = try makeListener(cfg);
        w.armAccept();
    }
    w.armHub();
    w.armEvent();
    w.armTimer();
    for (w.pgs) |*p| w.pgArmRecv(p);
    _ = @atomicRmw(u32, &shared.ready, .Add, 1, .release);
    w.run();
}

test "failed postgres sockets retain fd and buffers until both I/O completions retire" {
    for ([_]bool{ false, true }) |receive_first| {
        const raw_fd = linux.eventfd(0, linux.EFD.CLOEXEC);
        try std.testing.expectEqual(linux.E.SUCCESS, sys.errnoOf(raw_fd));
        const fd: i32 = @intCast(raw_fd);
        var shared: Shared = undefined;
        shared.cfg = std.mem.zeroes(Config);
        var pgs = [_]PgConn{.{ .fd = fd, .alive = true, .rs = try pg.Stream.init(64) }};
        const p = &pgs[0];
        defer if (p.fd >= 0) {
            _ = linux.close(p.fd);
        };
        defer p.rs.buf.deinit();
        defer p.wa.deinit();
        defer p.ws.deinit();
        var w: Worker = .{ .shared = &shared, .id = 0, .pgs = &pgs, .n_read = 1 };
        var ring: SendTestRing = .{};
        ring.attach(&w);
        p.ws.putSlice("pending PostgreSQL payload");
        w.pgFlush(p);
        w.pgArmRecv(p);
        p.rs.start = 1;
        p.rs.scan = 2;
        p.rs.end = 3;
        w.pgFail(p);
        try std.testing.expect(!p.alive and p.sending and p.recving);
        try std.testing.expectEqual(fd, p.fd);
        try std.testing.expectEqual(linux.E.SUCCESS, sys.errnoOf(linux.fcntl(fd, linux.F.GETFD, 0)));
        try std.testing.expectEqualStrings("pending PostgreSQL payload", p.wa.slice());
        try std.testing.expectEqual(@as(usize, 3), p.rs.end);
        if (receive_first) w.onPgRecv(0, 0, 1) else w.onPgSend(0, 0, 1);
        try std.testing.expectEqual(fd, p.fd);
        try std.testing.expectEqualStrings("pending PostgreSQL payload", p.wa.slice());
        try std.testing.expectEqual(@as(usize, 3), p.rs.end);
        try std.testing.expectEqual(@as(u32, 2), w.ring.sq.sqe_tail);
        if (receive_first) w.onPgSend(0, 0, 1) else w.onPgRecv(0, 0, 1);
        try std.testing.expectEqual(@as(i32, -1), p.fd);
        try std.testing.expect(!p.sending and !p.recving);
        try std.testing.expectEqual(@as(usize, 0), p.wa.len);
        try std.testing.expectEqual(@as(usize, 0), p.rs.end);
        try std.testing.expectEqual(@as(u32, 2), w.ring.sq.sqe_tail);
    }
}

test "postgres replacement waits for retirement and ignores old-generation completions" {
    const level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = level;
    const old_raw = linux.eventfd(0, linux.EFD.CLOEXEC);
    try std.testing.expectEqual(linux.E.SUCCESS, sys.errnoOf(old_raw));
    const old_fd: i32 = @intCast(old_raw);
    var shared: Shared = undefined;
    shared.cfg = std.mem.zeroes(Config);
    var pgs = [_]PgConn{.{ .fd = old_fd, .gen = 7, .sending = true, .recving = true, .rs = try pg.Stream.init(64) }};
    const p = &pgs[0];
    defer if (p.fd >= 0) {
        _ = linux.close(p.fd);
    };
    defer p.rs.buf.deinit();
    defer p.wa.deinit();
    defer p.ws.deinit();
    var w: Worker = .{ .shared = &shared, .id = 0, .pgs = &pgs, .n_read = 1 };
    var ring: SendTestRing = .{};
    ring.attach(&w);
    const early_raw = linux.eventfd(0, linux.EFD.CLOEXEC);
    try std.testing.expectEqual(linux.E.SUCCESS, sys.errnoOf(early_raw));
    w.adoptReconnected(@intCast(early_raw));
    try std.testing.expectEqual(old_fd, p.fd);
    try std.testing.expect(!p.alive and p.sending and p.recving);
    try std.testing.expectEqual(@as(u32, 0), w.ring.sq.sqe_tail);
    w.onPgSend(0, 7, 0);
    w.onPgRecv(0, 7, 0);
    try std.testing.expectEqual(@as(i32, -1), p.fd);
    const replacement_raw = linux.eventfd(0, linux.EFD.CLOEXEC);
    try std.testing.expectEqual(linux.E.SUCCESS, sys.errnoOf(replacement_raw));
    w.adoptReconnected(@intCast(replacement_raw));
    try std.testing.expect(p.alive and p.recving);
    try std.testing.expectEqual(@as(u32, 8), p.gen);
    try std.testing.expectEqual(ud(.pg_recv, 8, 0), ring.sqes[0].user_data);
    p.ws.putSlice("replacement payload");
    w.pgFlush(p);
    try std.testing.expectEqual(ud(.pg_send, 8, 0), ring.sqes[1].user_data);
    w.onPgSend(0, 7, 2);
    w.onPgRecv(0, 7, -@as(i32, @backingInt(linux.E.CONNRESET)));
    try std.testing.expect(p.alive and p.sending and p.recving);
    try std.testing.expectEqualStrings("replacement payload", p.wa.slice());
    try std.testing.expectEqual(@as(usize, 0), p.wsent);
    try std.testing.expectEqual(@as(usize, 0), p.rs.end);
    w.onPgSend(0, 8, 2);
    try std.testing.expectEqual(ud(.pg_send, 8, 0), ring.sqes[2].user_data);
    w.onPgSend(0, 8, @intCast(p.wa.len - 2));
    w.onPgRecv(0, 8, 0);
    try std.testing.expectEqual(@as(i32, -1), p.fd);
    try std.testing.expect(!p.alive and !p.sending and !p.recving);
}

test "response encoding honors identity exclusion without imposing a compression threshold" {
    for ([_]u32{ 0, 1, 2 }) |mode| {
        for ([_]bool{ false, true }) |identity| {
            for ([_]bool{ false, true }) |gzip| {
                for ([_]u16{ 200, 204 }) |code| {
                    var shared: Shared = undefined;
                    var conns = [_]Conn{.{ .gen = 9, .open = true, .busy = true, .gzip = gzip, .identity = identity }};
                    var w: Worker = .{ .shared = &shared, .id = 0, .conns = &conns, .gzip_mode = mode, .gzip_min = 1024 };
                    var ring: SendTestRing = .{};
                    ring.attach(&w);
                    defer w.response_pool.deinit();
                    defer for (w.slabs[0..w.slab_count]) |p| gpa.free(p[0..slab_size]);
                    defer w.out.deinit();
                    defer w.zip.deinit();
                    defer w.gzip_encoder.deinit();
                    w.beginBody();
                    w.out.putSlice("{}");
                    w.finishResponse(0, 9, code, true);
                    const c = &conns[0];
                    const response = (c.out + c.out_off)[0 .. c.out_len - c.out_off];
                    const rejected = code != 204 and !identity and (mode == 0 or !gzip);
                    try std.testing.expect(std.mem.startsWith(u8, response, http.statusLine(if (rejected) 406 else code)));
                    const compressed = code != 204 and !identity and mode != 0 and gzip;
                    try std.testing.expectEqual(compressed, std.mem.indexOf(u8, response, "Content-Encoding: gzip\r\n") != null);
                    if (rejected) try std.testing.expect(std.mem.indexOf(u8, response, "Content-Length: 0\r\n") != null);
                    if (rejected or code == 204) try std.testing.expectEqual(response.len, std.mem.indexOf(u8, response, "\r\n\r\n").? + 4);
                    c.send_live = false;
                    w.freeOut(c);
                }
            }
        }
    }
}

test "owned responses retain their allocation base through partial sends and notifications" {
    var shared: Shared = undefined;
    var conns = [_]Conn{.{ .gen = 9, .open = true, .busy = true, .recv_live = true }};
    var w: Worker = .{ .shared = &shared, .id = 0, .conns = &conns, .send_zc_enabled = true };
    var ring: SendTestRing = .{};
    ring.attach(&w);
    defer w.response_pool.deinit();
    defer for (w.slabs[0..w.slab_count]) |p| gpa.free(p[0..slab_size]);
    w.beginBody();
    w.out.putSlice("{\"test\":true}");
    const base = w.out.ptr;
    const resp = http.finishResponse(w.out.slice(), w.out.len - http.head_room, 200, true);
    const size = resp.len;
    w.sendOwned(0, 9, resp, true);
    try std.testing.expectEqual(base, conns[0].out);
    try std.testing.expect(conns[0].out_off > 0 and w.out.cap == 0);
    w.onSend(0, 9, 7, linux.IORING_CQE_F_MORE);
    try std.testing.expectEqual(@as(usize, 0), w.slab_count);
    try std.testing.expectEqual(@intFromPtr(resp.ptr + 7), ring.sqes[1].addr);
    w.onSend(0, 9, 0, linux.IORING_CQE_F_NOTIF);
    try std.testing.expectEqual(@as(usize, 0), w.slab_count);
    w.onSend(0, 9, @intCast(size - 7), 0);
    try std.testing.expectEqual(@as(usize, 1), w.slab_count);
    try std.testing.expectEqual(base, w.slabs[0]);
}

test "async ACK options hold fd lifetime and unsupported commands disable the feature" {
    var shared: Shared = undefined;
    var conns = [_]Conn{.{ .gen = 3, .open = true, .ack_live = true }};
    var w: Worker = .{ .shared = &shared, .id = 0, .conns = &conns, .ack_enabled = true };
    var ring: SendTestRing = .{};
    ring.attach(&w);
    w.closeConn(0);
    try std.testing.expect(conns[0].closing);
    try std.testing.expectEqual(@as(u32, 0), w.ring.sq.sqe_tail);
    w.onAck(0, 2, 0);
    try std.testing.expect(conns[0].ack_live);
    const level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = level;
    w.onAck(0, 3, -@as(i32, @backingInt(linux.E.INVAL)));
    try std.testing.expect(!w.ack_enabled and !conns[0].closing);
    try std.testing.expectEqual(linux.IORING_OP.CLOSE, ring.sqes[0].opcode);
}

test "idle connection metadata stays within one cache line" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Conn));
}

test "adaptive reads dispatch every queued batch when a backend is idle" {
    var cfg = std.mem.zeroes(Config);
    cfg.read_window_us = 100000;
    cfg.read_hold_min = 2048;
    cfg.adaptive_window = true;
    for ([_]usize{ 1, 2, 63, 64, 127, 128, 256, 512, 1024, 2048 }) |n| {
        try std.testing.expectEqual(@as(u64, 0), readWindowNs(&cfg, n, true));
    }
    try std.testing.expectEqual(@as(u64, 100 * std.time.ns_per_ms), readWindowNs(&cfg, 2, false));
    try std.testing.expectEqual(@as(u64, 50 * std.time.ns_per_ms), readWindowNs(&cfg, 128, false));
    try std.testing.expectEqual(@as(u64, 10 * std.time.ns_per_ms), readWindowNs(&cfg, 1024, false));
    cfg.read_window_us = 1000;
    for ([_]usize{ 1, 64, 128, 256, 512, 1024 }) |n| {
        try std.testing.expectEqual(@as(u64, std.time.ns_per_ms), readWindowNs(&cfg, n, false));
    }
    cfg.read_window_us = 0;
    for ([_]usize{ 1, 64, 128, 256, 512, 1024 }) |n| {
        try std.testing.expectEqual(@as(u64, 0), readWindowNs(&cfg, n, false));
    }
    cfg.read_window_us = 100000;
    cfg.adaptive_window = false;
    try std.testing.expectEqual(@as(u64, 100 * std.time.ns_per_ms), readWindowNs(&cfg, 2, true));
}

test "read connection affinity never bypasses an idle backend" {
    var shared: Shared = undefined;
    shared.cfg = std.mem.zeroes(Config);
    shared.cfg.pg_depth = 4;
    shared.cfg.read_depth = 4;
    var pgs = [_]PgConn{
        .{ .alive = true, .depth = 2, .last_stmt = .article },
        .{ .alive = true, .depth = 0, .last_stmt = .profile },
    };
    var w = Worker{ .shared = &shared, .id = 0, .pgs = &pgs, .n_read = pgs.len };
    try std.testing.expectEqual(&pgs[1], w.bestReadConn(.article).?);
    pgs[1].depth = 1;
    try std.testing.expectEqual(&pgs[0], w.bestReadConn(.article).?);
    pgs[0].alive = false;
    try std.testing.expectEqual(&pgs[1], w.bestReadConn(.article).?);
}

test "staged reads flush as soon as an in-flight backend becomes idle" {
    for ([_]usize{ 2, 63, 64, 128 }) |n| {
        var shared: Shared = undefined;
        shared.cfg = std.mem.zeroes(Config);
        shared.cfg.pg_depth = 4;
        shared.cfg.read_depth = 4;
        shared.cfg.batch_max = 64;
        shared.cfg.read_window_us = 100000;
        shared.cfg.read_hold_min = 2048;
        shared.cfg.adaptive_window = true;
        // Sending is already armed, so this test records queued wire bytes without kernel I/O.
        var pgs = [_]PgConn{.{ .alive = true, .sending = true, .depth = 1 }};
        defer pgs[0].ws.deinit();
        var w = Worker{ .shared = &shared, .id = 0, .pgs = &pgs, .n_read = 1 };
        defer w.enc.deinit();
        defer for (&w.stages) |*st| {
            while (st.len != 0) {
                var it = st.pop();
                it.deinit();
            }
            if (st.items.len != 0) gpa.free(st.items);
        };
        var req: Req = .{};
        for (0..n) |_| w.readSubmit(.tags, &req, .{});
        try std.testing.expect(readWindowNs(&shared.cfg, w.staged, false) != 0);
        pgs[0].depth = 0;
        w.flushReads();
        defer for (pgs[0].q[0..pgs[0].depth]) |token| {
            const rec: *BatchRec = @ptrFromInt(token & ~@as(usize, 3));
            gpa.destroy(rec);
        };
        try std.testing.expectEqual(@as(usize, 0), w.staged);
        try std.testing.expect(!w.hold_armed);
        try std.testing.expect(pgs[0].depth > 0);
        try std.testing.expect(pgs[0].ws.len > 0);
    }
}

test "per-kind batch encodes keys from stable stored inline and heap items" {
    const a127: [127]u8 = @splat('a');
    const b128: [128]u8 = @splat('b');
    const c129: [129]u8 = @splat('c');
    const texts = [_][]const u8{ "slug-alpha", "slug-bravo", &a127, &b128, &c129, "slug-alpha" };
    var reqs: [texts.len]Req = @splat(.{});
    const rec = try gpa.create(BatchRec);
    defer gpa.destroy(rec);
    rec.n = texts.len;
    var viewers: [texts.len]i64 = undefined;
    var limits: [texts.len]i32 = undefined;
    var offsets: [texts.len]i32 = undefined;
    for (texts, 0..) |text, i| {
        viewers[i] = @intCast(i);
        limits[i] = @intCast(i + 1);
        offsets[i] = @intCast(i * 2);
        var it = StageItem.init(&reqs[i], i, viewers[i], limits[i], offsets[i], text).?;
        rec.items[i] = it;
        rec.reqs[i] = it.r;
        @memset(&it.buf, 0xa5);
    }
    defer for (rec.items[0..rec.n]) |*it| it.deinit();
    var actual: Buf = .{};
    defer actual.deinit();
    var expected: Buf = .{};
    defer expected.deinit();
    for ([_]sql.Stmt{ .article, .comments, .profile, .list_tag, .list_author, .list_fav }) |stmt| {
        rec.stmt = stmt;
        actual.reset();
        expected.reset();
        var e = pg.Enc.init(&actual);
        rec.encode(&e);
        e.sync();
        var ref = pg.Enc.init(&expected);
        ref.bind(sql.batchId(stmt));
        ref.pInt8Array(&viewers);
        if (shapeLo(stmt)) {
            ref.pInt4Array(&limits);
            ref.pInt4Array(&offsets);
        }
        ref.pTextArray(&texts);
        ref.exec();
        ref.sync();
        try std.testing.expectEqualSlices(u8, expected.slice(), actual.slice());
    }
}

test "large grouped writes retain their full heap-backed wire payload" {
    const bytes = try gpa.alloc(u8, 128 * 1024);
    defer gpa.free(bytes);
    @memset(bytes, 0x5a);
    var req: Req = .{};
    var member = Member.init(&req, 1, bytes).?;
    defer member.deinit();
    try std.testing.expectEqualSlices(u8, bytes, member.slice());
}

test "partial zero-copy sends retain output until both tail and notification complete" {
    for ([_]bool{ false, true }) |notification_first| {
        const bytes = try gpa.alloc(u8, slab_size);
        defer gpa.free(bytes);
        var shared: Shared = undefined;
        var conns = [_]Conn{.{
            .gen = 7,
            .open = true,
            .busy = true,
            .send_live = true,
            .send_zc = true,
            .out = bytes.ptr,
            .out_len = slab_size,
            .out_cap = slab_size,
        }};
        var w = Worker{ .shared = &shared, .id = 0, .conns = &conns };
        const c = &conns[0];
        try std.testing.expect(c.completeSend(1024, linux.IORING_CQE_F_MORE));
        try std.testing.expect(c.zc_waiting);
        try std.testing.expectEqual(@as(u32, 1024), c.out_off);
        w.finishSend(0, c);
        try std.testing.expect(c.busy);
        try std.testing.expectEqual(@as(u32, slab_size), c.out_cap);
        c.send_live = true; // the remaining bytes use ordinary SEND
        if (notification_first) {
            w.onSend(0, 7, 0, linux.IORING_CQE_F_NOTIF);
            try std.testing.expect(c.busy and c.send_live);
            try std.testing.expectEqual(@as(u32, slab_size), c.out_cap);
        }
        w.onSend(0, 7, slab_size - 1024, 0);
        if (!notification_first) {
            try std.testing.expect(c.busy and c.zc_waiting);
            try std.testing.expectEqual(@as(u32, slab_size), c.out_cap);
            w.onSend(0, 7, 0, linux.IORING_CQE_F_NOTIF);
        }
        try std.testing.expect(!c.busy and !c.zc_waiting and !c.send_live);
        try std.testing.expectEqual(@as(u32, 0), c.out_cap);
        try std.testing.expectEqual(@as(usize, 1), w.slab_count);
    }
}

test "failed zero-copy sends still honor promised release notifications" {
    const bytes = try gpa.alloc(u8, slab_size);
    defer gpa.free(bytes);
    var shared: Shared = undefined;
    var w = Worker{ .shared = &shared, .id = 0 };
    var c = Conn{ .busy = true, .send_live = true, .send_zc = true, .out = bytes.ptr, .out_len = slab_size, .out_cap = slab_size };
    try std.testing.expect(c.completeSend(-@as(i32, @backingInt(linux.E.PIPE)), linux.IORING_CQE_F_MORE));
    w.freeOut(&c);
    try std.testing.expect(c.zc_waiting and c.busy);
    try std.testing.expectEqual(@as(u32, slab_size), c.out_cap);
    c.zc_waiting = false;
    w.freeOut(&c);
    try std.testing.expectEqual(@as(u32, 0), c.out_cap);
}

test "standalone writes cannot pipeline behind an unresolved write group" {
    var shared: Shared = undefined;
    shared.cfg = std.mem.zeroes(Config);
    shared.cfg.pg_depth = 4;
    var pgs = [_]PgConn{.{ .alive = true, .class = .write, .ginflight = true, .sending = true }};
    defer pgs[0].ws.deinit();
    var w = Worker{ .shared = &shared, .id = 0, .pgs = &pgs };
    const fifo = &w.fifo[@backingInt(Class.write)];
    defer {
        while (fifo.pop()) |q| gpa.free(q.bytes);
        if (fifo.items.len != 0) gpa.free(fifo.items);
    }
    var req: Req = .{};
    w.soloWrite(&req, "wire bytes");
    try std.testing.expectEqual(@as(usize, 1), fifo.len);
    try std.testing.expectEqual(@as(u32, 0), pgs[0].depth);
    w.pgDrain(.write);
    try std.testing.expectEqual(@as(usize, 1), fifo.len);
    pgs[0].ginflight = false;
    w.pgDrain(.write);
    try std.testing.expectEqual(@as(usize, 0), fifo.len);
    try std.testing.expectEqual(@as(u32, 1), pgs[0].depth);
    try std.testing.expectEqualStrings("wire bytes", pgs[0].ws.slice());
}

test "grouped writes wait without overwriting a full PostgreSQL token ring" {
    for ([_]u32{ 1, 4, 32, max_depth_cap }) |cap| {
        var shared: Shared = undefined;
        shared.cfg = std.mem.zeroes(Config);
        shared.cfg.pg_depth = cap;
        var pgs = [_]PgConn{.{ .alive = true, .class = .write, .sending = true, .q = @splat(0), .qh = max_depth_cap - 1 }};
        const p = &pgs[0];
        defer p.ws.deinit();
        defer p.staged.deinit(gpa);
        var w = Worker{ .shared = &shared, .id = 0, .pgs = &pgs };
        defer w.enc.deinit();
        var reqs: [max_depth_cap]Req = @splat(.{});
        for (reqs[0..cap]) |*r| w.pgPush(p, @intFromPtr(r), "standalone");
        const before = p.q;
        const wire_len = p.ws.len;
        var grouped: Req = .{};
        w.writeSubmit(&grouped, "memberS\x00\x00\x00\x04", 1);
        try std.testing.expectEqual(cap, p.depth);
        try std.testing.expectEqualSlices(usize, &before, &p.q);
        try std.testing.expectEqual(wire_len, p.ws.len);
        try std.testing.expect(!p.ginflight);
        try std.testing.expectEqual(@as(usize, 1), p.staged.items.len);
    }
}

test "deferred groups resume after standalone completions and rollback releases capacity" {
    for ([_]u32{ 1, 4, 32, max_depth_cap }) |cap| {
        var shared: Shared = undefined;
        shared.cfg = std.mem.zeroes(Config);
        shared.cfg.pg_depth = cap;
        var pgs = [_]PgConn{.{ .alive = true, .class = .write, .sending = true, .qh = max_depth_cap - 1 }};
        const p = &pgs[0];
        defer p.ws.deinit();
        defer p.staged.deinit(gpa);
        var w = Worker{ .shared = &shared, .id = 0, .pgs = &pgs };
        defer w.enc.deinit();
        const fifo = &w.fifo[@backingInt(Class.write)];
        defer {
            while (fifo.pop()) |q| gpa.free(q.bytes);
            if (fifo.items.len != 0) gpa.free(fifo.items);
        }
        w.pgPush(p, 0, "Q\x00\x00\x00\x0dROLLBACK\x00");
        var grouped: Req = .{};
        try p.staged.append(gpa, Member.init(&grouped, 1, "memberS\x00\x00\x00\x04").?);
        var reqs: [max_depth_cap]Req = @splat(.{});
        for (reqs[0..cap]) |*r| fifo.push(.{ .r = r, .bytes = try gpa.dupe(u8, "standalone") });
        w.pgDrain(.write);
        try std.testing.expectEqual(cap, p.depth);
        try std.testing.expectEqual(@as(usize, 1), fifo.len);
        try std.testing.expectEqual(@as(usize, 0), p.q[p.qh]);
        // A successful ROLLBACK frees one slot, which the oldest standalone write gets first.
        p.qh = (p.qh + 1) % max_depth_cap;
        p.depth -= 1;
        w.pgDrain(.write);
        try std.testing.expectEqual(cap, p.depth);
        try std.testing.expectEqual(@as(usize, 0), fifo.len);
        try std.testing.expect(!p.ginflight);
        for (reqs[0..cap], 0..) |*r, i| try std.testing.expectEqual(@intFromPtr(r), p.q[(p.qh + i) % max_depth_cap]);
        // The next completion must resume the staged group without another incoming request.
        p.qh = (p.qh + 1) % max_depth_cap;
        p.depth -= 1;
        w.pgDrain(.write);
        try std.testing.expectEqual(cap, p.depth);
        try std.testing.expect(p.ginflight);
        try std.testing.expectEqual(@as(usize, 0), p.staged.items.len);
        for (reqs[1..cap], 0..) |*r, i| try std.testing.expectEqual(@intFromPtr(r), p.q[(p.qh + i) % max_depth_cap]);
        try std.testing.expectEqual(@intFromPtr(&p.wrec) | 2, p.q[(p.qh + p.depth - 1) % max_depth_cap]);
        try std.testing.expectEqual(&grouped, p.wrec.m[0].r);
    }
}

const SendTestRing = struct {
    head: u32 = 0,
    sqes: [16]linux.io_uring_sqe = undefined,

    fn attach(self: *SendTestRing, w: *Worker) void {
        w.ring = undefined;
        w.ring.sq = undefined;
        w.ring.sq.head = &self.head;
        w.ring.sq.mask = self.sqes.len - 1;
        w.ring.sq.sqes = &self.sqes;
        w.ring.sq.sqe_tail = 0;
    }
};

test "terminal receive waits for shutdown completion before closing the fd" {
    for ([_]i32{ 0, -@as(i32, @backingInt(linux.E.NOTCONN)) }) |shutdown_result| {
        var shared: Shared = undefined;
        var pbuf: [1]linux.io_uring_buf = undefined;
        var conns = [_]Conn{.{ .gen = 7, .open = true, .recv_live = true }};
        const c = &conns[0];
        var w = Worker{ .shared = &shared, .id = 0, .conns = &conns, .pbuf_ring = &pbuf };
        var ring = SendTestRing{};
        ring.attach(&w);
        w.closeConn(0);
        try std.testing.expectEqual(@as(u32, 1), w.ring.sq.sqe_tail);
        try std.testing.expectEqual(linux.IORING_OP.SHUTDOWN, ring.sqes[0].opcode);

        w.onRecv(0, 7, 0, 0);
        try std.testing.expect(!c.recv_live);
        try std.testing.expectEqual(@as(u32, 1), w.ring.sq.sqe_tail);
        try std.testing.expect(c.closing);

        w.dispatch(.{ .user_data = ring.sqes[0].user_data, .res = shutdown_result, .flags = 0 });
        try std.testing.expectEqual(@as(u32, 2), w.ring.sq.sqe_tail);
        try std.testing.expectEqual(linux.IORING_OP.CLOSE, ring.sqes[1].opcode);
        try std.testing.expect(!c.closing);
        w.maybeFinishClose(0);
        try std.testing.expectEqual(@as(u32, 2), w.ring.sq.sqe_tail);
    }
}

test "stale shutdown completions do not release the current fd" {
    var shared: Shared = undefined;
    var pbuf: [1]linux.io_uring_buf = undefined;
    var conns = [_]Conn{ .{}, .{ .gen = 0x01000008, .open = true, .recv_live = true } };
    const fd: i32 = 1;
    const c = &conns[1];
    var w = Worker{ .shared = &shared, .id = 0, .conns = &conns, .pbuf_ring = &pbuf };
    var ring = SendTestRing{};
    ring.attach(&w);
    w.closeConn(fd);
    try std.testing.expectEqual(@as(u32, 1), w.ring.sq.sqe_tail);
    try std.testing.expectEqual(fd, ring.sqes[0].fd);
    try std.testing.expectEqual(ud(.shut, 8, 1), ring.sqes[0].user_data);
    w.onRecv(fd, 8, 0, 0);
    try std.testing.expect(c.closing and c.shutdown_live and !c.recv_live);

    w.dispatch(.{ .user_data = ud(.shut, 7, 1), .res = 0, .flags = 0 });
    try std.testing.expect(c.closing and c.shutdown_live);
    try std.testing.expectEqual(@as(u32, 1), w.ring.sq.sqe_tail);
    w.dispatch(.{ .user_data = ring.sqes[0].user_data, .res = 0, .flags = 0 });
    try std.testing.expect(!c.closing and !c.shutdown_live);
    try std.testing.expectEqual(@as(u32, 2), w.ring.sq.sqe_tail);
    try std.testing.expectEqual(linux.IORING_OP.CLOSE, ring.sqes[1].opcode);
    try std.testing.expectEqual(fd, ring.sqes[1].fd);
}

test "poll removal completion cannot retire a live shutdown at generation zero" {
    const bytes = try gpa.alloc(u8, slab_size);
    defer gpa.free(bytes);
    var shared: Shared = undefined;
    var conns = [_]Conn{.{ .open = true, .busy = true, .recv_live = true, .send_live = true, .out = bytes.ptr, .out_len = slab_size, .out_cap = slab_size }};
    const c = &conns[0];
    var w = Worker{ .shared = &shared, .id = 0, .conns = &conns };
    var ring = SendTestRing{};
    ring.attach(&w);
    w.closeConn(0);
    try std.testing.expect(!c.open and c.closing and c.busy and !c.recv_live and c.send_live and c.shutdown_live);
    try std.testing.expectEqual(@as(u32, 2), w.ring.sq.sqe_tail);
    try std.testing.expectEqual(linux.IORING_OP.POLL_REMOVE, ring.sqes[0].opcode);
    try std.testing.expectEqual(ud(.poll, 0, 0), ring.sqes[0].addr);
    try std.testing.expectEqual(ud(.cancel, 0, 0), ring.sqes[0].user_data);
    try std.testing.expectEqual(linux.IORING_OP.SHUTDOWN, ring.sqes[1].opcode);
    try std.testing.expectEqual(ud(.shut, 0, 0), ring.sqes[1].user_data);

    w.onSend(0, 0, 1024, 0);
    try std.testing.expect(c.closing and c.busy and !c.send_live and c.shutdown_live);
    try std.testing.expectEqual(@as(u32, 0), c.out_cap);
    try std.testing.expectEqual(@as(usize, 1), w.slab_count);
    try std.testing.expectEqual(@as(u32, 2), w.ring.sq.sqe_tail);
    w.dispatch(.{ .user_data = ring.sqes[0].user_data, .res = 0, .flags = 0 });
    try std.testing.expect(c.closing and c.shutdown_live);
    try std.testing.expectEqual(@as(u32, 2), w.ring.sq.sqe_tail);
    w.dispatch(.{ .user_data = ring.sqes[0].addr, .res = -@as(i32, @backingInt(linux.E.CANCELED)), .flags = 0 });
    try std.testing.expect(c.closing and c.shutdown_live);
    try std.testing.expectEqual(@as(u32, 2), w.ring.sq.sqe_tail);
    w.dispatch(.{ .user_data = ring.sqes[1].user_data, .res = -@as(i32, @backingInt(linux.E.NOTCONN)), .flags = 0 });
    try std.testing.expect(!c.closing and !c.busy and !c.shutdown_live);
    try std.testing.expectEqual(@as(u32, 3), w.ring.sq.sqe_tail);
    try std.testing.expectEqual(linux.IORING_OP.CLOSE, ring.sqes[2].opcode);
    w.maybeFinishClose(0);
    try std.testing.expectEqual(@as(usize, 1), w.slab_count);
    try std.testing.expectEqual(@as(u32, 3), w.ring.sq.sqe_tail);
}

test "poll-only close does not wait for the ignored cancellation completion" {
    var shared: Shared = undefined;
    var conns = [_]Conn{.{ .open = true, .recv_live = true }};
    const c = &conns[0];
    var w = Worker{ .shared = &shared, .id = 0, .conns = &conns };
    var ring = SendTestRing{};
    ring.attach(&w);
    w.closeConn(0);
    try std.testing.expect(!c.open and !c.recv_live and !c.closing and !c.shutdown_live);
    try std.testing.expectEqual(@as(u32, 2), w.ring.sq.sqe_tail);
    try std.testing.expectEqual(linux.IORING_OP.POLL_REMOVE, ring.sqes[0].opcode);
    try std.testing.expectEqual(ud(.cancel, 0, 0), ring.sqes[0].user_data);
    try std.testing.expectEqual(linux.IORING_OP.CLOSE, ring.sqes[1].opcode);
    w.dispatch(.{ .user_data = ring.sqes[0].user_data, .res = -@as(i32, @backingInt(linux.E.NOENT)), .flags = 0 });
    w.dispatch(.{ .user_data = ring.sqes[0].addr, .res = -@as(i32, @backingInt(linux.E.CANCELED)), .flags = 0 });
    try std.testing.expectEqual(@as(u32, 2), w.ring.sq.sqe_tail);
}

test "zero-copy ENOMEM retries copied send without closing or releasing the response early" {
    const log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = log_level;
    const Order = enum { no_notification, notification_first, send_first };
    for ([_]Order{ .no_notification, .notification_first, .send_first }) |order| {
        const bytes = try gpa.alloc(u8, slab_size);
        defer gpa.free(bytes);
        @memset(bytes, 0x5a);
        var shared: Shared = undefined;
        var conns = [_]Conn{.{
            .gen = 7,
            .open = true,
            .busy = true,
            .recv_live = true,
            .send_live = true,
            .send_zc = true,
            .out = bytes.ptr,
            .out_len = slab_size,
            .out_cap = slab_size,
        }};
        const c = &conns[0];
        var w = Worker{ .shared = &shared, .id = 0, .conns = &conns, .send_zc_enabled = true };
        var ring = SendTestRing{};
        ring.attach(&w);
        const more: u32 = if (order == .no_notification) 0 else linux.IORING_CQE_F_MORE;
        w.onSend(0, 7, -@as(i32, @backingInt(linux.E.NOMEM)), more);
        try std.testing.expect(c.open and c.busy and c.send_live and !c.send_zc);
        try std.testing.expectEqual(@as(u32, 1), w.ring.sq.sqe_tail);
        try std.testing.expectEqual(linux.IORING_OP.SEND, ring.sqes[0].opcode);
        try std.testing.expectEqual(@intFromPtr(bytes.ptr), ring.sqes[0].addr);
        try std.testing.expectEqual(@as(u32, slab_size), ring.sqes[0].len);
        try std.testing.expectEqual(@as(u32, 0), c.out_off);
        try std.testing.expect(w.send_zc_enabled);
        if (order == .notification_first) {
            w.onSend(0, 7, 0, linux.IORING_CQE_F_NOTIF);
            try std.testing.expect(c.busy and c.send_live);
            try std.testing.expectEqual(@as(u32, slab_size), c.out_cap);
        }
        w.onSend(0, 7, 1024, 0);
        try std.testing.expect(c.open and c.busy and c.send_live and !c.send_zc);
        try std.testing.expectEqual(@as(u32, 2), w.ring.sq.sqe_tail);
        try std.testing.expectEqual(linux.IORING_OP.SEND, ring.sqes[1].opcode);
        try std.testing.expectEqual(@intFromPtr(bytes.ptr + 1024), ring.sqes[1].addr);
        try std.testing.expectEqual(@as(u32, slab_size - 1024), ring.sqes[1].len);
        w.onSend(0, 7, slab_size - 1024, 0);
        if (order == .send_first) {
            try std.testing.expect(c.open and c.busy and c.zc_waiting);
            try std.testing.expectEqual(@as(u32, slab_size), c.out_cap);
            w.onSend(0, 7, 0, linux.IORING_CQE_F_NOTIF);
        }
        try std.testing.expect(c.open and !c.busy and !c.send_live and !c.zc_waiting);
        try std.testing.expectEqual(@as(u32, 0), c.out_cap);
        try std.testing.expectEqual(@as(usize, 1), w.slab_count);
        try std.testing.expectEqual(@as(u32, 2), w.ring.sq.sqe_tail);
        try std.testing.expect(w.send_zc_enabled);
        try std.testing.expectEqual(@as(u64, 1), w.stats.zc_nomem);
        try std.testing.expectEqual(@as(u64, 0), w.stats.send_errors);
    }
}

test "a failed copied fallback is not retried and still waits for the original notification" {
    const log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = log_level;
    for ([_]bool{ false, true }) |notification| {
        const bytes = try gpa.alloc(u8, slab_size);
        defer gpa.free(bytes);
        var shared: Shared = undefined;
        var conns = [_]Conn{.{ .gen = 7, .open = true, .busy = true, .send_live = true, .send_zc = true, .out = bytes.ptr, .out_len = slab_size, .out_cap = slab_size }};
        const c = &conns[0];
        var w = Worker{ .shared = &shared, .id = 0, .conns = &conns, .send_zc_enabled = true };
        var ring = SendTestRing{};
        ring.attach(&w);
        const more: u32 = if (notification) linux.IORING_CQE_F_MORE else 0;
        w.onSend(0, 7, -@as(i32, @backingInt(linux.E.NOMEM)), more);
        try std.testing.expect(c.open and c.send_live and !c.send_zc);
        try std.testing.expectEqual(linux.IORING_OP.SEND, ring.sqes[0].opcode);
        w.onSend(0, 7, -@as(i32, @backingInt(linux.E.NOMEM)), 0);
        try std.testing.expect(!c.open and !c.send_live);
        if (notification) {
            try std.testing.expect(c.zc_waiting);
            try std.testing.expectEqual(@as(u32, slab_size), c.out_cap);
            try std.testing.expectEqual(@as(u32, 1), w.ring.sq.sqe_tail);
            w.onSend(0, 7, 0, linux.IORING_CQE_F_NOTIF);
        }
        try std.testing.expectEqual(@as(u32, 0), c.out_cap);
        try std.testing.expectEqual(@as(u32, 2), w.ring.sq.sqe_tail);
        try std.testing.expectEqual(linux.IORING_OP.CLOSE, ring.sqes[1].opcode);
        try std.testing.expectEqual(@as(u64, 1), w.stats.zc_nomem);
        try std.testing.expectEqual(@as(u64, 1), w.stats.send_errors);
    }
}

test "closing during copied ENOMEM fallback waits for receive, send, notification and shutdown" {
    const log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = log_level;
    const Completion = enum { recv, send, notification, shutdown };
    const orders = [24][4]Completion{
        .{ .recv, .send, .notification, .shutdown },
        .{ .recv, .send, .shutdown, .notification },
        .{ .recv, .notification, .send, .shutdown },
        .{ .recv, .notification, .shutdown, .send },
        .{ .recv, .shutdown, .send, .notification },
        .{ .recv, .shutdown, .notification, .send },
        .{ .send, .recv, .notification, .shutdown },
        .{ .send, .recv, .shutdown, .notification },
        .{ .send, .notification, .recv, .shutdown },
        .{ .send, .notification, .shutdown, .recv },
        .{ .send, .shutdown, .recv, .notification },
        .{ .send, .shutdown, .notification, .recv },
        .{ .notification, .recv, .send, .shutdown },
        .{ .notification, .recv, .shutdown, .send },
        .{ .notification, .send, .recv, .shutdown },
        .{ .notification, .send, .shutdown, .recv },
        .{ .notification, .shutdown, .recv, .send },
        .{ .notification, .shutdown, .send, .recv },
        .{ .shutdown, .recv, .send, .notification },
        .{ .shutdown, .recv, .notification, .send },
        .{ .shutdown, .send, .recv, .notification },
        .{ .shutdown, .send, .notification, .recv },
        .{ .shutdown, .notification, .recv, .send },
        .{ .shutdown, .notification, .send, .recv },
    };
    for (orders) |order| {
        const bytes = try gpa.alloc(u8, slab_size);
        defer gpa.free(bytes);
        var shared: Shared = undefined;
        // A provided-buffer receive stays live until its terminal CQE. None of
        // the injected completions selects a buffer, so this ring is not read.
        var pbuf: [1]linux.io_uring_buf = undefined;
        var conns = [_]Conn{.{
            .gen = 7,
            .open = true,
            .busy = true,
            .recv_live = true,
            .send_live = true,
            .send_zc = true,
            .out = bytes.ptr,
            .out_len = slab_size,
            .out_cap = slab_size,
        }};
        const c = &conns[0];
        var w = Worker{ .shared = &shared, .id = 0, .conns = &conns, .send_zc_enabled = true, .pbuf_ring = &pbuf };
        var ring = SendTestRing{};
        ring.attach(&w);
        w.onSend(0, 7, -@as(i32, @backingInt(linux.E.NOMEM)), linux.IORING_CQE_F_MORE);
        try std.testing.expect(c.open and c.recv_live and c.send_live and c.zc_waiting and !c.send_zc);
        try std.testing.expectEqual(@as(u32, 1), w.ring.sq.sqe_tail);
        try std.testing.expectEqual(linux.IORING_OP.SEND, ring.sqes[0].opcode);
        try std.testing.expectEqual(@as(usize, 0), w.slab_count);

        w.closeConn(0);
        try std.testing.expect(!c.open and c.closing and c.busy);
        try std.testing.expect(c.recv_live and c.send_live and c.zc_waiting and c.shutdown_live);
        try std.testing.expectEqual(@as(u32, slab_size), c.out_cap);
        try std.testing.expectEqual(@as(usize, 0), w.slab_count);
        try std.testing.expectEqual(@as(u32, 2), w.ring.sq.sqe_tail);
        try std.testing.expectEqual(linux.IORING_OP.SHUTDOWN, ring.sqes[1].opcode);

        var recv_pending = true;
        var send_pending = true;
        var notification_pending = true;
        var shutdown_pending = true;
        for (order) |completion| {
            switch (completion) {
                .recv => {
                    w.onRecv(0, 7, 0, 0);
                    recv_pending = false;
                },
                .send => {
                    // A short copied send after close must not submit its unsent tail.
                    w.onSend(0, 7, 1024, 0);
                    send_pending = false;
                },
                .notification => {
                    w.onSend(0, 7, 0, linux.IORING_CQE_F_NOTIF);
                    notification_pending = false;
                },
                .shutdown => {
                    w.dispatch(.{ .user_data = ring.sqes[1].user_data, .res = 0, .flags = 0 });
                    shutdown_pending = false;
                },
            }
            const retained = send_pending or notification_pending;
            const closing = recv_pending or retained or shutdown_pending;
            try std.testing.expect(!c.open and !c.send_zc);
            try std.testing.expectEqual(recv_pending, c.recv_live);
            try std.testing.expectEqual(send_pending, c.send_live);
            try std.testing.expectEqual(notification_pending, c.zc_waiting);
            try std.testing.expectEqual(shutdown_pending, c.shutdown_live);
            try std.testing.expectEqual(closing, c.closing);
            try std.testing.expectEqual(closing, c.busy);
            try std.testing.expectEqual(@as(u32, if (retained) slab_size else 0), c.out_cap);
            try std.testing.expectEqual(@as(u32, if (!send_pending and retained) 1024 else 0), c.out_off);
            try std.testing.expectEqual(@as(usize, if (retained) 0 else 1), w.slab_count);
            try std.testing.expectEqual(@as(u32, if (closing) 2 else 3), w.ring.sq.sqe_tail);
        }
        try std.testing.expectEqual(linux.IORING_OP.CLOSE, ring.sqes[2].opcode);
        try std.testing.expectEqual(@intFromPtr(bytes.ptr), @intFromPtr(w.slabs[0]));

        w.closeConn(0);
        w.finishSend(0, c);
        w.maybeFinishClose(0);
        try std.testing.expectEqual(@as(usize, 1), w.slab_count);
        try std.testing.expectEqual(@as(u32, 0), c.out_cap);
        try std.testing.expectEqual(@as(u32, 3), w.ring.sq.sqe_tail);
    }
}

test "late zero-copy ENOMEM cannot resurrect a closed connection" {
    const log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = log_level;
    const bytes = try gpa.alloc(u8, slab_size);
    defer gpa.free(bytes);
    var shared: Shared = undefined;
    var conns = [_]Conn{.{ .gen = 7, .closing = true, .busy = true, .send_live = true, .send_zc = true, .out = bytes.ptr, .out_len = slab_size, .out_cap = slab_size }};
    const c = &conns[0];
    var w = Worker{ .shared = &shared, .id = 0, .conns = &conns, .send_zc_enabled = true };
    var ring = SendTestRing{};
    ring.attach(&w);
    w.onSend(0, 7, -@as(i32, @backingInt(linux.E.NOMEM)), linux.IORING_CQE_F_MORE);
    try std.testing.expect(!c.open and !c.send_live and c.zc_waiting);
    try std.testing.expectEqual(@as(u32, 0), w.ring.sq.sqe_tail);
    try std.testing.expectEqual(@as(u32, slab_size), c.out_cap);
    w.onSend(0, 7, 0, linux.IORING_CQE_F_NOTIF);
    try std.testing.expect(!c.open and !c.send_live and !c.zc_waiting);
    try std.testing.expectEqual(@as(u32, 1), w.ring.sq.sqe_tail);
    try std.testing.expectEqual(linux.IORING_OP.CLOSE, ring.sqes[0].opcode);
    try std.testing.expectEqual(@as(u32, 0), c.out_cap);
}

test "memory pressure preserves future zero-copy eligibility but unsupported kernels disable it" {
    const log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = log_level;
    for ([_]linux.E{ .NOMEM, .INVAL, .OPNOTSUPP }) |err| {
        const bytes = try gpa.alloc(u8, slab_size);
        defer gpa.free(bytes);
        var shared: Shared = undefined;
        var conns = [_]Conn{.{ .gen = 7, .open = true, .busy = true, .send_live = true, .send_zc = true, .out = bytes.ptr, .out_len = slab_size, .out_cap = slab_size }};
        const c = &conns[0];
        var w = Worker{ .shared = &shared, .id = 0, .conns = &conns, .send_zc_enabled = true };
        var ring = SendTestRing{};
        ring.attach(&w);
        w.onSend(0, 7, -@as(i32, @backingInt(err)), linux.IORING_CQE_F_MORE);
        try std.testing.expect(c.open and c.send_live and !c.send_zc);
        try std.testing.expectEqual(linux.IORING_OP.SEND, ring.sqes[0].opcode);
        const enabled = err == .NOMEM;
        try std.testing.expectEqual(enabled, w.send_zc_enabled);
        w.onSend(0, 7, slab_size, 0);
        try std.testing.expect(c.busy and c.zc_waiting);
        w.onSend(0, 7, 0, linux.IORING_CQE_F_NOTIF);
        try std.testing.expect(c.open and !c.busy);
        const next: [512]u8 = @splat('x');
        c.busy = true;
        w.sendCopy(0, 7, &next, true);
        try std.testing.expectEqual(enabled, c.send_zc);
        try std.testing.expectEqual(if (enabled) linux.IORING_OP.SEND_ZC else linux.IORING_OP.SEND, ring.sqes[1].opcode);
        w.onSend(0, 7, next.len, if (enabled) linux.IORING_CQE_F_MORE else 0);
        if (enabled) w.onSend(0, 7, 0, linux.IORING_CQE_F_NOTIF);
        try std.testing.expect(c.open and !c.busy and !c.zc_waiting);
        try std.testing.expectEqual(@as(u32, 0), c.out_cap);
        try std.testing.expectEqual(@as(u32, 2), w.ring.sq.sqe_tail);
    }
}

test "outstanding unsupported zero-copy sends retain their own attempt identity" {
    var shared: Shared = undefined;
    var w = Worker{ .shared = &shared, .id = 0, .send_zc_enabled = true };
    var a = Conn{ .send_live = true, .send_zc = true };
    var b = Conn{ .send_live = true, .send_zc = true };
    try std.testing.expect(a.completeSend(-@as(i32, @backingInt(linux.E.OPNOTSUPP)), 0));
    w.send_zc_enabled = false;
    try std.testing.expect(b.completeSend(-@as(i32, @backingInt(linux.E.INVAL)), 0));
    try std.testing.expect(!w.send_zc_enabled);
    try std.testing.expect(!a.send_zc and !b.send_zc);
}
