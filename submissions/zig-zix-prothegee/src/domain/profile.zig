//! Profile domain: the read model and the follow edges.

const std = @import("std");
const zix = @import("zix");

const postgrez = zix.Driver.postgrez;

// --------------------------------------------------------- //

pub const Profile = struct {
    username: []const u8,
    bio: ?[]const u8,
    image: ?[]const u8,
    following: bool,
};

pub const Error = error{Database};

const ProfileRow = struct {
    id: i64,
    username: []const u8,
    bio: ?[]const u8,
    image: ?[]const u8,
    following: bool,
};

const Target = struct {
    id: i64,
    username: []const u8,
    bio: ?[]const u8,
    image: ?[]const u8,
};

// --------------------------------------------------------- //

const SQL_FIND =
    \\SELECT u.id, u.username, u.bio, u.image,
    \\EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following
    \\FROM users u WHERE u.username = $2
;

const SQL_TARGET = "SELECT id, username, bio, image FROM users WHERE username = $1";

const SQL_FOLLOW =
    "INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2) ON CONFLICT DO NOTHING";

const SQL_UNFOLLOW = "DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2";

// --------------------------------------------------------- //

fn parseProfile(result: *postgrez.Result, allocator: std.mem.Allocator) Error!?Profile {
    const maybe_row = result.next() catch return error.Database;
    const row = maybe_row orelse return null;
    const found = postgrez.row.parseRow(ProfileRow, allocator, row.columns, row.cells, .{}) catch {
        return error.Database;
    };

    return .{
        .username = found.username,
        .bio = found.bio,
        .image = found.image,
        .following = found.following,
    };
}

fn findTarget(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    username: []const u8,
) Error!?Target {
    var result = conn.rows(SQL_TARGET, .{username}) catch return error.Database;
    defer result.deinit();

    const maybe_row = result.next() catch return error.Database;
    const row = maybe_row orelse return null;

    return postgrez.row.parseRow(Target, allocator, row.columns, row.cells, .{}) catch error.Database;
}

// --------------------------------------------------------- //

/// A prepared profile read. The server-side statement keeps the plan, not the rows.
pub const Query = struct {
    statement: postgrez.Statement,

    /// Prepare the statement once on this connection.
    pub fn init(conn: *postgrez.Conn) Error!Query {
        return .{ .statement = conn.prepare(SQL_FIND) catch return error.Database };
    }

    /// Close the server-side statement (best effort).
    pub fn deinit(self: *Query) void {
        self.statement.deinit();
    }

    /// One profile with the viewer's follow state.
    pub fn findByUsername(
        self: *Query,
        allocator: std.mem.Allocator,
        viewer: i64,
        username: []const u8,
    ) Error!?Profile {
        var result = self.statement.rows(.{ viewer, username }) catch return error.Database;
        defer result.deinit();

        return parseProfile(&result, allocator);
    }
};

threadlocal var tl_query: ?Query = null;
threadlocal var tl_query_conn: ?*postgrez.Conn = null;

/// The prepared query for this worker's connection, prepared once.
pub fn prepared(conn: *postgrez.Conn) Error!*Query {
    if (tl_query != null and tl_query_conn == conn) {
        return &tl_query.?;
    }

    if (tl_query) |*query| {
        query.deinit();
        tl_query = null;
    }

    tl_query = try Query.init(conn);
    tl_query_conn = conn;

    return &tl_query.?;
}

// --------------------------------------------------------- //

/// One profile with the viewer's follow state, via the unnamed statement.
pub fn findByUsername(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    viewer: i64,
    username: []const u8,
) Error!?Profile {
    var result = conn.rows(SQL_FIND, .{ viewer, username }) catch return error.Database;
    defer result.deinit();

    return parseProfile(&result, allocator);
}

/// Insert the follow edge and return the target profile with `following` true.
pub fn follow(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    viewer: i64,
    username: []const u8,
) Error!?Profile {
    const target = (try findTarget(conn, allocator, username)) orelse return null;

    _ = conn.exec(SQL_FOLLOW, .{ viewer, target.id }) catch return error.Database;

    return .{
        .username = target.username,
        .bio = target.bio,
        .image = target.image,
        .following = true,
    };
}

/// Remove the follow edge and return the target profile with `following` false.
pub fn unfollow(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    viewer: i64,
    username: []const u8,
) Error!?Profile {
    const target = (try findTarget(conn, allocator, username)) orelse return null;

    _ = conn.exec(SQL_UNFOLLOW, .{ viewer, target.id }) catch return error.Database;

    return .{
        .username = target.username,
        .bio = target.bio,
        .image = target.image,
        .following = false,
    };
}
