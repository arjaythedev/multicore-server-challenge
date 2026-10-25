//! The event loop: one thread per worker, each with its own io_uring, SO_REUSEPORT listener, connection table and
//! Postgres connections. Nothing on the request path is shared between workers.
//!
//! Idle keep-alive connections cost one 48-byte table slot (indexed by fd) plus the kernel socket: receive buffers
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
const log = std.log.scoped(.server);

pub const Config = struct {
    host: [4]u8,
    port: u16,
    db: pg.Config,
    secret: []const u8,
    threads: u32,
    pg_read: u32, // connections per worker
    pg_write: u32,
    pg_depth: u32, // batches in flight per connection
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
};

const max_pend = http.max_body + http.max_head + 4096;

// user_data layout: tag (8) | gen (24) | index (32)
const Tag = enum(u8) { accept = 1, recv, poll, send, pg_recv, pg_send, event, close, shut, timer, hold };

inline fn ud(tag: Tag, gen: u32, idx: u32) u64 {
    return (@as(u64, @backingInt(tag)) << 56) | (@as(u64, gen & 0xffffff) << 32) | idx;
}

// ---------------------------------------------------------------------------------------------
// Postgres connections
// ---------------------------------------------------------------------------------------------

const max_depth_cap = 64;

const prepare_list = blk: {
    var out: [sql.prepared.len]pg.Prep = undefined;
    for (sql.prepared, 0..) |x, i| out[i] = .{ .id = x.id, .sql = x.sql, .params = x.params };
    break :blk out;
};

const PgConn = struct {
    fd: i32 = -1,
    class: Class = .read,
    alive: bool = false,
    sending: bool = false,
    recving: bool = false,
    rs: pg.Stream = undefined,
    wa: Buf = .{}, // in flight (immutable while `sending`)
    ws: Buf = .{}, // staging
    wsent: usize = 0,
    q: [max_depth_cap]usize = undefined, // *Req, or *BatchRec | 1
    qh: u32 = 0,
    depth: u32 = 0,
    ginflight: bool = false, // a group commit is in flight on this (write) connection
    staged: std.ArrayList(Member) = .empty, // writes waiting for the in-flight group to commit
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
pub const StageItem = struct { r: *Req, seq: u64, viewer: i64, limit: i32, offset: i32, text: []u8, single_only: bool = false };

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

/// One write request inside a group commit: its encoded statements (with their own trailing Sync, used if the group
/// has to be retried member by member) and how many statements it contributes.
const Member = struct { r: *Req, k: u8, bytes: []u8 };
const max_group = 32;

const WRec = struct {
    n: u32,
    m: [max_group]Member,
};

const sync_len = 5;

const BatchRec = struct {
    n: u32,
    /// All requests share one statement's reply (`tags`: viewer-independent, so one run serves every waiting request).
    fanout: bool = false,
    reqs: [max_batch]*Req,
    /// The requests' parameters, kept (text owned) until the reply: if the statement fails, each request is re-run alone.
    items: [max_batch]StageItem,
    stmt: sql.Stmt,
};

// ---------------------------------------------------------------------------------------------
// Worker
// ---------------------------------------------------------------------------------------------

const buf_size = 2048;
const n_bufs = 16384;
const bgid = 1;
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
    enc: Buf = .{},
    scratch: Scratch = undefined,
    free_reqs: ?*Req = null,
    slabs: [slab_pool_cap][*]u8 = undefined,
    slab_count: usize = 0,
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
    hold_ts: linux.kernel_timespec = .{ .sec = 0, .nsec = 0 },
    hold_armed: bool = false,
    staged_since: u64 = 0, // nowNs() when `staged` last went from 0
    stats: struct { reqs: u64 = 0, pg_batches: u64 = 0, fifo_max: usize = 0, batched_reqs: u64 = 0, batches: u64 = 0 } = .{},

    // ---- small helpers ----------------------------------------------------------------------

    pub fn beginBody(self: *Worker) void {
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

    // ---- sending responses ------------------------------------------------------------------

    /// Copy `resp` into an owned buffer and send it on `fd` (if that connection is still the same one).
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
        self.submitSend(fd, c);
    }

    fn submitSend(self: *Worker, fd: i32, c: *Conn) void {
        const s = self.sqe();
        const to_send = (c.out + c.out_off)[0 .. c.out_len - c.out_off];
        if (self.shared.cfg.send_zc and to_send.len >= 256 and c.out_off == 0) {
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

        // io_uring zero-copy buffer release notification (IORING_CQE_F_NOTIF)
        if (flags & linux.IORING_CQE_F_NOTIF != 0) {
            c.zc_waiting = false;
            if (c.send_live) return;
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
            if (c.pend_len != 0) self.parsePend(fd, c);
            if (c.eof and c.open and !c.busy) self.closeConn(fd);
            return;
        }

        c.send_live = false;
        if (res < 0) {
            const err_num = -res;
            if (self.shared.cfg.send_zc and (err_num == @as(i32, @intFromEnum(linux.E.OPNOTSUPP)) or err_num == @as(i32, @intFromEnum(linux.E.INVAL)))) {
                self.shared.cfg.send_zc = false;
                if (c.open) {
                    self.submitSend(fd, c);
                    return;
                }
            }
            self.freeOut(c);
            self.closeConn(fd);
            self.maybeFinishClose(fd); // closeConn does nothing when the connection was already closing
            return;
        }
        c.out_off += @intCast(res);
        if (c.out_off < c.out_len and c.open) {
            self.submitSend(fd, c);
            return;
        }

        if (flags & linux.IORING_CQE_F_MORE != 0) {
            c.zc_waiting = true;
            if (!c.open) return;
        } else {
            self.freeOut(c);
            if (!c.open) {
                self.maybeFinishClose(fd);
                return;
            }
            c.busy = false;
            if (c.close_after) {
                self.closeConn(fd);
                return;
            }
            if (c.pend_len != 0) self.parsePend(fd, c);
            if (c.eof and c.open and !c.busy) self.closeConn(fd);
        }
    }

    fn freeOut(self: *Worker, c: *Conn) void {
        if (c.zc_waiting or c.send_live) return;
        if (c.out_cap == slab_size and self.slab_count < slab_pool_cap) {
            self.slabs[self.slab_count] = c.out;
            self.slab_count += 1;
        } else if (c.out_cap != 0) {
            gpa.free(c.out[0..c.out_cap]);
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
        const c = &self.conns[@intCast(fd)];
        c.* = .{ .gen = c.gen +% 1, .open = true };
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
            rm.user_data = ud(.shut, 0, 0);
            c.recv_live = false;
        }
        if (c.recv_live or c.send_live) {
            const s = self.sqe();
            s.prep_rw(.SHUTDOWN, fd, 0, 0, 0);
            s.len = linux.SHUT.RDWR;
            s.user_data = ud(.shut, 0, 0);
        }
        self.maybeFinishClose(fd);
    }

    fn maybeFinishClose(self: *Worker, fd: i32) void {
        const c = &self.conns[@intCast(fd)];
        if (!c.closing or c.recv_live or c.send_live or c.zc_waiting) return;
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
        const rc = linux.recvfrom(fd, self.scratch_rx.ptr, self.scratch_rx.len, linux.MSG.DONTWAIT, null, null);
        switch (sys.errnoOf(rc)) {
            .SUCCESS => {
                if (rc == 0) {
                    if (c.busy) c.eof = true else self.closeConn(fd);
                    return;
                }
                self.onData(fd, c, self.scratch_rx[0..rc]);
            },
            .AGAIN, .INTR => {},
            else => {
                self.closeConn(fd);
                return;
            },
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
        self.sendCopy(fd, c.gen, resp, false);
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
        const range = self.classRange(class);
        const cap = self.shared.cfg.pg_depth;
        // least-loaded live connection with room; rotate the start so ties spread out
        var best: ?*PgConn = null;
        const n = range.hi - range.lo;
        if (n != 0) {
            var i: usize = 0;
            const start = self.rr[@backingInt(class)];
            while (i < n) : (i += 1) {
                const p = &self.pgs[range.lo + (start + i) % n];
                if (!p.alive or p.depth >= cap) continue;
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
        p.ws.putSlice(bytes);
        p.q[(p.qh + p.depth) % max_depth_cap] = token;
        p.depth += 1;
        if (!p.sending) self.pgFlush(p);
    }

    fn pgFlush(self: *Worker, p: *PgConn) void {
        if (p.ws.len == 0 or p.sending) return;
        const t = p.wa;
        p.wa = p.ws;
        p.ws = t;
        p.ws.reset();
        p.wsent = 0;
        p.sending = true;
        const idx: u32 = @intCast(p - self.pgs.ptr);
        const s = self.sqe();
        s.prep_send(p.fd, p.wa.slice(), linux.MSG.NOSIGNAL);
        s.user_data = ud(.pg_send, 0, idx);
    }

    fn onPgSend(self: *Worker, idx: u32, res: i32) void {
        const p = &self.pgs[idx];
        p.sending = false;
        if (res <= 0) return self.pgFail(p);
        p.wsent += @intCast(res);
        if (p.wsent < p.wa.len) {
            p.sending = true;
            const s = self.sqe();
            s.prep_send(p.fd, p.wa.slice()[p.wsent..], linux.MSG.NOSIGNAL);
            s.user_data = ud(.pg_send, 0, idx);
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
        s.user_data = ud(.pg_recv, 0, @intCast(p - self.pgs.ptr));
        p.recving = true;
    }

    fn onPgRecv(self: *Worker, idx: u32, res: i32) void {
        const p = &self.pgs[idx];
        p.recving = false;
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
            switch (token & 3) {
                0 => api.onPg(self, @ptrFromInt(token), batch),
                1 => self.onBatchReply(@ptrFromInt(token & ~@as(usize, 3)), batch),
                2 => self.onGroupReply(p, @ptrFromInt(token & ~@as(usize, 3)), batch),
                else => self.onPlanReply(p, @ptrFromInt(token & ~@as(usize, 3)), batch),
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
        const cap = self.shared.cfg.pg_depth;
        while (f.len != 0) {
            var best: ?*PgConn = null;
            for (self.pgs[range.lo..range.hi]) |*p| {
                if (!p.alive or p.depth >= cap) continue;
                if (best == null or p.depth < best.?.depth) best = p;
            }
            const p = best orelse return;
            const q = f.pop().?;
            self.pgPush(p, @intFromPtr(q.r), q.bytes);
            gpa.free(q.bytes);
        }
    }

    fn pgFail(self: *Worker, p: *PgConn) void {
        if (!p.alive) return;
        log.err("postgres connection {d} lost", .{@as(usize, @intCast(p - self.pgs.ptr))});
        p.alive = false;
        _ = linux.close(p.fd);
        p.fd = -1;
        // Fail what was in flight on this connection; nothing is replayed (a write may have committed).
        var i: u32 = 0;
        while (i < p.depth) : (i += 1) self.failToken(p.q[(p.qh + i) % max_depth_cap]);
        p.depth = 0;
        p.qh = 0;
        p.ginflight = false;
        for (p.staged.items) |mem| {
            api.onPgFailure(self, mem.r);
            gpa.free(mem.bytes);
        }
        p.staged.clearRetainingCapacity();
        p.wa.reset();
        p.ws.reset();
        p.rs.start = 0;
        p.rs.scan = 0;
        p.rs.end = 0;
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

    /// Dead Postgres connections are replaced by a helper thread, so a slow or stalled server cannot freeze the loop;
    /// the loop adopts the finished socket from `onEvent`.
    fn pgReconnect(self: *Worker) void {
        var dead = false;
        for (self.pgs) |*p| dead = dead or !p.alive;
        if (!dead) return;
        if (@cmpxchgStrong(u32, &self.rc_busy, 0, 1, .acq_rel, .monotonic) != null) return;
        const t = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, Worker.reconnectMain, .{self}) catch {
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
            if (p.alive) continue;
            p.fd = fd;
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
        switch (token & 3) {
            0 => api.onPgFailure(self, @ptrFromInt(token)),
            1 => {
                const rec: *BatchRec = @ptrFromInt(token & ~@as(usize, 3));
                for (rec.reqs[0..rec.n]) |r| api.onPgFailure(self, r);
                if (!rec.fanout) for (rec.items[0..rec.n]) |it| gpa.free(it.text);
                gpa.destroy(rec);
            },
            2 => {
                const rec: *WRec = @ptrFromInt(token & ~@as(usize, 3));
                for (rec.m[0..rec.n]) |mem| {
                    api.onPgFailure(self, mem.r);
                    gpa.free(mem.bytes);
                }
                gpa.destroy(rec);
            },
            else => {
                const rec: *plan.Plan = @ptrFromInt(token & ~@as(usize, 3));
                for (rec.items) |it| api.onPgFailure(self, it.r);
                plan.destroy(rec, true);
            },
        }
    }

    // ---- staged (batchable) reads ---------------------------------------------------------------

    /// Queue a read; it is sent when a connection has room, merged with waiting reads of the same kind.
    pub fn readSubmit(self: *Worker, stmt: sql.Stmt, r: *Req, a: ReadArgs) void {
        const text = gpa.dupe(u8, a.text) catch return api.onPgFailure(self, r);
        self.seq += 1;
        if (self.staged == 0) self.staged_since = sys.nowNs();
        self.stages[@backingInt(stmt)].push(.{ .r = r, .seq = self.seq, .viewer = a.viewer, .limit = a.limit, .offset = a.offset, .text = text });
        self.staged += 1;
    }

    fn bestReadConn(self: *Worker) ?*PgConn {
        const cap = self.shared.cfg.pg_depth;
        const n = self.n_read;
        var best: ?*PgConn = null;
        var i: usize = 0;
        const start = self.rr[0];
        while (i < n) : (i += 1) {
            const p = &self.pgs[(start + i) % n];
            if (!p.alive or p.depth >= cap) continue;
            if (best == null or p.depth < best.?.depth) best = p;
        }
        self.rr[0] = (start + 1) % @max(n, 1);
        return best;
    }

    /// Send staged reads to connections with room, oldest kind first.
    pub fn flushReads(self: *Worker) void {
        if (self.staged == 0) return;
        const window_ns = @as(u64, self.shared.cfg.read_window_us) * 1000;
        const effective_window_ns: u64 = if (!self.shared.cfg.adaptive_window) window_ns else blk: {
            if (self.staged >= self.shared.cfg.read_hold_min) break :blk 0;
            if (self.staged >= 1024) break :blk 10 * std.time.ns_per_ms;
            if (self.staged >= 512) break :blk 25 * std.time.ns_per_ms;
            if (self.staged >= 256) break :blk 35 * std.time.ns_per_ms;
            if (self.staged >= 128) break :blk 50 * std.time.ns_per_ms;

            var has_idle_pg = false;
            for (self.pgs[0..self.n_read]) |*p| {
                if (p.alive and p.depth == 0) {
                    has_idle_pg = true;
                    break;
                }
            }
            if (has_idle_pg and self.staged >= 64) break :blk 15 * std.time.ns_per_ms;
            break :blk window_ns;
        };

        if (effective_window_ns != 0 and self.staged < self.shared.cfg.read_hold_min) {
            // Young and few: wait for company. One timeout wakes the loop when the oldest has waited the window out.
            const waited = sys.nowNs() -| self.staged_since;
            if (waited < effective_window_ns) {
                if (!self.hold_armed) {
                    const left = effective_window_ns - waited;
                    self.hold_ts = .{ .sec = @intCast(left / 1_000_000_000), .nsec = @intCast(left % 1_000_000_000) };
                    const e = self.sqe();
                    e.prep_timeout(&self.hold_ts, 0, 0);
                    e.user_data = ud(.hold, 0, 0);
                    self.hold_armed = true;
                }
                return;
            }
        }
        const batch_max = @min(self.shared.cfg.batch_max, max_batch);
        while (self.staged != 0) {
            var any_alive = false;
            for (self.pgs[0..self.n_read]) |*x| any_alive = any_alive or x.alive;
            if (!any_alive) {
                // nothing can serve them: fail everything staged
                for (&self.stages) |*st| {
                    while (st.len != 0) {
                        const it = st.pop();
                        gpa.free(it.text);
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
            const p = self.bestReadConn() orelse return;
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
            const n: usize = if (st.front().single_only) 1 else if (isBatchable(stmt) or stmt == .tags) st.batchableRun(batch_max) else 1;
            self.enc.reset();
            var e = pg.Enc.init(&self.enc);
            if (stmt == .tags and n > 1) {
                // One execution answers all of them: they were all waiting before it started, and nothing is kept after.
                const rec = gpa.create(BatchRec) catch return;
                rec.n = @intCast(n);
                rec.fanout = true;
                rec.stmt = .tags;
                for (0..n) |i| {
                    const it = st.pop();
                    rec.reqs[i] = it.r;
                    gpa.free(it.text);
                }
                self.staged -= n;
                e.bind(sql.id(.tags));
                e.pInt8(0);
                e.exec();
                e.sync();
                self.pgPush(p, @intFromPtr(rec) | 1, self.enc.slice());
            } else if (n == 1) {
                const it = st.pop();
                self.staged -= 1;
                e.bind(sql.id(stmt));
                e.pInt8(it.viewer);
                if (shapeLo(stmt)) {
                    e.pInt4(it.limit);
                    e.pInt4(it.offset);
                }
                if (shapeText(stmt)) e.pText(it.text);
                e.exec();
                e.sync();
                gpa.free(it.text);
                self.pgPush(p, @intFromPtr(it.r), self.enc.slice());
            } else {
                const rec = gpa.create(BatchRec) catch return;
                rec.n = @intCast(n);
                rec.fanout = false; // create() does not apply field defaults
                var viewers: [max_batch]i64 = undefined;
                var limits: [max_batch]i32 = undefined;
                var offsets: [max_batch]i32 = undefined;
                var texts: [max_batch][]const u8 = undefined;
                rec.stmt = stmt;
                for (0..n) |i| {
                    const it = st.pop();
                    rec.reqs[i] = it.r;
                    rec.items[i] = it;
                    viewers[i] = it.viewer;
                    limits[i] = it.limit;
                    offsets[i] = it.offset;
                    texts[i] = it.text;
                }
                self.staged -= n;
                e.bind(sql.batchId(stmt));
                e.pInt8Array(viewers[0..n]);
                if (shapeLo(stmt)) {
                    e.pInt4Array(limits[0..n]);
                    e.pInt4Array(offsets[0..n]);
                }
                if (shapeText(stmt)) e.pTextArray(texts[0..n]);
                e.exec();
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
        const p = self.bestReadConn() orelse return .no_conn;
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
        // Oldest first across every kind: a capped plan must not leave the older reads of a late-arriving kind behind.
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
            if (it.single_only) kept.append(gpa, t) catch return self.unstage(&taken, &kept) else taken.append(gpa, t) catch return self.unstage(&taken, &kept);
        }
        if (taken.items.len < self.shared.cfg.plan_min) return self.unstage(&taken, &kept);
        const rec = plan.start(self, taken.items) orelse return self.unstage(&taken, &kept);
        for (kept.items) |t| self.stages[@backingInt(t.stmt)].push(t.it);
        self.staged -= taken.items.len;
        self.pgPush(p, @intFromPtr(rec) | 3, self.enc.slice());
        return .started;
    }

    /// Read connections that are alive and have room for another batch.
    fn freeReadConns(self: *Worker) usize {
        var n: usize = 0;
        for (self.pgs[0..self.n_read]) |*p| {
            if (p.alive and p.depth < self.shared.cfg.pg_depth) n += 1;
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
        defer gpa.destroy(rec);
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
        defer for (rec.items[0..rec.n]) |it| gpa.free(it.text);
        var rd = pg.Reader{ .data = batch };
        var pending: ?pg.Msg = null;
        const syn = &self.synth;
        var idx: u32 = 0;
        while (idx < rec.n) : (idx += 1) {
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
            api.onPg(self, rec.reqs[idx], syn.slice());
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
        const copy = gpa.dupe(u8, bytes) catch return api.onPgFailure(self, r);
        p.staged.append(gpa, .{ .r = r, .k = k, .bytes = copy }) catch {
            gpa.free(copy);
            return api.onPgFailure(self, r);
        };
        if (!p.ginflight) self.sendGroup(p);
    }

    fn sendGroup(self: *Worker, p: *PgConn) void {
        const n = @min(p.staged.items.len, max_group);
        if (n == 0) return;
        const rec = gpa.create(WRec) catch return;
        rec.n = @intCast(n);
        self.enc.reset();
        for (0..n) |i| {
            rec.m[i] = p.staged.items[i];
            self.enc.putSlice(rec.m[i].bytes[0 .. rec.m[i].bytes.len - sync_len]); // members' statements, no Sync
        }
        if (self.shared.cfg.test_fail_groups and n >= 2) {
            // Bind to a statement that does not exist: the server answers with an error and rolls the group back.
            self.enc.putSlice("B\x00\x00\x00\x11\x00s9999\x00\x00\x00\x00\x00\x00\x00");
            self.enc.putSlice("E\x00\x00\x00\x09\x00\x00\x00\x00\x00");
        }
        self.enc.putSlice("S\x00\x00\x00\x04");
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
            // Rolled back as a whole (nothing committed): run each member on its own.
            for (rec.m[0..rec.n]) |mem| {
                self.soloWrite(mem.r, mem.bytes);
                gpa.free(mem.bytes);
            }
        } else {
            var rd = pg.Reader{ .data = batch };
            var start: usize = 0;
            var idx: usize = 0;
            var seen: u32 = 0;
            const syn = &self.synth;
            while (idx < rec.n) {
                const m = rd.next() orelse break;
                if (m.kind != 'C') continue;
                seen += 1;
                if (seen < rec.m[idx].k) continue;
                syn.reset();
                syn.putSlice(batch[start..rd.pos]);
                syn.putSlice("Z\x00\x00\x00\x05I");
                start = rd.pos;
                seen = 0;
                const mem = rec.m[idx];
                idx += 1;
                api.onPg(self, mem.r, syn.slice());
                gpa.free(mem.bytes);
            }
            while (idx < rec.n) : (idx += 1) { // reply shorter than expected: should not happen
                api.onPgFailure(self, rec.m[idx].r);
                gpa.free(rec.m[idx].bytes);
            }
        }
        gpa.destroy(rec);
        if (p.staged.items.len != 0) self.sendGroup(p);
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
            .accept => self.onAccept(cqe.res, cqe.flags),
            .pg_recv => self.onPgRecv(idx, cqe.res),
            .pg_send => self.onPgSend(idx, cqe.res),
            .event => self.onEvent(),
            .hold => self.hold_armed = false,
            .timer => {
                if (!self.accept_live) self.armAccept();
                self.pgReconnect();
                self.sweepPartials();
                if (self.shared.cfg.stats) self.printStats();
                self.armTimer();
            },
            .close, .shut => {},
        }
    }

    fn printStats(self: *Worker) void {
        std.debug.print("[w{d}] reqs={d} pg_syncs={d} batched_reqs={d} in {d} statements fifo_max={d}\n", .{ self.id, self.stats.reqs, self.stats.pg_batches, self.stats.batched_reqs, self.stats.batches, self.stats.fifo_max });
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
    w.* = .{ .shared = shared, .id = id };
    w.scratch = try Scratch.init(64 * 1024);
    w.out = try Buf.init(64 * 1024);
    w.enc = try Buf.init(16 * 1024);
    w.scratch_rx = try gpa.alloc(u8, 64 * 1024);
    w.ring = try initRing();
    if (!cfg.no_pbuf) setupPbufRing(w);
    w.now = sys.nowUnix();
    w.mono = monoSecs();

    // connection table, indexed by fd (lazily committed by the kernel)
    var rl: linux.rlimit = undefined;
    _ = linux.getrlimit(.NOFILE, &rl);
    rl.cur = rl.max;
    _ = linux.setrlimit(.NOFILE, &rl);
    const nfds: usize = @intCast(@min(rl.max, 1 << 21));
    const cmem = try sys.mapAnon(nfds * @sizeOf(Conn));
    w.conns = @as([*]Conn, @ptrCast(@alignCast(cmem.ptr)))[0..nfds];

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

    w.listener = try makeListener(cfg);
    w.armAccept();
    w.armEvent();
    w.armTimer();
    for (w.pgs) |*p| w.pgArmRecv(p);
    _ = @atomicRmw(u32, &shared.ready, .Add, 1, .release);
    w.run();
}
