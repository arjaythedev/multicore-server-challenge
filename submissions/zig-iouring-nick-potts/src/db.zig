//! Request queues and the Postgres connections that drain them.
//!
//! Every queued request waits in its statement's FIFO; the process's read connections share them. With one worker
//! that is the worker itself; with more, every read goes to the drain process (drain.zig), which runs the read path
//! below for all of them and hands each result back to the worker that asked. Reads go out on a
//! batch clock (PR #47's two-phase gather, measured on branch sql-proto as proto-gather5ms): once the oldest queued
//! read has waited `window_ns`, a free read connection takes every queued read into one Sync group, so each drain
//! holds everything that arrived during the window. Same-statement requests become one batched execution (one array
//! per parameter, rows tagged with the request ordinal), tag reads share one execution, and the whole drain rides one
//! Sync. The next drain's clock starts with the next read to arrive. A drain with two or more reads that MEGA
//! serves sends those as one execution of it instead, last in the Sync group (mega.zig). Comments stay out of MEGA:
//! one runs COMMENTS_LIST_SET, two or more its batched form.
//!
//! Writes go to their own connection (sql-writes' writes-1conn). An idle write connection takes the first queued
//! write; when nothing else is queued it waits `write_wait_ns` first. Then it takes up to `max_writes` into one Sync
//! group, without BEGIN or COMMIT: writes of one statement that has a batched form become one execution of it, at the
//! place of the first of them, and every other write is its own execution. The group commits at its Sync, and every
//! write in it is answered only after its ReadyForQuery, so the commit is durable before any response (group commit).
//! A write that can fail on data (`sql.fallible`) never shares a group, so its failure rolls back nobody else's. A
//! failed group is retried one request per group; a failed solo request gets its error.
const std = @import("std");
const sql = @import("sql.zig");
const pg = @import("pg.zig");
const sys = @import("sys.zig");
const api = @import("api.zig");
const mega = @import("mega.zig");
const drain = @import("drain.zig");
const Stmt = sql.Stmt;

pub const Param = union(enum) {
    null,
    int: i64,
    text: []const u8,
    /// A value already in Postgres binary form (the text[] of a new article's tags).
    raw: []const u8,
};

/// Sync groups in flight per read connection.
const depth = 1;
/// The batch clock: how long the oldest queued read waits for others before its drain goes out. Longer clocks make
/// bigger drains, which cost Postgres less per read and add up to the clock to every read's latency; arms sweep it
/// end to end (rig/zig-arms.sh) and read p95/p99 at the knee.
const window_ns = 5 * std.time.ns_per_ms;
/// How long an idle write connection holding a lone write waits for others before it sends it (sql-writes'
/// delay_us). Writes that arrive meanwhile join it; the wait does not end early.
const write_wait_ns = 3 * std.time.ns_per_ms;
/// Writes in one drain at most (sql-writes' max_batch).
const max_writes = 128;

/// One statement a caller asked to run: a worker's API request, or in the drain process its stand-in for a worker's
/// ask. db owns it while it is queued or executing.
pub const Query = struct {
    next: ?*Query = null,
    seq: u64 = 0,
    /// When it was queued (monotonic ns), for the read batch clock.
    queued_ns: u64 = 0,
    solo: bool = false,
    stmt: Stmt = .tags,
    params: [6]Param = undefined,
};

pub const Queue = struct {
    head: ?*Query = null,
    tail: ?*Query = null,
    len: u32 = 0,

    pub fn push(q: *Queue, r: *Query) void {
        r.next = null;
        if (q.tail) |t| t.next = r else q.head = r;
        q.tail = r;
        q.len += 1;
    }

    pub fn pop(q: *Queue) *Query {
        const r = q.head.?;
        q.head = r.next;
        if (q.head == null) q.tail = null;
        q.len -= 1;
        r.next = null;
        return r;
    }

    /// Unlinks `r`, which follows `prev` (null: `r` is the head).
    fn unlink(q: *Queue, prev: ?*Query, r: *Query) void {
        if (prev) |p| p.next = r.next else q.head = r.next;
        if (q.tail == r) q.tail = prev;
        q.len -= 1;
        r.next = null;
    }
};

var reads: [sql.count]Queue = @splat(.{});
var writes: Queue = .{};
var seq: u64 = 0;
/// Monotonic ns at the start of the event loop's iteration.
pub var now_ns: u64 = 0;

pub fn enqueue(r: *Query) void {
    enqueueAt(r, now_ns);
}

/// Queues `r` as if it arrived at `at` (monotonic ns), which starts its batch clock: the drain process passes the
/// time the worker queued it.
pub fn enqueueAt(r: *Query, at: u64) void {
    seq += 1;
    r.seq = seq;
    r.queued_ns = at;
    if (r.stmt.def().write) return writes.push(r);
    if (drain.role == .worker) return drain.ask(r);
    reads[@intFromEnum(r.stmt)].push(r);
}

/// Whether reads wait in this process's queues.
pub fn readsQueued() bool {
    return oldestRead() != null;
}

// ---------------------------------------------------------------- groups

/// Executions in one drain at most: a write drain's writes may each be their own.
const max_units = max_writes;
/// Reads in one drain at most (sql-proto's max_batch).
const max_members = 4096;
/// The fewest mega-able reads that make a drain send MEGA.
const mega_min = 2;

const UnitKind = enum(u8) { single, batched, broadcast, mega };

const Unit = struct {
    stmt: Stmt,
    kind: UnitKind,
    first: u16,
    n: u16,
};

const Group = struct {
    units: [max_units]Unit = undefined,
    nunits: u16 = 0,
    members: [max_members]*Query = undefined,
    nmembers: u16 = 0,
    cur: u16 = 0,
    failed_at: ?u16 = null,
    err: pg.ErrorInfo = .{},
    write: bool = false,
    next_free: ?*Group = null,

    fn unitMembers(g: *Group, u: *const Unit) []*Query {
        return g.members[u.first..][0..u.n];
    }
};

var free_groups: ?*Group = null;

fn newGroup(write: bool) *Group {
    const g = if (free_groups) |f| reuse: {
        free_groups = f.next_free;
        break :reuse f;
    } else std.heap.page_allocator.create(Group) catch @panic("oom");
    g.* = .{ .write = write };
    return g;
}

fn freeGroup(g: *Group) void {
    g.next_free = free_groups;
    free_groups = g;
}

// ---------------------------------------------------------------- connections

pub const Conn = struct {
    fd: i32,
    index: u16,
    write: bool,
    rbuf: []u8,
    rstart: usize = 0,
    rend: usize = 0,
    pending: pg.Out = .{},
    sending: pg.Out = .{},
    send_off: usize = 0,
    in_send: bool = false,
    inflight: [8]*Group = undefined,
    in_head: u8 = 0,
    in_len: u8 = 0,
    row: pg.Row = .{},
    mega: mega.Result = .{},
    /// A write connection's next drain time (monotonic ns), set once it is idle with writes queued.
    write_due: ?u64 = null,

    fn front(c: *Conn) *Group {
        return c.inflight[c.in_head];
    }

    fn pushGroup(c: *Conn, g: *Group) void {
        c.inflight[(c.in_head + c.in_len) % c.inflight.len] = g;
        c.in_len += 1;
    }

    fn popGroup(c: *Conn) *Group {
        const g = c.inflight[c.in_head];
        c.in_head = @intCast((c.in_head + 1) % c.inflight.len);
        c.in_len -= 1;
        return g;
    }
};

pub var conns: []Conn = &.{};

/// Statement names: "s<n>" single, "b<n>" batched, "m" MEGA.
const mega_name = "m";

fn stmtName(buf: *[8]u8, prefix: u8, s: Stmt) []const u8 {
    buf[0] = prefix;
    const n = std.fmt.printInt(buf[1..], @intFromEnum(s), 10, .lower, .{});
    return buf[0 .. 1 + n];
}

/// Connects and prepares every statement this connection runs, checking each against the live schema.
pub fn openConn(url: pg.Url, write: bool, index: u16) !Conn {
    const gucs = [_][2][]const u8{
        .{ "plan_cache_mode", "force_generic_plan" },
        .{ "jit", "off" },
        .{ "application_name", "conduit-zig" },
    };
    const b = try pg.connect(url, &gucs);
    defer std.heap.smp_allocator.destroy(b);
    var name: [8]u8 = undefined;
    for (0..sql.count) |i| {
        const s: Stmt = @enumFromInt(i);
        const d = s.def();
        if (d.write != write) continue;
        try pg.prepareChecked(b, stmtName(&name, 's', s), d.sql, d.params, d.cols);
        if (d.batch == .arrays) {
            const text = try sql.batchedSql(std.heap.smp_allocator, s);
            defer std.heap.smp_allocator.free(text);
            const cols = try sql.batchedCols(std.heap.smp_allocator, s);
            defer std.heap.smp_allocator.free(cols);
            var types: [8]sql.Oid = undefined;
            for (d.params, 0..) |p, k| types[k] = sql.arrayOid(p);
            try pg.prepareChecked(b, stmtName(&name, 'b', s), text, types[0..d.params.len], cols);
        }
    }
    if (!write) try pg.prepareChecked(b, mega_name, sql.mega.sql, &sql.mega.params, &sql.mega.cols);
    if (b.end != b.start) return error.UnexpectedData;
    return .{
        .fd = b.fd,
        .index = index,
        .write = write,
        .rbuf = try std.heap.page_allocator.alloc(u8, 1 << 20),
    };
}

// ---------------------------------------------------------------- building groups

fn oldestRead() ?Stmt {
    var best: ?Stmt = null;
    var best_seq: u64 = std.math.maxInt(u64);
    for (&reads, 0..) |*q, i| {
        if (q.head) |h| if (h.seq < best_seq) {
            best_seq = h.seq;
            best = @enumFromInt(i);
        };
    }
    return best;
}

fn addUnit(g: *Group, s: Stmt, kind: UnitKind) *Unit {
    const u = &g.units[g.nunits];
    u.* = .{ .stmt = s, .kind = kind, .first = g.nmembers, .n = 0 };
    g.nunits += 1;
    return u;
}

fn addMember(g: *Group, u: *Unit, r: *Query) void {
    g.members[g.nmembers] = r;
    g.nmembers += 1;
    u.n += 1;
}

/// When the queued reads' drain is due (monotonic ns): the oldest's arrival plus the window, or now once a full
/// drain is queued. Null with nothing queued.
fn readsDue() ?u64 {
    const s = oldestRead() orelse return null;
    var queued: u32 = 0;
    for (&reads) |*q| queued += q.len;
    if (queued >= max_members) return now_ns;
    return reads[@intFromEnum(s)].head.?.queued_ns + window_ns;
}

/// Whether the queues hold at least `mega_min` reads that may ride in MEGA: those with a mega form, except
/// retries, which run alone.
fn megaDue() bool {
    var n: u32 = 0;
    for (&reads, 0..) |*q, i| {
        const s: Stmt = @enumFromInt(i);
        if (s.def().mega == null) continue;
        var it = q.head;
        while (it) |r| : (it = r.next) {
            if (!r.solo) n += 1;
            if (n >= mega_min) return true;
        }
    }
    return false;
}

/// Moves the reads of `q` that may ride in MEGA into the group's members, leaving retries queued in order.
fn takeMega(g: *Group, q: *Queue) void {
    var prev: ?*Query = null;
    var it = q.head;
    while (it) |r| {
        it = r.next;
        if (r.solo) {
            prev = r;
            continue;
        }
        if (g.nmembers == max_members) return;
        q.unlink(prev, r);
        g.members[g.nmembers] = r;
        g.nmembers += 1;
    }
}

fn buildRead() ?*Group {
    if (oldestRead() == null) return null;
    const g = newGroup(false);
    // The mega reads take the first members, but their unit goes last, after the other reads' units.
    var mega_unit: ?Unit = null;
    if (megaDue()) {
        for (&reads, 0..) |*q, i| {
            const s: Stmt = @enumFromInt(i);
            if (s.def().mega != null) takeMega(g, q);
        }
        mega_unit = .{ .stmt = g.members[0].stmt, .kind = .mega, .first = 0, .n = g.nmembers };
    }
    const unit_room: u16 = if (mega_unit == null) max_units else max_units - 1;
    while (g.nunits + 1 < unit_room) {
        const s = oldestRead() orelse break;
        const q = &reads[@intFromEnum(s)];
        const d = s.def();
        const room = max_members - g.nmembers;
        if (room == 0) break;
        if (q.head.?.solo or d.batch == .none) {
            const u = addUnit(g, s, .single);
            addMember(g, u, q.pop());
            continue;
        }
        if (d.batch == .broadcast) {
            const u = addUnit(g, s, .broadcast);
            while (q.head != null and u.n < room) addMember(g, u, q.pop());
            continue;
        }
        const u = addUnit(g, s, .batched);
        while (q.head) |h| {
            if (u.n >= room or h.solo) break;
            addMember(g, u, q.pop());
        }
        if (u.n == 1) u.kind = .single;
    }
    if (mega_unit) |u| {
        g.units[g.nunits] = u;
        g.nunits += 1;
    }
    return g;
}

/// Whether a write must run alone: a retry, or a statement that can fail on data.
fn alone(r: *const Query) bool {
    return r.solo or sql.fallible(r.stmt);
}

/// When the idle write connection `c` sends its next drain (monotonic ns): now if the first queued write has company
/// or must run alone, else `write_wait_ns` after the connection took it. Null with nothing queued.
fn writesDue(c: *Conn) ?u64 {
    const h = writes.head orelse {
        c.write_due = null;
        return null;
    };
    if (c.write_due == null) c.write_due = if (writes.len > 1 or alone(h)) now_ns else now_ns + write_wait_ns;
    return c.write_due;
}

fn buildWrite() ?*Group {
    const h = writes.head orelse return null;
    const g = newGroup(true);
    if (alone(h)) {
        const u = addUnit(g, h.stmt, .single);
        addMember(g, u, writes.pop());
        return g;
    }
    // Take up to max_writes, leaving the writes that run alone queued in order.
    var taken: [max_writes]?*Query = undefined;
    var n: usize = 0;
    var prev: ?*Query = null;
    var it = writes.head;
    while (it) |r| {
        if (n == max_writes) break;
        it = r.next;
        if (alone(r)) {
            prev = r;
            continue;
        }
        writes.unlink(prev, r);
        taken[n] = r;
        n += 1;
    }
    for (0..n) |i| {
        const first = taken[i] orelse continue;
        const batches = first.stmt.def().batch == .arrays;
        const u = addUnit(g, first.stmt, .single);
        for (taken[i..n]) |*t| {
            const r = t.* orelse continue;
            if (r != first and !(batches and r.stmt == first.stmt)) continue;
            addMember(g, u, r);
            t.* = null;
        }
        if (u.n > 1) u.kind = .batched;
    }
    return g;
}

fn encodeGroup(o: *pg.Out, g: *Group) void {
    var name: [8]u8 = undefined;
    for (g.units[0..g.nunits]) |*u| {
        const d = u.stmt.def();
        const members = g.unitMembers(u);
        switch (u.kind) {
            .single, .broadcast => {
                const r = members[0];
                const at = pg.bindBegin(o, stmtName(&name, 's', u.stmt), @intCast(d.params.len));
                for (r.params[0..d.params.len]) |p| encodeParam(o, p);
                pg.bindEnd(o, at);
            },
            .batched => {
                const at = pg.bindBegin(o, stmtName(&name, 'b', u.stmt), @intCast(d.params.len));
                for (d.params, 0..) |ptype, k| {
                    const arr = pg.arrayBegin(o, ptype, members.len);
                    for (members) |r| encodeParam(o, r.params[k]);
                    pg.arrayEnd(o, arr);
                }
                pg.bindEnd(o, at);
            },
            .mega => mega.encode(o, mega_name, members),
        }
    }
    pg.sync(o);
}

fn encodeParam(o: *pg.Out, p: Param) void {
    switch (p) {
        .null => pg.paramNull(o),
        .int => |v| pg.paramInt(o, v),
        .text => |t| pg.paramText(o, t),
        .raw => |t| pg.paramText(o, t),
    }
}

/// Fills every connection that has room with new Sync groups, encoded into its pending bytes; reads only once
/// their drain is due, writes once the write wait is over. Returns the next such time (monotonic ns) if it is still
/// ahead; reads already due are waiting for a connection, whose completion ends the wait.
pub fn pump() ?u64 {
    var next: ?u64 = null;
    for (conns) |*c| {
        if (c.write) {
            if (c.in_len > 0) continue;
            const due = writesDue(c) orelse continue;
            if (due > now_ns) {
                next = if (next) |t| @min(t, due) else due;
                continue;
            }
            c.write_due = null;
            const g = buildWrite().?;
            encodeGroup(&c.pending, g);
            c.pushGroup(g);
            continue;
        }
        while (c.in_len < depth) {
            if (readsDue()) |due| if (due > now_ns) break;
            const g = buildRead() orelse break;
            encodeGroup(&c.pending, g);
            c.pushGroup(g);
        }
    }
    const due = readsDue() orelse return next;
    if (due <= now_ns) return next;
    return if (next) |t| @min(t, due) else due;
}

// ---------------------------------------------------------------- results

/// Consumes whatever complete messages sit in the connection's receive buffer.
pub fn onRecv(c: *Conn) void {
    while (c.rend - c.rstart >= 5) {
        const len: usize = @intCast(std.mem.readInt(i32, c.rbuf[c.rstart + 1 ..][0..4], .big));
        if (c.rend - c.rstart < len + 1) {
            if (len + 1 > c.rbuf.len) grow(c, len + 1);
            break;
        }
        const t = c.rbuf[c.rstart];
        const body = c.rbuf[c.rstart + 5 .. c.rstart + 1 + len];
        c.rstart += len + 1;
        message(c, t, body);
    }
    if (c.rstart == c.rend) {
        c.rstart = 0;
        c.rend = 0;
    } else if (c.rstart > c.rbuf.len / 2) {
        const n = c.rend - c.rstart;
        std.mem.copyForwards(u8, c.rbuf[0..n], c.rbuf[c.rstart..c.rend]);
        c.rstart = 0;
        c.rend = n;
    }
}

/// Free space at the end of the receive buffer, compacting or growing it so a recv has room for at least 64 KB.
pub fn recvSpace(c: *Conn) []u8 {
    const want = 64 * 1024;
    if (c.rbuf.len - c.rend < want and c.rstart > 0) {
        const n = c.rend - c.rstart;
        std.mem.copyForwards(u8, c.rbuf[0..n], c.rbuf[c.rstart..c.rend]);
        c.rstart = 0;
        c.rend = n;
    }
    if (c.rbuf.len - c.rend < want) grow(c, c.rbuf.len * 2);
    return c.rbuf[c.rend..];
}

fn grow(c: *Conn, need: usize) void {
    var size = c.rbuf.len;
    while (size < need) size *= 2;
    const nb = std.heap.page_allocator.alloc(u8, size) catch @panic("oom");
    const n = c.rend - c.rstart;
    @memcpy(nb[0..n], c.rbuf[c.rstart..c.rend]);
    std.heap.page_allocator.free(c.rbuf);
    c.rbuf = nb;
    c.rstart = 0;
    c.rend = n;
}

fn message(c: *Conn, t: u8, body: []const u8) void {
    const results: Results() = .{};
    switch (t) {
        'D' => {
            const g = c.front();
            if (g.failed_at != null) return;
            const u = &g.units[g.cur];
            if (u.kind == .mega) return c.mega.add(body) catch |e| sys.fatal("bad MEGA row: {s}", .{@errorName(e)});
            c.row.parse(body) catch sys.fatal("bad DataRow", .{});
            const members = g.unitMembers(u);
            switch (u.kind) {
                .single => results.row(members[0], &c.row),
                .broadcast => for (members) |r| results.row(r, &c.row),
                .batched => {
                    c.row.n -= 1;
                    const ord = c.row.int(c.row.n);
                    if (ord < 1 or ord > members.len) sys.fatal("batched row ordinal {d} out of range", .{ord});
                    results.row(members[@intCast(ord - 1)], &c.row);
                },
                .mega => unreachable,
            }
        },
        'C', 'I' => {
            const g = c.front();
            if (g.failed_at != null) return;
            const u = &g.units[g.cur];
            if (u.kind == .mega) {
                c.mega.deliver(g.unitMembers(u), results) catch |e| sys.fatal("MEGA result: {s}", .{@errorName(e)});
                c.mega.reset();
            } else if (!g.write) {
                for (g.unitMembers(u)) |r| results.done(r);
            }
            g.cur += 1;
        },
        'E' => {
            const g = c.front();
            g.failed_at = g.cur;
            g.err = pg.ErrorInfo.parse(body);
            c.mega.reset();
        },
        'Z' => {
            const g = c.popGroup();
            finishGroup(g);
            freeGroup(g);
        },
        '2', 'N', 'S', 'A', '1', '3', 'n', 's', 't', 'T', 'K' => {},
        else => sys.log("unexpected postgres message '{c}'", .{t}),
    }
}

/// Where every result leaves db, chosen at startup by `drain.role`: in a worker, the API request that queued the
/// query; in the drain process, an answer record for the worker that asked.
fn Results() type {
    return struct {
        pub fn row(_: @This(), r: *Query, x: *const pg.Row) void {
            if (drain.role == .drain) drain.row(r, x) else api.onRow(api.request(r), x);
        }

        pub fn done(_: @This(), r: *Query) void {
            if (drain.role == .drain) drain.done(r) else api.onDone(api.request(r));
        }

        /// The statement failed for this query alone.
        fn fail(_: @This(), r: *Query, e: *const pg.ErrorInfo) void {
            if (drain.role == .drain) drain.fail(r, e) else api.onFail(api.request(r), e);
        }

        /// The query runs again; the rows it produced so far are void.
        fn reset(_: @This(), r: *Query) void {
            if (drain.role == .drain) drain.reset(r) else api.onReset(api.request(r));
        }
    };
}

fn finishGroup(g: *Group) void {
    const results: Results() = .{};
    const failed = g.failed_at orelse {
        if (g.write) for (g.members[0..g.nmembers]) |r| results.done(r);
        return;
    };
    const fu = &g.units[failed];
    // Writes: the whole transaction rolled back. A lone request gets its error; otherwise every request retries in
    // a transaction of its own.
    // Reads: units before the failure are answered. A single-request unit gets its error; a batched or MEGA unit's
    // requests retry alone, each as its own statement; later units run again as usual.
    const answered = if (g.write) g.nmembers == 1 else fu.n == 1 and fu.kind != .mega;
    if (answered) {
        results.fail(g.members[fu.first], &g.err);
    } else {
        const what = if (fu.kind == .mega) "MEGA" else @tagName(fu.stmt);
        sys.log("group failed at unit {d} ({s}): {s} {s}; retrying", .{ failed, what, &g.err.code, g.err.message() });
    }
    const first_unanswered: u16 = if (g.write) 0 else failed;
    for (g.units[first_unanswered..g.nunits], first_unanswered..) |*u, i| {
        if (i == failed and answered) continue;
        for (g.unitMembers(u)) |r| {
            results.reset(r);
            r.solo = g.write or i == failed;
            enqueue(r);
        }
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Empties every queue, as at startup, for tests that queue requests they never run.
pub fn clearQueuesForTest() void {
    comptime std.debug.assert(@import("builtin").is_test);
    reads = @splat(.{});
    writes = .{};
}

test "a write drain batches by statement in first-write order and leaves writes that run alone queued" {
    const stmts = [_]Stmt{ .favorite, .comment_create, .favorite, .user_update, .follow, .article_create, .favorite, .comment_create };
    var reqs: [stmts.len]Query = undefined;
    for (&reqs, stmts) |*r, s| r.* = .{ .stmt = s };
    for (&reqs) |*r| enqueue(r);
    var c: Conn = .{ .fd = -1, .index = 0, .write = true, .rbuf = &.{} };
    try testing.expectEqual(now_ns, writesDue(&c));

    const g = buildWrite().?;
    defer freeGroup(g);
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    for (g.units[0..g.nunits]) |*u| {
        try got.print(testing.allocator, "{s} {s}", .{ @tagName(u.kind), @tagName(u.stmt) });
        for (g.unitMembers(u)) |r| try got.print(testing.allocator, " {d}", .{(@intFromPtr(r) - @intFromPtr(&reqs)) / @sizeOf(Query)});
        try got.append(testing.allocator, '\n');
    }
    try testing.expectEqualStrings(
        \\batched favorite 0 2 6
        \\batched comment_create 1 7
        \\single follow 4
        \\single article_create 5
        \\
    , got.items);

    // The update waits for its own drain, which goes out at once: it runs alone.
    try testing.expectEqual(&reqs[3], writes.head.?);
    try testing.expectEqual(1, writes.len);
    c.write_due = null;
    try testing.expectEqual(now_ns, writesDue(&c));
    const solo = buildWrite().?;
    defer freeGroup(solo);
    try testing.expectEqual(1, solo.nmembers);
    try testing.expectEqual(null, writes.head);
}

test "a lone write waits for company, and the wait does not end early" {
    now_ns = 1000;
    var a: Query = .{ .stmt = .favorite };
    var b: Query = .{ .stmt = .follow };
    enqueue(&a);
    var c: Conn = .{ .fd = -1, .index = 0, .write = true, .rbuf = &.{} };
    try testing.expectEqual(1000 + write_wait_ns, writesDue(&c));
    now_ns = 1500;
    enqueue(&b);
    try testing.expectEqual(1000 + write_wait_ns, writesDue(&c));
    const g = buildWrite().?;
    defer freeGroup(g);
    try testing.expectEqual(2, g.nunits);
    try testing.expectEqual(null, writes.head);
    try testing.expectEqual(null, writesDue(&c));
    try testing.expectEqual(null, c.write_due);
}
