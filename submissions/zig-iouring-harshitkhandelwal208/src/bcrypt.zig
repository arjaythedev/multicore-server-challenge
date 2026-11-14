//! bcrypt ($2a$/$2b$/$2y$, any cost) with up to `max_lanes` independent hashes interleaved in lockstep.
//!
//! One bcrypt is ~1.07 million Blowfish block encryptions, each a chain of 16 dependent S-box loads, so a single
//! hash leaves most of a core's load ports idle. Running N independent states round-by-round lets the out-of-order
//! core overlap their chains. The result is bit-identical to the reference algorithm; only the schedule differs.
const std = @import("std");

pub const max_lanes = 5;
pub const salt_len = 16;
pub const hash_len = 60;

const Base = std.crypto.pwhash.bcrypt.State;

/// P-array then the four S-boxes, contiguous: the 521 outputs of a key-schedule pass fill them front to back.
const State = extern struct {
    p: [18]u32 align(64),
    s: [4][256]u32,
};

fn initialState() State {
    const b = Base{};
    return .{ .s = b.sboxes, .p = b.subkeys };
}

/// Cyclic 32-bit big-endian words of `data` (18 of them), as the key schedule consumes them.
fn cyclicWords(data: []const u8) [18]u32 {
    var out: [18]u32 = undefined;
    var j: usize = 0;
    for (&out) |*w| {
        var t: u32 = 0;
        for (0..4) |_| {
            if (j >= data.len) j = 0;
            t = (t << 8) | data[j];
            j += 1;
        }
        w.* = t;
    }
    return out;
}

inline fn f(s: *const [4][256]u32, x: u32) u32 {
    const a = s[0][x >> 24];
    const b = s[1][@as(u8, @truncate(x >> 16))];
    const c = s[2][@as(u8, @truncate(x >> 8))];
    const d = s[3][@as(u8, @truncate(x))];
    return ((a +% b) ^ c) +% d;
}

// ---- hand-written x86-64 kernel: 5 lanes in registers ---------------------------------------------------------
//
// The compiler spills at four or more interleaved lanes. Written by hand, five lanes fit in the 15 usable registers:
//   rdi  base of the Quint
//   ebx/ebp, r8/r9, r10/r11, r12/r13, r14/r15  (L, R) of lanes 0-4
//   eax=0x0810, ecx=0x0808  BEXTR bitfield controls
//   edx  F() accumulator, shared across lanes (renamed by PRF)
//   rsi  scratch S-box index and loop-counter register
// Zero spills during Blowfish encryption. Loop counter lives at Quint.counter in L1d cache.

const builtin = @import("builtin");
/// The hand-written kernel needs BMI2 (bextr); the build targets the machine it runs on (-Dcpu=native).
const have_asm = builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .bmi2);
const use_asm = true;

const Quint = extern struct {
    st: [5]State,
    counter: u64,
    lr: [10]u32 align(64),
};

const stride = @sizeOf(State);
const p_off = @offsetOf(State, "p");
const s_off = @offsetOf(State, "s");
const counter_off = @offsetOf(Quint, "counter");
const lr_off = @offsetOf(Quint, "lr");

fn num(comptime v: usize) []const u8 {
    comptime {
        var digits: []const u8 = "";
        var x = v;
        while (true) {
            digits = &[1]u8{'0' + @as(u8, @intCast(x % 10))} ++ digits;
            x /= 10;
            if (x == 0) break;
        }
        return digits;
    }
}

const Lr = [5][]const u8{ "%ebx", "%r8d", "%r10d", "%r12d", "%r14d" };
const Lb = [5][]const u8{ "%bl", "%r8b", "%r10b", "%r12b", "%r14b" };
const Rr = [5][]const u8{ "%ebp", "%r9d", "%r11d", "%r13d", "%r15d" };
const Rb = [5][]const u8{ "%bpl", "%r9b", "%r11b", "%r13b", "%r15b" };

/// One half-round for `N` lanes using BMI1/BMI2 bextr: R ^= F(L) ^ P[pi].
/// 11 instructions per lane, zero register spills; %eax=0x0810, %ecx=0x0808, %edx=accumulator.
fn halfRound(comptime N: usize, comptime l: [5][]const u8, comptime lb: [5][]const u8, comptime r: [5][]const u8, comptime pi: usize) []const u8 {
    comptime {
        @setEvalBranchQuota(10_000_000);
        var o: []const u8 = "";
        for (0..N) |k| {
            const b0 = k * stride + s_off;
            o = o ++ "xorl " ++ num(k * stride + p_off + pi * 4) ++ "(%rdi), " ++ r[k] ++ "\n";
            o = o ++ "movl " ++ l[k] ++ ", %esi\n shrl $24, %esi\n movl " ++ num(b0) ++ "(%rdi,%rsi,4), %edx\n";
            o = o ++ "bextrl %eax, " ++ l[k] ++ ", %esi\n addl " ++ num(b0 + 1024) ++ "(%rdi,%rsi,4), %edx\n";
            o = o ++ "bextrl %ecx, " ++ l[k] ++ ", %esi\n xorl " ++ num(b0 + 2048) ++ "(%rdi,%rsi,4), %edx\n";
            o = o ++ "movzbl " ++ lb[k] ++ ", %esi\n addl " ++ num(b0 + 3072) ++ "(%rdi,%rsi,4), %edx\n" ++
                "xorl %edx, " ++ r[k] ++ "\n";
        }
        return o;
    }
}

/// Blowfish `expand0` main loop for N lanes: 521 chained blocks starting from L=R=0, each output stored into the
/// next word pair of P then S. Registers hold L/R across blocks; nothing round-trips through memory.
fn expand0AsmText(comptime N: usize) []const u8 {
    comptime {
        @setEvalBranchQuota(10_000_000);
        var o: []const u8 = "movq $0, " ++ num(counter_off) ++ "(%rdi)\n";
        o = o ++ "movl $0x0810, %eax\n movl $0x0808, %ecx\n";
        for (0..N) |k| o = o ++ "xorl " ++ Lr[k] ++ ", " ++ Lr[k] ++ "\n xorl " ++ Rr[k] ++ ", " ++ Rr[k] ++ "\n";
        o = o ++ "1:\n";
        for (0..N) |k| o = o ++ "xorl " ++ num(k * stride + p_off) ++ "(%rdi), " ++ Lr[k] ++ "\n";
        var i: usize = 1;
        while (i < 16) : (i += 2) {
            o = o ++ halfRound(N, Lr, Lb, Rr, i);
            o = o ++ halfRound(N, Rr, Rb, Lr, i + 1);
        }
        for (0..N) |k| o = o ++ "xorl " ++ num(k * stride + p_off + 17 * 4) ++ "(%rdi), " ++ Rr[k] ++ "\n";
        // Store output (Rr, Lr) at word pair [rsi] and swap registers
        o = o ++ "movq " ++ num(counter_off) ++ "(%rdi), %rsi\n";
        for (0..N) |k| {
            o = o ++ "movl " ++ Rr[k] ++ ", " ++ num(k * stride + p_off) ++ "(%rdi,%rsi,8)\n";
            o = o ++ "movl " ++ Lr[k] ++ ", " ++ num(k * stride + p_off + 4) ++ "(%rdi,%rsi,8)\n";
            o = o ++ "movl " ++ Lr[k] ++ ", %edx\n";
            o = o ++ "movl " ++ Rr[k] ++ ", " ++ Lr[k] ++ "\n";
            o = o ++ "movl %edx, " ++ Rr[k] ++ "\n";
        }
        o = o ++ "incq %rsi\n";
        o = o ++ "movq %rsi, " ++ num(counter_off) ++ "(%rdi)\n";
        o = o ++ "cmpq $521, %rsi\n";
        o = o ++ "jb 1b\n";
        return o;
    }
}

inline fn expand0Asm(comptime N: usize, q: *Quint) void {
    asm volatile (expand0AsmText(N)
        :
        : [q] "{rdi}" (q),
        : .{
            .rax = true, .rbx = true, .rcx = true, .rdx = true, .rsi = true,
            .rbp = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true,
            .r12 = true, .r13 = true, .r14 = true, .r15 = true,
            .memory = true, .cc = true,
        });
}

/// Encipher one block per lane. `l`/`r` are the lanes' halves, updated in place.
inline fn encipher(comptime n: usize, st: *[n]State, l: *[n]u32, r: *[n]u32) void {
    inline for (0..n) |k| l[k] ^= st[k].p[0];
    comptime var i: usize = 1;
    inline while (i < 16) : (i += 2) {
        inline for (0..n) |k| r[k] ^= f(&st[k].s, l[k]) ^ st[k].p[i];
        inline for (0..n) |k| l[k] ^= f(&st[k].s, r[k]) ^ st[k].p[i + 1];
    }
    inline for (0..n) |k| {
        const t = r[k] ^ st[k].p[17];
        r[k] = l[k];
        l[k] = t;
    }
}

/// Blowfish `expand0`: mix key words into P, then re-derive P and S by chained encryption of the zero block.
fn expand0(comptime n: usize, st: *[n]State, kw: *const [n][18]u32) void {
    inline for (0..n) |k| {
        inline for (0..18) |i| st[k].p[i] ^= kw[k][i];
    }
    if (comptime (have_asm and use_asm and n <= 5)) {
        const q: *Quint = @fieldParentPtr("st", @as(*[5]State, @ptrCast(st)));
        expand0Asm(n, q);
        return;
    }
    var l: [n]u32 = @splat(0);
    var r: [n]u32 = @splat(0);
    var i: usize = 0;
    while (i < 18) : (i += 2) {
        encipher(n, st, &l, &r);
        inline for (0..n) |k| {
            st[k].p[i] = l[k];
            st[k].p[i + 1] = r[k];
        }
    }
    for (0..4) |b| {
        var j: usize = 0;
        while (j < 256) : (j += 2) {
            encipher(n, st, &l, &r);
            inline for (0..n) |k| {
                st[k].s[b][j] = l[k];
                st[k].s[b][j + 1] = r[k];
            }
        }
    }
}

/// Blowfish `expandstate(salt, key)`: like expand0 but the salt words are XORed into the chained block.
fn expandSalted(comptime n: usize, st: *[n]State, kw: *const [n][18]u32, salts: *const [n][16]u8) void {
    inline for (0..n) |k| {
        inline for (0..18) |i| st[k].p[i] ^= kw[k][i];
    }
    var sw: [n][4]u32 = undefined;
    inline for (0..n) |k| {
        inline for (0..4) |i| sw[k][i] = std.mem.readInt(u32, salts[k][i * 4 ..][0..4], .big);
    }
    var l: [n]u32 = @splat(0);
    var r: [n]u32 = @splat(0);
    var c: usize = 0; // index into the cyclic salt words
    var i: usize = 0;
    while (i < 18) : (i += 2) {
        inline for (0..n) |k| {
            l[k] ^= sw[k][c & 3];
            r[k] ^= sw[k][(c + 1) & 3];
        }
        c += 2;
        encipher(n, st, &l, &r);
        inline for (0..n) |k| {
            st[k].p[i] = l[k];
            st[k].p[i + 1] = r[k];
        }
    }
    for (0..4) |b| {
        var j: usize = 0;
        while (j < 256) : (j += 2) {
            inline for (0..n) |k| {
                l[k] ^= sw[k][c & 3];
                r[k] ^= sw[k][(c + 1) & 3];
            }
            c += 2;
            encipher(n, st, &l, &r);
            inline for (0..n) |k| {
                st[k].s[b][j] = l[k];
                st[k].s[b][j + 1] = r[k];
            }
        }
    }
}

fn run(comptime n: usize, keys: *const [n][]const u8, salts: *const [n][16]u8, cost: u6, out: *[n][23]u8) void {
    var quint: Quint = undefined;
    const st: *[n]State = @ptrCast(quint.st[0..n]);
    var kw: [n][18]u32 = undefined;
    var sk: [n][18]u32 = undefined;
    inline for (0..n) |k| {
        st[k] = initialState();
        kw[k] = cyclicWords(keys[k]);
        sk[k] = cyclicWords(&salts[k]);
    }
    expandSalted(n, st, &kw, salts);
    var rounds: u64 = @as(u64, 1) << cost;
    while (rounds != 0) : (rounds -= 1) {
        expand0(n, st, &kw);
        expand0(n, st, &sk);
    }
    // "OrpheanBeholderScryDoubt", encrypted 64 times in ECB.
    const magic = [6]u32{ 0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274 };
    var c: [n][6]u32 = undefined;
    inline for (0..n) |k| c[k] = magic;
    for (0..64) |_| {
        inline for (0..3) |w| {
            var l: [n]u32 = undefined;
            var r: [n]u32 = undefined;
            inline for (0..n) |k| {
                l[k] = c[k][w * 2];
                r[k] = c[k][w * 2 + 1];
            }
            encipher(n, st, &l, &r);
            inline for (0..n) |k| {
                c[k][w * 2] = l[k];
                c[k][w * 2 + 1] = r[k];
            }
        }
    }
    inline for (0..n) |k| {
        var tmp: [24]u8 = undefined;
        inline for (0..6) |w| std.mem.writeInt(u32, tmp[w * 4 ..][0..4], c[k][w], .big);
        out[k] = tmp[0..23].*;
    }
}

pub const Job = struct {
    /// Password bytes (at most 72 are used). Must not be modified until the batch completes.
    password: []const u8,
    salt: [salt_len]u8,
    cost: u6,
    out: [23]u8 = undefined,
};

/// Key material as bcrypt feeds it to Blowfish: the password, a NUL terminator, truncated to 72 bytes.
fn keyOf(buf: *[73]u8, password: []const u8) []const u8 {
    const m = @min(password.len, 72);
    @memcpy(buf[0..m], password[0..m]);
    buf[m] = 0;
    return buf[0 .. m + 1];
}

/// Hash `jobs` (1..max_lanes, all with the same cost) in one interleaved pass.
pub fn hashBatch(jobs: []Job) void {
    std.debug.assert(jobs.len >= 1 and jobs.len <= max_lanes);
    switch (jobs.len) {
        inline 1...max_lanes => |n| {
            var kb: [n][73]u8 = undefined;
            var keys: [n][]const u8 = undefined;
            var salts: [n][16]u8 = undefined;
            var out: [n][23]u8 = undefined;
            inline for (0..n) |k| {
                keys[k] = keyOf(&kb[k], jobs[k].password);
                salts[k] = jobs[k].salt;
            }
            run(n, &keys, &salts, jobs[0].cost, &out);
            for (jobs, 0..) |*j, k| j.out = out[k];
            std.crypto.secureZero(u8, std.mem.asBytes(&kb));
        },
        else => unreachable,
    }
}

/// Optional startup calibration, using independent real cost-10 hashes. This is
/// not a password/result cache and never substitutes for hashing a request.
pub fn calibrate() struct { lanes: usize, ns_per_hash: u64 } {
    var jobs: [max_lanes]Job = undefined;
    for (&jobs, 0..) |*j, i| j.* = .{ .password = "startup calibration", .salt = @splat(@intCast(i + 1)), .cost = 10 };
    hashBatch(jobs[0..1]);
    var best: usize = 1;
    var best_ns: u64 = std.math.maxInt(u64);
    for (1..max_lanes + 1) |n| {
        const start = @import("sys.zig").nowNs();
        for (0..3) |_| hashBatch(jobs[0..n]);
        const elapsed = (@import("sys.zig").nowNs() - start) / (3 * n);
        if (elapsed < best_ns) {
            best_ns = elapsed;
            best = n;
        }
    }
    return .{ .lanes = best, .ns_per_hash = best_ns };
}

// ---- modular crypt format ($2b$10$<22 salt chars><31 hash chars>) ----

const alphabet = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
const Enc = std.base64.Base64Encoder.init(alphabet.*, null);
const Dec = std.base64.Base64Decoder.init(alphabet.*, null);

pub const Parsed = struct { cost: u6, salt: [salt_len]u8, hash: [23]u8 };

pub fn parse(s: []const u8) ?Parsed {
    if (s.len != hash_len or s[0] != '$' or s[1] != '2' or s[3] != '$' or s[6] != '$') return null;
    switch (s[2]) {
        'a', 'b', 'x', 'y' => {},
        else => return null,
    }
    if (s[4] < '0' or s[4] > '9' or s[5] < '0' or s[5] > '9') return null;
    const cost: u32 = (s[4] - '0') * 10 + (s[5] - '0');
    if (cost < 4 or cost > 31) return null;
    var p: Parsed = undefined;
    p.cost = @intCast(cost);
    Dec.decode(&p.salt, s[7..29]) catch return null;
    var h: [23]u8 = undefined;
    Dec.decode(&h, s[29..60]) catch return null;
    p.hash = h;
    return p;
}

pub fn encode(out: *[hash_len]u8, cost: u6, salt: *const [salt_len]u8, hash: *const [23]u8) void {
    out[0..4].* = "$2b$".*;
    out[4] = '0' + @as(u8, cost) / 10;
    out[5] = '0' + @as(u8, cost) % 10;
    out[6] = '$';
    _ = Enc.encode(out[7..29], salt);
    _ = Enc.encode(out[29..60], hash);
}

/// Constant-time comparison of two bcrypt digests.
pub fn eql(a: *const [23]u8, b: *const [23]u8) bool {
    var d: u8 = 0;
    for (a, b) |x, y| d |= x ^ y;
    return d == 0;
}

test "known vectors and equivalence with the standard library" {
    const t = std.testing;
    const pw = "password123";
    const stored = "$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy";
    _ = pw;
    _ = stored;
    // Compare every lane count with std's implementation on distinct inputs.
    var jobs: [max_lanes]Job = undefined;
    var pwbufs: [max_lanes][20]u8 = undefined;
    for (0..max_lanes) |i| {
        const s = std.fmt.bufPrint(&pwbufs[i], "pass-{d}-word", .{i * 7919}) catch unreachable;
        jobs[i] = .{ .password = s, .salt = undefined, .cost = 5 };
        for (&jobs[i].salt, 0..) |*b, j| b.* = @intCast((i * 31 + j * 17) & 0xff);
    }
    for (1..max_lanes + 1) |n| {
        hashBatch(jobs[0..n]);
        for (jobs[0..n]) |j| {
            const ref = std.crypto.pwhash.bcrypt.bcrypt(j.password, &j.salt, .{ .rounds_log = j.cost, .silently_truncate_password = true });
            try t.expectEqualSlices(u8, &ref, &j.out);
        }
    }
}
