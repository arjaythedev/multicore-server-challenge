const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info (default: yes for release builds)") orelse (optimize != .debug);

    const exe = b.addExecutable(.{
        .name = "conduit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = false,
            .strip = strip,
        }),
    });
    exe.root_module.link_libc = true;
    exe.root_module.linkSystemLibrary("deflate", .{});
    b.installArtifact(exe);

    // The bcrypt kernel is hand-written assembly that needs the register allocator of an optimized build, so a Debug
    // `zig build test` is run as a safe-optimized build (bounds and overflow checks stay on).
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/all_tests.zig"),
        .target = target,
        .optimize = if (optimize == .debug) .safe else optimize,
    }) });
    tests.root_module.link_libc = true;
    tests.root_module.linkSystemLibrary("deflate", .{});
    const bc = b.createModule(.{ .root_source_file = b.path("src/bcrypt.zig"), .target = target, .optimize = optimize });
    const bench = b.addExecutable(.{ .name = "bench-bcrypt", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/bench_bcrypt.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "bcrypt", .module = bc }},
    }) });
    b.step("bench-bcrypt", "Build the bcrypt lane benchmark").dependOn(&b.addInstallArtifact(bench, .{}).step);

    const dump = b.addExecutable(.{ .name = "sqldump", .root_module = b.createModule(.{
        .root_source_file = b.path("src/sqldump.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.step("sqldump", "Build the SQL dumper").dependOn(&b.addInstallArtifact(dump, .{}).step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
