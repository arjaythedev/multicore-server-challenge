//! bcrypt at cost 10, off the shards: a hash takes ~50 ms of a core, which
//! would stall every connection of the shard that ran it. Shards queue
//! jobs; worker threads take them; the request's fiber waits on the job's
//! word (a futex the worker wakes).
//!
//! The modular crypt format, `$2a$10$<salt 22><hash 31>`: `$2a$`, `$2b$`
//! and `$2y$` are one algorithm for the passwords accepted here (72 bytes at
//! most, so none wraps), and new hashes are written `$2b$`.

const std = @import("std");
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

pub const Job = struct {
    kind: enum { verify, hash },
    password: []const u8,
    /// To verify against (`verify`).
    stored: []const u8 = "",
    /// The answer: whether it matched (`verify`), the new hash (`hash`).
    matched: bool = false,
    hashed: [hash_bytes]u8 = undefined,
    /// 0 until a worker has done it; the requesting fiber waits on it.
    done: std.atomic.Value(u32) = .init(0),
    next: ?*Job = null,
};

/// Jobs from every shard, taken by the workers in order.
pub const Pool = struct {
    lock: std.atomic.Value(u32) = .init(0),
    head: ?*Job = null,
    tail: ?*Job = null,
    /// Bumped per job queued: idle workers wait on it.
    queued: std.atomic.Value(u32) = .init(0),

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
        // Bounded only to say so: workers run for good.
        for (0..std.math.maxInt(u64)) |_| {
            const seen = pool.queued.load(.acquire);
            const job = pool.take() orelse {
                _ = linux.futex_4arg(&pool.queued.raw, .{ .cmd = .WAIT, .private = true }, seen, null);
                continue;
            };
            switch (job.kind) {
                .verify => job.matched = verify(job.stored, job.password),
                .hash => hash(job.password, &job.hashed),
            }
            job.done.store(1, .release);
            _ = linux.futex_3arg(&job.done.raw, .{ .cmd = .WAKE, .private = true }, 1);
        } else unreachable;
    }

    fn take(pool: *Pool) ?*Job {
        pool.acquire();
        defer pool.release();
        const job = pool.head orelse return null;
        pool.head = job.next;
        if (pool.head == null) pool.tail = null;
        job.next = null;
        return job;
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
