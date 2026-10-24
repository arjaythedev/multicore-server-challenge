const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --------------------------------------------------------- //

    // module zix
    const mod_zix = b.dependency("zix", .{
        .target = target,
        .optimize = optimize
    });

    // --------------------------------------------------------- //

    // exec main
    const exec_main = b.addExecutable(.{
        .name = "conduit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        })
    });

    exec_main.root_module.addImport("zix", mod_zix.module("zix"));

    b.installArtifact(exec_main);
}
