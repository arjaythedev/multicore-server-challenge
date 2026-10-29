//! The EksBlowfish kernel: `N` independent bcrypt hashes in one thread, their Blowfish rounds interleaved so the
//! dependent S-box lookups of every lane overlap. Each lane is full bcrypt at the batch's cost.
const std = @import("std");
const consts = @import("bf_consts.zig");

/// Hashes N lanes; with a `Progress`, from and to the rounds it gives, returning false with `out` undefined if it
/// stops before the end.
pub const KernelFn = *const fn ([*]const [18]u32, [*]const [4]u32, u32, [*][6]u32, ?*Progress) callconv(.c) bool;
/// A hand-written expand0state over all N lanes' states (asm_gen.zig).
pub const Expand0Fn = *const fn (*anyopaque) callconv(.c) void;

pub const max_lanes = 8;
/// One lane's Blowfish state, laid out as asm_gen.zig expects.
pub const State = extern struct { P: [18]u32, S: [4][256]u32 };

/// Rounds of the cost loop between saved states. Saving costs under 1% of a batch's CPU (Ryzen 9 5950X, 4 to 8 lanes).
pub const save_every = 16;

/// A batch's way through the cost loop, kept outside the kernel so another thread can finish the batch from where
/// this one got to. The kernel saves its lanes' states every `save_every` rounds into the half of `saved` that the
/// newest save is not in, then publishes the new round count; `take` stops it and reads that count in one step, so
/// the half it names is never written again.
pub const Progress = extern struct {
    /// Read once a round. High half: how many rounds the kernel may do before it stops. Low half: the rounds done in
    /// the newest saved state, 0 if none.
    at: std.atomic.Value(u64) = .init(no_stop),
    /// The rounds done in `saved[half(from)]` to start from; 0 starts from the setting.
    from: u32 = 0,
    /// Whether to save as it goes.
    save: bool = false,
    saved: [2][max_lanes]State = undefined,

    pub const no_stop: u64 = @as(u64, std.math.maxInt(u32)) << 32;

    pub fn half(rounds: u32) usize {
        return (rounds / save_every) & 1;
    }

    /// Stops the kernel at its next round. Returns the rounds done in the newest saved state, which stays as it is.
    pub fn take(p: *Progress) u32 {
        return @truncate(p.at.fetchAnd(std.math.maxInt(u32), .acquire));
    }

    pub fn taken(p: *const Progress) bool {
        return p.at.load(.monotonic) >> 32 == 0;
    }

    /// The kernel stops on its own after `rounds`, as if taken there.
    pub fn stopAfter(p: *Progress, rounds: u32) void {
        p.at.store(@as(u64, rounds) << 32, .monotonic);
    }
};

/// `expand0`, if given, replaces the Zig expand0state in the cost loop, where all but 0.05% of the time goes.
pub fn Kernel(comptime N: usize, comptime expand0: ?Expand0Fn) type {
    return struct {
        pub const lanes = N;
        /// The block halves live outside the state so LLVM keeps them in registers.
        const Block = struct { L: [N]u32, R: [N]u32 };

        st: [N]State,
        kw: [N][18]u32,
        ss: [N][18]u32,
        sw: [N][4]u32,
        c: [N][6]u32,

        const G = @This();

        inline fn F(st: *const State, x: u32) u32 {
            return ((st.S[0][x >> 24] +% st.S[1][(x >> 16) & 0xff]) ^ st.S[2][(x >> 8) & 0xff]) +% st.S[3][x & 0xff];
        }

        inline fn init(g: *G, kw: [*]const [18]u32, sw: [*]const [4]u32) void {
            inline for (0..N) |u| {
                g.st[u].P = consts.P0;
                g.st[u].S = consts.S0;
                g.kw[u] = kw[u];
                g.sw[u] = sw[u];
                for (0..18) |i| g.ss[u][i] = g.sw[u][i & 3];
            }
        }

        inline fn enc(g: *G, x: *Block) void {
            inline for (0..N) |u| x.L[u] ^= g.st[u].P[0];
            var r: usize = 1;
            while (r < 17) : (r += 2) {
                inline for (0..N) |u| x.R[u] ^= F(&g.st[u], x.L[u]) ^ g.st[u].P[r];
                inline for (0..N) |u| x.L[u] ^= F(&g.st[u], x.R[u]) ^ g.st[u].P[r + 1];
            }
            inline for (0..N) |u| {
                const t = x.L[u];
                x.L[u] = x.R[u] ^ g.st[u].P[17];
                x.R[u] = t;
            }
        }

        // P ^= key words, then re-encrypt the whole state in place. With salt the input blocks are first
        // XORed with the cycled salt stream ("expandstate"); without, it is "expand0state".
        inline fn expand(g: *G, comptime salt_key: bool, comptime with_salt: bool) void {
            @setEvalBranchQuota(1_000_000);
            var x: Block = undefined;
            inline for (0..N) |u| {
                const k = if (salt_key) &g.ss[u] else &g.kw[u];
                for (0..18) |i| g.st[u].P[i] ^= k[i];
                x.L[u] = 0;
                x.R[u] = 0;
            }
            if (expand0) |f| if (!with_salt) return f(&g.st);
            var i: usize = 0;
            while (i < 18) : (i += 2) {
                if (with_salt) inline for (0..N) |u| {
                    x.L[u] ^= g.sw[u][i & 3];
                    x.R[u] ^= g.sw[u][(i + 1) & 3];
                };
                g.enc(&x);
                inline for (0..N) |u| {
                    g.st[u].P[i] = x.L[u];
                    g.st[u].P[i + 1] = x.R[u];
                }
            }
            inline for (0..4) |b| {
                var j: usize = 0;
                while (j < 256) : (j += 2) {
                    if (with_salt) inline for (0..N) |u| {
                        x.L[u] ^= g.sw[u][(18 + b * 256 + j) & 3];
                        x.R[u] ^= g.sw[u][(18 + b * 256 + j + 1) & 3];
                    };
                    g.enc(&x);
                    inline for (0..N) |u| {
                        g.st[u].S[b][j] = x.L[u];
                        g.st[u].S[b][j + 1] = x.R[u];
                    }
                }
            }
        }

        /// `kw`, `sw` and `out` hold `N` entries.
        pub fn run(kw: [*]const [18]u32, sw: [*]const [4]u32, cost: u32, out: [*][6]u32, progress: ?*Progress) callconv(.c) bool {
            @setEvalBranchQuota(1_000_000);
            var g: G = undefined;
            g.init(kw, sw);
            const rounds = @as(u32, 1) << @intCast(cost);
            const from = if (progress) |p| p.from else 0;
            if (from == 0) g.expand(false, true) else g.st = progress.?.saved[Progress.half(from)][0..N].*;
            var r = from;
            while (r < rounds) : (r += 1) {
                if (progress) |p| {
                    const at = p.at.load(.monotonic);
                    if (r >= at >> 32) return false;
                    if (p.save and r != from and r % save_every == 0) {
                        p.saved[Progress.half(r)][0..N].* = g.st;
                        // Fails only if taken meanwhile.
                        if (p.at.cmpxchgStrong(at, at >> 32 << 32 | r, .release, .monotonic) != null) return false;
                    }
                }
                g.expand(false, false);
                g.expand(true, false);
            }
            const orphean = [6]u32{ 0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274 };
            inline for (0..N) |u| g.c[u] = orphean;
            var x: Block = undefined;
            for (0..64) |_| {
                inline for (0..3) |h| {
                    inline for (0..N) |u| {
                        x.L[u] = g.c[u][2 * h];
                        x.R[u] = g.c[u][2 * h + 1];
                    }
                    g.enc(&x);
                    inline for (0..N) |u| {
                        g.c[u][2 * h] = x.L[u];
                        g.c[u][2 * h + 1] = x.R[u];
                    }
                }
            }
            inline for (0..N) |u| out[u] = g.c[u];
            return true;
        }
    };
}
