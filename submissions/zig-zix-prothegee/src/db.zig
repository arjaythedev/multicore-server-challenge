//! Per-worker PostgreSQL connection for the request path.

const std = @import("std");
const zix = @import("zix");

const postgrez = zix.Driver.postgrez;

// --------------------------------------------------------- //

var g_config: postgrez.Config = undefined;
var g_io: std.Io = undefined;
var g_ready: bool = false;

/// One connection per worker thread, opened on first use.
threadlocal var tl_conn: ?*postgrez.Conn = null;

const DEFAULT_CPU: usize = 8;

// --------------------------------------------------------- //

/// Store the database target once at startup.
pub fn init(database_url: []const u8, io: std.Io) !void {
    const cpus = std.Thread.getCpuCount() catch DEFAULT_CPU;
    const park_len = @max(512, 8 * 1024 / cpus);

    g_config = try postgrez.parseUrl(database_url);
    g_config.tls = .OFF;
    g_config.dispatch_model = .URING;
    g_config.process_queue_len = park_len;
    g_io = io;
    g_ready = true;
}

/// The calling worker's connection.
pub fn conn() !*postgrez.Conn {
    if (tl_conn) |existing| return existing;
    if (!g_ready) return error.DatabaseNotConfigured;

    const opened = try postgrez.Conn.connect(std.heap.smp_allocator, g_io, g_config);
    tl_conn = opened;

    return opened;
}
