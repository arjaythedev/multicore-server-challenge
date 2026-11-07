//! Build-time generator of the hand-scheduled expand0 kernels: GNU assembler (Intel syntax, BMI1/BMI2), one
//! function per extraction style and width, `void bc_expand0_<style>_<N>(u32 *state)`. `state` holds N lanes of 1042 words each (P[18] then
//! S[4][256], lane stride 4168 bytes) with P already XORed with the key; the function encrypts a zero block and
//! writes each of its 521 chained outputs over P and S in turn, as Blowfish's expand0state does.
//!
//! One base register (rdi) reaches every lane: each S-box and P read is rdi + index*4 + a fixed displacement,
//! folded into an add or xor. Per round, a lane whose halves live in registers costs 11 instructions, in one of
//! two styles that differ in how they extract the index bytes; startup calibration picks per CPU:
//! - `ah`: byte 0 by movzx from the low byte, byte 1 by BEXTR, bytes 2 and 3 by one RORX into eax then movzx
//!   from al and ah. Best on Zen 3.
//! - `bextr`: byte 3 by a register copy (eliminated at rename) and a shift, bytes 2 and 1 by BEXTR, byte 0 by
//!   movzx. No partial-register reads, which Zen 5 runs 8% faster.
//! Only five lanes fit in registers; further lanes keep their halves on the stack and load their index bytes with
//! movzx straight from memory, 10 instructions that use the load ports instead of the ALUs.
//! Usage: asm_gen <out.S>
const std = @import("std");

const max_lanes = 8;
const words = 18 + 4 * 256;
const stride = words * 4;
const encryptions = words / 2;
/// Lanes whose halves fit in registers: 15 GPRs less base, index, accumulator, and eax and ecx (`ah`: rotate
/// temp and BEXTR control; `bextr`: two BEXTR controls).
const reg_lanes = 5;
const halves = [reg_lanes][2][]const u8{ .{ "ebx", "ebp" }, .{ "r8d", "r9d" }, .{ "r10d", "r11d" }, .{ "r12d", "r13d" }, .{ "r14d", "r15d" } };
const low_byte = [reg_lanes][2][]const u8{ .{ "bl", "bpl" }, .{ "r8b", "r9b" }, .{ "r10b", "r11b" }, .{ "r12b", "r13b" }, .{ "r14b", "r15b" } };

const Style = enum { ah, bextr };

const Gen = struct {
    out: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    fn line(g: *Gen, comptime fmt: []const u8, args: anytype) !void {
        try g.out.print(g.gpa, fmt ++ "\n", args);
    }
};

/// Where lane `u`'s half `h` (0 = L, 1 = R) lives: a register, or a stack slot after the 8-byte counter.
fn slot(u: usize, h: usize) usize {
    return 8 + 8 * (u - reg_lanes) + 4 * h;
}

/// y ^= P[r] ^ F(x) for lane u, where x is half `hx` and y the other.
fn halfRound(g: *Gen, style: Style, u: usize, hx: usize, r: usize) !void {
    const base = u * stride;
    const s = base + 72;
    const hy = 1 - hx;
    if (u < reg_lanes) {
        const x = halves[u][hx];
        const y = halves[u][hy];
        try g.line("  xor {s}, dword ptr [rdi + {d}]", .{ y, base + 4 * r });
        switch (style) {
            .ah => {
                try g.line("  rorx eax, {s}, 16", .{x});
                try g.line("  movzx esi, ah", .{});
                try g.line("  mov edx, dword ptr [rdi + rsi*4 + {d}]", .{s});
                try g.line("  movzx esi, al", .{});
            },
            .bextr => {
                try g.line("  mov esi, {s}", .{x});
                try g.line("  shr esi, 24", .{});
                try g.line("  mov edx, dword ptr [rdi + rsi*4 + {d}]", .{s});
                try g.line("  bextr esi, {s}, eax", .{x});
            },
        }
        try g.line("  add edx, dword ptr [rdi + rsi*4 + {d}]", .{s + 1024});
        try g.line("  bextr esi, {s}, ecx", .{x});
        try g.line("  xor edx, dword ptr [rdi + rsi*4 + {d}]", .{s + 2048});
        try g.line("  movzx esi, {s}", .{low_byte[u][hx]});
        try g.line("  add edx, dword ptr [rdi + rsi*4 + {d}]", .{s + 3072});
        try g.line("  xor {s}, edx", .{y});
    } else {
        const x = slot(u, hx);
        try g.line("  movzx esi, byte ptr [rsp + {d}]", .{x + 3});
        try g.line("  mov edx, dword ptr [rdi + rsi*4 + {d}]", .{s});
        try g.line("  movzx esi, byte ptr [rsp + {d}]", .{x + 2});
        try g.line("  add edx, dword ptr [rdi + rsi*4 + {d}]", .{s + 1024});
        try g.line("  movzx esi, byte ptr [rsp + {d}]", .{x + 1});
        try g.line("  xor edx, dword ptr [rdi + rsi*4 + {d}]", .{s + 2048});
        try g.line("  movzx esi, byte ptr [rsp + {d}]", .{x});
        try g.line("  add edx, dword ptr [rdi + rsi*4 + {d}]", .{s + 3072});
        try g.line("  xor edx, dword ptr [rdi + {d}]", .{base + 4 * r});
        try g.line("  xor dword ptr [rsp + {d}], edx", .{slot(u, hy)});
    }
}

fn function(g: *Gen, style: Style, n: usize) !void {
    const mem_lanes = n -| reg_lanes;
    // Counter plus the stack lanes, keeping rsp 16-byte aligned after the six pushes.
    const frame = 8 + 8 * mem_lanes + (if (mem_lanes % 2 == 0) @as(usize, 8) else 0);
    const name = @tagName(style);
    try g.line("  .globl bc_expand0_{s}_{d}", .{ name, n });
    try g.line("  .type bc_expand0_{s}_{d}, @function", .{ name, n });
    try g.line("  .p2align 6", .{});
    try g.line("bc_expand0_{s}_{d}:", .{ name, n });
    for ([_][]const u8{ "rbx", "rbp", "r12", "r13", "r14", "r15" }) |r| try g.line("  push {s}", .{r});
    try g.line("  sub rsp, {d}", .{frame});
    try g.line("  mov ecx, 0x0808", .{});
    if (style == .bextr) try g.line("  mov eax, 0x0810", .{});
    try g.line("  mov qword ptr [rsp], 0", .{});
    for (0..n) |u| {
        if (u < reg_lanes) {
            try g.line("  xor {s}, {s}", .{ halves[u][0], halves[u][0] });
            try g.line("  xor {s}, {s}", .{ halves[u][1], halves[u][1] });
        } else try g.line("  mov qword ptr [rsp + {d}], 0", .{slot(u, 0)});
    }
    try g.line("  .p2align 4", .{});
    try g.line(".Lenc_{s}_{d}:", .{ name, n });
    for (0..n) |u| {
        if (u < reg_lanes) {
            try g.line("  xor {s}, dword ptr [rdi + {d}]", .{ halves[u][0], u * stride });
        } else {
            try g.line("  mov edx, dword ptr [rdi + {d}]", .{u * stride});
            try g.line("  xor dword ptr [rsp + {d}], edx", .{slot(u, 0)});
        }
    }
    var r: usize = 1;
    while (r < 17) : (r += 2) {
        for (0..n) |u| try halfRound(g, style, u, 0, r);
        for (0..n) |u| try halfRound(g, style, u, 1, r + 1);
    }
    // Output block (R ^ P[17], L) goes to words 2j, 2j+1 and is the next input: store it, then swap the halves.
    try g.line("  mov rsi, qword ptr [rsp]", .{});
    for (0..n) |u| {
        const base = u * stride;
        if (u < reg_lanes) {
            const l = halves[u][0];
            const rr = halves[u][1];
            try g.line("  xor {s}, dword ptr [rdi + {d}]", .{ rr, base + 68 });
            try g.line("  mov dword ptr [rdi + rsi*8 + {d}], {s}", .{ base, rr });
            try g.line("  mov dword ptr [rdi + rsi*8 + {d}], {s}", .{ base + 4, l });
            try g.line("  mov edx, {s}", .{l});
            try g.line("  mov {s}, {s}", .{ l, rr });
            try g.line("  mov {s}, edx", .{rr});
        } else {
            try g.line("  mov edx, dword ptr [rsp + {d}]", .{slot(u, 1)});
            try g.line("  xor edx, dword ptr [rdi + {d}]", .{base + 68});
            try g.line("  mov eax, dword ptr [rsp + {d}]", .{slot(u, 0)});
            try g.line("  mov dword ptr [rdi + rsi*8 + {d}], edx", .{base});
            try g.line("  mov dword ptr [rdi + rsi*8 + {d}], eax", .{base + 4});
            try g.line("  mov dword ptr [rsp + {d}], edx", .{slot(u, 0)});
            try g.line("  mov dword ptr [rsp + {d}], eax", .{slot(u, 1)});
        }
    }
    // The stack lanes' swap used eax.
    if (style == .bextr and mem_lanes > 0) try g.line("  mov eax, 0x0810", .{});
    try g.line("  add rsi, 1", .{});
    try g.line("  mov qword ptr [rsp], rsi", .{});
    try g.line("  cmp rsi, {d}", .{encryptions});
    try g.line("  jb .Lenc_{s}_{d}", .{ name, n });
    try g.line("  add rsp, {d}", .{frame});
    for ([_][]const u8{ "r15", "r14", "r13", "r12", "rbp", "rbx" }) |reg| try g.line("  pop {s}", .{reg});
    try g.line("  ret", .{});
    try g.line("  .size bc_expand0_{s}_{d}, .-bc_expand0_{s}_{d}", .{ name, n, name, n });
}

pub fn main(init: std.process.Init) !void {
    var it = init.minimal.args.iterate();
    _ = it.next();
    const path = it.next() orelse return error.MissingOutputPath;
    var g: Gen = .{ .gpa = init.arena.allocator() };
    try g.line("  .intel_syntax noprefix", .{});
    try g.line("  .text", .{});
    for ([_]Style{ .ah, .bextr }) |style| {
        for (1..max_lanes + 1) |n| try function(&g, style, n);
    }
    try g.line("  .section .note.GNU-stack,\"\",@progbits", .{});
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    defer _ = std.os.linux.close(fd);
    var off: usize = 0;
    while (off < g.out.items.len) off += std.os.linux.write(fd, g.out.items[off..].ptr, g.out.items.len - off);
}
