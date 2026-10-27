const std = @import("std");

// --------------------------------------------------------- //

fn addTestFile(
    b: *std.Build,
    step: *std.Build.Step,
    zix_module: *std.Build.Module,
    conduit_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    src: []const u8,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path(src),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("zix", zix_module);
    mod.addImport("conduit", conduit_module);

    const exe = b.addTest(.{ .root_module = mod });
    const run = b.addRunArtifact(exe);

    step.dependOn(&run.step);
}

fn addSuite(
    b: *std.Build,
    step_name: []const u8,
    description: []const u8,
    zix_module: *std.Build.Module,
    conduit_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    files: []const []const u8,
) *std.Build.Step {
    const step = b.step(step_name, description);

    for (files) |src| {
        addTestFile(b, step, zix_module, conduit_module, target, optimize, src);
    }

    return step;
}

// --------------------------------------------------------- //

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --------------------------------------------------------- //

    // module zix
    const mod_zix = b.dependency("zix", .{ .target = target, .optimize = optimize });
    const zix_module = mod_zix.module("zix");

    // module conduit, the app surface the suites import
    const conduit_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    conduit_module.addImport("zix", zix_module);

    // --------------------------------------------------------- //

    // exec main
    const exec_main = b.addExecutable(.{ .name = "conduit", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }) });

    exec_main.root_module.addImport("zix", zix_module);

    if (optimize != .debug) {
        exec_main.lto = .full;
        exec_main.root_module.strip = true;
    }

    b.installArtifact(exec_main);

    // --------------------------------------------------------- //

    // unit tests, inline in src
    const unit = addSuite(
        b,
        "unit-test",
        "Run unit tests",
        zix_module,
        conduit_module,
        target,
        optimize,
        &.{"src/tests.zig"},
    );

    // edge tests
    const edge = addSuite(
        b,
        "edge-test",
        "Run edge tests",
        zix_module,
        conduit_module,
        target,
        optimize,
        &.{"tests/edge/users_auth_test.zig"},
    );

    // behaviour tests
    const behaviour = addSuite(
        b,
        "behaviour-test",
        "Run behaviour tests",
        zix_module,
        conduit_module,
        target,
        optimize,
        &.{
            "tests/behaviour/articles_test.zig",
            "tests/behaviour/comments_test.zig",
            "tests/behaviour/favorites_test.zig",
            "tests/behaviour/profiles_test.zig",
            "tests/behaviour/tags_test.zig",
            "tests/behaviour/users_auth_test.zig",
        },
    );

    // integration tests, skipped when the database is down
    const integration = addSuite(
        b,
        "integration-test",
        "Run integration tests",
        zix_module,
        conduit_module,
        target,
        optimize,
        &.{
            "tests/integration/articles_test.zig",
            "tests/integration/comments_test.zig",
            "tests/integration/favorites_test.zig",
            "tests/integration/profiles_test.zig",
            "tests/integration/tags_test.zig",
            "tests/integration/users_auth_test.zig",
        },
    );

    // --------------------------------------------------------- //

    const test_step = b.step("test", "Run every test suite");

    test_step.dependOn(unit);
    test_step.dependOn(edge);
    test_step.dependOn(behaviour);
    test_step.dependOn(integration);
}
