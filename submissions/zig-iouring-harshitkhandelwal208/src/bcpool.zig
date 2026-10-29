//! bcrypt worker threads. Logins and sign-ups are ~0.1% of requests but cost ~40 ms of CPU each when run one at a
//! time, so jobs are collected for a short window and hashed several at once (interleaved, see bcrypt.zig).
//! The workers run at normal priority: at a lower one they starve while Postgres saturates the CPUs and logins time
//! out. A job that has waited longer than `stale_ns` is dropped (its client gave up long ago).
const std = @import("std");
const linux = std.os.linux;
const bcrypt = @import("bcrypt.zig");
const sync = @import("sync.zig");
const sys = @import("sys.zig");

pub const Kind = enum { hash, verify };

pub const Job = struct {
    kind: Kind,
    cost: u6,
    plen: u8,
    password: [72]u8,
    salt: [16]u8,
    expect: [23]u8,
    /// Opaque to the pool: identifies the request in the owning event loop.
    tag: usize,
    sink: *Sink,
    enqueued_ns: u64 = 0,
};

pub const Done = struct {
    tag: usize,
    /// verify: password matched. hash: always true.
    ok: bool,
    stale: bool = false,
    cost: u6,
    salt: [16]u8,
    hash: [23]u8,
};

/// Per-event-loop mailbox for finished jobs; the loop is woken through `efd`.
pub const Sink = struct {
    mu: sync.Mutex = .{},
    items: [1024]Done = undefined,
    n: usize = 0,
    efd: i32 = -1,

    fn push(self: *Sink, d: Done) void {
        while (true) {
            self.mu.lock();
            if (self.n < self.items.len) {
                self.items[self.n] = d;
                self.n += 1;
                self.mu.unlock();
                break;
            }
            self.mu.unlock();
            // The loop is behind; give it a moment (the queue is bounded, so this is real back-pressure).
            _ = linux.nanosleep(&.{ .sec = 0, .nsec = 1_000_000 }, null);
        }
        const one: u64 = 1;
        _ = linux.write(self.efd, std.mem.asBytes(&one), 8);
    }

    /// Move finished jobs into `out`; returns how many.
    pub fn take(self: *Sink, out: []Done) usize {
        self.mu.lock();
        defer self.mu.unlock();
        const n = @min(out.len, self.n);
        @memcpy(out[0..n], self.items[0..n]);
        std.mem.copyForwards(Done, self.items[0 .. self.n - n], self.items[n..self.n]);
        self.n -= n;
        return n;
    }
};

const qcap = 4096;
/// Challenge generator client timeout is 10 s; drop work that waited >= 9.5 s to avoid wasting hashing CPU.
const default_stale_ns: u64 = 9500 * std.time.ns_per_ms;

pub const Pool = struct {
    mu: sync.Mutex = .{},
    sig: sync.Signal = .{},
    q: [qcap]Job = undefined,
    head: usize = 0,
    count: usize = 0,
    lanes: usize,
    wait_ns: u64,
    idle_ns: u64 = 0,
    stale_ns: u64 = default_stale_ns,
    last_done_ns: u64 = 0,

    pub fn submit(self: *Pool, job: Job) bool {
        var j = job;
        j.enqueued_ns = sys.nowNs();
        self.mu.lock();
        if (self.count == qcap) {
            self.mu.unlock();
            return false;
        }
        self.q[(self.head + self.count) % qcap] = j;
        self.count += 1;
        self.mu.unlock();
        self.sig.notify();
        return true;
    }

    fn at(self: *Pool, i: usize) *Job {
        return &self.q[(self.head + i) % qcap];
    }

    /// Remove job `i` (0 = oldest) from the queue.
    fn removeAt(self: *Pool, i: usize) Job {
        const job = self.at(i).*;
        var k = i;
        while (k + 1 < self.count) : (k += 1) self.at(k).* = self.at(k + 1).*;
        self.count -= 1;
        return job;
    }

    fn worker(self: *Pool, index: usize) void {
        var batch: [bcrypt.max_lanes]Job = undefined;
        var bj: [bcrypt.max_lanes]bcrypt.Job = undefined;
        while (true) {
            const seen = self.sig.current();
            self.mu.lock();
            if (self.count == 0) {
                self.mu.unlock();
                self.sig.wait(seen, null);
                continue;
            }
            // Gather jobs of the oldest job's cost. Worker 0 lets the oldest job wait up to `wait_ns` for company;
            // extra workers only help when a full batch has built up or a job has waited the whole window.
            const first_cost = self.at(0).cost;
            var same: usize = 0;
            for (0..self.count) |i| if (self.at(i).cost == first_cost) {
                same += 1;
            };
            const lanes = @min(self.lanes, bcrypt.max_lanes);
            const age = sys.nowNs() -| self.at(0).enqueued_ns;
            const idle = self.idle_ns != 0 and sys.nowNs() -| self.last_done_ns >= self.idle_ns;
            const ready = same >= lanes or age >= self.wait_ns or (index == 0 and idle);
            if (!ready) {
                self.mu.unlock();
                if (index == 0) self.sig.wait(seen, self.wait_ns - age) else self.sig.wait(seen, self.wait_ns);
                continue;
            }
            if (index != 0 and same < lanes and age < self.wait_ns) {
                self.mu.unlock();
                self.sig.wait(seen, self.wait_ns);
                continue;
            }
            var n: usize = 0;
            var i: usize = 0;
            while (i < self.count and n < lanes) {
                if (self.at(i).cost == first_cost) {
                    batch[n] = self.removeAt(i);
                    n += 1;
                } else i += 1;
            }
            self.mu.unlock();

            const now = sys.nowNs();
            var live: usize = 0;
            for (0..n) |k| {
                if (now -| batch[k].enqueued_ns > self.stale_ns) {
                    batch[k].sink.push(.{ .tag = batch[k].tag, .ok = false, .stale = true, .cost = batch[k].cost, .salt = batch[k].salt, .hash = undefined });
                } else {
                    batch[live] = batch[k];
                    live += 1;
                }
            }
            n = live;
            if (n == 0) continue;
            for (0..n) |k| {
                bj[k] = .{ .password = batch[k].password[0..batch[k].plen], .salt = batch[k].salt, .cost = batch[k].cost };
            }
            bcrypt.hashBatch(bj[0..n]);
            self.mu.lock();
            self.last_done_ns = sys.nowNs();
            self.mu.unlock();
            for (0..n) |k| {
                const ok = switch (batch[k].kind) {
                    .hash => true,
                    .verify => bcrypt.eql(&bj[k].out, &batch[k].expect),
                };
                batch[k].sink.push(.{ .tag = batch[k].tag, .ok = ok, .cost = batch[k].cost, .salt = batch[k].salt, .hash = bj[k].out });
            }
        }
    }

    pub fn start(self: *Pool, threads: usize) !void {
        for (0..threads) |i| {
            const t = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, worker, .{ self, i });
            t.detach();
        }
    }
};
