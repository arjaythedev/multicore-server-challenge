//! Request queues and the Postgres connections that drain them.
//!
//! Every queued request waits in its statement's FIFO; the process's read connections share them. With one worker
//! that is the worker itself; with more, every read goes to the drain process (drain.zig), which runs the read path
//! below for all of them and hands each result back to the worker that asked. Reads drain on three lanes: feeds,
//! comments, and every other read on the shared lane (`laneOf`). Each lane goes out on a batch clock (PR #47's
//! two-phase gather, measured on branch sql-proto as proto-gather5ms): once the oldest queued read of the lane has
//! waited `window_ns` and the lane's gap (`gap_ns`, `feed_gap_ns`, `comments_gap_ns`) has passed since the lane's
//! previous drain started, a free read connection takes every queued read of the lane into one Sync group, so each
//! drain holds everything that arrived on its lane since the last one. A lane whose own queue is full (`max_members`,
//! one drain's worth) drains at once; the other lanes keep their gaps. A lane with its cap of drains in flight
//! (`max_inflight`, `feed_max_inflight`, `comments_max_inflight`) starts no new one until one finishes, full queue or
//! not, so near saturation its batches grow instead of its concurrency. Same-statement requests become one batched
//! execution (one array per parameter, rows tagged with the request ordinal), tag reads share one execution, and the
//! whole drain rides one Sync. A drain with two or more reads that MEGA serves sends those as one execution of it
//! instead, last in the Sync group (mega.zig), so the cheap reads it does not serve (tags, profiles, users, logins)
//! are answered before it runs; a feed drain is one MEGA execution of feeds alone. Comments stay out of MEGA: a
//! comments drain runs COMMENTS_LIST_SET for one read, its batched form for more, which reads each distinct thread
//! once (threads.zig).
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
const threads = @import("threads.zig");
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
/// bigger drains, which cost Postgres less per read and add up to the clock to every read's latency.
const window_ns = 5 * std.time.ns_per_ms;
/// The drain gap (#47's gather): a lane's read drain starts only once this long has passed since the lane's previous
/// one started, so below saturation the reads of the whole gap share one drain instead of ~5 ms worth each. At
/// 130,000 users 80 ms puts about 1,400 reads in a shared drain, where the measured cost curve flattens (per read
/// against 215 per drain: 0.91 at 430, 0.73 at 860, 0.70 at 1,290); the gap adds up to itself to a shared read's
/// latency.
const gap_ns = 80 * std.time.ns_per_ms;
/// The feed lane's gap. A feed is the dearest read (its page walk and the favorite counts of what it returns) and
/// shares the most within one execution, so feeds drain on a lane of their own with a longer gap: four times the feeds
/// per execution, and no other read's drain waits for the feed work.
const feed_gap_ns = 80 * std.time.ns_per_ms;
/// The comments lane's gap. Comments are one batched execution that reads each distinct thread once, so a longer gap
/// puts twice the comment reads in each, and the shared drain no longer waits on them.
const comments_gap_ns = 100 * std.time.ns_per_ms;
/// Drains of the shared lane in flight at most. Near saturation an execution outlasts the gap, so a free connection
/// starts another drain as the gap ends and up to eight stretched executions of one lane contend for the cores. At
/// the cap the lane waits for one to finish, and its next drain takes everything that arrived meanwhile, so under
/// load its batches grow instead of its concurrency. The lane needs about two of the eight read connections at the
/// knee (1.9 backend-seconds per second at 130,000 users on the rig), so three leaves it headroom and binds only in a
/// pile-up. PR #99 caps the same way on the official box: lists 2, feeds 5, cheap reads 1, of 8.
const max_inflight = 3;
/// The feed lane's cap. Feed executions run 150-230 ms against the 80 ms gap at 135,000 users, two to three in
/// flight, and the lane needs about 1.9 backends at the knee at its largest batches, so one or two would starve it.
const feed_max_inflight = 2;
/// The comments lane's cap. A comments execution runs about as long as its gap (34 ms against 40 at 135,000 users),
/// so one or two are in flight and the lane needs under one backend at the knee.
const comments_max_inflight = 2;

/// The read lanes, in the order a free connection serves them.
const LaneId = enum(u8) { feed, comments, shared };
const lane_order = [_]LaneId{ .feed, .comments, .shared };

const Lane = struct {
    gap_ns: u64,
    /// Drains of the lane in flight at most.
    max_inflight: u8,
    /// When the lane's last drain started (monotonic ns).
    last_ns: u64 = 0,
    /// Drains of the lane on a connection, from a connection taking the group to its ReadyForQuery.
    inflight: u8 = 0,
};

var lanes = [_]Lane{
    .{ .gap_ns = feed_gap_ns, .max_inflight = feed_max_inflight },
    .{ .gap_ns = comments_gap_ns, .max_inflight = comments_max_inflight },
    .{ .gap_ns = gap_ns, .max_inflight = max_inflight },
};

fn lane(l: LaneId) *Lane {
    return &lanes[@intFromEnum(l)];
}

/// The lane a statement's reads drain on. Every statement is on one lane.
fn laneOf(s: Stmt) LaneId {
    return switch (s) {
        .list_feed => .feed,
        .comments_list_set => .comments,
        else => .shared,
    };
}
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
    return queuedReads() > 0;
}

fn queuedReads() u32 {
    var n: u32 = 0;
    for (&reads) |*q| n += q.len;
    return n;
}

/// Reads queued on lane `l`.
fn queuedOn(l: LaneId) u32 {
    var n: u32 = 0;
    for (&reads, 0..) |*q, i| {
        if (laneOf(@enumFromInt(i)) == l) n += q.len;
    }
    return n;
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
    /// A read drain's lane.
    lane: LaneId = .shared,
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
    fan: threads.Fan = .{},
    /// A write connection's next drain time (monotonic ns), set once it is idle with writes queued.
    write_due: ?u64 = null,

    fn front(c: *Conn) *Group {
        return c.inflight[c.in_head];
    }

    fn pushGroup(c: *Conn, g: *Group) void {
        c.inflight[(c.in_head + c.in_len) % c.inflight.len] = g;
        c.in_len += 1;
        if (!g.write) lane(g.lane).inflight += 1;
    }

    fn popGroup(c: *Conn) *Group {
        const g = c.inflight[c.in_head];
        c.in_head = @intCast((c.in_head + 1) % c.inflight.len);
        c.in_len -= 1;
        if (!g.write) lane(g.lane).inflight -= 1;
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
    // Read connections also get 32 MB of work_mem: a big drain's MEGA sorts and hashes stay in memory.
    const gucs = [_][2][]const u8{
        .{ "plan_cache_mode", "force_generic_plan" },
        .{ "jit", "off" },
        .{ "application_name", "conduit-zig" },
        .{ "work_mem", "32MB" },
    };
    const b = try pg.connect(url, if (write) gucs[0..3] else &gucs);
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

/// The statement of the oldest read queued on lane `l`.
fn oldestRead(l: LaneId) ?Stmt {
    var best: ?Stmt = null;
    var best_seq: u64 = std.math.maxInt(u64);
    for (&reads, 0..) |*q, i| {
        const s: Stmt = @enumFromInt(i);
        if (laneOf(s) != l) continue;
        if (q.head) |h| if (h.seq < best_seq) {
            best_seq = h.seq;
            best = s;
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

/// When lane `l`'s drain is due (monotonic ns): its oldest read's arrival plus the window, after the lane's gap, or
/// now while the lane's queue is full. Null with nothing queued on the lane, or while the lane has its cap of drains
/// in flight: one of their ReadyForQuerys makes it due.
fn readsDue(l: LaneId) ?u64 {
    const s = oldestRead(l) orelse return null;
    const ln = lane(l);
    if (ln.inflight >= ln.max_inflight) return null;
    if (full(l)) return now_ns;
    return @max(reads[@intFromEnum(s)].head.?.queued_ns + window_ns, ln.last_ns + ln.gap_ns);
}

/// Whether lane `l`'s queue is full: `max_members` reads, as many as one drain takes, which starts its drain at once.
/// Each lane counts its own queue, so one lane's backlog cannot strip the others of their gaps. An earlier version
/// counted every lane together and started every lane's drain past the mark. Under load the feed lane runs at its
/// cap with a backlog, and that backlog plus the shared lane's gap of reads crossed the mark, which drained the
/// shared and comments lanes early and small, in more executions, for as long as it lasted.
fn full(l: LaneId) bool {
    return queuedOn(l) >= max_members;
}

/// Whether lane `l` holds at least `mega_min` reads that may ride in MEGA: those with a mega form, except retries,
/// which run alone.
fn megaDue(l: LaneId) bool {
    var n: u32 = 0;
    for (&reads, 0..) |*q, i| {
        const s: Stmt = @enumFromInt(i);
        if (s.def().mega == null or laneOf(s) != l) continue;
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

/// The drain of lane `l`: every read queued on it, up to `max_members`. Null with nothing queued on the lane.
fn buildRead(l: LaneId) ?*Group {
    if (oldestRead(l) == null) return null;
    const g = newGroup(false);
    g.lane = l;
    // The mega reads take the first members, but their unit goes last, after the other reads' units.
    var mega_unit: ?Unit = null;
    if (megaDue(l)) {
        for (&reads, 0..) |*q, i| {
            const s: Stmt = @enumFromInt(i);
            if (s.def().mega != null and laneOf(s) == l) takeMega(g, q);
        }
        mega_unit = .{ .stmt = g.members[0].stmt, .kind = .mega, .first = 0, .n = g.nmembers };
    }
    const unit_room: u16 = if (mega_unit == null) max_units else max_units - 1;
    while (g.nunits + 1 < unit_room) {
        const s = oldestRead(l) orelse break;
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
    for (g.units[0..g.nunits], 0..) |*u, i| {
        // Postgres keeps a finished unit's results until the Sync or a full send buffer, so a read unit would wait
        // behind the units after it (MEGA, the slow one, is last). Writes are answered at ReadyForQuery anyway.
        if (i > 0 and !g.write) pg.flush(o);
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

/// The drain of the first lane, in `lane_order`, whose drain is due, with the lane's clock restarted. Null when no
/// lane is due.
fn dueRead() ?*Group {
    for (lane_order) |l| {
        const due = readsDue(l) orelse continue;
        if (due > now_ns) continue;
        lane(l).last_ns = now_ns;
        return buildRead(l).?;
    }
    return null;
}

/// Fills every connection that has room with new Sync groups, encoded into its pending bytes; reads only once
/// their lane's drain is due, writes once the write wait is over. Returns the next such time (monotonic ns) if it is
/// still ahead; reads already due are waiting for a connection or for one of their lane's drains, whose completion
/// ends the wait.
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
            const g = dueRead() orelse break;
            encodeGroup(&c.pending, g);
            c.pushGroup(g);
        }
    }
    for (lane_order) |l| {
        const due = readsDue(l) orelse continue;
        if (due <= now_ns) continue;
        next = if (next) |t| @min(t, due) else due;
    }
    return next;
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
                    if (u.stmt.def().thread_cols != null)
                        return c.fan.row(&c.row, members, results) catch |e| sys.fatal("comments result: {s}", .{@errorName(e)});
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
            c.fan.reset();
            g.cur += 1;
        },
        'E' => {
            const g = c.front();
            g.failed_at = g.cur;
            g.err = pg.ErrorInfo.parse(body);
            c.mega.reset();
            c.fan.reset();
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

/// Empties every queue and restarts the lane clocks, as at startup, for tests that queue requests they never run.
pub fn clearQueuesForTest() void {
    comptime std.debug.assert(@import("builtin").is_test);
    reads = @splat(.{});
    writes = .{};
    for (&lanes) |*l| l.* = .{ .gap_ns = l.gap_ns, .max_inflight = l.max_inflight };
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

/// The type of every message in `o`, in order.
fn messageTypes(buf: []u8, o: *const pg.Out) []const u8 {
    const b = o.list.items;
    var n: usize = 0;
    var at: usize = 0;
    while (at < b.len) : (n += 1) {
        buf[n] = b[at];
        at += 1 + @as(usize, @intCast(std.mem.readInt(i32, b[at + 1 ..][0..4], .big)));
    }
    return buf[0..n];
}

test "a read group flushes after every unit but the last, so each unit's results come back as it completes; a write group does not" {
    const stmts = [_]Stmt{ .comments_list_set, .user_by_email, .article_by_slug, .comments_list_set, .article_by_slug };
    var reqs: [stmts.len]Query = undefined;
    for (&reqs, stmts) |*r, s| r.* = .{ .stmt = s, .params = @splat(Param{ .int = 1 }) };
    for (&reqs) |*r| enqueue(r);
    var buf: [32]u8 = undefined;

    const g = buildRead(.shared).?;
    defer freeGroup(g);
    var o: pg.Out = .{};
    defer o.deinit();
    encodeGroup(&o, g);
    // The login's lookup, then MEGA: Bind and Execute each.
    try testing.expectEqual(2, g.nunits);
    try testing.expectEqualStrings("BEHBES", messageTypes(&buf, &o));

    const cg = buildRead(.comments).?;
    defer freeGroup(cg);
    var co: pg.Out = .{};
    defer co.deinit();
    encodeGroup(&co, cg);
    try testing.expectEqual(1, cg.nunits);
    try testing.expectEqualStrings("BES", messageTypes(&buf, &co));

    var favs = [_]Query{ .{ .stmt = .favorite }, .{ .stmt = .follow }, .{ .stmt = .favorite } };
    for (&favs) |*r| {
        r.params = @splat(Param{ .int = 1 });
        enqueue(r);
    }
    const w = buildWrite().?;
    defer freeGroup(w);
    var wo: pg.Out = .{};
    defer wo.deinit();
    encodeGroup(&wo, w);
    try testing.expectEqualStrings("BEBES", messageTypes(&buf, &wo));
}

test "tag, profile and user reads run as units of their own ahead of MEGA, each answered before MEGA runs" {
    clearQueuesForTest();
    defer clearQueuesForTest();
    const stmts = [_]Stmt{ .article_by_slug, .tags, .profile, .user_by_id, .article_by_id, .tags, .profile };
    var reqs: [stmts.len]Query = undefined;
    for (&reqs, stmts) |*r, s| r.* = .{ .stmt = s, .params = @splat(Param{ .int = 1 }) };
    for (&reqs) |*r| enqueue(r);

    const g = buildRead(.shared).?;
    defer freeGroup(g);
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    for (g.units[0..g.nunits]) |*u| {
        try got.print(testing.allocator, "{s} {s}", .{ @tagName(u.kind), @tagName(u.stmt) });
        for (g.unitMembers(u)) |r| try got.print(testing.allocator, " {d}", .{(@intFromPtr(r) - @intFromPtr(&reqs)) / @sizeOf(Query)});
        try got.append(testing.allocator, '\n');
    }
    try testing.expectEqualStrings(
        \\broadcast tags 1 5
        \\batched profile 2 6
        \\single user_by_id 3
        \\mega article_by_slug 0 4
        \\
    , got.items);

    var o: pg.Out = .{};
    defer o.deinit();
    encodeGroup(&o, g);
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("BEHBEHBEHBES", messageTypes(&buf, &o));
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

fn readAt(r: *Query, s: Stmt, at: u64) void {
    r.* = .{ .stmt = s };
    enqueueAt(r, at);
}

const feed_q = &reads[@intFromEnum(Stmt.list_feed)];
const ms = std.time.ns_per_ms;

test "feeds drain on their own lane and gap while the shared lane keeps the drain gap" {
    clearQueuesForTest();
    defer clearQueuesForTest();
    // The shared lane last drained at 100 ms and the feed lane a shared gap later, so the shared drain is due first.
    const feed_last = 100 * ms + gap_ns;
    for (&lanes) |*l| l.last_ns = 100 * ms;
    lane(.feed).last_ns = feed_last;
    var feed: Query = undefined;
    var list: Query = undefined;
    var article: Query = undefined;
    readAt(&feed, .list_feed, 101 * ms);
    readAt(&list, .list_all, 110 * ms);
    readAt(&article, .article_by_slug, 111 * ms);

    now_ns = 115 * ms;
    try testing.expectEqual(100 * ms + gap_ns, readsDue(.shared).?);
    try testing.expectEqual(feed_last + feed_gap_ns, readsDue(.feed).?);
    try testing.expectEqual(null, dueRead());
    try testing.expectEqual(100 * ms + gap_ns, pump().?);

    now_ns = 100 * ms + gap_ns;
    const g = dueRead().?;
    defer freeGroup(g);
    try testing.expectEqual(1, g.nunits);
    try testing.expectEqual(.mega, g.units[0].kind);
    try testing.expectEqual(2, g.nmembers);
    try testing.expectEqual(&feed, feed_q.head.?);
    try testing.expectEqual(100 * ms + gap_ns, lane(.shared).last_ns);
    try testing.expectEqual(feed_last, lane(.feed).last_ns);

    // Only the feed is left: the next drain is the feed lane's, when its gap ends, and nothing drains before then.
    try testing.expect(readsQueued());
    try testing.expectEqual(null, dueRead());
    try testing.expectEqual(feed_last + feed_gap_ns, pump().?);
    now_ns = feed_last + feed_gap_ns - 1;
    try testing.expectEqual(null, dueRead());

    now_ns = feed_last + feed_gap_ns;
    const g2 = dueRead().?;
    defer freeGroup(g2);
    try testing.expectEqual(1, g2.nmembers);
    try testing.expectEqual(&feed, g2.members[0]);
    try testing.expectEqual(.single, g2.units[0].kind);
    try testing.expectEqual(.list_feed, g2.units[0].stmt);
    try testing.expectEqual(feed_last + feed_gap_ns, lane(.feed).last_ns);
    try testing.expect(!readsQueued());
    try testing.expectEqual(null, pump());
}

test "a lane at its in-flight cap starts no drain, full queue or not, until one finishes, and other lanes still drain" {
    const cases = [_]struct { l: LaneId, s: Stmt, other: Stmt }{
        .{ .l = .feed, .s = .list_feed, .other = .list_all },
        .{ .l = .comments, .s = .comments_list_set, .other = .list_all },
        .{ .l = .shared, .s = .list_all, .other = .list_feed },
    };
    const most = @max(feed_max_inflight, @max(comments_max_inflight, max_inflight));
    for (cases) |t| {
        clearQueuesForTest();
        defer clearQueuesForTest();
        const ln = lane(t.l);
        var cs: [most]Conn = undefined;
        for (&cs) |*c| c.* = .{ .fd = -1, .index = 0, .write = false, .rbuf = &.{} };
        var qs: [most + 2]Query = undefined;
        now_ns = 1000 * ms;
        // Fill the lane to its cap, one drain per gap, each with the read queued since the one before.
        for (0..ln.max_inflight) |i| {
            readAt(&qs[i], t.s, now_ns);
            now_ns += ln.gap_ns;
            const g = dueRead().?;
            try testing.expectEqual(1, g.nmembers);
            try testing.expectEqual(&qs[i], g.members[0]);
            cs[i].pushGroup(g);
        }
        // At the cap a read waits past the gap and the window, and no clock is set for it.
        readAt(&qs[ln.max_inflight], t.s, now_ns);
        now_ns += ln.gap_ns;
        try testing.expectEqual(null, readsDue(t.l));
        try testing.expectEqual(null, dueRead());
        try testing.expectEqual(null, pump());
        try testing.expect(readsQueued());
        // Another lane's read drains at once.
        var o: Query = undefined;
        readAt(&o, t.other, now_ns - window_ns);
        const og = dueRead().?;
        defer freeGroup(og);
        try testing.expectEqual(&o, og.members[0]);
        try testing.expectEqual(t.other, og.members[0].stmt);
        // One drain's ReadyForQuery frees its slot: the next drain is due and takes every read that waited.
        readAt(&qs[ln.max_inflight + 1], t.s, now_ns);
        now_ns += window_ns;
        message(&cs[0], 'Z', "I");
        try testing.expect(readsDue(t.l).? <= now_ns);
        const g = dueRead().?;
        defer freeGroup(g);
        try testing.expectEqual(2, g.nmembers);
        try testing.expectEqual(&qs[ln.max_inflight], g.members[0]);
        try testing.expectEqual(&qs[ln.max_inflight + 1], g.members[1]);
        try testing.expect(!readsQueued());
        for (cs[1..ln.max_inflight]) |*c| message(c, 'Z', "I");
    }
}

test "two or more feeds ride one MEGA execution of feeds alone, a feed retry runs alone beside them" {
    clearQueuesForTest();
    defer clearQueuesForTest();
    var retry: Query = undefined;
    var f1: Query = undefined;
    var f2: Query = undefined;
    var list: Query = undefined;
    readAt(&retry, .list_feed, 1000 * ms);
    retry.solo = true;
    readAt(&f1, .list_feed, 1000 * ms);
    readAt(&f2, .list_feed, 1000 * ms);
    readAt(&list, .list_all, 1000 * ms);
    now_ns = 1005 * ms;

    const feeds = dueRead().?;
    defer freeGroup(feeds);
    try testing.expectEqual(3, feeds.nmembers);
    try testing.expectEqual(2, feeds.nunits);
    try testing.expectEqual(.single, feeds.units[0].kind);
    try testing.expectEqual(&retry, feeds.unitMembers(&feeds.units[0])[0]);
    try testing.expectEqual(.mega, feeds.units[1].kind);
    try testing.expectEqual(2, feeds.units[1].n);
    for (feeds.members[0..feeds.nmembers]) |r| try testing.expectEqual(.list_feed, r.stmt);

    const shared = dueRead().?;
    defer freeGroup(shared);
    try testing.expectEqual(1, shared.nmembers);
    try testing.expectEqual(&list, shared.members[0]);
    try testing.expectEqual(.single, shared.units[0].kind);
    try testing.expect(!readsQueued());
}

test "a full lane drains at once and the other lanes keep their gaps" {
    clearQueuesForTest();
    defer clearQueuesForTest();
    for (&lanes) |*l| l.last_ns = 100 * ms;
    const qs = try testing.allocator.alloc(Query, max_members);
    defer testing.allocator.free(qs);
    now_ns = 101 * ms;
    for (qs) |*r| readAt(r, .list_feed, now_ns);
    var o: Query = undefined;
    readAt(&o, .list_all, now_ns);
    try testing.expect(full(.feed));
    try testing.expect(!full(.shared));
    try testing.expectEqual(now_ns, readsDue(.feed).?);
    try testing.expectEqual(100 * ms + gap_ns, readsDue(.shared).?);

    const feeds = dueRead().?;
    defer freeGroup(feeds);
    try testing.expectEqual(max_members, feeds.nmembers);
    try testing.expectEqual(null, feed_q.head);
    try testing.expectEqual(null, dueRead());
    try testing.expect(readsQueued());
    try testing.expectEqual(now_ns, lane(.feed).last_ns);
    try testing.expectEqual(100 * ms, lane(.shared).last_ns);
    try testing.expectEqual(100 * ms + gap_ns, pump().?);
}

test "a lane at its cap starts no drain with its queue full, and the next drain takes the whole queue" {
    clearQueuesForTest();
    defer clearQueuesForTest();
    const ln = lane(.feed);
    var cs: [feed_max_inflight]Conn = undefined;
    for (&cs) |*c| c.* = .{ .fd = -1, .index = 0, .write = false, .rbuf = &.{} };
    var first: [feed_max_inflight]Query = undefined;
    now_ns = 1000 * ms;
    for (0..ln.max_inflight) |i| {
        readAt(&first[i], .list_feed, now_ns);
        now_ns += ln.gap_ns;
        cs[i].pushGroup(dueRead().?);
    }
    const qs = try testing.allocator.alloc(Query, max_members);
    defer testing.allocator.free(qs);
    for (qs) |*r| readAt(r, .list_feed, now_ns);
    try testing.expect(full(.feed));
    try testing.expectEqual(null, readsDue(.feed));
    try testing.expectEqual(null, dueRead());
    message(&cs[0], 'Z', "I");
    const g = dueRead().?;
    defer freeGroup(g);
    try testing.expectEqual(max_members, g.nmembers);
    try testing.expect(!readsQueued());
    for (cs[1..]) |*c| message(c, 'Z', "I");
}
