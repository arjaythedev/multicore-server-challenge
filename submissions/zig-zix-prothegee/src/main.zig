const std = @import("std");
const zix = @import("zix");
const builtin = @import("builtin");

const api_users = @import("handlers/api_users.zig");
const api_users_login = @import("handlers/api_users_login.zig");
const api_user = @import("handlers/api_user.zig");

const api_profiles_username = @import("handlers/api_profiles_username.zig");
const api_profiles_username_follow = @import("handlers/api_profiles_username_follow.zig");

// --------------------------------------------------------- //

const IP = if (builtin.mode == .debug) "127.0.0.1" else "0.0.0.0";
const PORT: u16 = if (builtin.mode == .debug) 3000 else 80;
const DEFAULT_CPU: usize = 8;
const DIR_LOG_PATH: []const u8 = "./logs";
const ALLOW_DEBUG = builtin.mode == .debug;

// --------------------------------------------------------- //

fn createLogDir(io: std.Io, force_fail: bool) void {
    var err: bool = false;
    std.Io.Dir.cwd().createDirPath(io, DIR_LOG_PATH) catch |e| {
        std.debug.print("ERROR: create log dir path {any}\n", .{e});
    err = true;
    };

    if (err and force_fail) {
        return;
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
        .path = api_profiles_username.PATH,
        .handler = api_profiles_username.RESPONSE,
        .kind = .PARAM,
    },
    .{
        .path = api_profiles_username_follow.PATH,
        .handler = api_profiles_username_follow.RESPONSE,
        .kind = .PARAM,
    },
    // Articles
    // Favorites
    // Comments
    // Tags
});

pub fn main(init: std.process.Init) !void {
    std.debug.print("zix entry: conduit\n", .{});
    const cpus = std.Thread.getCpuCount() catch DEFAULT_CPU;
    const park_len = @max(512, 16 * 1024 / cpus);

    createLogDir(init.io, true);

    var allocator_logger = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer allocator_logger.deinit();
    var logger = try zix.Logger.init(allocator_logger.allocator(), .{
        .save_path = DIR_LOG_PATH,
        .save_file = "conduit",
        .save_min_level = .INFO,
        .console = if(ALLOW_DEBUG) .ALWAYS else .OFF,
    });
    defer logger.deinit();

    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = init.io,
        .ip = IP,
        .port = PORT,
        .logger = &logger,
        //
        .workers = 0,
        .dispatch_model = .URING,
        //
        .send_date_header = true,
        .max_response_headers = .MINIMAL,
        //
        .kernel_backlog = 16 * 1024,
        .max_recv_buf = 6 * 1024,
        .max_request_body = 16 * 1024 * 1024,
        //
        .response_cache = true,
        .cache_max_entries = 256,
        .cache_max_value_bytes = 16 * 1024,
        .cache_ttl_ms = 2_000,
        .cache_max_total_bytes = 16 * 1024,
        //
        .uring_send_buf_size = 16 * 1024,
        .uring_idle_pool_floor = 16,
        .uring_idle_pool_ceiling = 1 * 1024,
        .process_queue_len = park_len,
    });
    defer server.deinit();

    try server.run();
}
