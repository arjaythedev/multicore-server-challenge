//! One read drain for all worker processes. With two or more workers the parent forks one more process, the drain
//! process. It owns every read connection, the read queues and the batch clock, and runs db.zig's read path for all
//! workers, so each drain holds the reads of the whole box. Workers keep their write connection and write queue.
//!
//! A worker sends each read as an ask record on its ask ring (shared.zig). The drain process queues a stand-in for
//! it (`Proxy`, with its own copy of the parameters) and writes what db.zig hands over as answer records on that
//! worker's answer ring, as each unit completes: rows in the DataRow body layout, then done or fail, and reset when
//! a retry voids the rows so far. The worker hands them to the API as db.zig would have.
//!
//! Wakeups go through eventfds made before forking, read by each process's io_uring. The drain process writes a
//! worker's answer eventfd once per loop iteration in which it wrote that worker answers. Workers write the drain's
//! eventfd only while it sleeps with nothing queued: it raises the idle flag, looks at every ask ring once more, and
//! only then waits; a worker publishes its asks, then lowers the flag and writes the eventfd if it was raised. Both
//! sides use sequentially consistent atomics, so either the drain sees the ask or the worker sees the flag. While
//! reads are queued the drain process wakes on its clock anyway, so asks cost busy workers no system call.
//!
//! A full ring loses nothing: a worker keeps the reads it cannot ask yet in a FIFO, the drain process keeps a
//! worker's answers in a spill buffer, and each tries again every `retry_ns` until the ring has room.
//!
//! Shared responses (the `share` flag): each ask carries the read's share class (api.shareClass), the inputs of its
//! response head, and the drain process adds the worker. Within one execution, reads with the same class, statement
//! and parameters after the viewer, and no viewer flag in their rows, would get byte-identical responses (`Plan`).
//! The first of each such set leads: it gets its rows, then `lead` with the number of reads that follow it. They
//! follow at once on the same ring as `same` answers, without rows, and the worker sends each of them the bytes it
//! rendered for the lead (loop.zig). Nothing outlives the execution that produced it.
const std = @import("std");
const linux = std.os.linux;
const shared = @import("shared.zig");
const db = @import("db.zig");
const api = @import("api.zig");
const pg = @import("pg.zig");
const sys = @import("sys.zig");
const Query = db.Query;
const Param = db.Param;

const gpa = std.heap.smp_allocator;

pub const Role = enum {
    /// The only worker: it has its own read connections and there is no drain process.
    alone,
    /// One of several workers: its reads go to the drain process.
    worker,
    /// The drain process.
    drain,
};

pub var role: Role = .alone;

/// Ring data bytes per worker. An ask is about 50 bytes, but a login's email may be as long as a request body (1 MB);
/// an answer row is as long as its article (a body of up to 1 MB). At the knee a 12.5 ms drain holds about 800
/// reads, 200 per worker: about 10 KB of a worker's ask ring, and about 1 MB of its answer ring (lists at ~5 KB),
/// several times over when the drains of several read connections complete together.
pub const ask_bytes = 4 << 20;
pub const answer_bytes = 16 << 20;
/// How often a process holding records that found a ring full tries again.
const retry_ns = 1 * std.time.ns_per_ms;

var region: shared.Region = undefined;
var drain_efd: i32 = -1;
var answer_efds: []i32 = &.{};

/// Maps the rings and makes the eventfds; called before forking.
pub fn setup(workers: usize) void {
    region = shared.Region.map(workers, ask_bytes, answer_bytes) catch sys.fatal("shared memory: mmap failed", .{});
    drain_efd = eventfd();
    answer_efds = std.heap.page_allocator.alloc(i32, workers) catch sys.fatal("oom", .{});
    for (answer_efds) |*e| e.* = eventfd();
}

fn eventfd() i32 {
    const fd = sys.check(linux.eventfd(0, linux.EFD.CLOEXEC)) catch sys.fatal("eventfd failed", .{});
    return @intCast(fd);
}

fn signal(fd: i32) void {
    const one: u64 = 1;
    _ = linux.write(fd, std.mem.asBytes(&one), 8);
    wakes.sent += 1;
}

/// Counters for ZIG_LANE_STATS: eventfd writes to wake the other side, wake completions taken, and loop iterations.
pub var wakes: struct { sent: u32 = 0, taken: u32 = 0, iterations: u32 = 0 } = .{};

pub fn logWakes(span_ms: u64) void {
    if (role == .alone) return;
    sys.log("wakes {d} ms: {s} sent {d}, took {d}, {d} loop iterations", .{ span_ms, @tagName(role), wakes.sent, wakes.taken, wakes.iterations });
    wakes = .{};
}

/// The eventfd this process's loop reads besides its sockets, if any.
pub fn wakeFd() ?i32 {
    return switch (role) {
        .alone => null,
        .worker => answer_efds[me],
        .drain => drain_efd,
    };
}

/// Takes what the other side published: a worker its answers, the drain process its asks. Called once per loop
/// iteration, after the completions.
pub fn receive() void {
    wakes.iterations += 1;
    switch (role) {
        .alone => {},
        .worker => takeAnswers(),
        .drain => {
            region.idle().store(0, .seq_cst);
            for (peers, 0..) |*p, w| {
                while (p.asks.next()) |rec| takeAsk(w, rec);
                p.asks.release();
            }
        },
    }
}

/// Publishes this iteration's records and wakes the other side when it must; returns when the loop's wait must end
/// (`due`, or sooner while records wait for ring space). In the drain process with nothing queued, this is the idle
/// check, and an ask that came in meanwhile ends the wait at once.
pub fn send(due: ?u64) ?u64 {
    switch (role) {
        .alone => return due,
        .worker => {
            flushAsks();
            return if (waiting.head != null) soonest(due, db.now_ns + retry_ns) else due;
        },
        .drain => {
            var spilled = false;
            for (peers, 0..) |*p, w| spilled = flushAnswers(p, w) or spilled;
            const next = if (spilled) soonest(due, db.now_ns + retry_ns) else due;
            if (db.readsQueued()) return next;
            region.idle().store(1, .seq_cst);
            for (peers) |*p| if (p.asks.pending()) {
                region.idle().store(0, .seq_cst);
                return db.now_ns;
            };
            return next;
        },
    }
}

fn soonest(a: ?u64, b: u64) u64 {
    return if (a) |t| @min(t, b) else b;
}

// ---------------------------------------------------------------- records

/// An ask: the worker's query as an opaque tag, the time it was queued, its statement, its share class, then each
/// parameter as its kind and value.
fn askSize(q: *const Query) usize {
    var n: usize = 8 + 8 + 1 + 4;
    for (q.params[0..q.stmt.def().params.len]) |p| n += 1 + switch (p) {
        .null => 0,
        .int => 8,
        .text, .raw => |t| 4 + t.len,
    };
    return n;
}

fn encodeAsk(b: []u8, q: *const Query, share: u32) void {
    var w: Writer = .{ .b = b };
    w.int(u64, @intFromPtr(q));
    w.int(u64, q.queued_ns);
    w.int(u8, @intFromEnum(q.stmt));
    w.int(u32, share);
    for (q.params[0..q.stmt.def().params.len]) |p| {
        w.int(u8, @intFromEnum(std.meta.activeTag(p)));
        switch (p) {
            .null => {},
            .int => |v| w.int(i64, v),
            .text, .raw => |t| {
                w.int(u32, @intCast(t.len));
                w.bytes(t);
            },
        }
    }
}

/// Fills `x` from an ask, its text parameters copied into `x.bytes`; returns when the worker queued it. A share
/// class gets the worker in bits 3-15, below the segment size.
fn decodeAsk(x: *Proxy, rec: []const u8) u64 {
    var r: Reader = .{ .b = rec };
    x.tag = r.int(u64);
    const at = r.int(u64);
    x.q = .{ .stmt = @enumFromInt(r.int(u8)) };
    const share = r.int(u32);
    if (share != 0) x.q.share = share | @as(u32, @intCast(x.worker)) << 3;
    // Room for every byte first, so the slices into it stay valid.
    x.bytes.clearRetainingCapacity();
    x.bytes.ensureTotalCapacity(gpa, rec.len) catch sys.fatal("oom", .{});
    for (x.q.params[0..x.q.stmt.def().params.len]) |*p| {
        p.* = switch (@as(std.meta.Tag(Param), @enumFromInt(r.int(u8)))) {
            .null => .null,
            .int => .{ .int = r.int(i64) },
            .text => .{ .text = x.keep(r.bytes(r.int(u32))) },
            .raw => .{ .raw = x.keep(r.bytes(r.int(u32))) },
        };
    }
    return at;
}

const Answer = enum(u8) { row, done, fail, reset, lead, same };
/// An answer: the ask's tag, its kind, then a row's DataRow body, a failure's error or a lead's follower count.
const answer_head = 8 + 1;

fn rowSize(x: *const pg.Row) usize {
    var n: usize = 2;
    for (x.len[0..x.n]) |l| n += 4 + @as(usize, @intCast(@max(l, 0)));
    return n;
}

/// The DataRow body layout, so the worker reads it with `pg.Row.parse`.
fn writeRow(b: []u8, x: *const pg.Row) void {
    std.mem.writeInt(u16, b[0..2], x.n, .big);
    var at: usize = 2;
    for (0..x.n) |i| {
        std.mem.writeInt(i32, b[at..][0..4], x.len[i], .big);
        const v = x.raw(i);
        @memcpy(b[at + 4 ..][0..v.len], v);
        at += 4 + v.len;
    }
}

fn failSize(e: *const pg.ErrorInfo) usize {
    return e.code.len + 1 + e.msg_len;
}

fn writeFail(b: []u8, e: *const pg.ErrorInfo) void {
    b[0..5].* = e.code;
    b[5] = e.msg_len;
    @memcpy(b[6..][0..e.msg_len], e.message());
}

fn readFail(b: []const u8) pg.ErrorInfo {
    var e: pg.ErrorInfo = .{ .code = b[0..5].*, .msg_len = b[5] };
    @memcpy(e.msg[0..e.msg_len], b[6..][0..e.msg_len]);
    return e;
}

const Writer = struct {
    b: []u8,
    at: usize = 0,

    fn int(w: *Writer, comptime T: type, v: T) void {
        std.mem.writeInt(T, w.b[w.at..][0..@sizeOf(T)], v, .little);
        w.at += @sizeOf(T);
    }

    fn bytes(w: *Writer, s: []const u8) void {
        @memcpy(w.b[w.at..][0..s.len], s);
        w.at += s.len;
    }
};

const Reader = struct {
    b: []const u8,
    at: usize = 0,

    fn int(r: *Reader, comptime T: type) T {
        defer r.at += @sizeOf(T);
        return std.mem.readInt(T, r.b[r.at..][0..@sizeOf(T)], .little);
    }

    fn bytes(r: *Reader, n: usize) []const u8 {
        defer r.at += n;
        return r.b[r.at..][0..n];
    }
};

// ---------------------------------------------------------------- the worker's side

var me: usize = 0;
var asks: shared.Producer = undefined;
var answers: shared.Consumer = undefined;
/// Reads not yet written to the ask ring, oldest first: this iteration's, and those that found the ring full.
var waiting: db.Queue = .{};
var warned_asks = false;

/// Makes this forked process worker `w`.
pub fn becomeWorker(w: usize) void {
    role = .worker;
    me = w;
    asks = region.askProducer(w);
    answers = region.answerConsumer(w);
}

/// Sends a read to the drain process (db.enqueue in a worker); it goes on the ask ring at the end of the iteration.
/// Its request stays alive until its done or fail answer: the client's request is busy until then, as with a read on
/// a local connection.
pub fn ask(q: *Query) void {
    waiting.push(q);
}

fn flushAsks() void {
    var asked = false;
    while (waiting.head) |q| {
        const b = asks.reserve(askSize(q)) orelse {
            if (!warned_asks) {
                warned_asks = true;
                sys.log("ask ring full: reads wait in the worker until it has room", .{});
            }
            break;
        };
        encodeAsk(b, q, api.shareClass(api.request(q)));
        _ = waiting.pop();
        asked = true;
    }
    if (!asked) return;
    asks.publish();
    if (region.idle().swap(0, .seq_cst) == 1) signal(drain_efd);
}

fn takeAnswers() void {
    while (answers.next()) |rec| {
        var rd: Reader = .{ .b = rec };
        const r = api.request(@ptrFromInt(rd.int(u64)));
        const body = rec[answer_head..];
        switch (@as(Answer, @enumFromInt(rd.int(u8)))) {
            .row => {
                var x: pg.Row = .{};
                x.parse(body) catch sys.fatal("bad answer row", .{});
                api.onRow(r, &x);
            },
            .done => api.onDone(r),
            .fail => {
                const e = readFail(body);
                api.onFail(r, &e);
            },
            .reset => api.onReset(r),
            .lead => api.onLead(r, std.mem.readInt(u32, body[0..4], .little)),
            .same => api.onSame(r),
        }
    }
    answers.release();
}

// ---------------------------------------------------------------- the drain process's side

/// The drain process's stand-in for a worker's read while it is queued or executing.
const Proxy = struct {
    q: Query = .{},
    /// The worker's query, echoed in every answer.
    tag: u64 = 0,
    worker: u32 = 0,
    /// The parameters' bytes, owned until the answer is complete.
    bytes: std.ArrayList(u8) = .empty,
    next_free: ?*Proxy = null,

    fn keep(x: *Proxy, s: []const u8) []const u8 {
        const at = x.bytes.items.len;
        x.bytes.appendSliceAssumeCapacity(s);
        return x.bytes.items[at..];
    }

    fn of(q: *Query) *Proxy {
        return @fieldParentPtr("q", q);
    }
};

/// The drain process's end of one worker's rings.
const Peer = struct {
    asks: shared.Consumer,
    answers: shared.Producer,
    /// Answers that found the ring full, oldest first, each as its length (u32) and payload.
    spill: std.ArrayList(u8) = .empty,
    /// Bytes of `spill` already moved to the ring.
    spill_done: usize = 0,
    /// Answers were written since the worker was last woken.
    wrote: bool = false,
};

var peers: []Peer = &.{};
var free_proxies: ?*Proxy = null;
var warned_answers = false;

/// Makes this forked process the drain process.
pub fn becomeDrain() void {
    role = .drain;
    peers = gpa.alloc(Peer, region.workers) catch sys.fatal("oom", .{});
    for (peers, 0..) |*p, w| p.* = .{ .asks = region.askConsumer(w), .answers = region.answerProducer(w) };
}

fn takeAsk(w: usize, rec: []const u8) void {
    const x = free_proxies orelse blk: {
        const n = gpa.create(Proxy) catch sys.fatal("oom", .{});
        n.* = .{};
        break :blk n;
    };
    free_proxies = x.next_free;
    x.worker = @intCast(w);
    const at = decodeAsk(x, rec);
    db.enqueueAt(&x.q, at);
}

fn release(x: *Proxy) void {
    if (x.bytes.capacity > 64 * 1024) x.bytes.clearAndFree(gpa);
    x.next_free = free_proxies;
    free_proxies = x;
}

/// Room for an answer to `x` with `len` bytes after its head: on the worker's ring, or in its spill buffer while
/// the ring is full or older answers wait there.
fn answer(x: *Proxy, kind: Answer, len: usize) []u8 {
    const p = &peers[x.worker];
    p.wrote = true;
    const n = answer_head + len;
    const on_ring = if (p.spill_done == p.spill.items.len) p.answers.reserve(n) else null;
    const b = on_ring orelse spill(p, n);
    std.mem.writeInt(u64, b[0..8], x.tag, .little);
    b[8] = @intFromEnum(kind);
    return b[answer_head..];
}

fn spill(p: *Peer, n: usize) []u8 {
    if (!warned_answers) {
        warned_answers = true;
        sys.log("answer ring full: answers wait in the drain process until it has room", .{});
    }
    const s = p.spill.addManyAsSlice(gpa, 4 + n) catch sys.fatal("oom", .{});
    std.mem.writeInt(u32, s[0..4], @intCast(n), .little);
    return s[4..];
}

/// Moves spilled answers to the ring while it has room, publishes, and wakes the worker if it has new answers.
/// Returns whether answers still wait in the spill buffer.
fn flushAnswers(p: *Peer, w: usize) bool {
    while (p.spill_done < p.spill.items.len) {
        const n = std.mem.readInt(u32, p.spill.items[p.spill_done..][0..4], .little);
        const b = p.answers.reserve(n) orelse break;
        @memcpy(b, p.spill.items[p.spill_done + 4 ..][0..n]);
        p.spill_done += 4 + n;
        p.wrote = true;
    }
    if (p.spill_done == p.spill.items.len) {
        p.spill.clearRetainingCapacity();
        p.spill_done = 0;
    }
    if (p.wrote) {
        p.wrote = false;
        p.answers.publish();
        signal(answer_efds[w]);
    }
    return p.spill.items.len > 0;
}

// db.zig's results, in the drain process.

pub fn row(q: *Query, x: *const pg.Row) void {
    writeRow(answer(Proxy.of(q), .row, rowSize(x)), x);
}

pub fn done(q: *Query) void {
    const x = Proxy.of(q);
    _ = answer(x, .done, 0);
    release(x);
}

pub fn fail(q: *Query, e: *const pg.ErrorInfo) void {
    const x = Proxy.of(q);
    writeFail(answer(x, .fail, failSize(e)), e);
    release(x);
}

pub fn reset(q: *Query) void {
    _ = answer(Proxy.of(q), .reset, 0);
}

/// `q` is done, and the next `n` answers on its worker's ring are `same`: they get its response.
pub fn lead(q: *Query, n: u32) void {
    const x = Proxy.of(q);
    std.mem.writeInt(u32, answer(x, .lead, 4)[0..4], n, .little);
    release(x);
}

pub fn same(q: *Query) void {
    const x = Proxy.of(q);
    _ = answer(x, .same, 0);
    release(x);
}

// ---------------------------------------------------------------- shared responses

/// Which reads of one execution share a response: those with the same share class, statement and parameters after
/// the viewer ($1), and no viewer flag set in their rows. The first read of each set leads; the others follow it.
pub const Plan = struct {
    /// The execution's reads; empty while there is no plan.
    reads: []const *Query = &.{},
    links: std.ArrayList(Link) = .empty,
    /// Each set's lead, with the set's last read so far.
    sets: std.HashMapUnmanaged(u32, u32, Key, std.hash_map.default_max_load_percentage) = .empty,

    const none = std.math.maxInt(u32);

    const Link = struct {
        /// The next read of its set.
        next: u32 = none,
        /// A lead's followers.
        followers: u32 = 0,
        follows: bool = false,
    };

    /// Reads by index: equal when their responses are equal, flags aside.
    const Key = struct {
        reads: []const *Query,

        fn params(q: *const Query) []const Param {
            const n = q.stmt.def().params.len;
            return if (n == 0) &.{} else q.params[1..n];
        }

        pub fn hash(k: Key, i: u32) u64 {
            const q = k.reads[i];
            var h = std.hash.Wyhash.init(q.share);
            h.update(&.{@intFromEnum(q.stmt)});
            for (params(q)) |p| switch (p) {
                .null => h.update(&.{0}),
                .int => |v| h.update(std.mem.asBytes(&v)),
                .text, .raw => |t| {
                    h.update(std.mem.asBytes(&t.len));
                    h.update(t);
                },
            };
            return h.final();
        }

        pub fn eql(k: Key, i: u32, j: u32) bool {
            const a = k.reads[i];
            const b = k.reads[j];
            if (a.share != b.share or a.stmt != b.stmt) return false;
            for (params(a), params(b)) |x, y| {
                if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
                const same_value = switch (x) {
                    .null => true,
                    .int => |v| v == y.int,
                    .text => |t| std.mem.eql(u8, t, y.text),
                    .raw => |t| std.mem.eql(u8, t, y.raw),
                };
                if (!same_value) return false;
            }
            return true;
        }
    };

    /// Starts the plan for an execution answering `reads`, each on its own.
    pub fn begin(p: *Plan, reads: []const *Query) void {
        p.reads = reads;
        p.sets.clearRetainingCapacity();
        p.links.clearRetainingCapacity();
        p.links.appendNTimes(gpa, .{}, reads.len) catch sys.fatal("oom", .{});
    }

    /// The plan for an execution whose rows carry no viewer flag: every read with a share class may share.
    pub fn all(p: *Plan, reads: []const *Query) void {
        p.begin(reads);
        for (reads, 0..) |r, k| if (r.share != 0) p.add(@intCast(k));
    }

    /// Read `k`, which has a share class and no flag set in its rows, joins its set. Reads come in order.
    pub fn add(p: *Plan, k: u32) void {
        const g = p.sets.getOrPutContext(gpa, k, .{ .reads = p.reads }) catch sys.fatal("oom", .{});
        if (!g.found_existing) {
            g.value_ptr.* = k;
            return;
        }
        p.links.items[g.value_ptr.*].next = k;
        p.links.items[g.key_ptr.*].followers += 1;
        p.links.items[k].follows = true;
        g.value_ptr.* = k;
    }

    pub fn follows(p: *const Plan, k: usize) bool {
        return p.links.items[k].follows;
    }

    /// Answers read `k`, which does not follow, and the reads that follow it.
    pub fn done(p: *const Plan, k: usize, sink: anytype) void {
        const l = p.links.items[k];
        if (l.followers == 0) return sink.done(p.reads[k]);
        sink.lead(p.reads[k], l.followers);
        var f = l.next;
        while (f != none) : (f = p.links.items[f].next) sink.same(p.reads[f]);
    }

    /// Answers every read of `reads`: each with `done` while there is no plan, else each set once, through its lead.
    pub fn answer(p: *const Plan, reads: []const *Query, sink: anytype) void {
        if (p.reads.len == 0) {
            for (reads) |r| sink.done(r);
            return;
        }
        for (0..reads.len) |k| if (!p.follows(k)) p.done(k, sink);
    }

    pub fn reset(p: *Plan) void {
        p.reads = &.{};
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "answers that waited for ring space reach the worker without a newer answer" {
    region = try shared.Region.map(1, 1024, 1024);
    var efds = [_]i32{eventfd()};
    answer_efds = &efds;
    becomeDrain();
    // Leave this process as it was: a lone worker, no rings.
    defer {
        for (peers) |*p| p.spill.deinit(gpa);
        gpa.free(peers);
        peers = &.{};
        _ = linux.close(efds[0]);
        answer_efds = &.{};
        _ = linux.munmap(region.base.ptr, region.base.len);
        region = undefined;
        warned_answers = false;
        role = .alone;
    }
    var worker = region.answerConsumer(0);
    var x: Proxy = .{};
    // About 40 fit the ring; the rest wait in the spill buffer.
    const sent = 100;
    for (0..sent) |_| reset(&x.q);
    var got: usize = 0;
    for (0..10) |_| {
        _ = flushAnswers(&peers[0], 0);
        while (worker.next()) |_| got += 1;
        worker.release();
    }
    try testing.expectEqual(sent, got);
}

test "an ask arrives in the drain's proxy with its tag, time, statement and its own copy of every parameter" {
    var text = "dragons".*;
    var q: Query = .{ .stmt = .list_tag, .queued_ns = 123_456_789 };
    q.params[0] = .{ .int = -7 };
    q.params[1] = .null;
    q.params[2] = .{ .int = 40 };
    q.params[3] = .{ .text = &text };
    var b: [64]u8 = undefined;
    const n = askSize(&q);
    encodeAsk(b[0..n], &q, 1 | 1448 << 16);

    var x: Proxy = .{ .worker = 3 };
    defer x.bytes.deinit(gpa);
    try testing.expectEqual(123_456_789, decodeAsk(&x, b[0..n]));
    try testing.expectEqual(1 | 3 << 3 | 1448 << 16, x.q.share);
    text = "changed".*;
    try testing.expectEqual(@intFromPtr(&q), x.tag);
    try testing.expectEqual(.list_tag, x.q.stmt);
    try testing.expectEqual(Param{ .int = -7 }, x.q.params[0]);
    try testing.expectEqual(Param.null, x.q.params[1]);
    try testing.expectEqual(Param{ .int = 40 }, x.q.params[2]);
    try testing.expectEqualStrings("dragons", x.q.params[3].text);
}

test "a row crosses as a DataRow body: NULL, empty and long columns parse back unchanged" {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    const long: [300]u8 = @splat('x');
    const cols = [_]?[]const u8{ "slug-1", null, "", &long };
    try src.appendSlice(testing.allocator, &.{ 0, cols.len });
    for (cols) |c| {
        var l: [4]u8 = undefined;
        std.mem.writeInt(i32, &l, if (c) |s| @intCast(s.len) else -1, .big);
        try src.appendSlice(testing.allocator, &l);
        if (c) |s| try src.appendSlice(testing.allocator, s);
    }
    var in: pg.Row = .{};
    try in.parse(src.items);
    // A batched row arrives with its ordinal column dropped; the copy carries only what the API reads.
    in.n -= 1;
    const out = try testing.allocator.alloc(u8, rowSize(&in));
    defer testing.allocator.free(out);
    writeRow(out, &in);
    var got: pg.Row = .{};
    try got.parse(out);
    try testing.expectEqual(3, got.n);
    try testing.expectEqualStrings("slug-1", got.text(0));
    try testing.expect(got.isNull(1));
    try testing.expect(!got.isNull(2));
    try testing.expectEqualStrings("", got.text(2));
}

test "a failure crosses with its code and message" {
    const e = pg.ErrorInfo.parse("SERROR\x00C23505\x00Mduplicate key value\x00\x00");
    var b: [64]u8 = undefined;
    writeFail(b[0..failSize(&e)], &e);
    const got = readFail(b[0..failSize(&e)]);
    try testing.expect(got.is("23505"));
    try testing.expectEqualStrings("duplicate key value", got.message());
}

/// Writes what a plan answers, one line per answer, reads named by their viewer.
const Answers = struct {
    out: *std.ArrayList(u8),

    pub fn done(a: Answers, r: *Query) void {
        a.out.print(testing.allocator, "done {d}\n", .{viewerOf(r)}) catch @panic("oom");
    }

    pub fn lead(a: Answers, r: *Query, n: u32) void {
        a.out.print(testing.allocator, "lead {d} of {d}\n", .{ viewerOf(r), n }) catch @panic("oom");
    }

    pub fn same(a: Answers, r: *Query) void {
        a.out.print(testing.allocator, "same {d}\n", .{viewerOf(r)}) catch @panic("oom");
    }

    fn viewerOf(r: *const Query) i64 {
        return if (r.stmt == .tags) @intCast(r.seq) else r.params[0].int;
    }
};

test "reads share a response only with the same class, statement and parameters after the viewer" {
    const w0: u32 = 1 | 2 | 4 | 1448 << 16;
    var reqs = [_]Query{
        .{ .stmt = .list_tag, .share = w0, .params = .{ .{ .int = 1 }, .{ .int = 10 }, .{ .int = 0 }, .{ .text = "dragons" }, .null, .null } },
        .{ .stmt = .list_tag, .share = w0, .params = .{ .{ .int = 2 }, .{ .int = 10 }, .{ .int = 0 }, .{ .text = "dragon" }, .null, .null } },
        .{ .stmt = .list_author, .share = w0, .params = .{ .{ .int = 3 }, .{ .int = 10 }, .{ .int = 0 }, .{ .text = "dragons" }, .null, .null } },
        // No keep-alive: another response head.
        .{ .stmt = .list_tag, .share = w0 & ~@as(u32, 2), .params = .{ .{ .int = 4 }, .{ .int = 10 }, .{ .int = 0 }, .{ .text = "dragons" }, .null, .null } },
        .{ .stmt = .list_tag, .share = w0, .params = .{ .{ .int = 5 }, .{ .int = 10 }, .{ .int = 0 }, .{ .text = "dragons" }, .null, .null } },
        .{ .stmt = .article_by_slug, .share = w0, .params = .{ .{ .int = 6 }, .{ .text = "how-to" }, .null, .null, .null, .null } },
        .{ .stmt = .article_by_slug, .share = w0, .params = .{ .{ .int = 7 }, .{ .text = "how-to" }, .null, .null, .null, .null } },
        .{ .stmt = .list_tag, .share = w0, .params = .{ .{ .int = 8 }, .{ .int = 10 }, .{ .int = 0 }, .{ .text = "dragons" }, .null, .null } },
    };
    var ptrs: [reqs.len]*Query = undefined;
    for (&reqs, &ptrs) |*r, *p| p.* = r;
    var plan: Plan = .{};
    defer plan.links.deinit(gpa);
    defer plan.sets.deinit(gpa);
    plan.all(&ptrs);
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    plan.answer(&ptrs, Answers{ .out = &got });
    try testing.expectEqualStrings(
        \\lead 1 of 2
        \\same 5
        \\same 8
        \\done 2
        \\done 3
        \\done 4
        \\lead 6 of 1
        \\same 7
        \\
    , got.items);

    // Without a plan, every read is answered on its own.
    plan.reset();
    got.clearRetainingCapacity();
    plan.answer(ptrs[5..7], Answers{ .out = &got });
    try testing.expectEqualStrings("done 6\ndone 7\n", got.items);
}

test "a broadcast's members share by worker and response head, and a read without a class keeps its own" {
    const w0: u32 = 1 | 2 | 4 | 1448 << 16;
    const w1: u32 = w0 | 1 << 3;
    var reqs: [5]Query = undefined;
    for (&reqs, [_]u32{ w0, w1, w0, 0, w1 }, 1..) |*r, c, i| r.* = .{ .stmt = .tags, .share = c, .seq = i };
    var ptrs: [reqs.len]*Query = undefined;
    for (&reqs, &ptrs) |*r, *p| p.* = r;
    var plan: Plan = .{};
    defer plan.links.deinit(gpa);
    defer plan.sets.deinit(gpa);
    plan.all(&ptrs);
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    plan.answer(&ptrs, Answers{ .out = &got });
    try testing.expectEqualStrings("lead 1 of 1\nsame 3\nlead 2 of 1\nsame 5\ndone 4\n", got.items);
}
