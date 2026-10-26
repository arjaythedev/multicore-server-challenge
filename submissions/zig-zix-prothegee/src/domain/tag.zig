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

/// Every tag name, sorted by name, allocated from `allocator`.
pub fn list(conn: *postgrez.Conn, allocator: std.mem.Allocator) Error![]const []const u8 {
    var result = conn.rows(SQL_LIST, .{}) catch return error.Database;
    defer result.deinit();

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
