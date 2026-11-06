//! The portable kernel object: the Zig kernel at every width, compiled for baseline x86-64. `init` falls back to it
//! on a CPU without x86-64-v3 (some KVM CPU models hide AVX2 and BMI2), where the other variants can't run.
const std = @import("std");
const kernel = @import("kernel.zig");

comptime {
    for (1..9) |n| @export(&kernel.Kernel(n, null).run, .{ .name = std.fmt.comptimePrint("bc_port_{d}", .{n}) });
}
