//! Favorite edges between a user and an article.

const std = @import("std");
const zix = @import("zix");

const postgrez = zix.Driver.postgrez;

// --------------------------------------------------------- //

pub const Error = error{Database};

const ArticleId = struct {
    id: i64,
};

// --------------------------------------------------------- //

const SQL_ARTICLE_ID = "SELECT id FROM articles WHERE slug = $1";

const SQL_ADD = "INSERT INTO favorites (user_id, article_id) VALUES ($1, $2) ON CONFLICT DO NOTHING";

const SQL_REMOVE = "DELETE FROM favorites WHERE user_id = $1 AND article_id = $2";

// --------------------------------------------------------- //

/// The article id for a slug, or null when the article is missing.
pub fn findArticleId(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    slug: []const u8,
) Error!?i64 {
    var result = conn.rows(SQL_ARTICLE_ID, .{slug}) catch return error.Database;
    defer result.deinit();

    const maybe_row = result.next() catch return error.Database;
    const row = maybe_row orelse return null;
    const found = postgrez.row.parseRow(ArticleId, allocator, row.columns, row.cells, .{}) catch {
        return error.Database;
    };

    return found.id;
}

/// Add the edge. A duplicate is a no-op.
pub fn add(conn: *postgrez.Conn, viewer: i64, article_id: i64) Error!void {
    _ = conn.exec(SQL_ADD, .{ viewer, article_id }) catch return error.Database;
}

/// Remove the edge. A missing edge is a no-op.
pub fn remove(conn: *postgrez.Conn, viewer: i64, article_id: i64) Error!void {
    _ = conn.exec(SQL_REMOVE, .{ viewer, article_id }) catch return error.Database;
}
