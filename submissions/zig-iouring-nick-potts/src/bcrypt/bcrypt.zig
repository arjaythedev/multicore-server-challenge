//! bcrypt `$2a$`/`$2b$` in batches. One kernel call hashes up to `max_lanes` passwords in one thread, each a full
//! bcrypt at the batch's cost. Password bytes follow golang.org/x/crypto/bcrypt: every byte is hashed, embedded
//! NULs included, followed by one NUL, cycled over the 72 key bytes; bytes past 72 never reach the key.
//!
//! Startup: `init` runs the self-test (every kernel variant and width against reference vectors) and fails on any
//! mismatch, then times each variant at each width from `min_calibrated_lanes` to `max_lanes` and keeps the
//! cheapest. `Engine.hash` then runs one batch.
const std = @import("std");
pub const cpu = @import("cpu.zig");
const kernel = @import("kernel.zig");

pub const KernelFn = kernel.KernelFn;
pub const Progress = kernel.Progress;
pub const save_every = kernel.save_every;

pub const max_lanes = kernel.max_lanes;
pub const min_calibrated_lanes = 4;
/// Register and password change reject longer passwords with 422, as the Go reference does. Login does not:
/// there the bytes past 72 are ignored, as `CompareHashAndPassword` ignores them.
pub const max_password_len = 72;
pub const cost = 10;

/// One kernel family, compiled once per width 1..max_lanes.
pub const Variant = struct {
    name: []const u8,
    widths: [max_lanes]KernelFn,

    fn width(v: *const Variant, n: usize) KernelFn {
        return v.widths[n - 1];
    }
};

fn variant(comptime name: []const u8) Variant {
    var v: Variant = .{ .name = name, .widths = undefined };
    for (1..max_lanes + 1) |n| {
        v.widths[n - 1] = @extern(KernelFn, .{ .name = std.fmt.comptimePrint("bc_{s}_{d}", .{ name, n }) });
    }
    return v;
}

/// These need x86-64-v3: their kernel object is built for it (kernels.zig).
pub const variants = [_]Variant{ variant("zig"), variant("asm_ah"), variant("asm_bextr") };
/// The Zig kernel built for baseline x86-64 (kernels_port.zig), the fallback below x86-64-v3.
pub const portable = [_]Variant{variant("port")};

pub fn findVariant(name: []const u8) ?*const Variant {
    for (&(variants ++ portable)) |*v| if (std.mem.eql(u8, v.name, name)) return v;
    return null;
}

// ---------- bcrypt base64 and setting strings ----------

const alphabet = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

const decode_table = blk: {
    var t: [256]u8 = @splat(0xff);
    for (alphabet, 0..) |c, i| t[c] = i;
    break :blk t;
};

fn b64enc(out: []u8, in: []const u8) void {
    var o: usize = 0;
    var i: usize = 0;
    while (i < in.len) : (i += 3) {
        const b0: u32 = in[i];
        const b1: u32 = if (i + 1 < in.len) in[i + 1] else 0;
        const b2: u32 = if (i + 2 < in.len) in[i + 2] else 0;
        const w = (b0 << 16) | (b1 << 8) | b2;
        const chars = @min(4, (in.len - i) * 8 / 6 + 1);
        for (0..chars) |k| out[o + k] = alphabet[(w >> @intCast(18 - 6 * k)) & 63];
        o += chars;
    }
}

fn b64dec16(s: *const [22]u8) ?[16]u8 {
    var out: [16]u8 = undefined;
    var acc: u32 = 0;
    var bits: u5 = 0;
    var o: usize = 0;
    for (s) |c| {
        const v = decode_table[c];
        if (v == 0xff) return null;
        acc = (acc << 6) | v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (o < 16) out[o] = @truncate(acc >> bits);
            o += 1;
        }
    }
    return out;
}

/// What a hash is computed from: cost and salt, plus the 29-character "$2x$NN$" + salt prefix that starts every
/// hash made from it. The prefix is kept as given, so a hash verifies against its stored form byte for byte.
pub const Setting = struct {
    prefix: [29]u8,
    cost: u5,
    salt: [4]u32,
};

/// Reads the setting from a stored hash, or from a bare 29-character setting string.
pub fn parseSetting(s: []const u8) ?Setting {
    if (s.len < 29 or s[0] != '$' or s[1] != '2' or s[3] != '$' or s[6] != '$') return null;
    if (s[2] != 'a' and s[2] != 'b' and s[2] != 'y') return null;
    if (s[4] < '0' or s[4] > '3' or s[5] < '0' or s[5] > '9') return null;
    const c = @as(u32, s[4] - '0') * 10 + (s[5] - '0');
    if (c < 4 or c > 31) return null;
    const raw = b64dec16(s[7..29]) orelse return null;
    var st: Setting = .{ .prefix = s[0..29].*, .cost = @intCast(c), .salt = undefined };
    for (0..4) |i| st.salt[i] = std.mem.readInt(u32, raw[4 * i ..][0..4], .big);
    return st;
}

/// A fresh "$2a$10$" setting, the form the Go reference writes.
pub fn newSetting(random: std.Random) Setting {
    return newSettingCost(random, cost);
}

pub fn newSettingCost(random: std.Random, c: u5) Setting {
    var raw: [16]u8 = undefined;
    random.bytes(&raw);
    return settingFromSalt(raw, c);
}

/// The "$2a$" setting for these 16 salt bytes at cost `c`.
pub fn settingFromSalt(raw: [16]u8, c: u5) Setting {
    var s: [29]u8 = undefined;
    @memcpy(s[0..4], "$2a$");
    s[4] = '0' + @as(u8, c / 10);
    s[5] = '0' + @as(u8, c % 10);
    s[6] = '$';
    b64enc(s[7..29], &raw);
    return parseSetting(&s).?;
}

/// The password and one NUL, cycled, as 18 big-endian words: Go's `append(password, 0)` fed to Blowfish's key
/// schedule. Only the first 72 bytes are read.
pub fn keyWords(pw: []const u8) [18]u32 {
    const n = pw.len + 1;
    var kw: [18]u32 = undefined;
    var j: usize = 0;
    for (0..18) |i| {
        var w: u32 = 0;
        for (0..4) |_| {
            const byte: u8 = if (j == pw.len) 0 else pw[j];
            w = (w << 8) | byte;
            j = if (j + 1 == n) 0 else j + 1;
        }
        kw[i] = w;
    }
    return kw;
}

pub const Hash = [60]u8;

pub const Job = struct { password: []const u8, setting: *const Setting };

/// Constant-time comparison of a computed hash against the stored string.
pub fn matches(computed: *const Hash, stored: []const u8) bool {
    if (stored.len != 60) return false;
    return std.crypto.timing_safe.eql(Hash, computed.*, stored[0..60].*);
}

pub const HashError = error{ MixedCost, Abandoned };

/// Hashes `jobs` (1..max_lanes, one cost) in one call of `v`'s kernel of exactly that width, the lanes in `jobs`'
/// order. With `progress`, it starts and saves as that says, and error.Abandoned (`out` undefined) is a stop before the
/// end.
pub fn hashWith(v: *const Variant, jobs: []const Job, out: []Hash, progress: ?*Progress) HashError!void {
    std.debug.assert(jobs.len >= 1 and jobs.len <= max_lanes and out.len >= jobs.len);
    var kw: [max_lanes][18]u32 = undefined;
    var sw: [max_lanes][4]u32 = undefined;
    var ct: [max_lanes][6]u32 = undefined;
    const c = jobs[0].setting.cost;
    for (jobs, 0..) |job, l| {
        if (job.setting.cost != c) return error.MixedCost;
        kw[l] = keyWords(job.password);
        sw[l] = job.setting.salt;
    }
    if (!v.width(jobs.len)(&kw, &sw, c, &ct, progress)) return error.Abandoned;
    for (jobs, 0..) |job, l| {
        var raw: [24]u8 = undefined;
        for (0..6) |j| std.mem.writeInt(u32, raw[4 * j ..][0..4], ct[l][j], .big);
        out[l][0..29].* = job.setting.prefix;
        b64enc(out[l][29..60], raw[0..23]);
    }
}

/// The calibrated kernel: `lanes` is the batch size to fill before calling `hash`.
pub const Engine = struct {
    variant: *const Variant,
    lanes: u8,
    cpu_ms_per_hash: f64,

    /// `jobs.len` may be anything from 1 to `lanes`; a short batch runs the kernel of its own width.
    pub fn hash(e: Engine, jobs: []const Job, out: []Hash, progress: ?*Progress) HashError!void {
        std.debug.assert(jobs.len <= e.lanes);
        return hashWith(e.variant, jobs, out, progress);
    }
};

// ---------- self-test ----------

pub const Known = struct { pw: []const u8, hash: []const u8 };

/// Openwall/OpenBSD vectors; one embedded-NUL password from the Rust `bcrypt` crate 0.19.3, which keeps every
/// byte as Go does; vectors from golang.org/x/crypto/bcrypt v0.58.0 (goref, vectors/go-x-crypto-v0.58.0.txt)
/// with NULs and the 71/72-byte edges; and the challenge's seeded user, the one cost-10 hash.
pub const known = [_]Known{
    .{ .pw = "U*U", .hash = "$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW" },
    .{ .pw = "U*U*", .hash = "$2a$05$CCCCCCCCCCCCCCCCCCCCC.VGOzA784oUp/Z0DY336zx7pLYAy0lwK" },
    .{ .pw = "U*U*U", .hash = "$2a$05$XXXXXXXXXXXXXXXXXXXXXOAcXxm9kjPGEMsLznoKqmqw7tc8WCx4a" },
    .{ .pw = "", .hash = "$2a$05$CCCCCCCCCCCCCCCCCCCCC.7uG0VCzI2bS7j6ymqJi9CdcdxiRTWNy" },
    .{ .pw = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789chars after 72 are ignored", .hash = "$2a$05$abcdefghijklmnopqrstuu5s2v8.iXieOjg/.AySBTTZIIVFJeBui" },
    .{ .pw = "\xc1\x00\x3f\x4d\xf9\x4e\x0c", .hash = "$2b$05$LLBrsH0SU0Ur0A19aAY23OOz3rCFnplONOQLNk39DCR9JWIWSBQRu" },
    .{ .pw = "password123", .hash = "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq" },
} ++ @import("go_known.zig").vectors;

pub const SelfTestError = error{ KnownVectorMismatch, WidthMismatch } || HashError;

pub const Failure = struct { variant: []const u8 = "", width: usize = 0, case: usize = 0 };

/// Every variant of `set` at width 1 against `known`, then at every width against those width-1 results on a batch
/// of awkward passwords (empty, NULs, 71 to 80 bytes, random bytes) at cost 5.
pub fn selfTest(set: []const Variant, failure: *Failure) SelfTestError!void {
    for (set) |*v| {
        for (known, 0..) |k, i| {
            const st = parseSetting(k.hash).?;
            var h: [1]Hash = undefined;
            try hashWith(v, &.{.{ .password = k.pw, .setting = &st }}, &h, null);
            if (!std.mem.eql(u8, &h[0], k.hash)) {
                failure.* = .{ .variant = v.name, .width = 1, .case = i };
                return error.KnownVectorMismatch;
            }
        }
    }
    var prng = std.Random.DefaultPrng.init(0x5e1f7e57);
    const random = prng.random();
    var pwbuf: [max_lanes][80]u8 = undefined;
    var settings: [max_lanes]Setting = undefined;
    var jobs: [max_lanes]Job = undefined;
    const lens = [_]usize{ 0, 1, 71, 72, 73, 80, 9, 40 };
    for (0..max_lanes) |l| {
        const len = lens[l];
        for (pwbuf[l][0..len]) |*b| b.* = random.int(u8);
        if (len > 2) pwbuf[l][len / 2] = 0;
        settings[l] = newSettingCost(random, 5);
        jobs[l] = .{ .password = pwbuf[l][0..len], .setting = &settings[l] };
    }
    var expect: [max_lanes]Hash = undefined;
    for (0..max_lanes) |l| try hashWith(&set[0], jobs[l..][0..1], expect[l..][0..1], null);
    for (set) |*v| {
        for (1..max_lanes + 1) |n| {
            var got: [max_lanes]Hash = undefined;
            // Rotate which jobs land in which lanes so every lane of every width sees several passwords.
            for (0..max_lanes) |shift| {
                var batch: [max_lanes]Job = undefined;
                var want: [max_lanes]Hash = undefined;
                for (0..n) |l| {
                    batch[l] = jobs[(l + shift) % max_lanes];
                    want[l] = expect[(l + shift) % max_lanes];
                }
                try hashWith(v, batch[0..n], got[0..n], null);
                for (0..n) |l| if (!std.mem.eql(u8, &got[l], &want[l])) {
                    failure.* = .{ .variant = v.name, .width = n, .case = l };
                    return error.WidthMismatch;
                };
                if (n == max_lanes) break;
            }
        }
    }
}

// ---------- calibration ----------

pub fn nowNs(clock: std.os.linux.clockid_t) u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(clock, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// Thread-CPU ms per hash of one batch of `v` at width `n`, cost 10.
pub fn timeWidth(v: *const Variant, n: usize) f64 {
    var kw: [max_lanes][18]u32 = undefined;
    var sw: [max_lanes][4]u32 = undefined;
    var ct: [max_lanes][6]u32 = undefined;
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    for (0..n) |l| {
        var pw: [12]u8 = undefined;
        random.bytes(&pw);
        kw[l] = keyWords(&pw);
        random.bytes(std.mem.asBytes(&sw[l]));
    }
    const t0 = nowNs(.THREAD_CPUTIME_ID);
    _ = v.width(n)(&kw, &sw, cost, &ct, null);
    const ns = nowNs(.THREAD_CPUTIME_ID) - t0;
    return @as(f64, @floatFromInt(ns)) / 1e6 / @as(f64, @floatFromInt(n));
}

pub const InitError = SelfTestError;

const Candidate = struct { v: *const Variant, n: usize, ms: f64 = std.math.inf(f64) };

fn cheaper(_: void, a: Candidate, b: Candidate) bool {
    return a.ms < b.ms;
}

/// Calibration times every candidate (each variant at each width from `min_calibrated_lanes` to `max_lanes`) in
/// the first `screen_rounds` rounds, then only the `finalists` cheapest. Each keeps its fastest batch:
/// interference from the host or a neighbour on the core only ever adds time, so the minimum is the least
/// disturbed sample, and the extra rounds go where candidates are close.
const screen_rounds = 2;
const finalists = 4;

/// Startup: the variants this CPU can run (`variants` on x86-64-v3, else `portable`), then `initWith`.
pub fn init(rounds: usize, failure: *Failure) InitError!Engine {
    return initWith(if (cpu.detect().v3) &variants else &portable, rounds, failure);
}

/// Self-test of `set` (fatal on mismatch: a wrong kernel would lock users out), then calibration over `rounds`
/// interleaved rounds. 8 rounds of `variants` time 54 batches, about 3 CPU-seconds on a Ryzen 9 9950X.
pub fn initWith(set: []const Variant, rounds: usize, failure: *Failure) InitError!Engine {
    try selfTest(set, failure);
    const widths = max_lanes + 1 - min_calibrated_lanes;
    var buf: [variants.len * widths]Candidate = undefined;
    const c = buf[0 .. set.len * widths];
    for (set, 0..) |*v, i| {
        for (0..widths) |k| c[i * widths + k] = .{ .v = v, .n = min_calibrated_lanes + k };
    }
    for (0..rounds) |r| {
        for (c[0..if (r < screen_rounds) c.len else @min(finalists, c.len)]) |*x| x.ms = @min(x.ms, timeWidth(x.v, x.n));
        if (r + 1 == screen_rounds) std.mem.sort(Candidate, c, {}, cheaper);
    }
    std.mem.sort(Candidate, c, {}, cheaper);
    return .{ .variant = c[0].v, .lanes = @intCast(c[0].n), .cpu_ms_per_hash = c[0].ms };
}

test "known vectors and every width" {
    var failure: Failure = .{};
    const sets: []const []const Variant = if (cpu.detect().v3) &.{ &variants, &portable } else &.{&portable};
    for (sets) |set| selfTest(set, &failure) catch |e| {
        std.debug.print("self-test failed: {s} width {d} case {d}\n", .{ failure.variant, failure.width, failure.case });
        return e;
    };
}

test "the portable fallback hashes like the reference" {
    var failure: Failure = .{};
    const e = try initWith(&portable, 1, &failure);
    try std.testing.expectEqualStrings("port", e.variant.name);
    const k = known[6];
    const st = parseSetting(k.hash).?;
    var h: [1]Hash = undefined;
    try e.hash(&.{.{ .password = k.pw, .setting = &st }}, &h, null);
    try std.testing.expectEqualStrings(k.hash, &h[0]);
}

/// Eight jobs at cost `c`, passwords of 0 to 21 random bytes.
const Batch = struct {
    pw: [max_lanes][21]u8 = undefined,
    settings: [max_lanes]Setting = undefined,
    jobs: [max_lanes]Job = undefined,
    want: [max_lanes]Hash = undefined,

    fn init(b: *Batch, c: u5, seed: u64) !void {
        var prng = std.Random.DefaultPrng.init(seed);
        for (0..max_lanes) |l| {
            prng.random().bytes(&b.pw[l]);
            b.settings[l] = newSettingCost(prng.random(), c);
            b.jobs[l] = .{ .password = b.pw[l][0 .. 3 * l], .setting = &b.settings[l] };
            try hashWith(&portable[0], b.jobs[l..][0..1], b.want[l..][0..1], null);
        }
    }
};

/// What a thread that takes `p` carries on from, as bcrypt.zig's watchdog does.
fn carryOn(p: *Progress, n: usize) Progress {
    var next: Progress = .{ .from = p.take(), .save = true };
    const h = Progress.half(next.from);
    @memcpy(next.saved[h][0..n], p.saved[h][0..n]);
    return next;
}

test "a batch stopped after any round and finished from its newest saved state hashes as one run straight through" {
    const sets: []const []const Variant = if (cpu.detect().v3) &.{ &variants, &portable } else &.{&portable};
    const c = 6;
    var b: Batch = .{};
    try b.init(c, 0x0e5a17e);
    for (sets) |set| for (set) |*v| for (1..max_lanes + 1) |n| for (0..(1 << c) + 1) |k| {
        var first: Progress = .{ .save = true };
        first.stopAfter(@intCast(k));
        var got: [max_lanes]Hash = undefined;
        const finished = if (hashWith(v, b.jobs[0..n], got[0..n], &first)) true else |e| switch (e) {
            error.Abandoned => false,
            else => return e,
        };
        try std.testing.expectEqual(k == 1 << c, finished);
        var next = carryOn(&first, n);
        const saved: u32 = if (k <= save_every) 0 else @intCast((k - 1) / save_every * save_every);
        try std.testing.expectEqual(saved, next.from);
        try hashWith(v, b.jobs[0..n], got[0..n], &next);
        for (b.want[0..n], got[0..n]) |*w, *g| try std.testing.expectEqualStrings(w, g);
    };
}

fn hashOn(v: *const Variant, jobs: []const Job, out: []Hash, p: *Progress) void {
    hashWith(v, jobs, out, p) catch {};
}

test "a batch taken while its thread hashes finishes from the state that thread had saved" {
    const v = if (cpu.detect().v3) &variants[2] else &portable[0];
    const n = 5;
    var b: Batch = .{};
    try b.init(8, 0x7a4e);
    var prng = std.Random.DefaultPrng.init(0x7a4f);
    for (0..64) |i| {
        var p: Progress = .{ .save = true };
        var out: [max_lanes]Hash = undefined;
        const t = try std.Thread.spawn(.{}, hashOn, .{ v, b.jobs[0..n], out[0..n], &p });
        // Wait for some saved progress, then take the batch while the thread runs on, maybe mid-save.
        const target: u32 = @intCast(i % 16 * save_every);
        while (@as(u32, @truncate(p.at.load(.monotonic))) < target) std.atomic.spinLoopHint();
        for (0..prng.random().uintLessThan(u32, 20_000)) |_| std.atomic.spinLoopHint();
        var next = carryOn(&p, n);
        t.join();
        var got: [max_lanes]Hash = undefined;
        try hashWith(v, b.jobs[0..n], got[0..n], &next);
        for (b.want[0..n], got[0..n]) |*w, *g| try std.testing.expectEqualStrings(w, g);
    }
}

test "setting round trip and too-long passwords" {
    const s = parseSetting("$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq").?;
    try std.testing.expectEqual(@as(u5, 10), s.cost);
    try std.testing.expect(parseSetting("$2a$10$ZSfEoPvlcsj2XfvsSeK2!e") == null);
    try std.testing.expect(parseSetting("$2x$10$ZSfEoPvlcsj2XfvsSeK25e") == null);
    // Bytes past 72 never reach the key, so login with a longer password matches its 72-byte prefix.
    var long: [76]u8 = @splat('a');
    @memcpy(long[72..], "tail");
    try std.testing.expectEqualSlices(u32, &keyWords(long[0..72]), &keyWords(&long));
}
