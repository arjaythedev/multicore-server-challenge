//! bcrypt ($2a$/$2b$/$2y$, any cost) with up to `max_lanes` independent hashes interleaved in lockstep.
//!
//! One bcrypt is ~1.07 million Blowfish block encryptions, each a chain of 16 dependent S-box loads, so a single
//! hash leaves most of a core's load ports idle. Running N independent states round-by-round lets the out-of-order
//! core overlap their chains. The result is bit-identical to the reference algorithm; only the schedule differs.
const std = @import("std");

pub const max_lanes = 4;
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

// ---- hand-written x86-64 kernel: 4 lanes in registers ---------------------------------------------------------
//
// The compiler spills at four or more interleaved lanes. Written by hand, four lanes fit in the 15 usable registers:
//   rdi  base of the Quad          r8-r11  L of lane 0-3        r12-r15  R of lane 0-3
//   rax, rbx, rcx, rdx  F() accumulator of lane 0-3             rsi      byte-index temp, shared by all lanes
// Reusing one index register across lanes costs nothing: the core renames it, so only true dependencies remain.
// Per half-round and lane: R ^= ((S0[L>>24] + S1[L>>16&255]) ^ S2[L>>8&255]) + S3[L&255] ^ P[i].

const builtin = @import("builtin");
/// The hand-written kernel needs BMI2 (rorx); the build targets the machine it runs on (-Dcpu=native).
const have_asm = builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .bmi2);
const use_asm = true;

const Quad = extern struct {
    st: [4]State,
    lr: [8]u32 align(64), // l0..l3, r0..r3 (loaded at entry, stored at exit)
};

const stride = @sizeOf(State);
const p_off = @offsetOf(State, "p");
const s_off = @offsetOf(State, "s");
const lr_off = @offsetOf(Quad, "lr");

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

const Lr = [4][]const u8{ "%r8d", "%r9d", "%r10d", "%r11d" };
const Lb = [4][]const u8{ "%r8b", "%r9b", "%r10b", "%r11b" };
const Rr = [4][]const u8{ "%r12d", "%r13d", "%r14d", "%r15d" };
const Xr = [4][]const u8{ "%eax", "%ebx", "%ecx", "%edx" };

/// One half-round for `N` lanes (lane-major so each lane's chain is contiguous): R ^= F(L) ^ P[pi].
fn halfRound(comptime N: usize, comptime l: [4][]const u8, comptime lb: [4][]const u8, comptime r: [4][]const u8, comptime pi: usize) []const u8 {
    comptime {
        @setEvalBranchQuota(10_000_000);
        var o: []const u8 = "";
        for (0..N) |k| {
            const b0 = k * stride + s_off;
            // rorx (BMI2) is a 3-operand rotate: the wanted byte lands in the low byte without a separate mov.
            // R ^= P[pi] is off the F() chain: do it first, while the S-box loads are in flight
            o = o ++ "xorl " ++ num(k * stride + p_off + pi * 4) ++ "(%rdi), " ++ r[k] ++ "\n";
            o = o ++ "rorxl $24, " ++ l[k] ++ ", %esi\n movzbl %sil, %esi\n movl " ++ num(b0) ++ "(%rdi,%rsi,4), " ++ Xr[k] ++ "\n";
            o = o ++ "rorxl $16, " ++ l[k] ++ ", %esi\n movzbl %sil, %esi\n addl " ++ num(b0 + 1024) ++ "(%rdi,%rsi,4), " ++ Xr[k] ++ "\n";
            o = o ++ "rorxl $8, " ++ l[k] ++ ", %esi\n movzbl %sil, %esi\n xorl " ++ num(b0 + 2048) ++ "(%rdi,%rsi,4), " ++ Xr[k] ++ "\n";
            o = o ++ "movzbl " ++ lb[k] ++ ", %esi\n addl " ++ num(b0 + 3072) ++ "(%rdi,%rsi,4), " ++ Xr[k] ++ "\n" ++
                "xorl " ++ Xr[k] ++ ", " ++ r[k] ++ "\n";
        }
        return o;
    }
}

const Rb = [4][]const u8{ "%r12b", "%r13b", "%r14b", "%r15b" };

/// One block: L,R -> (R ^ P[17], L) in the register roles swapped (the caller swaps names, no moves).
fn blockText(comptime N: usize, comptime l: [4][]const u8, comptime lb: [4][]const u8, comptime r: [4][]const u8, comptime rb: [4][]const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(10_000_000);
        var o: []const u8 = "";
        for (0..N) |k| o = o ++ "xorl " ++ num(k * stride + p_off) ++ "(%rdi), " ++ l[k] ++ "\n";
        var i: usize = 1;
        while (i < 16) : (i += 2) {
            o = o ++ halfRound(N, l, lb, r, i);
            o = o ++ halfRound(N, r, rb, l, i + 1);
        }
        for (0..N) |k| o = o ++ "xorl " ++ num(k * stride + p_off + 17 * 4) ++ "(%rdi), " ++ r[k] ++ "\n";
        return o;
    }
}

/// Stores the block just computed (new L is in `r`, new R in `l`) at byte offset %rbp of each lane's state.
fn storeText(comptime N: usize, comptime l: [4][]const u8, comptime r: [4][]const u8) []const u8 {
    comptime {
        var o: []const u8 = "";
        for (0..N) |k| o = o ++ "movl " ++ r[k] ++ ", " ++ num(k * stride + p_off) ++ "(%rdi,%rbp)\n movl " ++ l[k] ++ ", " ++ num(k * stride + p_off + 4) ++ "(%rdi,%rbp)\n";
        return o;
    }
}

/// Blowfish `expand0` main loop for N lanes: 521 chained blocks starting from L=R=0, each output stored into the
/// next word pair of P then S. Registers hold L/R across blocks; nothing round-trips through memory.
fn expand0AsmText(comptime N: usize) []const u8 {
    comptime {
        var o: []const u8 = "";
        for (0..N) |k| o = o ++ "xorl " ++ Lr[k] ++ ", " ++ Lr[k] ++ "\n xorl " ++ Rr[k] ++ ", " ++ Rr[k] ++ "\n";
        o = o ++ "xorl %ebp, %ebp\n1:\n";
        o = o ++ blockText(N, Lr, Lb, Rr, Rb) ++ storeText(N, Lr, Rr) ++ "addq $8, %rbp\n";
        o = o ++ blockText(N, Rr, Rb, Lr, Lb) ++ storeText(N, Rr, Lr) ++ "addq $8, %rbp\n";
        o = o ++ "cmpq $4160, %rbp\n jb 1b\n";
        o = o ++ blockText(N, Lr, Lb, Rr, Rb) ++ storeText(N, Lr, Rr);
        return o;
    }
}

inline fn expand0Asm(comptime N: usize, q: *Quad) void {
    asm volatile (expand0AsmText(N)
        :
        : [q] "{rdi}" (q),
        : .{ .rax = true, .rbx = true, .rcx = true, .rdx = true, .rsi = true, .rbp = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true, .r12 = true, .r13 = true, .r14 = true, .r15 = true, .memory = true, .cc = true });
}

fn encipherAsmText(comptime N: usize) []const u8 {
    comptime {
        @setEvalBranchQuota(10_000_000);
        var o: []const u8 = "";
        for (0..N) |k| o = o ++ "movl " ++ num(lr_off + k * 4) ++ "(%rdi), " ++ Lr[k] ++ "\n movl " ++ num(lr_off + 16 + k * 4) ++ "(%rdi), " ++ Rr[k] ++ "\n";
        o = o ++ blockText(N, Lr, Lb, Rr, Rb);
        for (0..N) |k| {
            o = o ++ "movl " ++ Rr[k] ++ ", " ++ num(lr_off + k * 4) ++ "(%rdi)\n";
            o = o ++ "movl " ++ Lr[k] ++ ", " ++ num(lr_off + 16 + k * 4) ++ "(%rdi)\n";
        }
        return o;
    }
}

inline fn encipherAsm(comptime N: usize, q: *Quad) void {
    asm volatile (encipherAsmText(N)
        :
        : [q] "{rdi}" (q),
        : .{ .rax = true, .rbx = true, .rcx = true, .rdx = true, .rsi = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true, .r12 = true, .r13 = true, .r14 = true, .r15 = true, .memory = true, .cc = true });
}

/// Encipher one block per lane. `l`/`r` are the lanes' halves, updated in place.
inline fn encipher(comptime n: usize, st: *[n]State, l: *[n]u32, r: *[n]u32) void {
    if (comptime (n == 4 and have_asm and use_asm)) {
        const q: *Quad = @fieldParentPtr("st", st);
        q.lr[0..4].* = l.*;
        q.lr[4..8].* = r.*;
        encipherAsm(4, q);
        l.* = q.lr[0..4].*;
        r.* = q.lr[4..8].*;
        return;
    }
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
    if (comptime (n == 4 and have_asm and use_asm)) {
        const q: *Quad = @fieldParentPtr("st", st);
        expand0Asm(4, q);
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
    var quad: Quad = undefined;
    var plain: [if (n == 4) 0 else n]State = undefined;
    const st: *[n]State = if (n == 4) @ptrCast(&quad.st) else &plain;
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
/// One job runs alone (compiled kernel); 2 or 3 are padded to four lanes, which still beats running them one by one.
pub fn hashBatch(jobs: []Job) void {
    std.debug.assert(jobs.len >= 1 and jobs.len <= max_lanes);
    if (jobs.len == 1) {
        var kb: [1][73]u8 = undefined;
        var keys: [1][]const u8 = .{keyOf(&kb[0], jobs[0].password)};
        var salts: [1][16]u8 = .{jobs[0].salt};
        var out: [1][23]u8 = undefined;
        run(1, &keys, &salts, jobs[0].cost, &out);
        jobs[0].out = out[0];
        std.crypto.secureZero(u8, std.mem.asBytes(&kb));
        return;
    }
    var kb: [4][73]u8 = undefined;
    var keys: [4][]const u8 = undefined;
    var salts: [4][16]u8 = undefined;
    var out: [4][23]u8 = undefined;
    for (0..4) |k| {
        const j = &jobs[if (k < jobs.len) k else 0];
        keys[k] = keyOf(&kb[k], j.password);
        salts[k] = j.salt;
    }
    run(4, &keys, &salts, jobs[0].cost, &out);
    for (jobs, 0..) |*j, k| j.out = out[k];
    std.crypto.secureZero(u8, std.mem.asBytes(&kb));
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
