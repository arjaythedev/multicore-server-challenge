const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const pg_root = b.option([]const u8, "pg-root", "PostgreSQL installation prefix");
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const options = b.addOptions();
    options.addOption(bool, "prepared_queries", b.option(bool, "prepared-queries", "Prepare API queries per database connection") orelse true);
    const database_connections = b.option(usize, "db-connections", "Maximum owned PostgreSQL connections (1-95)") orelse 4;
    if (database_connections == 0 or database_connections > 95) @panic("db-connections must be between 1 and 95");
    options.addOption(usize, "database_connections", database_connections);
    const clients = b.option(usize, "max-clients", "Maximum HTTP connections") orelse 131072;
    if (clients < 256 or clients > 262144) @panic("max-clients must be between 256 and 262144");
    options.addOption(usize, "max_clients", clients);
    options.addOption(bool, "tag_batch", b.option(bool, "tag-batch", "Coalesce already queued tag reads (maximum 32)") orelse true);
    options.addOption(bool, "article_batch", b.option(bool, "article-batch", "Batch already queued single-article reads") orelse true);
    options.addOption(bool, "generic_plans", b.option(bool, "generic-plans", "Reuse generic plans on owned connections") orelse true);
    const bcrypt_workers = b.option(usize, "bcrypt-workers", "Bounded bcrypt workers (1-8)") orelse 4;
    if (bcrypt_workers == 0 or bcrypt_workers > 8) @panic("bcrypt-workers must be between 1 and 8");
    options.addOption(usize, "bcrypt_workers", bcrypt_workers);
    const bcrypt_jobs = b.option(usize, "bcrypt-jobs", "Maximum outstanding bcrypt jobs (16-128)") orelse 64;
    if (bcrypt_jobs < 16 or bcrypt_jobs > 128) @panic("bcrypt-jobs must be between 16 and 128");
    options.addOption(usize, "bcrypt_jobs", bcrypt_jobs);
    module.addOptions("build_options", options);
    module.addCSourceFile(.{ .file = b.path("vendor/picohttpparser/picohttpparser.c"), .flags = &.{"-std=c99"} });
    module.linkSystemLibrary("pq", .{ .use_pkg_config = .no });
    if (pg_root) |prefix| {
        const lib = b.pathJoin(&.{ prefix, "lib" });
        module.addLibraryPath(.{ .cwd_relative = lib });
        module.addRPath(.{ .cwd_relative = lib });
    }
    const exe = b.addExecutable(.{ .name = "conduit", .root_module = module });
    b.installArtifact(exe);
    const tests = b.addTest(.{ .root_module = module });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run protocol and configuration checks").dependOn(&run_tests.step);
}
