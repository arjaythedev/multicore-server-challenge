const std = @import("std");
const c = std.c;
const events = @import("events.zig");
const bcrypt = std.crypto.pwhash.bcrypt;

pub const capacity = @import("build_options").bcrypt_jobs;
pub const worker_count = @import("build_options").bcrypt_workers;
pub const Job = struct {
    mode: enum { hash, verify } = .hash,
    password: [72]u8 = @splat(0),
    password_len: usize = 0,
    hash: [60:0]u8 = @splat(0),
    salt: [16]u8 = undefined,
    ok: bool = false,
};

fn verify(hash: *const [60:0]u8, password: []const u8) bool {
    // Zig 0.17 compares the entire encoded string against a freshly rendered $2b$.
    // Go's corrected $2a$ hashes use the same calculation for our <=72-byte inputs.
    // Normalize only this version marker; still perform bcrypt for every attempt.
    if (!std.mem.startsWith(u8, hash, "$2a$10$") and !std.mem.startsWith(u8, hash, "$2b$10$")) return false;
    var normalized = hash.*;
    normalized[2] = 'b';
    bcrypt.strVerify(normalized[0..60], password, .{ .silently_truncate_password = false }) catch return false;
    return true;
}

pub const Pool = struct {
    io: std.Io = undefined,
    pipe: [2]c_int = .{ -1, -1 },
    mutex: std.Io.Mutex = .init,
    available: std.Io.Condition = .init,
    threads: [worker_count]?std.Thread = @splat(null),
    pending: [capacity]*Job = undefined,
    pending_count: usize = 0,
    completed: [capacity]*Job = undefined,
    completed_count: usize = 0,
    outstanding: usize = 0,
    stopping: bool = false,

    // The pool's address must remain stable after this call.
    pub fn start(self: *Pool, io: std.Io) !void {
        self.io = io;
        if (c.pipe(&self.pipe) < 0) return error.CompletionPipe;
        errdefer self.stop();
        try events.nonblocking(self.pipe[0]);
        try events.nonblocking(self.pipe[1]);
        for (&self.threads) |*thread| thread.* = try std.Thread.spawn(.{}, work, .{self});
    }

    pub fn stop(self: *Pool) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.available.broadcast(self.io);
        self.mutex.unlock(self.io);
        for (self.threads) |thread| if (thread) |t| t.join();
        for (self.pipe) |fd| if (fd >= 0) {
            _ = c.close(fd);
        };
    }

    pub fn submit(self: *Pool, job: *Job) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping or self.outstanding == capacity) return false;
        self.pending[self.pending_count] = job;
        self.pending_count += 1;
        self.outstanding += 1;
        self.available.signal(self.io);
        return true;
    }

    pub fn collect(self: *Pool, output: *[capacity]*Job) usize {
        var bytes: [64]u8 = undefined;
        while (true) {
            const n = c.read(self.pipe[0], &bytes, bytes.len);
            if (n > 0) continue;
            if (n < 0 and c.errno(n) == .INTR) continue;
            break;
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const count = self.completed_count;
        @memcpy(output[0..count], self.completed[0..count]);
        self.completed_count = 0;
        self.outstanding -= count;
        return count;
    }

    fn work(self: *Pool) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (self.pending_count == 0 and !self.stopping) self.available.waitUncancelable(self.io, &self.mutex);
            if (self.pending_count == 0) {
                self.mutex.unlock(self.io);
                return;
            }
            const job = self.pending[0];
            self.pending_count -= 1;
            std.mem.copyForwards(*Job, self.pending[0..self.pending_count], self.pending[1 .. self.pending_count + 1]);
            self.mutex.unlock(self.io);
            const password = job.password[0..job.password_len];
            job.ok = switch (job.mode) {
                .hash => if (bcrypt.strHashWithSalt(password, .{
                    .params = .{ .rounds_log = 10, .silently_truncate_password = false },
                    .encoding = .crypt,
                }, job.hash[0..60], job.salt)) |_| true else |_| false,
                .verify => verify(&job.hash, password),
            };
            std.crypto.secureZero(u8, &job.password);
            self.mutex.lockUncancelable(self.io);
            self.completed[self.completed_count] = job;
            self.completed_count += 1;
            self.mutex.unlock(self.io);
            const byte = [_]u8{1};
            while (c.write(self.pipe[1], &byte, 1) < 0) {
                if (c.errno(@as(c_int, -1)) != .INTR) break;
            }
        }
    }
};

test "upstream Go bcrypt seed is verified without caching or skipping the work" {
    const seed: [60:0]u8 = "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq".*;
    try std.testing.expect(verify(&seed, "password123"));
    try std.testing.expect(!verify(&seed, "wrong-password"));
    var invalid = seed;
    invalid[2] = 'x';
    try std.testing.expect(!verify(&invalid, "password123"));
}
