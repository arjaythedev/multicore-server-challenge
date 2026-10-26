//! Article comments: list, create, and delete.

const std = @import("std");
const zix = @import("zix");

const postgrez = zix.Driver.postgrez;

// --------------------------------------------------------- //

pub const Comment = struct {
    id: i64,
    body: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    username: []const u8,
    bio: ?[]const u8,
    image: ?[]const u8,
    following: bool,
};

pub const Error = error{Database};

const AuthorId = struct {
    author_id: i64,
};

// --------------------------------------------------------- //

const COMMENT_SELECT = "SELECT c.id, c.body, " ++
    "to_char(c.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"') AS created_at, " ++
    "to_char(c.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"') AS updated_at, " ++
    "u.username, u.bio, u.image, " ++
    "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following " ++
    "FROM comments c JOIN users u ON u.id = c.author_id ";

const SQL_LIST = COMMENT_SELECT ++ "WHERE c.article_id = $2 ORDER BY c.created_at DESC, c.id DESC LIMIT 100";

const SQL_BY_ID = COMMENT_SELECT ++ "WHERE c.id = $2";

const SQL_INSERT = "INSERT INTO comments (article_id, author_id, body) VALUES ($1, $2, $3) RETURNING id";

const SQL_OWNER = "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id " ++
    "WHERE c.id = $1 AND a.slug = $2";

const SQL_DELETE = "DELETE FROM comments WHERE id = $1";

// --------------------------------------------------------- //

fn runList(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    sql: []const u8,
    args: anytype,
) Error![]Comment {
    var result = conn.rows(sql, args) catch return error.Database;
    defer result.deinit();

    var comments: std.ArrayList(Comment) = .empty;
    errdefer comments.deinit(allocator);

    while (result.next() catch return error.Database) |row| {
        const comment = postgrez.row.parseRow(Comment, allocator, row.columns, row.cells, .{}) catch {
            return error.Database;
        };

        comments.append(allocator, comment) catch return error.Database;
    }

    return comments.toOwnedSlice(allocator) catch error.Database;
}

fn runOne(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    sql: []const u8,
    args: anytype,
) Error!?Comment {
    var result = conn.rows(sql, args) catch return error.Database;
    defer result.deinit();

    const maybe_row = result.next() catch return error.Database;
    const row = maybe_row orelse return null;

    return postgrez.row.parseRow(Comment, allocator, row.columns, row.cells, .{}) catch error.Database;
}

// --------------------------------------------------------- //

/// The newest 100 comments on one article.
pub fn list(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    viewer: i64,
    article_id: i64,
) Error![]Comment {
    return runList(conn, allocator, SQL_LIST, .{ viewer, article_id });
}

/// One comment by id.
pub fn findById(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    viewer: i64,
    id: i64,
) Error!?Comment {
    return runOne(conn, allocator, SQL_BY_ID, .{ viewer, id });
}

/// The author of a comment on the named article, for the delete check.
pub fn ownerBySlugAndId(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    slug: []const u8,
    id: i64,
) Error!?i64 {
    var result = conn.rows(SQL_OWNER, .{ id, slug }) catch return error.Database;
    defer result.deinit();

    const maybe_row = result.next() catch return error.Database;
    const row = maybe_row orelse return null;
    const found = postgrez.row.parseRow(AuthorId, allocator, row.columns, row.cells, .{}) catch {
        return error.Database;
    };

    return found.author_id;
}

/// Insert one comment and return the full row.
pub fn create(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    article_id: i64,
    author_id: i64,
    body: []const u8,
) Error!?Comment {
    const maybe_row = conn.queryRow(struct { id: i64 }, SQL_INSERT, .{ article_id, author_id, body }) catch {
        return error.Database;
    };
    const row = maybe_row orelse return error.Database;

    return findById(conn, allocator, author_id, row.id);
}

/// Delete one comment.
pub fn delete(conn: *postgrez.Conn, id: i64) Error!void {
    _ = conn.exec(SQL_DELETE, .{id}) catch return error.Database;
}
