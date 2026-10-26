//! Tag domain: the tag list the tags endpoint serves.

const std = @import("std");
const zix = @import("zix");

const postgrez = zix.Driver.postgrez;

// --------------------------------------------------------- //

pub const Error = error{Database};

const Name = struct {
    name: []const u8,
};

// --------------------------------------------------------- //

const SQL_LIST = "SELECT name FROM tags ORDER BY name";

// --------------------------------------------------------- //

fn parseNames(result: *postgrez.Result, allocator: std.mem.Allocator) Error![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(allocator);

    while (result.next() catch return error.Database) |row_view| {
        const tag = postgrez.row.parseRow(Name, allocator, row_view.columns, row_view.cells, .{}) catch {
            return error.Database;
        };

        names.append(allocator, tag.name) catch return error.Database;
    }

    return names.toOwnedSlice(allocator) catch error.Database;
}

// --------------------------------------------------------- //

/// A prepared tag query. The server-side statement keeps the plan, not the rows.
pub const Query = struct {
    statement: postgrez.Statement,

    /// Prepare the statement once on this connection.
    pub fn init(conn: *postgrez.Conn) Error!Query {
        return .{ .statement = conn.prepare(SQL_LIST) catch return error.Database };
    }

    /// Close the server-side statement (best effort).
    pub fn deinit(self: *Query) void {
        self.statement.deinit();
    }

    /// Every tag name, sorted by name, allocated from `allocator`.
    pub fn list(self: *Query, allocator: std.mem.Allocator) Error![]const []const u8 {
        var result = self.statement.rows(.{}) catch return error.Database;
        defer result.deinit();

        return parseNames(&result, allocator);
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

/// Every tag name via the unnamed statement. Used by the integration test.
pub fn list(conn: *postgrez.Conn, allocator: std.mem.Allocator) Error![]const []const u8 {
    var result = conn.rows(SQL_LIST, .{}) catch return error.Database;
    defer result.deinit();

    return parseNames(&result, allocator);
}
