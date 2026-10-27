//! One worker's event loop: a single io_uring drives the clients, this worker's Postgres connections and the bcrypt
//! completion eventfd, and it hands bcrypt batches to the hasher threads (bcrypt.pump). The drain process runs the
//! same loop without clients or bcrypt (drain.zig).
//!
//! Clients: multishot accept, then multishot recv into provided buffers (the classic PROVIDE_BUFFERS kind; buffer
//! rings return EINVAL on the target's 6.8 kernel). A request is parsed straight out of the provided buffer when it
//! arrived whole; only leftovers are copied into the client's own buffer. One request per client is handled at a
//! time, so pipelined requests are answered in order. A response leaves in one send from the buffer it was built in.
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
    req: api.Req = .{},
    next_free: ?*Client = null,
};

var ring: IoUring = undefined;
var listen_fd: i32 = -1;
var bufs: []align(4096) u8 = &.{};
var returned: std.ArrayList(u16) = .empty;
var rearm: std.ArrayList(*Client) = .empty;
var free_clients: ?*Client = null;
var efd_buf: u64 = 0;
var wake_buf: u64 = 0;
var now: i64 = 0;
/// Cleared for the rest of the process when the kernel refuses the socket uring_cmd.
var ack_delay = true;
const quickack_off: c_int = 0;
/// The setsockopt's completion, which only a failure posts: tag 0 like the buffer returns, told apart by a pointer
/// part of its own.
const ack_delay_data: u64 = 8;

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

    if (listener) |fd| {
        listen_fd = fd;
        bufs = std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(4096), buf_size * buf_count) catch sys.fatal("oom", .{});
        const s = sqe();
        s.prep_provide_buffers(bufs.ptr, buf_size, buf_count, buf_group, 0);
        s.user_data = 0;
        armAccept();
        armBcrypt();
    }
    for (db.conns) |*c| armPgRecv(c);
    armWake();

    var cqes: [512]linux.io_uring_cqe = undefined;
    // The drain process's first wait comes after its first idle check too, or no worker would wake it.
    var due: ?u64 = drain_process.send(null);
    while (true) {
        wait(due);
        now = sys.nowSec();
        db.now_ns = sys.monoNs();
        if (F.shed and listener != null) shed.ctl.tick(db.now_ns);
        while (true) {
            const n = ring.copy_cqes(&cqes, 0) catch |e| sys.fatal("io_uring cqes: {s}", .{@errorName(e)});
            if (n == 0) break;
            for (cqes[0..n]) |*c| complete(F, c);
        }
        drain_process.receive();
        due = db.pump();
        if (listener != null) if (bcrypt.pump(db.now_ns)) |t| {
            due = if (due) |d| @min(d, t) else t;
        };
        if (F.shed and listener != null) if (shed.ctl.due()) |t| {
            due = if (due) |d| @min(d, t) else t;
        };
        for (db.conns) |*c| flushPg(c);
        due = drain_process.send(due);
        for (returned.items) |bid| {
            const s = sqe();
            s.prep_provide_buffers(bufs[@as(usize, bid) * buf_size ..].ptr, buf_size, 1, buf_group, bid);
            s.flags |= linux.IOSQE_CQE_SKIP_SUCCESS;
            s.user_data = 0;
        }
        returned.clearRetainingCapacity();
        for (rearm.items) |c| armRecv(c);
        rearm.clearRetainingCapacity();
    }
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
        .wake => armWake(),
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
    armRecv(c);
}

fn armRecv(c: *Client) void {
    const s = sqe();
    s.prep_rw(.RECV, c.fd, 0, 0, 0);
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

fn delayAck(fd: i32) void {
    const s = sqe();
    s.prep_cmd_sock(.SETSOCKOPT, fd, linux.IPPROTO.TCP, linux.TCP.QUICKACK, @intFromPtr(&quickack_off), @sizeOf(c_int));
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
    sendBytes(c, bytes);
}

fn sendBytes(c: *Client, bytes: []const u8) void {
    c.sending = bytes;
    const s = sqe();
    s.prep_send(c.fd, bytes, linux.MSG.NOSIGNAL);
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
    c.busy = false;
    if (!c.req.keep_alive) c.closing = true;
    if (!c.closing) {
        if (F.ackdelay and ack_delay) delayAck(c.fd);
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
    sys.closeFd(c.fd);
    c.req.out.release();
    if (c.pending.capacity > 64 * 1024) c.pending.clearAndFree(gpa) else c.pending.clearRetainingCapacity();
    c.next_free = free_clients;
    free_clients = c;
}

// ---------------------------------------------------------------- postgres

fn armPgRecv(c: *db.Conn) void {
    const space = db.recvSpace(c);
    const s = sqe();
    s.prep_recv(c.fd, space, 0);
    s.user_data = userData(c, .pg_recv);
}

fn onPgRecv(c: *db.Conn, cqe: *const linux.io_uring_cqe) void {
    if (cqe.res <= 0) sys.fatal("postgres connection {d} lost ({d})", .{ c.index, cqe.res });
    c.rend += @intCast(cqe.res);
    db.onRecv(c);
    armPgRecv(c);
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

test "a served socket leaves quick-ACK mode through the ring, with no completion" {
    const testing = std.testing;
    ring = try IoUring.init(8, 0);
    defer ring.deinit();
    const stream = linux.SOCK.STREAM | linux.SOCK.CLOEXEC;
    const lfd: i32 = @intCast(try sys.check(linux.socket(linux.AF.INET, stream, 0)));
    defer sys.closeFd(lfd);
    var addr: linux.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    _ = try sys.check(linux.bind(lfd, @ptrCast(&addr), len));
    _ = try sys.check(linux.listen(lfd, 1));
    _ = try sys.check(linux.getsockname(lfd, @ptrCast(&addr), &len));
    const cfd: i32 = @intCast(try sys.check(linux.socket(linux.AF.INET, stream, 0)));
    defer sys.closeFd(cfd);
    _ = try sys.check(linux.connect(cfd, @ptrCast(&addr), len));
    const sfd: i32 = @intCast(try sys.check(linux.accept(lfd, null, null)));
    defer sys.closeFd(sfd);

    const quickAck = struct {
        fn get(fd: i32) !c_int {
            var v: c_int = -1;
            var n: linux.socklen_t = @sizeOf(c_int);
            _ = try sys.check(linux.getsockopt(fd, linux.IPPROTO.TCP, linux.TCP.QUICKACK, std.mem.asBytes(&v), &n));
            return v;
        }
    }.get;
    try testing.expectEqual(1, try quickAck(sfd));
    delayAck(sfd);
    try testing.expectEqual(1, try ring.submit());
    try testing.expectEqual(0, try quickAck(sfd));
    try testing.expectEqual(0, ring.cq_ready());
    try testing.expect(ack_delay);
}
