//! User domain: the rows and statements the user and auth endpoints need.

const std = @import("std");
const zix = @import("zix");

const postgrez = zix.Driver.postgrez;

// --------------------------------------------------------- //

pub const User = struct {
    id: i64,
    username: []const u8,
    email: []const u8,
    bio: ?[]const u8,
    image: ?[]const u8,
};

pub const UserWithSecret = struct {
    id: i64,
    username: []const u8,
    email: []const u8,
    bio: ?[]const u8,
    image: ?[]const u8,
    password_hash: []const u8,
};

pub const Error = error{
    Duplicate,
    Database,
};

// --------------------------------------------------------- //

const SQL_INSERT =
    "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image";

const SQL_FIND_BY_EMAIL =
    "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1";

const SQL_FIND_BY_ID =
    "SELECT id, username, email, bio, image FROM users WHERE id = $1";

const SQL_UPDATE =
    \\UPDATE users SET
    \\  email = COALESCE($2, email),
    \\  username = COALESCE($3, username),
    \\  password_hash = COALESCE($4, password_hash),
    \\  bio = COALESCE($5, bio),
    \\  image = COALESCE($6, image)
    \\WHERE id = $1
    \\RETURNING id, username, email, bio, image
;

// --------------------------------------------------------- //

/// Map a driver error, keeping the unique violation apart.
fn dbError(conn: *postgrez.Conn, err: anyerror) Error {
    if (err == error.PostgrezServerError and conn.lastServerError().state == .UNIQUE_VIOLATION) {
        return error.Duplicate;
    }

    return error.Database;
}

/// Insert one user and return the stored row.
pub fn insert(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    username: []const u8,
    email: []const u8,
    password_hash: []const u8,
) Error!User {
    var result = conn.rows(SQL_INSERT, .{ username, email, password_hash }) catch |err| return dbError(conn, err);
    defer result.deinit();

    const maybe_row = result.next() catch |err| return dbError(conn, err);
    const row = maybe_row orelse return error.Database;

    return postgrez.row.parseRow(User, allocator, row.columns, row.cells, .{}) catch error.Database;
}

/// Find one user by email, including the password hash.
pub fn findByEmail(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    email: []const u8,
) Error!?UserWithSecret {
    var result = conn.rows(SQL_FIND_BY_EMAIL, .{email}) catch |err| return dbError(conn, err);
    defer result.deinit();

    const maybe_row = result.next() catch |err| return dbError(conn, err);
    const row = maybe_row orelse return null;

    return postgrez.row.parseRow(UserWithSecret, allocator, row.columns, row.cells, .{}) catch error.Database;
}

/// Find one user by id.
pub fn findById(conn: *postgrez.Conn, allocator: std.mem.Allocator, id: i64) Error!?User {
    var result = conn.rows(SQL_FIND_BY_ID, .{id}) catch |err| return dbError(conn, err);
    defer result.deinit();

    const maybe_row = result.next() catch |err| return dbError(conn, err);
    const row = maybe_row orelse return null;

    return postgrez.row.parseRow(User, allocator, row.columns, row.cells, .{}) catch error.Database;
}

/// Update the fields that are present and return the stored row.
pub fn update(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    id: i64,
    email: ?[]const u8,
    username: ?[]const u8,
    password_hash: ?[]const u8,
    bio: ?[]const u8,
    image: ?[]const u8,
) Error!?User {
    var result = conn.rows(
        SQL_UPDATE,
        .{ id, email, username, password_hash, bio, image },
    ) catch |err| return dbError(conn, err);
    defer result.deinit();

    const maybe_row = result.next() catch |err| return dbError(conn, err);
    const row = maybe_row orelse return null;

    return postgrez.row.parseRow(User, allocator, row.columns, row.cells, .{}) catch error.Database;
}
