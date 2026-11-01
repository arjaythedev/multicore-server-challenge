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
    const linux = target.result.os.tag == .linux;
    const reactors: usize = b.option(usize, "reactors", "Independent HTTP reactors (1-4)") orelse (if (linux) 4 else 1);
    if (reactors == 0 or reactors > 4) @panic("reactors must be between 1 and 4");
    options.addOption(usize, "reactors", reactors);
    const max_tasks: usize = b.option(usize, "max-tasks", "Total admitted request tasks across all reactors") orelse (if (linux) 12288 else 2048);
    if (max_tasks < 64 or max_tasks > 32768 or max_tasks % reactors != 0) @panic("max-tasks must be 64-32768 and divisible by reactors");
    options.addOption(usize, "max_tasks", max_tasks);
    options.addOption(bool, "eager_write", b.option(bool, "eager-write", "Attempt response writes immediately") orelse true);
    options.addOption(bool, "epoll_pause", b.option(bool, "epoll-pause", "Keep paused sockets registered with one-shot zero interest") orelse true);
    options.addOption(bool, "prepared_queries", b.option(bool, "prepared-queries", "Prepare API queries per database connection") orelse true);
    const database_connections: usize = b.option(usize, "db-connections", "Maximum owned PostgreSQL connections (1-95)") orelse (if (linux) 40 else 4);
    if (database_connections < reactors or database_connections > 95) @panic("db-connections must be between reactors and 95");
    options.addOption(usize, "database_connections", database_connections);
    const writers: usize = b.option(usize, "write-connections", "Dedicated write connections within the total pool (0 disables partitioning)") orelse (if (linux and database_connections >= 40) 24 else 0);
    if (writers != 0 and (writers < reactors or writers + reactors > database_connections)) @panic("each reactor needs at least one read and one write connection");
    options.addOption(usize, "write_connections", writers);
    const clients: usize = b.option(usize, "max-clients", "Maximum HTTP connections") orelse 196608;
    if (clients < 256 or clients > 262144) @panic("max-clients must be between 256 and 262144");
    options.addOption(usize, "max_clients", clients);
    const read_batch_size: usize = b.option(usize, "read-batch-size", "Maximum requests captured in one read group (2-512)") orelse (if (linux) 512 else 32);
    if (read_batch_size < 2 or read_batch_size > 512) @panic("read-batch-size must be between 2 and 512");
    options.addOption(usize, "read_batch_size", read_batch_size);
    options.addOption(bool, "tag_batch", b.option(bool, "tag-batch", "Coalesce already queued tag reads") orelse true);
    options.addOption(bool, "article_batch", b.option(bool, "article-batch", "Batch already queued single-article reads") orelse true);
    options.addOption(bool, "profile_batch", b.option(bool, "profile-batch", "Batch already queued profile reads with independent viewer flags") orelse linux);
    options.addOption(bool, "page_batch", b.option(bool, "page-batch", "Batch queued list pages and subsequent capped counts") orelse true);
    options.addOption(bool, "comments_batch", b.option(bool, "comments-batch", "Batch already queued comment lists") orelse true);
    options.addOption(bool, "compact_comments", b.option(bool, "compact-comments", "Normalize overlapping comment groups within their statement") orelse false);
    options.addOption(bool, "favorite_batch", b.option(bool, "favorite-batch", "Combine already queued compatible favorite mutations") orelse linux);
    options.addOption(bool, "shared_page_metadata", b.option(bool, "shared-page-metadata", "Enrich each distinct article once within a closed page group") orelse linux);
    options.addOption(bool, "shared_article_json", b.option(bool, "shared-article-json", "Encode repeated article metadata once inside a closed result group") orelse linux);
    options.addOption(bool, "compact_pages", b.option(bool, "compact-pages", "Return distinct page metadata once with separate recipient references") orelse linux);
    options.addOption(bool, "loopback_no_tls", b.option(bool, "loopback-no-tls", "Skip optional TLS only for an unambiguous numeric loopback database") orelse linux);
    options.addOption(bool, "generic_plans", b.option(bool, "generic-plans", "Reuse generic plans on owned connections") orelse true);
    options.addOption(bool, "feed_prune", b.option(bool, "feed-prune", "Prune feed candidates using a rank proven within the current statement") orelse false);
    options.addOption(bool, "shared_feed_hubs", b.option(bool, "shared-feed-hubs", "Derive shared feed rank and count proofs within each statement") orelse linux);
    const shared_passwords = b.option(bool, "shared-bcrypt", "Share bounded password execution while keeping completions owned by each reactor") orelse linux;
    options.addOption(bool, "shared_bcrypt", shared_passwords);
    const bcrypt_workers: usize = b.option(usize, "bcrypt-workers", "Bounded bcrypt workers (1-8)") orelse (if (shared_passwords) 2 else @max(4, reactors));
    if (bcrypt_workers < (if (shared_passwords) @as(usize, 1) else reactors) or bcrypt_workers > 8) @panic("bcrypt-workers must be 1-8, with at least one per reactor for independent pools");
    options.addOption(usize, "bcrypt_workers", bcrypt_workers);
    const bcrypt_jobs: usize = b.option(usize, "bcrypt-jobs", "Maximum outstanding bcrypt jobs (16-128)") orelse 64;
    if (bcrypt_jobs < 16 or bcrypt_jobs > 128) @panic("bcrypt-jobs must be between 16 and 128");
    options.addOption(usize, "bcrypt_jobs", bcrypt_jobs);
    const password_lanes: usize = b.option(usize, "bcrypt-lanes", "Independent cost-ten hashes per worker batch (1-4)") orelse (if (linux) 4 else 1);
    if (password_lanes < 1 or password_lanes > 4) @panic("bcrypt-lanes must be 1-4");
    options.addOption(usize, "bcrypt_lanes", password_lanes);
    options.addOption(bool, "bcrypt_calibrate", b.option(bool, "bcrypt-calibrate", "Select the fastest permitted complete bcrypt lane width at startup") orelse linux);
    const gather_ms: usize = b.option(usize, "bcrypt-gather-ms", "Maximum password batch collection window (0-100 ms)") orelse (if (linux and password_lanes > 1) 100 else 0);
    if (gather_ms > 100 or (password_lanes == 1 and gather_ms != 0)) @panic("bcrypt-gather-ms must be 0-100, and zero for scalar workers");
    options.addOption(usize, "bcrypt_gather_ms", gather_ms);
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
    const password_module = b.createModule(.{ .root_source_file = b.path("src/bcrypt_lanes.zig"), .target = target, .optimize = optimize });
    const password_bench_module = b.createModule(.{ .root_source_file = b.path("benchmarks/passwords.zig"), .target = target, .optimize = optimize, .link_libc = true });
    password_bench_module.addImport("bcrypt_lanes", password_module);
    const password_bench = b.addExecutable(.{ .name = "password-bench", .root_module = password_bench_module });
    b.step("password-bench", "Compare scalar and independent bcrypt lanes at cost ten").dependOn(&b.addRunArtifact(password_bench).step);
    const catalog = b.createModule(.{ .root_source_file = b.path("src/query_catalog.zig"), .target = target, .optimize = optimize });
    catalog.addOptions("build_options", options);
    const queries = b.createModule(.{ .root_source_file = b.path("benchmarks/queries.zig"), .target = target, .optimize = optimize, .link_libc = true });
    queries.addImport("query_catalog", catalog);
    const query_dump = b.addExecutable(.{ .name = "query-dump", .root_module = queries });
    b.step("dump-queries", "Print exact prepared read templates for independent query-plan diagnostics").dependOn(&b.addRunArtifact(query_dump).step);
}
