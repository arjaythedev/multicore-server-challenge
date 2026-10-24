//! bcrypt at cost 10, off the shards: a hash takes ~50 ms of a core, which
//! would stall every connection of the shard that ran it. Shards queue
//! jobs; worker threads take them; the request's fiber waits on the job's
//! word (a futex the worker wakes).
//!
//! The modular crypt format, `$2a$10$<salt 22><hash 31>`: `$2a$`, `$2b$`
//! and `$2y$` are one algorithm for the passwords accepted here (72 bytes at
//! most, so none wraps), and new hashes are written `$2b$`.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const linux = std.os.linux;
const Io = std.Io;
const bcrypt = std.crypto.pwhash.bcrypt;

pub const cost = 10;
pub const hash_bytes = 60;
/// bcrypt reads at most 72 bytes; longer passwords are refused (422).
pub const password_bytes_max = 72;

const alphabet = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".*;
const encoder: std.base64.Base64Encoder = .init(alphabet, null);
const decoder: std.base64.Base64Decoder = .init(alphabet, null);
const salt_text_bytes = 22;
const digest_text_bytes = 31;

/// Whether `password` matches `hash` (`$2?$NN$...`); false for a hash this
/// cannot read.
pub fn verify(stored: []const u8, password: []const u8) bool {
    if (password.len > password_bytes_max) return false;
    if (stored.len != hash_bytes or stored[0] != '$' or stored[1] != '2' or stored[3] != '$' or stored[6] != '$') {
        return false;
    }
    switch (stored[2]) {
        'a', 'b', 'y' => {},
        else => return false,
    }
    const rounds_log = std.fmt.parseInt(u6, stored[4..6], 10) catch return false;
    if (rounds_log < 4 or rounds_log > 31) return false;
    var salt: [bcrypt.salt_length]u8 = undefined;
    decoder.decode(&salt, stored[7..][0..salt_text_bytes]) catch return false;
    const digest = bcrypt.bcrypt(password, &salt, .{
        .rounds_log = rounds_log,
        .silently_truncate_password = true,
    });
    var expected: [digest_text_bytes]u8 = undefined;
    _ = encoder.encode(&expected, &digest);
    const given = stored[7 + salt_text_bytes ..][0..digest_text_bytes];
    return std.crypto.timing_safe.eql([digest_text_bytes]u8, given.*, expected);
}

// ---------- bcrypt, several hashes in lockstep ----------
//
// A Blowfish round is a chain of four dependent table loads: one hash
// leaves most of a core idle. Lanes of independent hashes, interleaved
// round by round, fill it. The algorithm is std's (its initial state is
// std's `State`), every round kept.

pub const lanes_max = 4;
const State = bcrypt.State;
const digest_bytes = 23;

fn word(data: []const u8, at: *usize) u32 {
    var value: u32 = 0;
    inline for (0..4) |_| {
        if (at.* >= data.len) at.* = 0;
        value = value << 8 | data[at.*];
        at.* += 1;
    }
    return value;
}

inline fn half_round(state: *const State, i: u32, j: u32, comptime n: usize) u32 {
    var r = state.sboxes[0][@as(u8, @truncate(j >> 24))];
    r +%= state.sboxes[1][@as(u8, @truncate(j >> 16))];
    r ^= state.sboxes[2][@as(u8, @truncate(j >> 8))];
    r +%= state.sboxes[3][@as(u8, @truncate(j))];
    return i ^ r ^ state.subkeys[n];
}

/// The sixteen rounds of four lanes, as x86-64 assembly: each lane's halves
/// in registers of their own (left r8d-r11d, right r12d-r15d), the states
/// at %rdi, a lane's round at a time through four scratch registers that
/// renaming overlaps across the lanes. 13 instructions a round, the high
/// bytes read through %ah and %dh; the compiler's spills and copies made
/// 15. A hash in 10% fewer instructions, 13% less time with both
/// hyperthreads of a core hashing (34 ms to 29-30), 6% less of a worker's
/// CPU at 50k users on 4 CPUs, where bcrypt is a sixth of the CPUs.
const rounds4 = rounds4: {
    @setEvalBranchQuota(100_000);
    const left = [4][]const u8{ "r8d", "r9d", "r10d", "r11d" };
    const right = [4][]const u8{ "r12d", "r13d", "r14d", "r15d" };
    var text: []const u8 = "";
    for (1..17) |round| {
        // Odd rounds feed the right halves from the left, even the left from the right.
        const from, const to = if (round % 2 == 1) .{ left, right } else .{ right, left };
        for (0..4) |lane| {
            const boxes = lane * @sizeOf(State) + @offsetOf(State, "sboxes");
            const subkey = lane * @sizeOf(State) + @offsetOf(State, "subkeys") + 4 * round;
            text = text ++ std.fmt.comptimePrint(
                \\movl %%{s}, %%eax
                \\movl %%eax, %%edx
                \\shrl $16, %%edx
                \\movzx %%dh, %%ecx
                \\movl {d}(%%rdi,%%rcx,4), %%esi
                \\movzx %%dl, %%ecx
                \\addl {d}(%%rdi,%%rcx,4), %%esi
                \\movzx %%ah, %%ecx
                \\xorl {d}(%%rdi,%%rcx,4), %%esi
                \\movzx %%al, %%ecx
                \\addl {d}(%%rdi,%%rcx,4), %%esi
                \\xorl {d}(%%rdi), %%esi
                \\xorl %%esi, %%{s}
                \\
            , .{ from[lane], boxes, boxes + 1024, boxes + 2048, boxes + 3072, subkey, to[lane] });
        }
    }
    break :rounds4 text;
};

comptime {
    // The S-boxes as rounds4 indexes them: four of 256 words, one after another.
    assert(@sizeOf(@FieldType(State, "sboxes")) == 4 * 256 * 4);
    assert(@sizeOf(@FieldType(State, "subkeys")) == 18 * 4);
}

inline fn encipher4_rounds(states: *[4]State, l: *[4]u32, r: *[4]u32) void {
    var l0, var l1, var l2, var l3 = l.*;
    var r0, var r1, var r2, var r3 = r.*;
    asm volatile (rounds4
        : [l0] "={r8}" (l0),
          [l1] "={r9}" (l1),
          [l2] "={r10}" (l2),
          [l3] "={r11}" (l3),
          [r0] "={r12}" (r0),
          [r1] "={r13}" (r1),
          [r2] "={r14}" (r2),
          [r3] "={r15}" (r3),
        : [states] "{rdi}" (states),
          [l0_in] "{r8}" (l0),
          [l1_in] "{r9}" (l1),
          [l2_in] "{r10}" (l2),
          [l3_in] "{r11}" (l3),
          [r0_in] "{r12}" (r0),
          [r1_in] "{r13}" (r1),
          [r2_in] "{r14}" (r2),
          [r3_in] "{r15}" (r3),
        : .{ .rax = true, .rcx = true, .rdx = true, .rsi = true, .cc = true, .memory = true });
    l.* = .{ l0, l1, l2, l3 };
    r.* = .{ r0, r1, r2, r3 };
}

/// Blowfish's encryption of each lane's halves under each lane's state.
inline fn encipher(comptime lanes: usize, states: *[lanes]State, l: *[lanes]u32, r: *[lanes]u32) void {
    inline for (0..lanes) |x| l[x] ^= states[x].subkeys[0];
    if (lanes == 4 and builtin.cpu.arch == .x86_64) {
        encipher4_rounds(states, l, r);
    } else {
        comptime var i = 1;
        inline while (i < 16) : (i += 2) {
            inline for (0..lanes) |x| r[x] = half_round(&states[x], r[x], l[x], i);
            inline for (0..lanes) |x| l[x] = half_round(&states[x], l[x], r[x], i + 1);
        }
    }
    inline for (0..lanes) |x| {
        const left = l[x];
        l[x] = r[x] ^ states[x].subkeys[17];
        r[x] = left;
    }
}

/// The key schedule: each lane's subkeys keyed by `keys`, then every
/// subkey and S-box entry replaced by the cipher's output, its input
/// first mixed with `salts` (bcrypt's `expand`) or not (`expand0`).
fn expand(comptime lanes: usize, states: *[lanes]State, salts: ?*const [lanes][]const u8, keys: *const [lanes][]const u8) void {
    var key_at: [lanes]usize = @splat(0);
    for (0..18) |n| {
        inline for (0..lanes) |x| states[x].subkeys[n] ^= word(keys[x], &key_at[x]);
    }
    var l: [lanes]u32 = @splat(0);
    var r: [lanes]u32 = @splat(0);
    var salt_at: [lanes]usize = @splat(0);
    var n: usize = 0;
    while (n < 18) : (n += 2) {
        if (salts) |salt| inline for (0..lanes) |x| {
            l[x] ^= word(salt[x], &salt_at[x]);
            r[x] ^= word(salt[x], &salt_at[x]);
        };
        encipher(lanes, states, &l, &r);
        inline for (0..lanes) |x| {
            states[x].subkeys[n] = l[x];
            states[x].subkeys[n + 1] = r[x];
        }
    }
    for (0..4) |box| {
        var k: usize = 0;
        while (k < 256) : (k += 2) {
            if (salts) |salt| inline for (0..lanes) |x| {
                l[x] ^= word(salt[x], &salt_at[x]);
                r[x] ^= word(salt[x], &salt_at[x]);
            };
            encipher(lanes, states, &l, &r);
            inline for (0..lanes) |x| {
                states[x].sboxes[box][k] = l[x];
                states[x].sboxes[box][k + 1] = r[x];
            }
        }
    }
}

/// bcrypt's digest of each lane's password (72 bytes at most) and salt,
/// at 2^rounds_log rounds: what std's `bcrypt` gives, lanes at a time.
fn digests(
    comptime lanes: usize,
    passwords: *const [lanes][]const u8,
    salts: *const [lanes][bcrypt.salt_length]u8,
    rounds_log: u6,
) [lanes][digest_bytes]u8 {
    var buffers: [lanes][password_bytes_max + 1]u8 = undefined;
    var keys: [lanes][]const u8 = undefined;
    var salt_slices: [lanes][]const u8 = undefined;
    inline for (0..lanes) |x| {
        const length = passwords[x].len;
        assert(length <= password_bytes_max);
        @memcpy(buffers[x][0..length], passwords[x]);
        buffers[x][length] = 0;
        keys[x] = buffers[x][0 .. length + 1];
        salt_slices[x] = &salts[x];
    }
    var states: [lanes]State = @splat(.{});
    expand(lanes, &states, &salt_slices, &keys);
    const rounds = @as(u64, 1) << rounds_log;
    for (0..rounds) |_| {
        expand(lanes, &states, null, &keys);
        expand(lanes, &states, null, &salt_slices);
    }
    var data: [lanes][6]u32 = @splat(.{ 0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274 });
    for (0..64) |_| {
        var pair: usize = 0;
        while (pair < 6) : (pair += 2) {
            var l: [lanes]u32 = undefined;
            var r: [lanes]u32 = undefined;
            inline for (0..lanes) |x| {
                l[x] = data[x][pair];
                r[x] = data[x][pair + 1];
            }
            encipher(lanes, &states, &l, &r);
            inline for (0..lanes) |x| {
                data[x][pair] = l[x];
                data[x][pair + 1] = r[x];
            }
        }
    }
    var out: [lanes][digest_bytes]u8 = undefined;
    inline for (0..lanes) |x| {
        var bytes: [24]u8 = undefined;
        for (data[x], 0..) |value, index| std.mem.writeInt(u32, bytes[index * 4 ..][0..4], value, .big);
        out[x] = bytes[0..digest_bytes].*;
        std.crypto.secureZero(u8, &buffers[x]);
    }
    return out;
}

test "password: lanes give std's digests" {
    const long: [password_bytes_max]u8 = @splat('a');
    const passwords = [lanes_max][]const u8{ "password123", "", &long, "x" };
    var salts: [lanes_max][bcrypt.salt_length]u8 = undefined;
    for (&salts, 0..) |*salt, index| salt.* = @splat(@intCast(index * 17 + 3));
    const together = digests(lanes_max, &passwords, &salts, 4);
    for (passwords, salts, together) |password, salt, digest| {
        const alone = bcrypt.bcrypt(password, &salt, .{ .rounds_log = 4, .silently_truncate_password = true });
        try std.testing.expectEqualSlices(u8, &alone, &digest);
    }
}

/// `$2b$10$...` of `password` with a fresh random salt.
pub fn hash(password: []const u8, out: *[hash_bytes]u8) void {
    assert(password.len <= password_bytes_max);
    var salt: [bcrypt.salt_length]u8 = undefined;
    const got = linux.getrandom(&salt, salt.len, 0);
    assert(got == salt.len);
    const digest = bcrypt.bcrypt(password, &salt, .{
        .rounds_log = cost,
        .silently_truncate_password = true,
    });
    @memcpy(out[0..7], "$2b$10$");
    _ = encoder.encode(out[7..][0..salt_text_bytes], &salt);
    _ = encoder.encode(out[7 + salt_text_bytes ..][0..digest_text_bytes], &digest);
}

/// How long a worker holding fewer than `lanes_max` jobs waits for more,
/// from the oldest's arrival: lanes hash 2.4 times as many (21 ms a hash
/// at four, 51 alone), and logins are a thousandth of the requests.
const gather_ns = 150 * std.time.ns_per_ms;

pub const Job = struct {
    kind: enum { verify, hash },
    password: []const u8,
    /// To verify against (`verify`).
    stored: []const u8 = "",
    /// The answer: whether it matched (`verify`), the new hash (`hash`).
    matched: bool = false,
    hashed: [hash_bytes]u8 = undefined,
    /// What the worker hashes: from `stored` (`verify`) or drawn (`hash`).
    salt: [bcrypt.salt_length]u8 = undefined,
    rounds_log: u6 = cost,
    /// A stored hash this cannot read: it matches nothing, and no worker
    /// sees the job.
    unreadable: bool = false,
    queued_ns: i128 = 0,
    /// 0 until a worker has done it; the requesting fiber waits on it.
    done: std.atomic.Value(u32) = .init(0),
    next: ?*Job = null,

    /// The salt and cost to hash with, on the requesting fiber.
    fn prepare(job: *Job) void {
        assert(job.password.len <= password_bytes_max);
        switch (job.kind) {
            .hash => {
                const got = linux.getrandom(&job.salt, job.salt.len, 0);
                assert(got == job.salt.len);
                job.rounds_log = cost;
            },
            .verify => {
                const stored = job.stored;
                job.unreadable = true;
                if (stored.len != hash_bytes or stored[0] != '$' or stored[1] != '2') return;
                if (stored[3] != '$' or stored[6] != '$') return;
                switch (stored[2]) {
                    'a', 'b', 'y' => {},
                    else => return,
                }
                const rounds_log = std.fmt.parseInt(u6, stored[4..6], 10) catch return;
                if (rounds_log < 4 or rounds_log > 31) return;
                decoder.decode(&job.salt, stored[7..][0..salt_text_bytes]) catch return;
                job.rounds_log = rounds_log;
                job.unreadable = false;
            },
        }
    }

    /// The answer from the job's digest.
    fn finish(job: *Job, digest: *const [digest_bytes]u8) void {
        var text: [digest_text_bytes]u8 = undefined;
        _ = encoder.encode(&text, digest);
        switch (job.kind) {
            .verify => {
                const given = job.stored[7 + salt_text_bytes ..][0..digest_text_bytes];
                job.matched = std.crypto.timing_safe.eql([digest_text_bytes]u8, given.*, text);
            },
            .hash => {
                @memcpy(job.hashed[0..7], "$2b$10$");
                _ = encoder.encode(job.hashed[7..][0..salt_text_bytes], &job.salt);
                @memcpy(job.hashed[7 + salt_text_bytes ..][0..digest_text_bytes], &text);
            },
        }
    }
};

fn now_ns() i128 {
    var spec: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &spec);
    return @as(i128, spec.sec) * std.time.ns_per_s + spec.nsec;
}

/// The jobs' digests, lanes at a time (all of one cost).
fn run_lanes(jobs: []const *Job) void {
    assert(jobs.len >= 1 and jobs.len <= lanes_max);
    switch (jobs.len) {
        inline 1...lanes_max => |lanes| {
            var passwords: [lanes][]const u8 = undefined;
            var salts: [lanes][bcrypt.salt_length]u8 = undefined;
            inline for (0..lanes) |x| {
                assert(jobs[x].rounds_log == jobs[0].rounds_log);
                passwords[x] = jobs[x].password;
                salts[x] = jobs[x].salt;
            }
            const results = digests(lanes, &passwords, &salts, jobs[0].rounds_log);
            inline for (0..lanes) |x| jobs[x].finish(&results[x]);
        },
        else => unreachable,
    }
}

/// Jobs from every shard, taken by the workers in order.
pub const Pool = struct {
    lock: std.atomic.Value(u32) = .init(0),
    head: ?*Job = null,
    tail: ?*Job = null,
    /// Bumped per job queued: idle workers wait on it.
    queued: std.atomic.Value(u32) = .init(0),
    gatherer: std.atomic.Value(u32) = .init(0),

    pub fn start(pool: *Pool, workers: u32) !void {
        assert(workers > 0);
        for (0..workers) |_| {
            const thread = try std.Thread.spawn(.{}, work, .{pool});
            thread.detach();
        }
    }

    /// Queue the job and wait for it, on the calling fiber.
    pub fn run(pool: *Pool, io: Io, job: *Job) void {
        assert(job.done.load(.monotonic) == 0);
        job.prepare();
        if (job.unreadable) return; // matches nothing (`matched` false)
        job.queued_ns = now_ns();
        pool.acquire();
        if (pool.tail) |tail| tail.next = job else pool.head = job;
        pool.tail = job;
        _ = pool.queued.fetchAdd(1, .release);
        pool.release();
        _ = linux.futex_3arg(&pool.queued.raw, .{ .cmd = .WAKE, .private = true }, 1);
        // Bounded only to say so: a wait ends when the worker is done.
        for (0..std.math.maxInt(u64)) |_| {
            if (job.done.load(.acquire) != 0) return;
            io.futexWaitUncancelable(u32, &job.done.raw, 0);
        } else unreachable;
    }

    fn work(pool: *Pool) void {
        var jobs: [lanes_max]*Job = undefined;
        // Bounded only to say so: workers run for good.
        for (0..std.math.maxInt(u64)) |_| {
            // One worker gathers at a time, so the others' batches are not
            // split from its: it hashes once its batch is full or old enough,
            // and the next gathers meanwhile.
            pool.gatherer_acquire();
            const count = pool.gather(&jobs);
            pool.gatherer_release();
            run_lanes(jobs[0..count]);
            for (jobs[0..count]) |job| {
                job.done.store(1, .release);
                _ = linux.futex_3arg(&job.done.raw, .{ .cmd = .WAKE, .private = true }, 1);
            }
        } else unreachable;
    }

    /// Jobs of one cost, `lanes_max` of them, or fewer once the oldest has
    /// waited `gather_ns`.
    fn gather(pool: *Pool, jobs: *[lanes_max]*Job) usize {
        var count: usize = 0;
        // Bounded only to say so: it returns once a job has come.
        for (0..std.math.maxInt(u64)) |_| {
            const seen = pool.queued.load(.acquire);
            const rounds_log: ?u6 = if (count > 0) jobs[0].rounds_log else null;
            while (count < lanes_max) {
                jobs[count] = pool.take(rounds_log orelse null) orelse break;
                count += 1;
            }
            if (count == lanes_max) return count;
            var wait: linux.timespec = .{ .sec = 1, .nsec = 0 };
            if (count > 0) {
                const left = jobs[0].queued_ns + gather_ns - now_ns();
                if (left <= 0) return count;
                wait = .{ .sec = 0, .nsec = @intCast(left) };
            }
            _ = linux.futex_4arg(&pool.queued.raw, .{ .cmd = .WAIT, .private = true }, seen, &wait);
        } else unreachable;
    }

    /// The oldest job, of the given cost when one is given (a later job of
    /// another cost waits for a batch of its own).
    fn take(pool: *Pool, rounds_log: ?u6) ?*Job {
        pool.acquire();
        defer pool.release();
        var previous: ?*Job = null;
        var cursor = pool.head;
        while (cursor) |job| : ({
            previous = job;
            cursor = job.next;
        }) {
            if (rounds_log) |rounds| if (job.rounds_log != rounds) continue;
            if (previous) |before| before.next = job.next else pool.head = job.next;
            if (pool.tail == job) pool.tail = previous;
            job.next = null;
            return job;
        }
        return null;
    }

    /// The gatherer's place: 0 free, 1 held; workers waiting sleep on it.
    fn gatherer_acquire(pool: *Pool) void {
        // Bounded only to say so: the holder releases once it has a batch.
        for (0..std.math.maxInt(u64)) |_| {
            if (pool.gatherer.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) return;
            _ = linux.futex_4arg(&pool.gatherer.raw, .{ .cmd = .WAIT, .private = true }, 1, null);
        } else unreachable;
    }

    fn gatherer_release(pool: *Pool) void {
        pool.gatherer.store(0, .release);
        _ = linux.futex_3arg(&pool.gatherer.raw, .{ .cmd = .WAKE, .private = true }, 1);
    }

    /// A spin lock: what it guards is a pointer or two.
    fn acquire(pool: *Pool) void {
        // Bounded only to say so: a holder releases within instructions.
        for (0..std.math.maxInt(u64)) |_| {
            if (pool.lock.cmpxchgWeak(0, 1, .acquire, .monotonic) == null) return;
            std.atomic.spinLoopHint();
        } else unreachable;
    }

    fn release(pool: *Pool) void {
        pool.lock.store(0, .release);
    }
};

test "password: the seed's $2a$ hash, and our own" {
    const seeded = "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq";
    try std.testing.expect(verify(seeded, "password123"));
    try std.testing.expect(!verify(seeded, "password124"));
    var out: [hash_bytes]u8 = undefined;
    hash("secret", &out);
    try std.testing.expect(std.mem.startsWith(u8, &out, "$2b$10$"));
    try std.testing.expect(verify(&out, "secret"));
    try std.testing.expect(!verify(&out, "secreT"));
}
