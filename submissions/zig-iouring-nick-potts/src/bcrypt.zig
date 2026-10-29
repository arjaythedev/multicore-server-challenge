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
//! `overdue_ns` after it was queued. A batch a hasher still holds past that goes to the watchdog whole. The hasher's
//! kernel saves its state every 16 rounds of the cost loop, and the watchdog carries on from the newest save with the
//! same salts, so it redoes at most 16 of the 1,024 rounds; the hasher's kernel reads a flag once a round and stops.
//! No batch is hashed to the end twice (a hasher that had just finished keeps its answer, and the watchdog's copy is
//! dropped), and every hash is the one a straight run gives. Jobs overdue in the queue go `lanes` at a
//! time, or fewer once the oldest has been overdue for `fill_ns`, since a short batch costs nearly a full one's CPU
//! and the watchdog's CPU is CPU the rest of the box wanted.
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
};

const idle: u32 = 0;
const ready: u32 = 1;
const finished_state: u32 = 2;

/// One hasher thread's batch. The event loop fills it while `idle` and sets `ready`; the thread hashes it and sets
/// `finished`; the event loop takes the results and sets `idle` again. The event loop takes `progress` once the
/// watchdog has the batch; the thread's kernel reads it once a round and stops, leaving `complete` false. Nothing
/// else is shared.
const Slot = struct {
    state: std.atomic.Value(u32) = .init(idle),
    /// The kernel's way through the batch: its newest saved state, and whether it must stop.
    progress: bc.Progress = .{},
    /// Whether the thread hashed the batch to the end; its results count only then.
    complete: bool = false,
    n: usize = 0,
    /// Each job as the event loop handed it over, and the number it had then.
    from: [bc.max_lanes]*Job = undefined,
    seq: [bc.max_lanes]u64 = undefined,
    /// The thread's own copies: the job's inputs, which outlive a request answered meanwhile by the other hasher,
    /// and its results.
    copy: [bc.max_lanes]Job = undefined,
    password: [bc.max_lanes][key_bytes]u8 = undefined,
    stored: [bc.max_lanes][hash_len]u8 = undefined,
    /// What each job is hashed with: the thread picks a fresh salt for a `hash` job, unless the batch carries on from
    /// another slot's progress, which brings that slot's settings.
    settings: [bc.max_lanes]bc.Setting = undefined,

    /// Hands the thread `jobs`, to start from the setting, or from `from` rounds already done if the event loop put
    /// that state and the settings it was made with into this slot.
    fn fill(s: *Slot, jobs: []const *Job, from: u32) void {
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
        s.progress.at.store(bc.Progress.no_stop, .monotonic);
        s.progress.from = from;
        s.state.store(ready, .release);
        _ = linux.futex_3arg(&s.state.raw, .{ .cmd = .WAKE, .private = true }, 1);
    }

    /// Hashes the batch it was given (on its thread), unless it is taken first.
    fn work(s: *Slot) void {
        s.complete = s.hash();
        s.state.store(finished_state, .release);
    }

    fn hash(s: *Slot) bool {
        var batch: [bc.max_lanes]*Job = undefined;
        for (0..s.n) |i| batch[i] = &s.copy[i];
        return run(batch[0..s.n], &s.settings, &s.progress);
    }

    /// When the oldest job of the batch it holds was queued, if any is still waiting on it.
    fn oldest(s: *const Slot) ?u64 {
        var at: ?u64 = null;
        for (s.from[0..s.n], s.seq[0..s.n]) |j, seq| {
            if (j.seq == seq) at = @min(at orelse j.queued, j.queued);
        }
        return at;
    }
};

/// The event loop's side: the queue, the batching decisions, and every slot. The last slot is the watchdog's.
const Pool = struct {
    lanes: usize,
    /// `overdueNs`.
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
            s.fill(batch[0..n], 0);
        }
        const watchdog = &p.slots[p.slots.len - 1];
        if (watchdog.state.load(.acquire) != idle) return next;
        var later: ?u64 = null;
        // A hasher whose batch is overdue is getting no CPU: the watchdog takes the whole batch, the oldest first,
        // and carries on from the hasher's newest saved state. The hasher stops at its next round.
        var stuck: ?*Slot = null;
        var stuck_at: u64 = std.math.maxInt(u64);
        for (hashers) |*s| {
            if (s.state.load(.acquire) != ready or s.progress.taken()) continue;
            const at = (s.oldest() orelse continue) + p.overdue_ns;
            if (at > now) {
                later = @min(later orelse at, at);
            } else if (at < stuck_at) {
                stuck_at = at;
                stuck = s;
            }
        }
        if (stuck) |s| {
            var batch: [bc.max_lanes]*Job = undefined;
            var n: usize = 0;
            for (s.from[0..s.n], s.seq[0..s.n]) |j, seq| {
                if (j.seq != seq) continue;
                batch[n] = j;
                n += 1;
            }
            // The saved state is the lanes of the hasher's whole batch, made with its salts: it goes with them unless
            // a job was answered meanwhile. The half of `saved` it is in is never written again by the hasher.
            var from = s.progress.take();
            if (n < s.n) from = 0;
            if (from != 0) {
                const h = bc.Progress.half(from);
                @memcpy(watchdog.progress.saved[h][0..n], s.progress.saved[h][0..n]);
                watchdog.settings = s.settings;
            }
            watchdog.fill(batch[0..n], from);
            return next;
        }
        // Jobs overdue in the queue, behind hashers that are busy or held up, go `lanes` at a time, or fewer once the
        // oldest has been overdue for `fill_ns`: a short batch costs nearly a full one's CPU, at normal priority.
        var batch: [bc.max_lanes]*Job = undefined;
        var n: usize = 0;
        var q = p.head;
        while (n < p.lanes) : (q = q.?.next) {
            const h = q orelse break;
            if (h.queued + p.overdue_ns > now) break;
            batch[n] = h;
            n += 1;
        }
        if (n > 0 and (n == p.lanes or batch[0].queued + p.overdue_ns + fill_ns <= now)) {
            for (0..n) |_| _ = p.pop();
            watchdog.fill(batch[0..n], 0);
            return next;
        }
        if (n > 0) {
            const t = batch[0].queued + p.overdue_ns + fill_ns;
            later = @min(later orelse t, t);
        }
        if (q) |h| {
            const t = h.queued + p.overdue_ns;
            later = @min(later orelse t, t);
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
            if (s.complete) for (s.from[0..s.n], s.seq[0..s.n], s.copy[0..s.n]) |j, seq, *c| {
                // Answered already (a hasher finished its batch just as the watchdog took it over), and maybe queued
                // again since under a new number. The job lives in a request, and requests are reused, never freed,
                // so reading its number is safe.
                if (j.seq != seq) continue;
                j.seq = 0;
                j.out = c.out;
                j.ok = c.ok;
                j.next = null;
                if (tail) |t| t.next = j else head = j;
                tail = j;
            };
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

/// How long after it was queued a job still unfinished goes to the watchdog: the fill window, which a job may spend
/// waiting by design, plus two of `e`'s batches' CPU time, the batch a free hasher may be finishing and the job's own.
/// A job later than that is not batching or queueing behind work; its hasher is getting no CPU.
pub fn overdueNs(e: bc.Engine) u64 {
    const batch_ns: u64 = @intFromFloat(e.cpu_ms_per_hash * @as(f64, @floatFromInt(e.lanes)) * std.time.ns_per_ms);
    return fill_ns + 2 * batch_ns;
}

/// Starts `threads` hashers at idle priority and the watchdog at normal priority.
pub fn start(comptime F: Flags, threads: usize) !void {
    prepare();
    done_efd = try eventfd(linux.EFD.CLOEXEC);
    pool = .{
        .lanes = engine.lanes,
        .overdue_ns = overdueNs(engine),
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
/// hash doesn't parse fails without hashing. A `hash` job gets a fresh salt in `settings`, unless the batch carries on
/// from `progress.from`, saved with the salts already there. Only a batch hashed in one call saves its progress, which
/// is that call's. False once the progress is taken, with the batch unfinished.
fn run(batch: []*Job, settings: *[bc.max_lanes]bc.Setting, progress: *bc.Progress) bool {
    var pending: [bc.max_lanes]bool = undefined;
    for (batch, 0..) |j, i| {
        pending[i] = true;
        switch (j.kind) {
            .hash => if (progress.from == 0) {
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
    var all: usize = 0;
    for (pending[0..batch.len]) |x| all += @intFromBool(x);
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
        std.debug.assert(progress.from == 0 or n == all);
        progress.save = n == all;
        engine.hash(jobs[0..n], out[0..n], progress) catch |e| switch (e) {
            error.Abandoned => return false,
            error.MixedCost => unreachable, // one cost per call
        };
        for (which[0..n], out[0..n]) |i, *h| {
            const j = batch[i];
            switch (j.kind) {
                .hash => j.out = h.*,
                .verify => j.ok = bc.matches(h, j.stored),
            }
        }
    }
    return true;
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

test "a job a hasher holds without getting a CPU goes to the watchdog once overdue, and the hasher drops it" {
    prepare();
    // No threads: this test plays both hashers, and the idle one never runs until the end.
    var slots: [2]Slot = .{ .{}, .{} };
    var p: Pool = .{ .lanes = 4, .overdue_ns = overdueNs(engine), .slots = &slots };
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
    // Overdue: the watchdog takes the batch, and the idle hasher is told to stop. It has saved nothing, so the
    // watchdog starts from the setting.
    try std.testing.expectEqual(null, p.pump(t0 + p.overdue_ns));
    try std.testing.expectEqual(ready, slots[1].state.load(.monotonic));
    try std.testing.expectEqual(&j, slots[1].from[0]);
    try std.testing.expect(slots[0].progress.taken());
    try std.testing.expectEqual(0, slots[1].progress.from);
    slots[1].work();
    const got = p.finished().?;
    try std.testing.expectEqual(&j, got);
    try std.testing.expect(got.ok);
    try std.testing.expectEqual(null, got.next);
    // It is not taken again. The idle hasher, running at last, stops at its first round and answers nothing.
    try std.testing.expectEqual(null, p.pump(t0 + 2 * p.overdue_ns));
    try std.testing.expectEqual(idle, slots[1].state.load(.monotonic));
    slots[0].work();
    try std.testing.expect(!slots[0].complete);
    try std.testing.expectEqual(null, p.finished());
    try std.testing.expectEqual(idle, slots[0].state.load(.monotonic));
}

test "a hasher that finished its batch just before the watchdog took it keeps its answer" {
    prepare();
    var slots: [2]Slot = .{ .{}, .{} };
    var p: Pool = .{ .lanes = 4, .overdue_ns = overdueNs(engine), .slots = &slots };
    var j: Job = .{ .kind = .verify, .password = cost4[0], .stored = cost4[1], .owner = &test_owner };
    const t0 = 1000 * std.time.ns_per_s;
    p.submit(&j, t0);
    _ = p.pump(t0);
    _ = p.pump(t0 + p.overdue_ns);
    try std.testing.expectEqual(ready, slots[1].state.load(.monotonic));
    // The hasher had passed its last round before it was taken: its result stands, the watchdog's is dropped.
    slots[0].progress.at.store(bc.Progress.no_stop, .monotonic);
    slots[0].work();
    try std.testing.expect(slots[0].complete);
    _ = slots[0].progress.take();
    try std.testing.expectEqual(&j, p.finished().?);
    try std.testing.expect(j.ok);
    slots[1].work();
    try std.testing.expectEqual(null, p.finished());
    try std.testing.expectEqual(idle, slots[0].state.load(.monotonic));
    try std.testing.expectEqual(idle, slots[1].state.load(.monotonic));
}

/// Verify jobs, one per cost in `costs`: the right password on even lanes, a wrong one on odd lanes.
const Logins = struct {
    pw: [bc.max_lanes][12]u8 = undefined,
    stored: [bc.max_lanes]bc.Hash = undefined,
    js: [bc.max_lanes]Job = undefined,

    fn init(l: *Logins, costs: []const u5, seed: u64) !void {
        var prng = std.Random.DefaultPrng.init(seed);
        for (costs, 0..) |c, i| {
            prng.random().bytes(&l.pw[i]);
            const st = bc.newSettingCost(prng.random(), c);
            try bc.hashWith(engine.variant, &.{.{ .password = &l.pw[i], .setting = &st }}, l.stored[i..][0..1], null);
            l.js[i] = .{ .kind = .verify, .password = if (i % 2 == 0) &l.pw[i] else "wrong", .stored = &l.stored[i], .owner = &test_owner };
        }
    }

    fn check(l: *const Logins, n: usize) !void {
        for (l.js[0..n], 0..) |j, i| {
            try std.testing.expectEqual(0, j.seq);
            try std.testing.expectEqual(i % 2 == 0, j.ok);
        }
    }
};

const cost6: [bc.max_lanes]u5 = @splat(6);

/// The rounds done in the newest state a kernel saved before it stopped after `k`.
fn savedBefore(k: u32) u32 {
    return if (k <= bc.save_every) 0 else (k - 1) / bc.save_every * bc.save_every;
}

test "the watchdog carries a hasher's batch on from the newest state the hasher saved, whatever round it got to" {
    prepare();
    const c = 6;
    var l: Logins = .{};
    try l.init(cost6[0..engine.lanes], 0x5701e);
    for (1..1 << c) |k| {
        var slots: [2]Slot = .{ .{}, .{} };
        var p: Pool = .{ .lanes = engine.lanes, .overdue_ns = overdueNs(engine), .slots = &slots };
        const t0 = 1000 * std.time.ns_per_s;
        for (l.js[0..p.lanes]) |*j| p.submit(j, t0);
        _ = p.pump(t0);
        // The hasher gets `k` rounds in, then no CPU until the watchdog has the batch.
        slots[0].progress.stopAfter(@intCast(k));
        try std.testing.expect(!slots[0].hash());
        try std.testing.expectEqual(null, p.pump(t0 + p.overdue_ns));
        try std.testing.expectEqual(ready, slots[1].state.load(.monotonic));
        try std.testing.expectEqual(p.lanes, slots[1].n);
        try std.testing.expectEqual(savedBefore(@intCast(k)), slots[1].progress.from);
        slots[1].work();
        try std.testing.expectEqual(p.lanes, count(p.finished()));
        try l.check(p.lanes);
        // The hasher, running at last, stops at once and answers nothing.
        slots[0].work();
        try std.testing.expect(!slots[0].complete);
        try std.testing.expectEqual(null, p.finished());
    }
}

test "sign-ups the watchdog carries on keep the salts the hasher picked" {
    prepare();
    for ([_]u32{ 17, 512, 1009 }) |k| {
        var slots: [2]Slot = .{ .{}, .{} };
        var p: Pool = .{ .lanes = engine.lanes, .overdue_ns = overdueNs(engine), .slots = &slots };
        var js: [bc.max_lanes]Job = undefined;
        var pws: [bc.max_lanes][3]u8 = undefined;
        const t0 = 1000 * std.time.ns_per_s;
        // One login in the batch, at the same cost, so it is still one kernel call.
        for (js[0..p.lanes], 0..) |*j, i| {
            pws[i] = .{ 'p', 'w', '0' + @as(u8, @intCast(i)) };
            j.* = if (i == 0)
                .{ .kind = .verify, .password = "password123", .stored = bc.known[6].hash, .owner = &test_owner }
            else
                .{ .kind = .hash, .password = &pws[i], .owner = &test_owner };
            p.submit(j, t0);
        }
        _ = p.pump(t0);
        slots[0].progress.stopAfter(k);
        try std.testing.expect(!slots[0].hash());
        const salts = slots[0].settings;
        _ = p.pump(t0 + p.overdue_ns);
        try std.testing.expectEqual(savedBefore(k), slots[1].progress.from);
        slots[1].work();
        try std.testing.expectEqual(p.lanes, count(p.finished()));
        try std.testing.expect(js[0].ok);
        for (js[1..p.lanes], salts[1..p.lanes], 1..) |j, st, i| {
            try std.testing.expectEqualStrings(&st.prefix, j.out[0..29]);
            var straight: [1]bc.Hash = undefined;
            try bc.hashWith(engine.variant, &.{.{ .password = &pws[i], .setting = &st }}, &straight, null);
            try std.testing.expectEqualStrings(&straight[0], &j.out);
        }
    }
}

test "the watchdog starts from the setting when the hasher's saved state is not the whole batch's" {
    prepare();
    const t0 = 1000 * std.time.ns_per_s;
    {
        // A job answered meanwhile: the batch the watchdog takes is not the one the state was saved for.
        var l: Logins = .{};
        try l.init(cost6[0..engine.lanes], 0xa5);
        var slots: [2]Slot = .{ .{}, .{} };
        var p: Pool = .{ .lanes = engine.lanes, .overdue_ns = overdueNs(engine), .slots = &slots };
        for (l.js[0..p.lanes]) |*j| p.submit(j, t0);
        _ = p.pump(t0);
        slots[0].progress.stopAfter(40);
        try std.testing.expect(!slots[0].hash());
        try std.testing.expectEqual(32, @as(u32, @truncate(slots[0].progress.at.load(.monotonic))));
        l.js[1].seq = 0;
        _ = p.pump(t0 + p.overdue_ns);
        try std.testing.expectEqual(p.lanes - 1, slots[1].n);
        try std.testing.expectEqual(0, slots[1].progress.from);
        slots[1].work();
        try std.testing.expectEqual(p.lanes - 1, count(p.finished()));
        try l.check(p.lanes);
    }
    {
        // Two costs: two kernel calls, and neither saves.
        var l: Logins = .{};
        try l.init(&.{ 4, 6, 4, 6 }, 0xa6);
        var slots: [2]Slot = .{ .{}, .{} };
        var p: Pool = .{ .lanes = 4, .overdue_ns = overdueNs(engine), .slots = &slots };
        for (l.js[0..4]) |*j| p.submit(j, t0);
        _ = p.pump(t0);
        slots[0].progress.stopAfter(40);
        try std.testing.expect(!slots[0].hash());
        _ = p.pump(t0 + p.overdue_ns);
        try std.testing.expectEqual(4, slots[1].n);
        try std.testing.expectEqual(0, slots[1].progress.from);
        slots[1].work();
        try std.testing.expectEqual(4, count(p.finished()));
        try l.check(4);
    }
}

test "overdue jobs still queued go to the watchdog `lanes` at a time, or fewer once overdue for `fill_ns`" {
    prepare();
    const ms = std.time.ns_per_ms;
    var slots: [2]Slot = .{ .{}, .{} };
    var p: Pool = .{ .lanes = 2, .overdue_ns = overdueNs(engine), .slots = &slots };
    var js: [5]Job = undefined;
    const t0 = 1000 * std.time.ns_per_s;
    for (&js, 0..) |*j, i| {
        j.* = .{ .kind = .verify, .password = cost4[0], .stored = cost4[1], .owner = &test_owner };
        p.submit(j, t0 + i * ms);
    }
    // A full batch of two goes to the hasher; three wait for it, and it never runs.
    _ = p.pump(t0 + 4 * ms);
    try std.testing.expectEqual(3, p.len);
    try std.testing.expectEqual(ready, slots[0].state.load(.monotonic));
    // The hasher's batch is overdue first: the watchdog takes it whole, and nothing from the queue.
    const over = t0 + p.overdue_ns;
    _ = p.pump(over);
    try std.testing.expectEqual(2, slots[1].n);
    try std.testing.expectEqual(&js[0], slots[1].from[0]);
    try std.testing.expectEqual(&js[1], slots[1].from[1]);
    try std.testing.expectEqual(3, p.len);
    slots[1].work();
    try std.testing.expectEqual(2, count(p.finished()));
    // Two queued jobs overdue: a full batch goes at once.
    try std.testing.expectEqual(null, p.pump(over + 3 * ms));
    try std.testing.expectEqual(1, p.len);
    try std.testing.expectEqual(&js[2], slots[1].from[0]);
    try std.testing.expectEqual(&js[3], slots[1].from[1]);
    slots[1].work();
    try std.testing.expectEqual(2, count(p.finished()));
    // One overdue job alone waits for company until it has been overdue for the fill window.
    try std.testing.expectEqual(over + 4 * ms + fill_ns, p.pump(over + 5 * ms));
    try std.testing.expectEqual(idle, slots[1].state.load(.monotonic));
    try std.testing.expectEqual(null, p.pump(over + 4 * ms + fill_ns));
    try std.testing.expectEqual(0, p.len);
    try std.testing.expectEqual(1, slots[1].n);
    try std.testing.expectEqual(&js[4], slots[1].from[0]);
    slots[1].work();
    try std.testing.expectEqual(1, count(p.finished()));
    // The hasher, held up all along, drops its batch.
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
