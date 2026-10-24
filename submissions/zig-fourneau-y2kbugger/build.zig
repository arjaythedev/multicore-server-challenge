//!   zig build          zig-out/bin/conduit, for this machine's CPU
//!   zig build test     the unit tests

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.Optimize, "optimize", "The mode (default fast)") orelse .fast;
    const fourneau = b.dependency("fourneau", .{});
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "fourneau", .module = fourneau.module("fourneau") },
        .{ .name = "zig_io_evented", .module = fourneau.module("zig_io_evented") },
    };
    const exe = b.addExecutable(.{
        .name = "conduit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    b.installArtifact(exe);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .debug,
        .imports = imports,
    }) });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(tests).step);
}
