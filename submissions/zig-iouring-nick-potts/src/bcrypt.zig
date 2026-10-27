//! bcrypt cost 10 on hasher threads, off the event loop, in batches of interleaved lanes (branch bcrypt's engine in
//! bcrypt/). The event loop calls `submit`, `pump` every iteration, and `finished` once `done_efd` is readable.
//!
//! `prepare` (main calls it before forking; `start` calls it too) runs the engine's self-test, exiting on a
//! mismatch, and its calibration, which picks the kernel and the batch width (`lanes`, 4 to 8) that cost the least
//! CPU per hash on this machine. A batch goes out once `lanes` jobs are queued or the oldest has waited `fill_ns`, and
//! a hasher thread hashes up to `lanes` of them in one kernel call. It waits only while logins overlap: when none
//! arrived to find another queued or hashing within the last `fill_ns`, nobody is coming to fill the batch, so a job
//! goes out at once. A short batch runs the kernel of its own width, which costs nearly as much as a full one, so CPU
//! per hash is lowest when batches fill. Every job is hashed on its own lane with its own password and salt;
//! identical jobs are never merged.
//!
//! The hasher threads run at SCHED_IDLE (or the lowest nice they can reach), so hashing takes only CPU nothing else
//! wants. Under saturation that can be none, and an unprivileged thread can never raise its priority again
//! (RLIMIT_NICE is 0), so one more hasher, the watchdog, stays at normal priority and takes every job left unfinished
//! `overdue_ns` after it was queued, whether it is still queued or held by a hasher that gets no CPU. Whichever
//! finishes a job first answers it; the other result is dropped.
//!
//! No thread ever waits on another. The event loop alone owns the queue and decides every batch; each hasher has
//! one slot, which the event loop fills with copies of a batch's inputs and the thread hands back with the results,
//! through one atomic state. A hasher sleeps on that state (futex) while it has nothing to hash. So a hasher
//! preempted at any point, however long, holds up only its own batch, and the watchdog takes that over.
//!
//! Password bytes follow Go's golang.org/x/crypto/bcrypt, the reference: every byte is hashed, embedded NULs
//! included, with the trailing NUL of C bcrypt; only the first 72 bytes affect the result. Callers reject
//! passwords over 72 bytes before hashing (422); a login with a longer password compares on its first 72 bytes,
//! as Go's CompareHashAndPassword does.
const std = @import("std");
const linux = std.os.linux;
const bc = @import("bcrypt/bcrypt.zig");
const shed = @import("shed.zig");
const Flags = @import("flags.zig").Flags;

pub const cost = bc.cost;

/// The longest the oldest queued job waits for its batch to fill. Login latency doesn't count, CPU does
/// (research/decisions.md, "bcrypt goal"); at 250k users a worker process sees about 17 logins a second, so a
/// batch of 5 fills in about 0.3 s. A client that sends one login at a time never overlaps itself, so it doesn't
/// wait at all (conformance, a nearly idle server).
pub const fill_ns = std.time.ns_per_s;

/// The bytes of a password that affect its hash.
const key_bytes = 72;
const hash_len = 60;

pub const Kind = enum { hash, verify };

pub const Job = struct {
    kind: Kind,
    password: []const u8,
    /// The stored hash to verify against.
    stored: []const u8 = "",
    /// Result of `hash`: a 60-byte "$2a$10$..." string.
    out: [60]u8 = undefined,
    /// Result of `verify`.
    ok: bool = false,
    owner: *anyopaque,
    next: ?*Job = null,
    /// When `submit` queued it, CLOCK_MONOTONIC ns.
    queued: u64 = 0,
    /// The event loop's number for it while it waits for its result; 0 once answered. A hasher's result counts only
    /// while this still matches the number the hasher was given.
    seq: u64 = 0,
    /// Handed to the watchdog already.
    watched: bool = false,
};

const idle: u32 = 0;
const ready: u32 = 1;
const finished_state: u32 = 2;

/// One hasher thread's batch. The event loop fills it while `idle` and sets `ready`; the thread hashes it and sets
/// `finished`; the event loop takes the results and sets `idle` again. Nothing else is shared.
const Slot = struct {
    state: std.atomic.Value(u32) = .init(idle),
    n: usize = 0,
    /// Each job as the event loop handed it over, and the number it had then.
    from: [bc.max_lanes]*Job = undefined,
    seq: [bc.max_lanes]u64 = undefined,
    /// The thread's own copies: the job's inputs, which outlive a request answered meanwhile by the other hasher,
    /// and its results.
    copy: [bc.max_lanes]Job = undefined,
    password: [bc.max_lanes][key_bytes]u8 = undefined,
    stored: [bc.max_lanes][hash_len]u8 = undefined,

    fn fill(s: *Slot, jobs: []const *Job) void {
        for (jobs, 0..) |j, i| {
            s.from[i] = j;
            s.seq[i] = j.seq;
            const pw = j.password[0..@min(j.password.len, key_bytes)];
            @memcpy(s.password[i][0..pw.len], pw);
            var stored: []const u8 = "";
            if (j.stored.len == hash_len) {
                s.stored[i] = j.stored[0..hash_len].*;
                stored = &s.stored[i];
            }
            s.copy[i] = .{ .kind = j.kind, .password = s.password[i][0..pw.len], .stored = stored, .owner = j.owner };
        }
        s.n = jobs.len;
        s.state.store(ready, .release);
        _ = linux.futex_3arg(&s.state.raw, .{ .cmd = .WAKE, .private = true }, 1);
    }

    /// Hashes the batch it was given (on its thread).
    fn work(s: *Slot) void {
        var batch: [bc.max_lanes]*Job = undefined;
        for (0..s.n) |i| batch[i] = &s.copy[i];
        run(batch[0..s.n]);
        s.state.store(finished_state, .release);
    }
};

/// The event loop's side: the queue, the batching decisions, and every slot. The last slot is the watchdog's.
const Pool = struct {
    lanes: usize,
    /// How long after it was queued a job still unfinished goes to the watchdog: the fill window, which a job may
    /// spend waiting by design, plus two batches' CPU time, the batch a free hasher may be finishing and the job's own.
    /// A job later than that is not batching or queueing behind work; its hasher is getting no CPU.
    overdue_ns: u64,
    slots: []Slot,
    head: ?*Job = null,
    tail: ?*Job = null,
    len: usize = 0,
    /// When a job last arrived to find another queued or hashing.
    overlap_ns: u64 = 0,
    seq: u64 = 0,

    fn submit(p: *Pool, j: *Job, now: u64) void {
        j.queued = now;
        if (p.len > 0 or p.hashing()) p.overlap_ns = now;
        p.seq += 1;
        j.seq = p.seq;
        j.watched = false;
        j.next = null;
        if (p.tail) |t| t.next = j else p.head = j;
        p.tail = j;
        p.len += 1;
    }

    fn hashing(p: *const Pool) bool {
        for (p.slots) |*s| if (s.state.load(.monotonic) != idle) return true;
        return false;
    }

    fn pop(p: *Pool) *Job {
        const j = p.head.?;
        p.head = j.next;
        if (p.head == null) p.tail = null;
        p.len -= 1;
        return j;
    }

    /// When the queued jobs' batch is due: at once with `lanes` queued, else once the oldest has waited `fill_ns` or
    /// no job has arrived to find company for `fill_ns`.
    fn due(p: *const Pool) u64 {
        const h = p.head.?;
        return if (p.len >= p.lanes) 0 else @min(h.queued, p.overlap_ns) + fill_ns;
    }

    /// Hands out every batch that is due to a free hasher, and every overdue job to the watchdog if it is free.
    /// Returns when it must be called again (monotonic ns) if that is still ahead; a slot that frees up wakes the
    /// event loop through `done_efd`.
    fn pump(p: *Pool, now: u64) ?u64 {
        var next: ?u64 = null;
        const hashers = p.slots[0 .. p.slots.len - 1];
        while (p.head != null) {
            const d = p.due();
            if (d > now) {
                next = d;
                break;
            }
            const s = for (hashers) |*s| {
                if (s.state.load(.acquire) == idle) break s;
            } else break;
            var batch: [bc.max_lanes]*Job = undefined;
            const n = @min(p.len, p.lanes);
            for (batch[0..n]) |*b| b.* = p.pop();
            s.fill(batch[0..n]);
        }
        const watchdog = &p.slots[p.slots.len - 1];
        if (watchdog.state.load(.acquire) != idle) return next;
        // The overdue jobs, oldest first: those held by hashers, then the queue's, which are all younger.
        var batch: [bc.max_lanes]*Job = undefined;
        var n: usize = 0;
        var later: ?u64 = null;
        for (hashers) |*s| {
            if (s.state.load(.acquire) != ready) continue;
            for (s.from[0..s.n], s.seq[0..s.n]) |j, seq| {
                if (j.seq != seq or j.watched) continue;
                const at = j.queued + p.overdue_ns;
                if (at > now) {
                    later = @min(later orelse at, at);
                    continue;
                }
                // Keep the `lanes` oldest, in order.
                if (n == p.lanes) {
                    if (batch[n - 1].queued <= j.queued) continue;
                    n -= 1;
                }
                var k = n;
                n += 1;
                while (k > 0 and batch[k - 1].queued > j.queued) : (k -= 1) batch[k] = batch[k - 1];
                batch[k] = j;
            }
        }
        while (n < p.lanes) {
            const h = p.head orelse break;
            if (h.queued + p.overdue_ns > now) break;
            batch[n] = p.pop();
            n += 1;
        }
        if (p.head) |h| later = @min(later orelse h.queued + p.overdue_ns, h.queued + p.overdue_ns);
        if (n > 0) {
            for (batch[0..n]) |j| j.watched = true;
            watchdog.fill(batch[0..n]);
            return next;
        }
        if (later) |t| next = @min(next orelse t, t);
        return next;
    }

    /// Answers the jobs whose results are back and frees their slots; returns them, linked through `next`.
    fn finished(p: *Pool) ?*Job {
        var head: ?*Job = null;
        var tail: ?*Job = null;
        for (p.slots) |*s| {
            if (s.state.load(.acquire) != finished_state) continue;
            for (s.from[0..s.n], s.seq[0..s.n], s.copy[0..s.n]) |j, seq, *c| {
                // Answered already by the other hasher, and maybe queued again since under a new number. The job
                // lives in a request, and requests are reused, never freed, so reading its number is safe.
                if (j.seq != seq) continue;
                j.seq = 0;
                j.out = c.out;
                j.ok = c.ok;
                j.next = null;
                if (tail) |t| t.next = j else head = j;
                tail = j;
            }
            s.state.store(idle, .release);
        }
        return head;
    }
};

var engine: bc.Engine = undefined;
var prepared = false;
var pool: Pool = .{ .lanes = 1, .overdue_ns = 0, .slots = &.{} };
/// The event loop reads this eventfd; a hasher writes it each time it finishes a batch.
pub var done_efd: i32 = -1;

/// Self-test, then calibration. Exits on a self-test mismatch (a wrong kernel would lock users out). Below
/// x86-64-v3 it runs the portable kernel, which costs more per hash but still batches. main.zig calls it once
/// before forking the workers, which spares each worker its own run (about 3.4 CPU-seconds on a Ryzen 9 9950X) and
/// gives them all the same pick; `start` calls it if nobody has.
pub fn prepare() void {
    if (prepared) return;
    var failure: bc.Failure = .{};
    engine = bc.init(8, &failure) catch |e| {
        std.debug.print("conduit: bcrypt self-test failed: {s} ({s} width {d} case {d})\n", .{
            @errorName(e), failure.variant, failure.width, failure.case,
        });
        linux.exit_group(1);
    };
    prepared = true;
    // Under `zig build test` any stderr output reads as a failed test.
    if (@import("builtin").is_test) return;
    std.debug.print("conduit[{d}]: bcrypt {s} in batches of {d}, {d:.2} CPU-ms per hash\n", .{
        linux.getpid(), engine.variant.name, engine.lanes, engine.cpu_ms_per_hash,
    });
}

/// Starts `threads` hashers at idle priority and the watchdog at normal priority.
pub fn start(comptime F: Flags, threads: usize) !void {
    prepare();
    done_efd = try eventfd(linux.EFD.CLOEXEC);
    const batch_ns: u64 = @intFromFloat(engine.cpu_ms_per_hash * @as(f64, @floatFromInt(engine.lanes)) * std.time.ns_per_ms);
    pool = .{
        .lanes = engine.lanes,
        .overdue_ns = fill_ns + 2 * batch_ns,
        .slots = try std.heap.page_allocator.alloc(Slot, threads + 1),
    };
    for (pool.slots, 0..) |*s, i| {
        s.* = .{};
        const t = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, hasher, .{ F, s, i < threads });
        t.detach();
    }
}

pub fn submit(j: *Job) void {
    pool.submit(j, monoNs());
}

/// Hands out what is due; returns when to call it again (monotonic ns), if that is still ahead. Call it every event
/// loop iteration.
pub fn pump(now: u64) ?u64 {
    return pool.pump(now);
}

/// Finished jobs. Call after `done_efd` became readable.
pub fn finished() ?*Job {
    return pool.finished();
}

fn hasher(comptime F: Flags, s: *Slot, low: bool) void {
    // Named so their CPU time can be told apart from the event loop's (/proc/<pid>/task/*/comm).
    const name = if (low) "bcrypt" else "bcrypt-watch";
    _ = linux.prctl(@intFromEnum(linux.PR.SET_NAME), @intFromPtr(name.ptr), 0, 0, 0);
    // An idle-priority hasher's CPU counts as idle to the overload trigger (shed.zig).
    if (low and lowestPriority() and F.shed) shed.addHasher(linux.gettid());
    while (true) {
        while (true) {
            const st = s.state.load(.acquire);
            if (st == ready) break;
            _ = linux.futex_4arg(&s.state.raw, .{ .cmd = .WAIT, .private = true }, st, null);
        }
        s.work();
        signal(done_efd, 1);
    }
}

/// SCHED_IDLE for the calling thread, or else the highest nice it may set; true if SCHED_IDLE.
fn lowestPriority() bool {
    const param: linux.sched_param = .{ .priority = 0 };
    if (linux.errno(linux.sched_setscheduler(0, .{ .mode = .IDLE }, &param)) == .SUCCESS) return true;
    // PRIO_PROCESS with 0 is the calling thread on Linux.
    _ = linux.syscall3(.setpriority, 0, 0, 19);
    return false;
}

/// Hashes a batch: one kernel call per cost among its jobs (all cost 10 in practice). A verify job whose stored
/// hash doesn't parse fails without hashing.
fn run(batch: []*Job) void {
    var settings: [bc.max_lanes]bc.Setting = undefined;
    var pending: [bc.max_lanes]bool = undefined;
    for (batch, 0..) |j, i| {
        pending[i] = true;
        switch (j.kind) {
            .hash => {
                var salt: [16]u8 = undefined;
                randomBytes(&salt);
                settings[i] = bc.settingFromSalt(salt, cost);
            },
            .verify => {
                const s = if (j.stored.len == 60) bc.parseSetting(j.stored) else null;
                if (s) |st| settings[i] = st else {
                    j.ok = false;
                    pending[i] = false;
                }
            },
        }
    }
    for (0..batch.len) |first| {
        if (!pending[first]) continue;
        var jobs: [bc.max_lanes]bc.Job = undefined;
        var which: [bc.max_lanes]usize = undefined;
        var n: usize = 0;
        for (first..batch.len) |i| {
            if (!pending[i] or settings[i].cost != settings[first].cost) continue;
            jobs[n] = .{ .password = batch[i].password, .setting = &settings[i] };
            which[n] = i;
            pending[i] = false;
            n += 1;
        }
        var out: [bc.max_lanes]bc.Hash = undefined;
        engine.hash(jobs[0..n], out[0..n]) catch unreachable; // one cost per call
        for (which[0..n], out[0..n]) |i, *h| {
            const j = batch[i];
            switch (j.kind) {
                .hash => j.out = h.*,
                .verify => j.ok = bc.matches(h, j.stored),
            }
        }
    }
}

fn eventfd(flags: u32) !i32 {
    const rc = linux.eventfd(0, flags);
    if (linux.errno(rc) != .SUCCESS) return error.Eventfd;
    return @intCast(rc);
}

fn signal(fd: i32, n: u64) void {
    _ = linux.write(fd, std.mem.asBytes(&n), 8);
}

fn monoNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn randomBytes(buf: []u8) void {
    var off: usize = 0;
    while (off < buf.len) {
        const rc = linux.getrandom(buf[off..].ptr, buf.len - off, 0);
        if (linux.errno(rc) != .SUCCESS) {
            std.debug.print("conduit: getrandom failed\n", .{});
            linux.exit_group(1);
        }
        off += rc;
    }
}

// The tests go through the queue as the server does: submit, wait on done_efd, take `finished`.

var test_owner: u8 = 0;

fn startOnce() !void {
    // With `shed`, so the hashers record their tids for the priority test.
    if (done_efd == -1) try start(.{ .shed = true }, 2);
}

/// Runs the event loop's side until `want` jobs are answered.
fn waitFor(want: usize) !void {
    var got: usize = 0;
    const give_up = monoNs() + 30 * std.time.ns_per_s;
    while (got < want) {
        const now = monoNs();
        if (now > give_up) return error.Timeout;
        const wake = pump(now) orelse give_up;
        var pfd = [1]linux.pollfd{.{ .fd = done_efd, .events = linux.POLL.IN, .revents = 0 }};
        if (linux.poll(&pfd, 1, @intCast((wake -| now) / std.time.ns_per_ms + 1)) == 0) continue;
        var n: u64 = 0;
        _ = linux.read(done_efd, std.mem.asBytes(&n), 8);
        var j = finished();
        while (j) |x| : (j = x.next) got += 1;
    }
}

test "hashes verify, through the queue" {
    try startOnce();
    const long: [72]u8 = @splat('x');
    const pws = [_][]const u8{ "password123", "a\x00b", &long, "" };
    var hs: [pws.len]Job = undefined;
    for (&hs, pws) |*j, p| {
        j.* = .{ .kind = .hash, .password = p, .owner = &test_owner };
        submit(j);
    }
    try waitFor(hs.len);
    for (hs) |j| try std.testing.expectEqualStrings("$2a$10$", j.out[0..7]);
    // Right and wrong passwords; embedded NULs count; bytes past 72 don't; a stored hash that doesn't parse fails.
    const cases = [_]struct { pw: []const u8, stored: []const u8, ok: bool }{
        .{ .pw = "password123", .stored = &hs[0].out, .ok = true },
        .{ .pw = "password124", .stored = &hs[0].out, .ok = false },
        .{ .pw = "a\x00b", .stored = &hs[1].out, .ok = true },
        .{ .pw = "a", .stored = &hs[1].out, .ok = false },
        .{ .pw = &(long ++ "yyy".*), .stored = &hs[2].out, .ok = true },
        .{ .pw = "", .stored = &hs[3].out, .ok = true },
        .{ .pw = "password123", .stored = hs[0].out[0..59], .ok = false },
        .{ .pw = "password123", .stored = "", .ok = false },
    };
    var vs: [cases.len]Job = undefined;
    for (&vs, cases) |*j, c| {
        j.* = .{ .kind = .verify, .password = c.pw, .stored = c.stored, .owner = &test_owner };
        submit(j);
    }
    try waitFor(vs.len);
    for (vs, cases) |j, c| try std.testing.expectEqual(c.ok, j.ok);
}

test "reference vectors in one batch of mixed costs" {
    try startOnce();
    // Openwall's crypt_blowfish vector, and hashes golang.org/x/crypto/bcrypt generated (embedded NULs included).
    const cases = [_][2][]const u8{
        .{ "U*U", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW" },
        .{ "password123", "$2a$10$7V25sfqO.LTv4sYF8LvvneyHTb0fHIBd3Q.5DKGTN2yUNyvVO0pri" },
        .{ "a\x00b\x00", "$2a$04$LdYgD3Typm6StFYO.T0t1uGyTIB3HMRJgY3cmxI0O.bosH66VcEJ6" },
        .{ "password123", "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq" },
    };
    var vs: [cases.len]Job = undefined;
    for (&vs, cases) |*j, c| {
        j.* = .{ .kind = .verify, .password = c[0], .stored = c[1], .owner = &test_owner };
        submit(j);
    }
    try waitFor(vs.len);
    for (vs) |j| try std.testing.expect(j.ok);
}

const cost4 = [2][]const u8{ "a\x00b\x00", "$2a$04$LdYgD3Typm6StFYO.T0t1uGyTIB3HMRJgY3cmxI0O.bosH66VcEJ6" };

test "a login with nobody else around goes out at once" {
    try startOnce();
    // Any overlap from the tests before ages out.
    var ts: linux.timespec = .{ .sec = 1, .nsec = 100 * std.time.ns_per_ms };
    _ = linux.nanosleep(&ts, null);
    var j: Job = .{ .kind = .verify, .password = cost4[0], .stored = cost4[1], .owner = &test_owner };
    const t0 = monoNs();
    submit(&j);
    try waitFor(1);
    try std.testing.expect(j.ok);
    try std.testing.expect(monoNs() - t0 < fill_ns / 2);
}

test "logins that overlap wait for company" {
    try startOnce();
    var js: [3]Job = undefined;
    const t0 = monoNs();
    for (&js) |*j| {
        j.* = .{ .kind = .verify, .password = cost4[0], .stored = cost4[1], .owner = &test_owner };
        submit(j);
    }
    try waitFor(js.len);
    // Fewer than `lanes` (4 at least): the second and third found company and waited the window out.
    try std.testing.expect(monoNs() - t0 >= fill_ns);
    for (js) |j| try std.testing.expect(j.ok);
}

test "a job a hasher holds without getting a CPU goes to the watchdog once overdue, and is answered once" {
    prepare();
    const ms = std.time.ns_per_ms;
    // No threads: this test plays both hashers, and the idle one never runs until the end.
    var slots: [2]Slot = .{ .{}, .{} };
    var p: Pool = .{ .lanes = 4, .overdue_ns = fill_ns + 400 * ms, .slots = &slots };
    var j: Job = .{ .kind = .verify, .password = cost4[0], .stored = cost4[1], .owner = &test_owner };
    const t0 = 1000 * std.time.ns_per_s;
    p.submit(&j, t0);
    // Nobody else around: it goes out at once, to the idle-priority hasher.
    try std.testing.expectEqual(t0 + p.overdue_ns, p.pump(t0));
    try std.testing.expectEqual(ready, slots[0].state.load(.monotonic));
    try std.testing.expectEqual(idle, slots[1].state.load(.monotonic));
    // Not overdue yet: the watchdog waits.
    try std.testing.expectEqual(t0 + p.overdue_ns, p.pump(t0 + p.overdue_ns - 1));
    try std.testing.expectEqual(idle, slots[1].state.load(.monotonic));
    // Overdue: the watchdog takes it, though the idle hasher still holds it.
    try std.testing.expectEqual(null, p.pump(t0 + p.overdue_ns));
    try std.testing.expectEqual(ready, slots[1].state.load(.monotonic));
    try std.testing.expectEqual(&j, slots[1].from[0]);
    slots[1].work();
    const got = p.finished().?;
    try std.testing.expectEqual(&j, got);
    try std.testing.expect(got.ok);
    try std.testing.expectEqual(null, got.next);
    // It is not handed to the watchdog again, and the idle hasher's late result is dropped.
    try std.testing.expectEqual(null, p.pump(t0 + 2 * p.overdue_ns));
    try std.testing.expectEqual(idle, slots[1].state.load(.monotonic));
    slots[0].work();
    try std.testing.expectEqual(null, p.finished());
    try std.testing.expectEqual(idle, slots[0].state.load(.monotonic));
}

test "overdue jobs still queued go to the watchdog while every hasher is held up" {
    prepare();
    const ms = std.time.ns_per_ms;
    var slots: [2]Slot = .{ .{}, .{} };
    var p: Pool = .{ .lanes = 2, .overdue_ns = fill_ns + 400 * ms, .slots = &slots };
    var js: [3]Job = undefined;
    const t0 = 1000 * std.time.ns_per_s;
    for (&js, 0..) |*j, i| {
        j.* = .{ .kind = .verify, .password = cost4[0], .stored = cost4[1], .owner = &test_owner };
        p.submit(j, t0 + i * ms);
    }
    // A full batch of two goes to the hasher; the third waits for it.
    _ = p.pump(t0 + 2 * ms);
    try std.testing.expectEqual(1, p.len);
    // Overdue: the watchdog takes the two oldest it can, those the hasher holds, then the queued one.
    _ = p.pump(t0 + p.overdue_ns + 2 * ms);
    try std.testing.expectEqual(2, slots[1].n);
    try std.testing.expectEqual(&js[0], slots[1].from[0]);
    try std.testing.expectEqual(&js[1], slots[1].from[1]);
    slots[1].work();
    try std.testing.expectEqual(2, count(p.finished()));
    _ = p.pump(t0 + p.overdue_ns + 3 * ms);
    try std.testing.expectEqual(0, p.len);
    try std.testing.expectEqual(&js[2], slots[1].from[0]);
    slots[1].work();
    try std.testing.expectEqual(1, count(p.finished()));
    slots[0].work();
    try std.testing.expectEqual(0, count(p.finished()));
}

fn count(list: ?*Job) usize {
    var n: usize = 0;
    var j = list;
    while (j) |x| : (j = x.next) n += 1;
    return n;
}

test "hasher threads run at idle priority, the watchdog at normal priority, and only the idle ones count as idle" {
    try startOnce();
    var dir: [64]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&dir, "/proc/{d}/task", .{linux.getpid()}, 0);
    const fd: i32 = @intCast(linux.open(path, .{ .DIRECTORY = true }, 0));
    defer _ = linux.close(fd);
    var buf: [8192]u8 = undefined;
    var idle_threads: usize = 0;
    var watch_threads: usize = 0;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (n == 0 or linux.errno(n) != .SUCCESS) break;
        var off: usize = 0;
        while (off < n) {
            const d: *align(1) linux.dirent64 = @ptrCast(&buf[off]);
            off += d.reclen;
            const tid = std.fmt.parseInt(i32, std.mem.sliceTo(@as([*:0]u8, @ptrCast(&d.name)), 0), 10) catch continue;
            var cbuf: [64]u8 = undefined;
            const cpath = try std.fmt.bufPrintSentinel(&cbuf, "/proc/{d}/task/{d}/comm", .{ linux.getpid(), tid }, 0);
            const cfd: i32 = @intCast(linux.open(cpath, .{}, 0));
            var comm: [32]u8 = undefined;
            const len = linux.read(cfd, &comm, comm.len);
            _ = linux.close(cfd);
            const policy = linux.syscall1(.sched_getscheduler, @as(u32, @bitCast(tid)));
            const name = std.mem.trimEnd(u8, comm[0..len], "\n");
            var recorded = false;
            for (shed.box.tids[0..shed.box.hashers.load(.monotonic)]) |*t| recorded = recorded or t.load(.monotonic) == tid;
            if (std.mem.eql(u8, name, "bcrypt")) {
                idle_threads += 1;
                try std.testing.expectEqual(@intFromEnum(linux.SCHED.Mode.IDLE), policy);
                try std.testing.expect(recorded);
            } else if (std.mem.eql(u8, name, "bcrypt-watch")) {
                watch_threads += 1;
                try std.testing.expectEqual(@intFromEnum(linux.SCHED.Mode.NORMAL), policy);
                try std.testing.expect(!recorded);
            }
        }
    }
    try std.testing.expectEqual(2, idle_threads);
    try std.testing.expectEqual(1, watch_threads);
}
