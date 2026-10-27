//! bcrypt cost 10 on hasher threads, off the event loop, in batches of interleaved lanes (branch bcrypt's engine in
//! bcrypt/). The same `Job`, `start`, `submit`, `finished` and `done_efd` as the single-lane module it replaced.
//!
//! `prepare` (main calls it before forking; `start` calls it too) runs the engine's self-test, exiting on a
//! mismatch, and its calibration, which picks the kernel and the batch width (`lanes`, 4 to 8) that cost the least
//! CPU per hash on this machine. A hasher thread then waits until `lanes` jobs are queued or the oldest has waited
//! `fill_ns`, and hashes up to `lanes` of them in one kernel call. It waits only while logins overlap: when none
//! arrived to find another queued or hashing within the last `fill_ns`, nobody is coming to fill the batch, so a job
//! goes out at once. A short batch runs the kernel of its own width, which costs nearly as much as a full one, so CPU
//! per hash is lowest when batches fill. Every job is hashed on its own lane with its own password and salt;
//! identical jobs are never merged.
//!
//! Password bytes follow Go's golang.org/x/crypto/bcrypt, the reference: every byte is hashed, embedded NULs
//! included, with the trailing NUL of C bcrypt; only the first 72 bytes affect the result. Callers reject
//! passwords over 72 bytes before hashing (422); a login with a longer password compares on its first 72 bytes,
//! as Go's CompareHashAndPassword does.
const std = @import("std");
const linux = std.os.linux;
const bc = @import("bcrypt/bcrypt.zig");

pub const cost = bc.cost;

/// The longest the oldest queued job waits for its batch to fill. Login latency doesn't count, CPU does
/// (research/decisions.md, "bcrypt goal"); at 250k users a worker process sees about 17 logins a second, so a
/// batch of 5 fills in about 0.3 s. A client that sends one login at a time never overlaps itself, so it doesn't
/// wait at all (conformance, a nearly idle server).
pub const fill_ns = std.time.ns_per_s;

/// The hasher threads' nice value (PGSERVE_HASH_NICE, default 19), so logins and sign-ups yield the CPU to the
/// event loops. Set before `start`.
pub var nice: ?i32 = 19;

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
};

const List = struct {
    lock: std.atomic.Mutex = .unlocked,
    head: ?*Job = null,
    tail: ?*Job = null,
    len: usize = 0,

    fn push(l: *List, j: *Job) void {
        l.acquire();
        l.pushLocked(j);
        l.lock.unlock();
    }

    /// Call with the lock held.
    fn pushLocked(l: *List, j: *Job) void {
        j.next = null;
        if (l.tail) |t| t.next = j else l.head = j;
        l.tail = j;
        l.len += 1;
    }

    /// Call with the lock held.
    fn popLocked(l: *List) ?*Job {
        const j = l.head orelse return null;
        l.head = j.next;
        if (l.head == null) l.tail = null;
        l.len -= 1;
        return j;
    }

    fn takeAll(l: *List) ?*Job {
        l.acquire();
        defer l.lock.unlock();
        const j = l.head;
        l.head = null;
        l.tail = null;
        l.len = 0;
        return j;
    }

    fn acquire(l: *List) void {
        while (!l.lock.tryLock()) std.atomic.spinLoopHint();
    }
};

var engine: bc.Engine = undefined;
var prepared = false;
var todo: List = .{};
var done: List = .{};
/// Under `todo`'s lock: batches being hashed, and when a job last arrived to find another queued or hashing.
var hashing: usize = 0;
var overlap_ns: u64 = 0;
/// Counts submits (not a semaphore, non-blocking): hasher threads poll it and re-check the queue.
var todo_efd: i32 = -1;
/// The event loop reads this eventfd; a completion count arrives here.
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

pub fn start(threads: usize) !void {
    prepare();
    todo_efd = try eventfd(linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
    done_efd = try eventfd(linux.EFD.CLOEXEC);
    for (0..threads) |_| {
        const t = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, worker, .{});
        t.detach();
    }
}

pub fn submit(j: *Job) void {
    j.queued = monoNs();
    todo.acquire();
    if (todo.len > 0 or hashing > 0) overlap_ns = j.queued;
    todo.pushLocked(j);
    todo.lock.unlock();
    signal(todo_efd, 1);
}

/// Finished jobs, oldest first. Call after `done_efd` became readable.
pub fn finished() ?*Job {
    return done.takeAll();
}

fn worker() void {
    // Named so their CPU time can be told apart from the event loop's (/proc/<pid>/task/*/comm).
    _ = linux.prctl(@intFromEnum(linux.PR.SET_NAME), @intFromPtr("bcrypt"), 0, 0, 0);
    // Nice, not SCHED_IDLE: `List.lock` spins, and a SCHED_IDLE holder could keep a worker spinning on it.
    if (nice) |n| _ = linux.syscall3(.setpriority, 0, @intCast(linux.gettid()), @bitCast(@as(isize, n))); // PRIO_PROCESS
    var buf: [bc.max_lanes]*Job = undefined;
    while (true) {
        const batch = collect(&buf);
        run(batch);
        // Before the results go out, so a client's next login can't see its own batch as company.
        todo.acquire();
        hashing -= 1;
        todo.lock.unlock();
        for (batch) |j| done.push(j);
        signal(done_efd, batch.len);
    }
}

/// Blocks until a batch is due and takes it: `engine.lanes` jobs, or fewer once the oldest has waited `fill_ns`
/// or no job has arrived to find company for `fill_ns`.
fn collect(buf: *[bc.max_lanes]*Job) []*Job {
    while (true) {
        todo.acquire();
        var wait_ms: i32 = -1;
        if (todo.head) |h| {
            const now = monoNs();
            const due = @min(h.queued, overlap_ns) + fill_ns;
            if (todo.len >= engine.lanes or now >= due) {
                var n: usize = 0;
                while (n < engine.lanes) : (n += 1) buf[n] = todo.popLocked() orelse break;
                hashing += 1;
                const more = todo.len > 0;
                todo.lock.unlock();
                // Another thread takes the rest.
                if (more) signal(todo_efd, 1);
                return buf[0..n];
            }
            wait_ms = @intCast((due - now + std.time.ns_per_ms - 1) / std.time.ns_per_ms);
        }
        todo.lock.unlock();
        var pfd = [1]linux.pollfd{.{ .fd = todo_efd, .events = linux.POLL.IN, .revents = 0 }};
        _ = linux.poll(&pfd, 1, wait_ms);
        var count: u64 = 0;
        _ = linux.read(todo_efd, std.mem.asBytes(&count), 8);
    }
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
    if (done_efd == -1) try start(2);
}

fn waitFor(want: usize) !void {
    var got: usize = 0;
    while (got < want) {
        var n: u64 = 0;
        var pfd = [1]linux.pollfd{.{ .fd = done_efd, .events = linux.POLL.IN, .revents = 0 }};
        if (linux.poll(&pfd, 1, 30_000) == 0) return error.Timeout;
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
