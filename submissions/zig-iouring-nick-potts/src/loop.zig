//! One worker's event loop: a single io_uring drives the clients, this worker's Postgres connections and the bcrypt
//! completion eventfd, and it hands bcrypt batches to the hasher threads (bcrypt.pump). The drain process runs the
//! same loop without clients or bcrypt (drain.zig).
//!
//! Clients: multishot accept, then multishot recv into provided buffers (the classic PROVIDE_BUFFERS kind; buffer
//! rings return EINVAL on the target's 6.8 kernel). A request is parsed straight out of the provided buffer when it
//! arrived whole; only leftovers are copied into the client's own buffer. One request per client is handled at a
//! time, so pipelined requests are answered in order. A response leaves in one send from the buffer it was built in;
//! a shared response (drain.zig) leaves from its lead's buffer, freed when the last of its sends completes.
//!
//! Each iteration handles every completion that is ready, takes what the other side of the drain rings published,
//! then fills the Postgres connections (db.pump), sends what they queued and publishes to the other side. While reads
//! wait for their batch clock, the wait ends when their drain is due.
//!
//! With `shed`, a worker's controller (shed.zig) ticks every iteration; worker 0's wakes for its tick at least every
//! interval, as it reads the box's CPU.
//!
//! With `ackdelay`, each sent response turns TCP_QUICKACK off on its socket through the ring (a socket uring_cmd,
//! kernel 6.7+), so the next request's ACK waits for its response instead of leaving alone. The kernel picks quick or
//! delayed ACK as a request arrives, before it is read, and leaves delayed mode whenever its delayed-ACK timer fires
//! (a response slower than about 40 ms), so this is done after every response, which carries any pending ACK and so
//! stops that timer.
//!
//! Ring knobs, each off by default (environment, read in main.zig):
//! - ZIG_BUF_RUNS=1: consecutive returned buffer ids go back in one PROVIDE_BUFFERS each, not one per buffer.
//! - ZIG_CQ_BUDGET=N: at most N completions per iteration before the rest of it (answers, pump, publish, buffer
//!   returns); the next wait then submits and returns at once, as completions are still ready.
//! - ZIG_FIXED_FILES=1: the Postgres sockets go through the ring's fixed-file table; 2: client sockets too, each
//!   client keeping its own slot while slots last (the rest stay plain).
//! - ZIG_PG_POLL_FIRST=1: a Postgres receive waits for data before trying (IORING_RECVSEND_POLL_FIRST) when the last
//!   one left the socket empty (no IORING_CQE_F_SOCK_NONEMPTY); 2: always.
//! - ZIG_ACK_SKIP_MS=N: no TCP_QUICKACK uring_cmd for a response sent within N ms of its socket's last data. The
//!   kernel already counts such a reply toward pingpong mode (a reply within ato of the last received segment, and
//!   6.8 keeps ato at 20 ms or more), so the setsockopt would change nothing. The socket's data is dated by the start
//!   of the iteration before the one that read it, so the gap is never undercounted.
//! - ZIG_URING_STATS=1: every 10 s each process logs what these act on.
const std = @import("std");
const linux = std.os.linux;
const IoUring = linux.IoUring;
const sys = @import("sys.zig");
const http = @import("http.zig");
const api = @import("api.zig");
const db = @import("db.zig");
const bcrypt = @import("bcrypt.zig");
const drain_process = @import("drain.zig");
const shed = @import("shed.zig");
const Flags = @import("flags.zig").Flags;
const Buf = @import("buf.zig").Buf;

const gpa = std.heap.smp_allocator;

const Tag = enum(u3) { accept = 1, recv, send, pg_recv, pg_send, bcrypt, wake };

fn userData(ptr: ?*const anyopaque, tag: Tag) u64 {
    return @as(u64, @intFromPtr(ptr)) | @intFromEnum(tag);
}

const buf_group = 1;
const buf_size = 4096;
const buf_count = 4096;
const max_body = 1 << 20;

const Client = struct {
    fd: i32,
    /// Bytes received but not yet handled (a partial request, or requests pipelined behind the current one).
    pending: std.ArrayList(u8) = .empty,
    /// A request is in progress: being handled or its response being sent.
    busy: bool = false,
    recv_armed: bool = false,
    /// No more requests will be read: the peer closed, the connection failed or the response said close.
    closing: bool = false,
    sending: []const u8 = "",
    /// The response being sent is this shared one.
    shared: ?*Shared = null,
    req: api.Req = .{},
    next_free: ?*Client = null,
    /// The next response waiting for the send budget (ZIG_SEND_PACE), and when this one started waiting.
    paced_next: ?*Client = null,
    paced_ns: u64 = 0,
    /// Its fixed-file slot (ZIG_FIXED_FILES=2), kept across reuse, or `no_slot`.
    slot: u32 = no_slot,
    /// When its last data arrived at the earliest (ZIG_ACK_SKIP_MS).
    rx_ns: u64 = 0,
};

/// A lead's response, sent to the lead and to each of its followers.
const Shared = struct {
    out: Buf,
    bytes: []const u8,
    /// Sends not completed yet, the followers' still to come included.
    refs: u32,
    /// Followers not answered yet.
    waiting: u32,
    next_free: ?*Shared = null,
};

pub var buf_runs = false;
pub var cq_budget: u32 = 0;
pub var fixed_files: u2 = 0;
pub var pg_poll_first: u2 = 0;
pub var ack_skip_ns: u64 = 0;
pub var stats_on = false;

const no_slot = std.math.maxInt(u32);
/// Client slots per worker; the table also holds the Postgres connections, first.
const client_slots = 1 << 17;
var slots: u32 = 0;
var next_slot: u32 = 0;
const no_fd: i32 = -1;
/// A fixed-file update's completion, which only a failure posts.
const files_update_data: u64 = 16;
/// The previous iteration's start: nothing read in this iteration arrived before it.
var prev_ns: u64 = 0;

var ring: IoUring = undefined;
var listen_fd: i32 = -1;
var bufs: []align(4096) u8 = &.{};
var returned: std.ArrayList(u16) = .empty;
var rearm: std.ArrayList(*Client) = .empty;
var free_clients: ?*Client = null;
var free_shared: ?*Shared = null;
/// The latest lead, while followers wait for its response.
var lead: ?*Shared = null;
var efd_buf: u64 = 0;
var wake_buf: u64 = 0;
var now: i64 = 0;
/// Cleared for the rest of the process when the kernel refuses the socket uring_cmd.
var ack_delay = true;
const quickack_off: c_int = 0;
/// The setsockopt's completion, which only a failure posts: tag 0 like the buffer returns, told apart by a pointer
/// part of its own.
const ack_delay_data: u64 = 8;

/// ZIG_SEND_PACE=N: the server hands responses to send at N Mbit/s at most, each worker an equal share, in the order
/// they finished; 0, the default, sends each at once. At 200,000 users a shared drain answers ~1,900 reads together,
/// ~4.5 MB, about 15 ms of the rig's 2.4 Gbit/s link. Queued that long in the NIC's one queue, responses' tail-loss
/// probes fire while the originals still wait (TCPSpuriousRtxHostQueues); queued here, they run no TCP timer.
pub var pace: Pacer = .{ .per_ms = 0 };
var paced: struct { head: ?*Client = null, tail: ?*Client = null, n: u32 = 0, bytes: u64 = 0, wait_max: u64 = 0, at: u64 = 0 } = .{};

/// Sends at `per_ms` bytes per ms: each send moves `free_at`, when everything handed to send so far has gone out at
/// that rate, and a send goes while `free_at` is at most 1 ms ahead. Only a response that finds no other waiting
/// restarts the clock from now, so a backlog leaves at the rate however late the loop comes back to it, and idle
/// time banks no more than that 1 ms.
pub const Pacer = struct {
    per_ms: u64,
    free_at: u64 = 0,

    fn restart(p: *Pacer, t: u64) void {
        p.free_at = @max(p.free_at, t);
    }

    fn open(p: *const Pacer, t: u64) bool {
        return p.free_at <= t + std.time.ns_per_ms;
    }

    fn take(p: *Pacer, bytes: usize) void {
        p.free_at += bytes * std.time.ns_per_ms / p.per_ms;
    }

    /// When the next send may go (monotonic ns).
    fn next(p: *const Pacer) u64 {
        return p.free_at - std.time.ns_per_ms;
    }
};

/// Hands waiting responses to send while the pace allows; returns when the next may go, if one waits.
fn sendPaced() ?u64 {
    while (paced.head) |c| {
        if (!pace.open(db.now_ns)) return pace.next();
        paced.head = c.paced_next;
        if (paced.head == null) paced.tail = null;
        c.paced_next = null;
        pace.take(c.sending.len);
        if (db.lane_stats) {
            paced.n += 1;
            paced.bytes += c.sending.len;
            paced.wait_max = @max(paced.wait_max, db.now_ns -| c.paced_ns);
        }
        sendBytes(c, c.sending);
    }
    return null;
}

fn logPaced() void {
    if (paced.at == 0) paced.at = db.now_ns;
    if (db.now_ns < paced.at + 10 * std.time.ns_per_s) return;
    sys.log("send pace {d} ms: {d} responses, {d} KB, longest wait {d} ms", .{
        (db.now_ns - paced.at) / std.time.ns_per_ms, paced.n, paced.bytes >> 10, paced.wait_max / std.time.ns_per_ms,
    });
    paced = .{ .head = paced.head, .tail = paced.tail, .at = db.now_ns };
}

fn sqe() *linux.io_uring_sqe {
    return ring.get_sqe() catch {
        _ = ring.submit() catch |e| sys.fatal("io_uring submit: {s}", .{@errorName(e)});
        return ring.get_sqe() catch sys.fatal("submission queue full", .{});
    };
}

/// Runs a worker on its listening socket, or the drain process without one, as the server built for `F`.
pub fn run(comptime F: Flags, listener: ?i32) noreturn {
    var params = std.mem.zeroInit(linux.io_uring_params, .{
        .flags = linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_DEFER_TASKRUN | linux.IORING_SETUP_COOP_TASKRUN |
            linux.IORING_SETUP_SUBMIT_ALL | linux.IORING_SETUP_CQSIZE,
        .cq_entries = 65536,
    });
    ring = IoUring.init_params(4096, &params) catch |e| sys.fatal("io_uring setup: {s}", .{@errorName(e)});
    if (fixed_files > 0) registerFiles(listener != null);

    if (listener) |fd| {
        listen_fd = fd;
        bufs = std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(4096), buf_size * buf_count) catch sys.fatal("oom", .{});
        const s = sqe();
        s.prep_provide_buffers(bufs.ptr, buf_size, buf_count, buf_group, 0);
        s.user_data = 0;
        armAccept();
        armBcrypt();
    }
    for (db.conns) |*c| armPgRecv(c, true);
    armWake();

    var cqes: [512]linux.io_uring_cqe = undefined;
    // The drain process's first wait comes after its first idle check too, or no worker would wake it.
    var due: ?u64 = drain_process.send(null);
    db.now_ns = sys.monoNs();
    while (true) {
        wait(due);
        now = sys.nowSec();
        prev_ns = db.now_ns;
        db.now_ns = sys.monoNs();
        if (F.shed and listener != null) shed.ctl.tick(db.now_ns);
        var handled: u32 = 0;
        while (cq_budget == 0 or handled < cq_budget) {
            const room = if (cq_budget == 0) cqes.len else @min(cqes.len, cq_budget - handled);
            const n = ring.copy_cqes(cqes[0..room], 0) catch |e| sys.fatal("io_uring cqes: {s}", .{@errorName(e)});
            if (n == 0) break;
            handled += n;
            for (cqes[0..n]) |*c| complete(F, c);
        }
        if (stats_on) stats.completions(handled, cq_budget > 0 and handled == cq_budget);
        drain_process.receive();
        if (stats_on) stats.answers();
        due = db.pump();
        if (listener != null) if (bcrypt.pump(db.now_ns)) |t| {
            due = if (due) |d| @min(d, t) else t;
        };
        if (F.shed and listener != null) if (shed.ctl.due()) |t| {
            due = if (due) |d| @min(d, t) else t;
        };
        if (listener != null and pace.per_ms > 0) {
            if (sendPaced()) |t| due = if (due) |d| @min(d, t) else t;
            if (db.lane_stats) logPaced();
        }
        for (db.conns) |*c| flushPg(c);
        due = drain_process.send(due);
        returnBuffers();
        for (rearm.items) |c| armRecv(c);
        rearm.clearRetainingCapacity();
        if (stats_on) stats.endIteration(listener != null, db.now_ns);
    }
}

/// Gives this iteration's buffers back, one PROVIDE_BUFFERS each, or one per run of consecutive ids with
/// ZIG_BUF_RUNS. A run is added in id order, so the kernel's list holds them in the same order either way.
fn returnBuffers() void {
    var i: usize = 0;
    while (i < returned.items.len) {
        const bid = returned.items[i];
        var n: u16 = 1;
        if (buf_runs) while (i + n < returned.items.len and returned.items[i + n] == bid + n) : (n += 1) {};
        const s = sqe();
        s.prep_provide_buffers(bufs[@as(usize, bid) * buf_size ..].ptr, buf_size, n, buf_group, bid);
        s.flags |= linux.IOSQE_CQE_SKIP_SUCCESS;
        s.user_data = 0;
        if (stats_on) stats.return_sqes += 1;
        i += n;
    }
    if (stats_on) stats.returns += returned.items.len;
    returned.clearRetainingCapacity();
}

/// The fixed-file table (ZIG_FIXED_FILES): the Postgres connections at their index, then client slots in a worker
/// with 2. If the kernel refuses it, every socket stays plain.
fn registerFiles(clients: bool) void {
    var lim: linux.rlimit = undefined;
    const most: u32 = if (linux.errno(linux.getrlimit(.NOFILE, &lim)) == .SUCCESS) @intCast(@min(lim.cur, 1 << 20)) else 1024;
    const conns: u32 = @intCast(db.conns.len);
    const want = conns + if (clients and fixed_files == 2) @min(client_slots, most -| conns) else 0;
    ring.register_files_sparse(want) catch |e| {
        sys.log("fixed files ({d}): {s}; sockets stay plain", .{ want, @errorName(e) });
        fixed_files = 0;
        return;
    };
    for (db.conns) |c| ring.register_files_update(c.index, &.{c.fd}) catch |e|
        sys.fatal("fixed file for postgres connection {d}: {s}", .{ c.index, @errorName(e) });
    slots = want;
    next_slot = conns;
}

/// Points `s` at the socket `fd`, through its fixed-file slot if it has one.
fn setFile(s: *linux.io_uring_sqe, fd: i32, slot: u32) void {
    if (slot == no_slot) {
        s.fd = fd;
    } else {
        s.fd = @intCast(slot);
        s.flags |= linux.IOSQE_FIXED_FILE;
    }
}

/// Puts `fd` (or `no_fd`, which empties it) in fixed-file slot `slot`, in submission order: the SQEs after it see
/// the new file. `fd` is read when the ring takes the SQE.
fn updateSlot(slot: u32, fd: *const i32) void {
    const s = sqe();
    s.prep_files_update(fd[0..1], slot);
    s.flags |= linux.IOSQE_CQE_SKIP_SUCCESS;
    s.user_data = files_update_data;
}

/// Waits for the first completion, or until `due` (monotonic ns) if that comes first.
fn wait(due: ?u64) void {
    const to_submit = ring.flush_sq();
    const rc = if (due) |d| blk: {
        const left = d -| sys.monoNs();
        var ts: linux.kernel_timespec = .{ .sec = @intCast(left / std.time.ns_per_s), .nsec = @intCast(left % std.time.ns_per_s) };
        var arg: linux.io_uring_getevents_arg = .{ .sigmask = 0, .sigmask_sz = 0, .pad = 0, .ts = @intFromPtr(&ts) };
        break :blk linux.syscall6(.io_uring_enter, @as(u32, @bitCast(ring.fd)), to_submit, 1,
            linux.IORING_ENTER_GETEVENTS | linux.IORING_ENTER_EXT_ARG, @intFromPtr(&arg), @sizeOf(linux.io_uring_getevents_arg));
    } else linux.io_uring_enter(ring.fd, to_submit, 1, linux.IORING_ENTER_GETEVENTS, null);
    switch (linux.errno(rc)) {
        // A timeout or a signal only ends the wait early.
        .SUCCESS, .TIME, .INTR => {},
        else => |e| sys.fatal("io_uring enter: {s}", .{@tagName(e)}),
    }
}

fn complete(comptime F: Flags, cqe: *const linux.io_uring_cqe) void {
    const tag_bits: u3 = @truncate(cqe.user_data);
    if (tag_bits == 0) {
        if (cqe.user_data == ack_delay_data) return ackDelayFailed(cqe);
        if (cqe.user_data == files_update_data) return sys.log("fixed-file update failed: {s}", .{@tagName(cqe.err())});
        if (cqe.res < 0) sys.log("provide buffers failed: {s}", .{@tagName(cqe.err())});
        return;
    }
    const ptr = cqe.user_data & ~@as(u64, 7);
    switch (@as(Tag, @enumFromInt(tag_bits))) {
        .accept => onAccept(cqe),
        .recv => onRecv(F, @ptrFromInt(ptr), cqe),
        .send => onSend(F, @ptrFromInt(ptr), cqe),
        .pg_recv => onPgRecv(@ptrFromInt(ptr), cqe),
        .pg_send => onPgSend(@ptrFromInt(ptr), cqe),
        .bcrypt => onBcrypt(),
        // Only ends the wait: every iteration takes what the rings hold.
        .wake => {
            drain_process.wakes.taken += 1;
            armWake();
        },
    }
}

// ---------------------------------------------------------------- clients

fn armAccept() void {
    const s = sqe();
    s.prep_multishot_accept(listen_fd, null, null, linux.SOCK.CLOEXEC);
    s.user_data = userData(null, .accept);
}

fn onAccept(cqe: *const linux.io_uring_cqe) void {
    if (cqe.flags & linux.IORING_CQE_F_MORE == 0) armAccept();
    if (cqe.res < 0) {
        sys.log("accept: {s}", .{@tagName(cqe.err())});
        return;
    }
    const fd: i32 = cqe.res;
    const c = free_clients orelse blk: {
        const n = gpa.create(Client) catch sys.fatal("oom", .{});
        n.* = .{ .fd = -1 };
        if (fixed_files == 2 and next_slot < slots) {
            n.slot = next_slot;
            next_slot += 1;
        }
        break :blk n;
    };
    free_clients = c.next_free;
    // A reused client keeps its buffers' capacity; everything else starts fresh.
    c.fd = fd;
    c.busy = false;
    c.recv_armed = false;
    c.closing = false;
    c.sending = "";
    c.next_free = null;
    // The segment size the gzip rule counts in: 1448 on IPv4 and 1428 on IPv6 with timestamps.
    var mss: c_int = 0;
    var len: linux.socklen_t = @sizeOf(c_int);
    c.req.mss = if (linux.errno(linux.getsockopt(fd, linux.IPPROTO.TCP, linux.TCP.MAXSEG, std.mem.asBytes(&mss), &len)) == .SUCCESS and mss >= 536 and mss <= 9000) @intCast(mss) else 1448;
    if (c.slot != no_slot) updateSlot(c.slot, &c.fd);
    armRecv(c);
}

fn armRecv(c: *Client) void {
    const s = sqe();
    s.prep_rw(.RECV, c.fd, 0, 0, 0);
    setFile(s, c.fd, c.slot);
    s.flags |= linux.IOSQE_BUFFER_SELECT;
    s.buf_index = buf_group;
    s.ioprio |= linux.IORING_RECV_MULTISHOT;
    s.user_data = userData(c, .recv);
    c.recv_armed = true;
}

fn onRecv(comptime F: Flags, c: *Client, cqe: *const linux.io_uring_cqe) void {
    const more = cqe.flags & linux.IORING_CQE_F_MORE != 0;
    if (!more) c.recv_armed = false;
    if (cqe.res > 0) {
        c.rx_ns = prev_ns;
        const bid = cqe.buffer_id() catch unreachable;
        returned.append(gpa, bid) catch sys.fatal("oom", .{});
        const data = bufs[@as(usize, bid) * buf_size ..][0..@intCast(cqe.res)];
        if (!c.closing) received(F, c, data);
        if (!more and !c.closing) armRecv(c);
    } else if (cqe.err() == .NOBUFS) {
        // Every buffer is in use until this iteration ends; rearm once they are back.
        rearm.append(gpa, c) catch sys.fatal("oom", .{});
        c.recv_armed = true;
    } else {
        // End of stream or an error: nothing more will be read.
        c.closing = true;
    }
    maybeFree(c);
}

fn received(comptime F: Flags, c: *Client, data: []const u8) void {
    if (c.busy or c.pending.items.len > 0) {
        c.pending.appendSlice(gpa, data) catch sys.fatal("oom", .{});
        if (!c.busy) drain(F, c);
        return;
    }
    const used = startOne(F, c, data);
    if (used < data.len and !c.closing) c.pending.appendSlice(gpa, data[used..]) catch sys.fatal("oom", .{});
}

/// Starts the next request held in `pending`, if it is complete.
fn drain(comptime F: Flags, c: *Client) void {
    if (c.busy or c.closing or c.pending.items.len == 0) return;
    const used = startOne(F, c, c.pending.items);
    if (used == 0) return;
    const rest = c.pending.items.len - used;
    std.mem.copyForwards(u8, c.pending.items[0..rest], c.pending.items[used..]);
    c.pending.items.len = rest;
}

/// Starts one request from the front of `data`; returns the bytes it used (0 while incomplete).
fn startOne(comptime F: Flags, c: *Client, data: []const u8) usize {
    switch (http.parseHead(data)) {
        .incomplete => return 0,
        .bad => {
            badRequest(c);
            return data.len;
        },
        .head => |h| {
            if (h.content_length > max_body) {
                badRequest(c);
                return data.len;
            }
            const total = h.len + h.content_length;
            if (data.len < total) return 0;
            c.busy = true;
            api.start(F, &c.req, &h, data[h.len..total], now);
            return total;
        },
    }
}

fn delayAck(fd: i32, slot: u32) void {
    const s = sqe();
    s.prep_cmd_sock(.SETSOCKOPT, fd, linux.IPPROTO.TCP, linux.TCP.QUICKACK, @intFromPtr(&quickack_off), @sizeOf(c_int));
    setFile(s, fd, slot);
    s.flags |= linux.IOSQE_CQE_SKIP_SUCCESS;
    s.user_data = ack_delay_data;
}

fn ackDelayFailed(cqe: *const linux.io_uring_cqe) void {
    // EBADF is a client closed in the same iteration, before the ring took the setsockopt.
    if (!ack_delay or (cqe.err() != .INVAL and cqe.err() != .OPNOTSUPP)) return;
    ack_delay = false;
    sys.log("TCP_QUICKACK through io_uring failed ({s}): requests' ACKs leave alone", .{@tagName(cqe.err())});
}

fn badRequest(c: *Client) void {
    c.busy = true;
    c.req.keep_alive = false;
    sendBytes(c, "HTTP/1.1 400 Bad Request\r\nContent-Length:0\r\nConnection:close\r\n\r\n");
}

/// Called by api with the finished response.
pub fn respond(r: *api.Req, bytes: []const u8) void {
    const c: *Client = @fieldParentPtr("req", r);
    if (pace.per_ms == 0) return sendBytes(c, bytes);
    c.sending = bytes;
    c.paced_ns = db.now_ns;
    if (paced.tail) |t| t.paced_next = c else {
        pace.restart(db.now_ns);
        paced.head = c;
    }
    paced.tail = c;
}

/// Makes the response `r` just started sending also the response of the next `followers` requests that get
/// `respondShared`.
pub fn share(r: *api.Req, followers: u32) void {
    const c: *Client = @fieldParentPtr("req", r);
    if (lead != null) sys.fatal("a lead before the previous lead's followers", .{});
    const s = free_shared orelse blk: {
        const n = gpa.create(Shared) catch sys.fatal("oom", .{});
        n.next_free = null;
        break :blk n;
    };
    free_shared = s.next_free;
    s.* = .{ .out = r.out, .bytes = c.sending, .refs = followers + 1, .waiting = followers };
    r.out = .{};
    c.shared = s;
    lead = s;
}

/// Sends `r` the latest lead's response.
pub fn respondShared(r: *api.Req) void {
    const c: *Client = @fieldParentPtr("req", r);
    const s = lead orelse sys.fatal("a follower without a lead", .{});
    s.waiting -= 1;
    if (s.waiting == 0) lead = null;
    c.shared = s;
    sendBytes(c, s.bytes);
}

fn unshare(c: *Client) void {
    const s = c.shared orelse return;
    c.shared = null;
    s.refs -= 1;
    if (s.refs > 0) return;
    s.out.release();
    s.next_free = free_shared;
    free_shared = s;
}

fn sendBytes(c: *Client, bytes: []const u8) void {
    c.sending = bytes;
    const s = sqe();
    s.prep_send(c.fd, bytes, linux.MSG.NOSIGNAL);
    setFile(s, c.fd, c.slot);
    s.user_data = userData(c, .send);
}

fn onSend(comptime F: Flags, c: *Client, cqe: *const linux.io_uring_cqe) void {
    if (cqe.res < 0) {
        c.closing = true;
    } else {
        c.sending = c.sending[@intCast(cqe.res)..];
        if (c.sending.len > 0) return sendBytes(c, c.sending);
    }
    c.req.out.release();
    unshare(c);
    c.busy = false;
    if (!c.req.keep_alive) c.closing = true;
    if (!c.closing) {
        if (F.ackdelay and ack_delay) {
            // db.now_ns is no earlier than the send, c.rx_ns no later than the socket's last data.
            if (db.now_ns - c.rx_ns >= ack_skip_ns) {
                delayAck(c.fd, c.slot);
                if (stats_on) stats.acks += 1;
            } else if (stats_on) stats.acks_skipped += 1;
        }
        return drain(F, c);
    }
    if (c.recv_armed) _ = linux.shutdown(c.fd, linux.SHUT.RDWR);
    maybeFree(c);
}

fn maybeFree(c: *Client) void {
    if (!c.closing) return;
    if (c.busy) return; // the request in flight still answers; onSend comes back here
    if (c.recv_armed) {
        // Ending the multishot recv is the last completion that can name this client.
        _ = linux.shutdown(c.fd, linux.SHUT.RDWR);
        return;
    }
    // The slot holds the socket open too; emptying it before the slot's next client fills it keeps them in order.
    if (c.slot != no_slot) updateSlot(c.slot, &no_fd);
    sys.closeFd(c.fd);
    c.req.out.release();
    if (c.pending.capacity > 64 * 1024) c.pending.clearAndFree(gpa) else c.pending.clearRetainingCapacity();
    c.next_free = free_clients;
    free_clients = c;
}

// ---------------------------------------------------------------- postgres

/// `empty`: the last receive left the socket empty, as far as the kernel said.
fn armPgRecv(c: *db.Conn, empty: bool) void {
    const space = db.recvSpace(c);
    const s = sqe();
    s.prep_recv(c.fd, space, 0);
    setFile(s, c.fd, pgSlot(c));
    if (pg_poll_first == 2 or (pg_poll_first == 1 and empty)) {
        s.ioprio |= linux.IORING_RECVSEND_POLL_FIRST;
        if (stats_on) stats.pg_poll_first += 1;
    }
    s.user_data = userData(c, .pg_recv);
}

fn onPgRecv(c: *db.Conn, cqe: *const linux.io_uring_cqe) void {
    if (cqe.res <= 0) sys.fatal("postgres connection {d} lost ({d})", .{ c.index, cqe.res });
    c.rend += @intCast(cqe.res);
    db.onRecv(c);
    const nonempty = cqe.flags & linux.IORING_CQE_F_SOCK_NONEMPTY != 0;
    if (stats_on) {
        stats.pg_recvs += 1;
        if (nonempty) stats.pg_nonempty += 1;
    }
    armPgRecv(c, !nonempty);
}

fn pgSlot(c: *const db.Conn) u32 {
    return if (fixed_files > 0) c.index else no_slot;
}

fn flushPg(c: *db.Conn) void {
    if (c.in_send or c.pending.list.items.len == 0) return;
    std.mem.swap(@TypeOf(c.pending), &c.pending, &c.sending);
    c.send_off = 0;
    c.in_send = true;
    pgSend(c);
}

fn pgSend(c: *db.Conn) void {
    const s = sqe();
    s.prep_send(c.fd, c.sending.list.items[c.send_off..], linux.MSG.NOSIGNAL);
    setFile(s, c.fd, pgSlot(c));
    s.user_data = userData(c, .pg_send);
}

fn onPgSend(c: *db.Conn, cqe: *const linux.io_uring_cqe) void {
    if (cqe.res < 0) sys.fatal("postgres send failed: {s}", .{@tagName(cqe.err())});
    c.send_off += @intCast(cqe.res);
    if (c.send_off < c.sending.list.items.len) return pgSend(c);
    c.sending.list.clearRetainingCapacity();
    c.in_send = false;
    flushPg(c);
}

// ---------------------------------------------------------------- bcrypt

fn armBcrypt() void {
    const s = sqe();
    s.prep_read(bcrypt.done_efd, std.mem.asBytes(&efd_buf), 0);
    s.user_data = userData(null, .bcrypt);
}

fn onBcrypt() void {
    var j = bcrypt.finished();
    while (j) |job| {
        j = job.next;
        api.onBcrypt(job);
    }
    armBcrypt();
}

// ---------------------------------------------------------------- drain rings

fn armWake() void {
    const fd = drain_process.wakeFd() orelse return;
    const s = sqe();
    s.prep_read(fd, std.mem.asBytes(&wake_buf), 0);
    s.user_data = userData(null, .wake);
}

// ---------------------------------------------------------------- stats

/// ZIG_URING_STATS: counts since the last line, logged every `stats_ns`.
var stats: Stats = .{};
const stats_ns = 10 * std.time.ns_per_s;

const Stats = struct {
    iterations: u64 = 0,
    cqes: u64 = 0,
    /// Iterations that stopped at ZIG_CQ_BUDGET with completions left.
    budget_hits: u64 = 0,
    returns: u64 = 0,
    return_sqes: u64 = 0,
    pg_recvs: u64 = 0,
    pg_nonempty: u64 = 0,
    pg_poll_first: u64 = 0,
    acks: u64 = 0,
    acks_skipped: u64 = 0,
    /// Each iteration's completion phase, then its answer phase (the drain rings), in µs.
    cqe_us: Hist = .{},
    answer_us: Hist = .{},
    mark_ns: u64 = 0,
    log_at: u64 = 0,

    /// Ends the completion phase, which began with the iteration.
    fn completions(s: *Stats, cqes: u32, hit: bool) void {
        s.mark_ns = sys.monoNs();
        s.cqe_us.add((s.mark_ns - db.now_ns) / std.time.ns_per_us);
        s.cqes += cqes;
        if (hit) s.budget_hits += 1;
    }

    /// Ends the answer phase, which began where the completion phase ended.
    fn answers(s: *Stats) void {
        s.answer_us.add((sys.monoNs() - s.mark_ns) / std.time.ns_per_us);
    }

    fn endIteration(s: *Stats, worker: bool, t: u64) void {
        s.iterations += 1;
        if (s.log_at == 0) s.log_at = t + stats_ns;
        if (t < s.log_at) return;
        s.log_at = t + stats_ns;
        sys.log("uring {s}: {d} iterations, {d} completions ({d} budget stops); buffers {d} returned in {d} SQEs; " ++
            "postgres receives {d} ({d} left data, {d} poll-first); quickack {d} sent, {d} skipped; " ++
            "completion phase us p50/p99/max {d}/{d}/{d}, answer phase {d}/{d}/{d}", .{
            if (worker) "worker" else "drain", s.iterations, s.cqes,          s.budget_hits, s.returns, s.return_sqes,
            s.pg_recvs,                         s.pg_nonempty, s.pg_poll_first, s.acks,        s.acks_skipped,
            s.cqe_us.pct(50),                   s.cqe_us.pct(99), s.cqe_us.max, s.answer_us.pct(50), s.answer_us.pct(99),
            s.answer_us.max,
        });
        s.* = .{ .log_at = s.log_at };
    }
};

/// Durations in µs, in power-of-two buckets; a percentile reads as its bucket's upper bound.
const Hist = struct {
    n: [32]u64 = @splat(0),
    max: u64 = 0,

    fn add(h: *Hist, us: u64) void {
        h.n[@min(31, std.math.log2_int_ceil(u64, us + 1))] += 1;
        h.max = @max(h.max, us);
    }

    fn pct(h: *const Hist, p: u64) u64 {
        var total: u64 = 0;
        for (h.n) |k| total += k;
        var seen: u64 = 0;
        for (h.n, 0..) |k, i| {
            seen += k;
            if (seen * 100 >= total * p and total > 0) return (@as(u64, 1) << @intCast(i)) - 1;
        }
        return 0;
    }
};

// ---------------------------------------------------------------- tests

test "text Postgres rejects never reaches a queue, and is answered as the reference answers it" {
    const testing = std.testing;
    const jwt = @import("jwt.zig");
    const F: Flags = .{ .shed = false };
    ring = try IoUring.init(8, 0);
    defer ring.deinit();
    var fds: [2]i32 = undefined;
    _ = try sys.check(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds));
    defer for (fds) |fd| sys.closeFd(fd);
    defer db.clearQueuesForTest();
    jwt.init("test secret");
    const t = sys.nowSec();
    var tok: [256]u8 = undefined;
    const token = jwt.issue(7, t, &tok);
    var c: Client = .{ .fd = fds[0] };
    defer c.req.scratch.deinit(std.heap.smp_allocator);

    const Case = struct { auth: bool = true, line: []const u8, body: []const u8 = "", status: []const u8, msg: []const u8 = "internal error" };
    const long_pw: [73]u8 = @splat('x');
    const answered = [_]Case{
        .{ .auth = false, .line = "GET /api/articles?tag=%FF", .status = "500" },
        .{ .line = "GET /api/articles?tag=&author=a%00b", .status = "500" },
        .{ .line = "GET /api/articles?limit=0&tag=%FF", .status = "422", .msg = "limit must be 1-100 and offset >= 0" },
        .{ .auth = false, .line = "GET /api/profiles/%ED%A0%80", .status = "500" },
        .{ .auth = false, .line = "POST /api/profiles/%00/follow", .status = "401", .msg = "unauthorized" },
        .{ .line = "POST /api/articles/%C3/favorite", .status = "500" },
        .{ .line = "DELETE /api/articles/%FF/comments/1", .status = "500" },
        .{ .line = "DELETE /api/articles/%FF/comments/x", .status = "404", .msg = "comment not found" },
        .{ .line = "PUT /api/articles/%FF", .body = "{\"article\":{\"title\":\"x\"}}", .status = "500" },
        .{ .line = "PUT /api/articles/%FF", .body = "{\"article\":{\"title\":\"\"}}", .status = "422", .msg = "title, description and body must be non-empty strings" },
        .{ .line = "POST /api/articles/%FF/comments", .body = "{\"comment\":{\"body\":\"a\\u0000\"}}", .status = "500" },
        .{ .line = "POST /api/articles/%FF/comments", .body = "{\"comment\":{}}", .status = "422", .msg = "body is required" },
        .{ .auth = false, .line = "POST /api/users/login", .body = "{\"user\":{\"email\":\"a\\u0000b\",\"password\":\"p\"}}", .status = "500" },
        .{ .line = "PUT /api/user", .body = "{\"user\":{\"bio\":\"a\\u0000b\"}}", .status = "500" },
        .{ .line = "PUT /api/user", .body = "{\"user\":{\"bio\":\"a\\u0000b\",\"password\":\"" ++ long_pw ++ "\"}}", .status = "422", .msg = "password is too long" },
        .{ .line = "POST /api/articles", .body = "{\"article\":{\"title\":\"t\",\"description\":\"d\",\"body\":\"b\",\"tagList\":[\"ok\",\"x\\u0000\"]}}", .status = "500" },
        .{ .line = "POST /api/articles", .body = "{\"article\":{\"title\":\"x\\u0000\",\"description\":\"d\",\"body\":\"b\",\"tagList\":[\"\"]}}", .status = "422", .msg = "tagList must be an array of non-empty strings" },
        .{ .line = "POST /api/articles", .body = "{\"article\":{\"title\":\"x\\u0000\",\"description\":\"d\",\"body\":\"b\"}}", .status = "500" },
    };
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(testing.allocator);
    const send = struct {
        fn f(cl: *Client, buf: *std.ArrayList(u8), k: Case, tk: []const u8, now_s: i64) !void {
            buf.clearRetainingCapacity();
            try buf.print(testing.allocator, "{s} HTTP/1.1\r\nContent-Length: {d}\r\n", .{ k.line, k.body.len });
            if (k.auth) try buf.print(testing.allocator, "Authorization: Token {s}\r\n", .{tk});
            try buf.appendSlice(testing.allocator, "\r\n");
            const p = http.parseHead(buf.items);
            try testing.expect(p == .head);
            cl.req.q = .{};
            api.start(F, &cl.req, &p.head, k.body, now_s);
        }
    }.f;
    for (answered) |k| {
        try send(&c, &raw, k, token, t);
        errdefer std.debug.print("case: {s} {s}\n", .{ k.line, k.body });
        try testing.expectEqual(0, c.req.q.seq);
        try testing.expectEqual(1, try ring.submit_and_wait(1));
        _ = try ring.copy_cqe();
        var got: [1024]u8 = undefined;
        const n = try sys.check(linux.read(fds[1], &got, got.len));
        const resp = got[0..n];
        try testing.expectEqualStrings(k.status, resp[9..12]);
        var want: [256]u8 = undefined;
        try testing.expect(std.mem.endsWith(u8, resp, try std.fmt.bufPrint(&want, "{{\"errors\":{{\"body\":[\"{s}\"]}}}}", .{k.msg})));
    }

    // A bad body string on a write the reference makes after a lookup: only the lookup runs, and its outcome picks
    // the answer.
    const sql = @import("sql.zig");
    const Lookup = struct { rows: u32, author: i64 = 0, status: []const u8 };
    const update = "{\"article\":{\"body\":\"x\\u0000\"}}";
    const comment = "{\"comment\":{\"body\":\"x\\u0000\"}}";
    const probes = [_]struct { Case, sql.Stmt, Lookup }{
        .{ .{ .line = "PUT /api/articles/a-1", .body = update, .status = "" }, .article_update, .{ .rows = 0, .status = "404" } },
        .{ .{ .line = "PUT /api/articles/a-1", .body = update, .status = "" }, .article_update, .{ .rows = 1, .author = 8, .status = "403" } },
        .{ .{ .line = "PUT /api/articles/a-1", .body = update, .status = "" }, .article_update, .{ .rows = 1, .author = 7, .status = "500" } },
        .{ .{ .line = "POST /api/articles/a-1/comments", .body = comment, .status = "" }, .article_by_slug, .{ .rows = 0, .status = "404" } },
        .{ .{ .line = "POST /api/articles/a-1/comments", .body = comment, .status = "" }, .article_by_slug, .{ .rows = 1, .status = "500" } },
    };
    for (probes) |x| {
        const k, const stmt, const o = x;
        try send(&c, &raw, k, token, t);
        try testing.expect(c.req.q.seq != 0);
        try testing.expectEqual(0, ring.sq_ready());
        try testing.expectEqual(stmt, c.req.q.stmt);
        // The update's lookup writes nothing: no new values, and author 0 is nobody.
        if (stmt == .article_update) {
            for (c.req.q.params[1..4]) |p| try testing.expect(p == .null);
            try testing.expectEqual(0, c.req.q.params[4].int);
        }
        c.req.rows = o.rows;
        c.req.author = o.author;
        api.onDone(&c.req);
        try testing.expectEqual(1, try ring.submit_and_wait(1));
        _ = try ring.copy_cqe();
        var got: [4096]u8 = undefined;
        const n = try sys.check(linux.read(fds[1], &got, got.len));
        try testing.expectEqualStrings(o.status, got[9..12]);
        try testing.expect(n > 12);
    }
}

test "the pacer lets a backlog out at its rate however late the loop comes back, and banks no more than 1 ms while idle" {
    const ms = std.time.ns_per_ms;
    var p: Pacer = .{ .per_ms = 1000 };
    // The first response after an idle spell: 1 ms of sends at once, and the second of two 600-byte ones goes past it.
    const t0: u64 = 16 * 24 * 3600 * std.time.ns_per_s;
    p.restart(t0);
    try std.testing.expect(p.open(t0));
    p.take(600);
    try std.testing.expect(p.open(t0));
    p.take(600);
    try std.testing.expect(!p.open(t0));
    try std.testing.expectEqual(t0 + 200 * ms / 1000, p.next());
    // The backlog's next turn comes 5 ms late: what the rate allowed meanwhile goes out then, up to 1 ms ahead.
    var sent: u64 = 0;
    while (p.open(t0 + 5 * ms)) : (sent += 500) p.take(500);
    try std.testing.expectEqual(5000, sent);
    // A response after a 10 ms lull with nothing waiting starts from now: 1 ms ahead at most.
    p.restart(t0 + 20 * ms);
    sent = 0;
    while (p.open(t0 + 20 * ms)) : (sent += 500) p.take(500);
    try std.testing.expectEqual(1500, sent);
}

/// A loopback TCP connection: the client's end, then the accepted end.
fn testPair() ![2]i32 {
    const stream = linux.SOCK.STREAM | linux.SOCK.CLOEXEC;
    const lfd: i32 = @intCast(try sys.check(linux.socket(linux.AF.INET, stream, 0)));
    defer sys.closeFd(lfd);
    var addr: linux.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    _ = try sys.check(linux.bind(lfd, @ptrCast(&addr), len));
    _ = try sys.check(linux.listen(lfd, 1));
    _ = try sys.check(linux.getsockname(lfd, @ptrCast(&addr), &len));
    const cfd: i32 = @intCast(try sys.check(linux.socket(linux.AF.INET, stream, 0)));
    errdefer sys.closeFd(cfd);
    _ = try sys.check(linux.connect(cfd, @ptrCast(&addr), len));
    return .{ cfd, @intCast(try sys.check(linux.accept(lfd, null, null))) };
}

/// TCP_QUICKACK as getsockopt reads it: 0 while the socket is in pingpong (delayed-ACK) mode.
fn quickAckForTest(fd: i32) !c_int {
    var v: c_int = -1;
    var n: linux.socklen_t = @sizeOf(c_int);
    _ = try sys.check(linux.getsockopt(fd, linux.IPPROTO.TCP, linux.TCP.QUICKACK, std.mem.asBytes(&v), &n));
    return v;
}

test "a served socket leaves quick-ACK mode through the ring, with no completion" {
    const testing = std.testing;
    ring = try IoUring.init(8, 0);
    defer ring.deinit();
    const cfd, const sfd = try testPair();
    defer sys.closeFd(cfd);
    defer sys.closeFd(sfd);
    const quickAck = quickAckForTest;
    try testing.expectEqual(1, try quickAck(sfd));
    delayAck(sfd, no_slot);
    try testing.expectEqual(1, try ring.submit());
    try testing.expectEqual(0, try quickAck(sfd));
    try testing.expectEqual(0, ring.cq_ready());
    try testing.expect(ack_delay);
}

test "a follower gets its lead's response even after the lead's client has sent its next one" {
    const testing = std.testing;
    const F: Flags = .{ .ackdelay = false };
    ring = try IoUring.init(8, 0);
    defer ring.deinit();
    var pairs: [2][2]i32 = undefined;
    for (&pairs) |*p| _ = try sys.check(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, p));
    defer for (pairs) |p| for (p) |fd| sys.closeFd(fd);
    var leader: Client = .{ .fd = pairs[0][0] };
    var follower: Client = .{ .fd = pairs[1][0], .busy = true };

    const first = "HTTP/1.1 200 OK\r\nContent-Type:application/json\r\nContent-Length:14\r\n\r\n{\"tags\":[\"a\"]}";
    const second = "HTTP/1.1 200 OK\r\nContent-Type:application/json\r\nContent-Length:14\r\n\r\n{\"tags\":[\"b\"]}";
    for ([_][]const u8{ "{\"tags\":[\"a\"]}", "{\"tags\":[\"b\"]}" }, 0..) |body, i| {
        leader.busy = true;
        leader.req.out = Buf.init();
        leader.req.out.append(body);
        respond(&leader.req, leader.req.out.finish(.ok, true, false, 1448));
        if (i == 0) share(&leader.req, 1);
        try testing.expectEqual(1, try ring.submit_and_wait(1));
        const cqe = try ring.copy_cqe();
        complete(F, &cqe);
        try testing.expect(!leader.busy);
    }
    respondShared(&follower.req);
    try testing.expectEqual(1, try ring.submit_and_wait(1));
    const cqe = try ring.copy_cqe();
    complete(F, &cqe);
    try testing.expectEqual(null, lead);

    var got: [512]u8 = undefined;
    var n = try sys.check(linux.read(pairs[0][1], &got, got.len));
    try testing.expectEqualStrings(first ++ second, got[0..n]);
    n = try sys.check(linux.read(pairs[1][1], &got, got.len));
    try testing.expectEqualStrings(first, got[0..n]);
}

test "ZIG_ACK_SKIP_MS: a quick reply already puts the socket in pingpong mode, a reply after the delayed ACK does not" {
    const testing = std.testing;
    const cfd, const sfd = try testPair();
    defer sys.closeFd(cfd);
    defer sys.closeFd(sfd);
    var b: [16]u8 = undefined;
    // Answered at once, as a response under ZIG_ACK_SKIP_MS is: the reply alone enters pingpong mode.
    _ = try sys.check(linux.write(cfd, "ask", 3));
    _ = try sys.check(linux.read(sfd, &b, b.len));
    _ = try sys.check(linux.write(sfd, "answer", 6));
    try testing.expectEqual(0, try quickAckForTest(sfd));
    // Answered after the delayed-ACK timer (40 ms here) fired: it left pingpong mode, and the late reply does not
    // bring it back, so this response still needs the uring_cmd.
    _ = try sys.check(linux.write(cfd, "ask", 3));
    _ = try sys.check(linux.read(sfd, &b, b.len));
    const ts: linux.timespec = .{ .sec = 0, .nsec = 70 * std.time.ns_per_ms };
    _ = linux.nanosleep(&ts, null);
    try testing.expectEqual(1, try quickAckForTest(sfd));
    _ = try sys.check(linux.write(sfd, "answer", 6));
    try testing.expectEqual(1, try quickAckForTest(sfd));
}

test "ZIG_BUF_RUNS: buffers given back in runs are handed out again in the same order as one at a time" {
    const testing = std.testing;
    const saved = .{ bufs, buf_runs, stats_on };
    defer bufs, buf_runs, stats_on = saved;
    stats_on = false;
    bufs = try std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(4096), buf_size * 8);
    defer std.heap.page_allocator.free(bufs);
    var orders: [2][8]u16 = undefined;
    for ([_]bool{ false, true }, 0..) |runs, k| {
        buf_runs = runs;
        ring = try IoUring.init(16, 0);
        defer ring.deinit();
        var fds: [2]i32 = undefined;
        _ = try sys.check(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds));
        defer for (fds) |fd| sys.closeFd(fd);
        var s = sqe();
        s.prep_provide_buffers(bufs.ptr, buf_size, 8, buf_group, 0);
        s.user_data = 0;
        s = sqe();
        s.prep_rw(.RECV, fds[0], 0, 0, 0);
        s.flags |= linux.IOSQE_BUFFER_SELECT;
        s.buf_index = buf_group;
        s.ioprio |= linux.IORING_RECV_MULTISHOT;
        s.user_data = 1;
        _ = try ring.submit_and_wait(1);
        _ = try ring.copy_cqe();
        // Take five, give them back, then take all eight.
        for (0..13) |i| {
            _ = try sys.check(linux.write(fds[1], "x", 1));
            _ = try ring.submit_and_wait(1);
            const c = try ring.copy_cqe();
            try testing.expect(c.res == 1 and c.flags & linux.IORING_CQE_F_MORE != 0);
            const bid = try c.buffer_id();
            if (i < 5) try returned.append(gpa, bid) else orders[k][i - 5] = bid;
            if (i == 4) {
                returnBuffers();
                try testing.expectEqual(@as(u32, if (runs) 1 else 5), ring.sq_ready());
            }
        }
    }
    try testing.expectEqualSlices(u16, &.{ 5, 6, 7, 0, 1, 2, 3, 4 }, &orders[0]);
    try testing.expectEqualSlices(u16, &orders[0], &orders[1]);
}

test "ZIG_FIXED_FILES: a client's slot is filled before its first send and emptied before its socket closes" {
    const testing = std.testing;
    ring = try IoUring.init(16, 0);
    defer ring.deinit();
    try ring.register_files_sparse(4);
    var fds: [2]i32 = undefined;
    _ = try sys.check(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds));
    defer sys.closeFd(fds[1]);
    var c: Client = .{ .fd = fds[0], .slot = 2 };
    // One submission: the update, then a send naming only the slot.
    updateSlot(c.slot, &c.fd);
    sendBytes(&c, "hello");
    try testing.expectEqual(2, try ring.submit_and_wait(1));
    const done = try ring.copy_cqe();
    try testing.expectEqual(userData(&c, .send), done.user_data);
    try testing.expectEqual(5, done.res);
    var b: [8]u8 = undefined;
    try testing.expectEqual(5, try sys.check(linux.read(fds[1], &b, b.len)));
    // Emptied and closed: the peer sees the end of the stream, so the slot no longer holds the socket open.
    updateSlot(c.slot, &no_fd);
    sys.closeFd(c.fd);
    _ = try ring.submit();
    try testing.expectEqual(0, ring.cq_ready());
    try testing.expectEqual(0, try sys.check(linux.recvfrom(fds[1], &b, b.len, linux.MSG.DONTWAIT, null, null)));
}

test "ZIG_PG_POLL_FIRST: a receive that waits for data first still gets it, and SOCK_NONEMPTY means more is queued" {
    const testing = std.testing;
    ring = try IoUring.init(16, 0);
    defer ring.deinit();
    const cfd, const sfd = try testPair();
    defer sys.closeFd(cfd);
    defer sys.closeFd(sfd);
    const saved = pg_poll_first;
    defer pg_poll_first = saved;
    pg_poll_first = 1;
    const rbuf = try std.heap.page_allocator.alloc(u8, 128 * 1024);
    var c: db.Conn = .{ .fd = sfd, .index = 0, .write = false, .rbuf = rbuf };
    defer std.heap.page_allocator.free(c.rbuf);
    armPgRecv(&c, true);
    try testing.expectEqual(1, try ring.submit());
    try testing.expectEqual(0, ring.cq_ready());
    _ = try sys.check(linux.write(cfd, "0123456789", 10));
    _ = try ring.submit_and_wait(1);
    var got = try ring.copy_cqe();
    try testing.expectEqual(10, got.res);
    try testing.expectEqualStrings("0123456789", c.rbuf[0..10]);
    // A receive that leaves bytes behind says so; the one that takes the rest does not.
    _ = try sys.check(linux.write(cfd, "0123456789", 10));
    var small: [4]u8 = undefined;
    for ([_]i32{ 4, 6 }, [_]bool{ true, false }) |want, more| {
        const s = sqe();
        s.prep_recv(sfd, if (more) &small else c.rbuf, 0);
        _ = try ring.submit_and_wait(1);
        got = try ring.copy_cqe();
        try testing.expectEqual(want, got.res);
        try testing.expectEqual(more, got.flags & linux.IORING_CQE_F_SOCK_NONEMPTY != 0);
    }
}

test "ZIG_CQ_BUDGET: the wait after a budget stop returns at once while completions are left" {
    const testing = std.testing;
    var params = std.mem.zeroInit(linux.io_uring_params, .{
        .flags = linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_DEFER_TASKRUN | linux.IORING_SETUP_COOP_TASKRUN,
    });
    ring = try IoUring.init_params(16, &params);
    defer ring.deinit();
    for (0..3) |_| sqe().prep_nop();
    _ = try ring.submit_and_wait(3);
    var cqes: [1]linux.io_uring_cqe = undefined;
    try testing.expectEqual(1, try ring.copy_cqes(&cqes, 0));
    const t = sys.monoNs();
    wait(t + std.time.ns_per_s);
    try testing.expect(sys.monoNs() - t < 100 * std.time.ns_per_ms);
    try testing.expectEqual(2, ring.cq_ready());
}
