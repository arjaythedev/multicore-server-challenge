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

const SQL_LIST =
    \\SELECT c.id, c.body,
    \\to_char(c.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS created_at,
    \\to_char(c.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS updated_at,
    \\u.username, u.bio, u.image,
    \\c.author_id IN (SELECT followee_id FROM follows WHERE follower_id = $1) AS following
    \\FROM comments c JOIN users u ON u.id = c.author_id
    \\WHERE c.article_id = $2
    \\ORDER BY c.created_at DESC, c.id DESC LIMIT 100
;

const SQL_LIST_BY_SLUG =
    \\SELECT c.id, c.body,
    \\to_char(c.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS created_at,
    \\to_char(c.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS updated_at,
    \\u.username, u.bio, u.image,
    \\c.author_id IN (SELECT followee_id FROM follows WHERE follower_id = $1) AS following
    \\FROM comments c JOIN articles a ON a.id = c.article_id
    \\JOIN users u ON u.id = c.author_id
    \\WHERE a.slug = $2
    \\ORDER BY c.created_at DESC, c.id DESC LIMIT 100
;

const SQL_BY_ID =
    \\SELECT c.id, c.body,
    \\to_char(c.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS created_at,
    \\to_char(c.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS updated_at,
    \\u.username, u.bio, u.image,
    \\EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following
    \\FROM comments c JOIN users u ON u.id = c.author_id
    \\WHERE c.id = $2
;

const SQL_INSERT = "INSERT INTO comments (article_id, author_id, body) VALUES ($1, $2, $3) RETURNING id";

const SQL_OWNER =
    \\SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
    \\WHERE c.id = $1 AND a.slug = $2
;

const SQL_DELETE = "DELETE FROM comments WHERE id = $1";

// --------------------------------------------------------- //

fn parseList(result: *postgrez.Result, allocator: std.mem.Allocator) Error![]Comment {
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

fn parseOne(result: *postgrez.Result, allocator: std.mem.Allocator) Error!?Comment {
    const maybe_row = result.next() catch return error.Database;
    const row = maybe_row orelse return null;

    return postgrez.row.parseRow(Comment, allocator, row.columns, row.cells, .{}) catch error.Database;
}

// --------------------------------------------------------- //

/// A prepared comment list by article slug. The server-side statement keeps
/// the plan, not the rows.
pub const ListQuery = struct {
    statement: postgrez.Statement,

    /// Prepare the statement once on this connection.
    pub fn init(conn: *postgrez.Conn) Error!ListQuery {
        return .{ .statement = conn.prepare(SQL_LIST_BY_SLUG) catch return error.Database };
    }

    /// Close the server-side statement (best effort).
    pub fn deinit(self: *ListQuery) void {
        self.statement.deinit();
    }

    /// The newest 100 comments on the article with this slug.
    pub fn listBySlug(
        self: *ListQuery,
        allocator: std.mem.Allocator,
        viewer: i64,
        slug: []const u8,
    ) Error![]Comment {
        var result = self.statement.rows(.{ viewer, slug }) catch return error.Database;
        defer result.deinit();

        return parseList(&result, allocator);
    }
};

threadlocal var tl_query: ?ListQuery = null;
threadlocal var tl_query_conn: ?*postgrez.Conn = null;

/// The prepared list query for this worker's connection, prepared once.
pub fn prepared(conn: *postgrez.Conn) Error!*ListQuery {
    if (tl_query != null and tl_query_conn == conn) {
        return &tl_query.?;
    }

    if (tl_query) |*query| {
        query.deinit();
        tl_query = null;
    }

    tl_query = try ListQuery.init(conn);
    tl_query_conn = conn;

    return &tl_query.?;
}

// --------------------------------------------------------- //

/// The newest 100 comments on one article, via the unnamed statement.
pub fn list(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    viewer: i64,
    article_id: i64,
) Error![]Comment {
    var result = conn.rows(SQL_LIST, .{ viewer, article_id }) catch return error.Database;
    defer result.deinit();

    return parseList(&result, allocator);
}

/// One comment by id.
pub fn findById(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    viewer: i64,
    id: i64,
) Error!?Comment {
    var result = conn.rows(SQL_BY_ID, .{ viewer, id }) catch return error.Database;
    defer result.deinit();

    return parseOne(&result, allocator);
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
