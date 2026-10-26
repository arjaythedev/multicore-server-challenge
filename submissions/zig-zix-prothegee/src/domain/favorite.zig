//! Favorite edges between a user and an article.

const zix = @import("zix");

const postgrez = zix.Driver.postgrez;

// --------------------------------------------------------- //

pub const Error = error{Database};

// --------------------------------------------------------- //

const SQL_ADD = "INSERT INTO favorites (user_id, article_id) VALUES ($1, $2) ON CONFLICT DO NOTHING";

const SQL_REMOVE = "DELETE FROM favorites WHERE user_id = $1 AND article_id = $2";

// --------------------------------------------------------- //

/// Add the edge. A duplicate is a no-op.
pub fn add(conn: *postgrez.Conn, viewer: i64, article_id: i64) Error!void {
    _ = conn.exec(SQL_ADD, .{ viewer, article_id }) catch return error.Database;
}

/// Remove the edge. A missing edge is a no-op.
pub fn remove(conn: *postgrez.Conn, viewer: i64, article_id: i64) Error!void {
    _ = conn.exec(SQL_REMOVE, .{ viewer, article_id }) catch return error.Database;
}
