//! The kernel object: every variant at every width the engine can run, exported with the C ABI. It is compiled
//! for x86-64-v3 on its own, so the program that links it can stay at any target. `zig` is the Zig kernel;
//! `asm_ah` and `asm_bextr` are the same kernel with a generated expand0 (asm_gen.zig) in its cost loop.
const std = @import("std");
const kernel = @import("kernel.zig");

comptime {
    for (1..9) |n| {
        @export(&kernel.Kernel(n, null).run, .{ .name = std.fmt.comptimePrint("bc_zig_{d}", .{n}) });
        for ([_][]const u8{ "ah", "bextr" }) |style| {
            const expand0 = @extern(kernel.Expand0Fn, .{ .name = std.fmt.comptimePrint("bc_expand0_{s}_{d}", .{ style, n }) });
            @export(&kernel.Kernel(n, expand0).run, .{ .name = std.fmt.comptimePrint("bc_asm_{s}_{d}", .{ style, n }) });
        }
    }
}
