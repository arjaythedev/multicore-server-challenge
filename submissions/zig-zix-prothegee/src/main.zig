const std = @import("std");
const zix = @import("zix");
const builtin = @import("builtin");

const app = @import("app.zig");
const config = @import("config.zig");
const db = @import("db.zig");

const api_users = @import("handlers/api_users.zig");
const api_users_login = @import("handlers/api_users_login.zig");
const api_user = @import("handlers/api_user.zig");
const api_profiles_username = @import("handlers/api_profiles_username.zig");
const api_profiles_username_follow = @import("handlers/api_profiles_username_follow.zig");
const api_articles = @import("handlers/api_articles.zig");
const api_articles_feed = @import("handlers/api_articles_feed.zig");
const api_articles_slug = @import("handlers/api_articles_slug.zig");
const api_articles_slug_favorite = @import("handlers/api_articles_slug_favorite.zig");
const api_articles_slug_comments = @import("handlers/api_articles_slug_comments.zig");
const api_articles_slug_comments_id = @import("handlers/api_articles_slug_comments_id.zig");
const api_tags = @import("handlers/api_tags.zig");

// --------------------------------------------------------- //

const DEFAULT_CPU: usize = 8;
const DIR_LOG_PATH: []const u8 = "./logs";
const ALLOW_DEBUG = builtin.mode == .debug;

// --------------------------------------------------------- //

fn createLogDir(io: std.Io) void {
    std.Io.Dir.cwd().createDirPath(io, DIR_LOG_PATH) catch |err| {
        std.debug.print("ERROR: create log dir path {any}\n", .{err});
    };
}

fn setupFileLimit() void {
    std.process.raiseFileDescriptorLimit();

    const limits = std.posix.getrlimit(.NOFILE) catch return;
    std.debug.print("conduit: open file limit {d} (hard {d})\n", .{ limits.cur, limits.max });

    if (limits.cur < 2048) {
        std.debug.print("conduit: WARNING: open file limit {d} is below the 2048 budget\n", .{limits.cur});
    }
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    // User and auth
    .{
        .path = api_users.PATH,
        .handler = api_users.RESPONSE,
    },
    .{
        .path = api_users_login.PATH,
        .handler = api_users_login.RESPONSE,
    },
    .{
        .path = api_user.PATH,
        .handler = api_user.RESPONSE,
    },
    // Profiles
    .{
        .path = api_profiles_username_follow.PATH,
        .handler = api_profiles_username_follow.RESPONSE,
        .kind = .PARAM,
    },
    .{
        .path = api_profiles_username.PATH,
        .handler = api_profiles_username.RESPONSE,
        .kind = .PARAM,
    },
    // Articles
    .{
        .path = api_articles.PATH,
        .handler = api_articles.RESPONSE,
    },
    .{
        .path = api_articles_feed.PATH,
        .handler = api_articles_feed.RESPONSE,
    },
    .{
        .path = api_articles_slug.PATH,
        .handler = api_articles_slug.RESPONSE,
        .kind = .PARAM,
    },
    // Favorites
    .{
        .path = api_articles_slug_favorite.PATH,
        .handler = api_articles_slug_favorite.RESPONSE,
        .kind = .PARAM,
    },
    // Comments
    .{
        .path = api_articles_slug_comments_id.PATH,
        .handler = api_articles_slug_comments_id.RESPONSE,
        .kind = .PARAM,
    },
    .{
        .path = api_articles_slug_comments.PATH,
        .handler = api_articles_slug_comments.RESPONSE,
        .kind = .PARAM,
    },
    // Tags
    .{
        .path = api_tags.PATH,
        .handler = api_tags.RESPONSE,
    },
});

// --------------------------------------------------------- //

pub fn main(init: std.process.Init) !void {
    setupFileLimit();
    createLogDir(init.io);

    const defaults = config.Defaults{
        .host = if (builtin.mode == .debug) "127.0.0.1" else "0.0.0.0",
        .port = if (builtin.mode == .debug) "3000" else "80",
    };

    const cfg = config.load(init.environ_map, defaults) catch |err| {
        std.debug.print("conduit: configuration error: {s}\n", .{@errorName(err)});

        return err;
    };

    app.init(cfg);
    try db.init(cfg.database_url, init.io);

    const cpus = std.Thread.getCpuCount() catch DEFAULT_CPU;
    const park_len = @max(512, 8 * 1024 / cpus);

    var allocator_logger = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer allocator_logger.deinit();
    var logger = try zix.Logger.init(allocator_logger.allocator(), .{
        .save_path = DIR_LOG_PATH,
        .save_file = "conduit",
        .save_min_level = .INFO,
        .console = if (ALLOW_DEBUG) .ALWAYS else .OFF,
    });
    defer logger.deinit();

    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = init.io,
        .ip = cfg.host,
        .port = cfg.port,
        .logger = &logger,
        .workers = 0,
        .dispatch_model = .URING,
        .send_date_header = false,
        .max_response_headers = .{ .CUSTOM = 8 },
        .kernel_backlog = 16 * 1024,
        .max_recv_buf = 16 * 1024,
        .max_request_body = 0, // disable check
        .busy_poll_us = 0,
        .uring_send_buf_size = 16 * 1024,
        .uring_idle_pool_floor = 16,
        .uring_idle_pool_ceiling = 1 * 1024,
        .process_queue_len = park_len,
    });
    defer server.deinit();

    std.debug.print("conduit: listening on {s}:{d}\n", .{ cfg.host, cfg.port });

    try server.run();
}
