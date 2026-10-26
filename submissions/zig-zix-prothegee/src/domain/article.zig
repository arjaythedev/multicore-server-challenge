//! Article domain: list, feed, detail, create, update, and delete.

const std = @import("std");
const zix = @import("zix");

const postgrez = zix.Driver.postgrez;
const jzon = zix.jzon;

// --------------------------------------------------------- //

pub const TagList = struct {
    tags: []const []const u8,
};

pub const Article = struct {
    id: i64,
    slug: []const u8,
    title: []const u8,
    description: []const u8,
    body: []const u8 = "",
    created_at: []const u8,
    updated_at: []const u8,
    tag_list: TagList,
    favorites_count: i64,
    favorited: bool,
    username: []const u8,
    bio: ?[]const u8,
    image: ?[]const u8,
    following: bool,
};

pub const Owner = struct {
    id: i64,
    author_id: i64,
};

pub const Filter = union(enum) {
    NONE,
    TAG: []const u8,
    AUTHOR: []const u8,
    FAVORITED: []const u8,
};

pub const Page = struct {
    articles: []Article,
    count: i64,
};

pub const Error = error{Database};

const Count = struct {
    count: i64,
};

const ArticleId = struct {
    id: i64,
};

// --------------------------------------------------------- //

fn columns(comptime with_body: bool) []const u8 {
    return "a.id, a.slug, a.title, a.description, " ++
        (if (with_body) "a.body, " else "") ++
        "to_char(a.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"') AS created_at, " ++
        "to_char(a.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"') AS updated_at, " ++
        "jsonb_build_object('tags', ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id " ++
        "WHERE at.article_id = a.id ORDER BY t.name)) AS tag_list, " ++
        "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, " ++
        "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, " ++
        "u.username, u.bio, u.image, " ++
        "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following ";
}

const ARTICLE_LIST_SELECT = "SELECT " ++ columns(false) ++ "FROM articles a JOIN users u ON u.id = a.author_id ";

const ARTICLE_FULL_SELECT = "SELECT " ++ columns(true) ++ "FROM articles a JOIN users u ON u.id = a.author_id ";

const SQL_LIST_NONE = ARTICLE_LIST_SELECT ++ "ORDER BY a.id DESC LIMIT $2 OFFSET $3";

const SQL_LIST_TAG = ARTICLE_LIST_SELECT ++
    "WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = " ++
    "(SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) " ++
    "ORDER BY a.id DESC";

const SQL_LIST_AUTHOR = ARTICLE_LIST_SELECT ++
    "WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4) " ++
    "ORDER BY a.id DESC LIMIT $2 OFFSET $3";

const SQL_LIST_FAVORITED = ARTICLE_LIST_SELECT ++
    "WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = " ++
    "(SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) " ++
    "ORDER BY a.id DESC";

const SQL_COUNT_NONE = "SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s";

const SQL_COUNT_TAG = "SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = " ++
    "(SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s";

const SQL_COUNT_AUTHOR = "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = " ++
    "(SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s";

const SQL_COUNT_FAVORITED = "SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = " ++
    "(SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s";

const SQL_FEED = ARTICLE_LIST_SELECT ++
    "WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL " ++
    "(SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x " ++
    "WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC";

const SQL_FEED_COUNT = "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN " ++
    "(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s";

const SQL_BY_SLUG = ARTICLE_FULL_SELECT ++ "WHERE a.slug = $2";

const SQL_BY_ID = ARTICLE_FULL_SELECT ++ "WHERE a.id = $2";

const SQL_ARTICLE_ID = "SELECT id FROM articles WHERE slug = $1";

const SQL_INSERT = "INSERT INTO articles (id, slug, author_id, title, description, body) " ++
    "SELECT n.id, trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id, $1, $2, $3, $4 " ++
    "FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n RETURNING id";

const SQL_INSERT_TAGS = "INSERT INTO tags (name) " ++
    "SELECT DISTINCT value FROM jsonb_array_elements_text($1::jsonb) ON CONFLICT (name) DO NOTHING";

const SQL_INSERT_ARTICLE_TAGS = "INSERT INTO article_tags (article_id, tag_id) " ++
    "SELECT $1, t.id FROM tags t WHERE t.name IN (SELECT value FROM jsonb_array_elements_text($2::jsonb))";

const SQL_OWNER = "SELECT id, author_id FROM articles WHERE slug = $1";

const SQL_UPDATE = "UPDATE articles SET " ++
    "title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body), " ++
    "slug = CASE WHEN $2::text IS NULL THEN slug ELSE " ++
    "trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END, " ++
    "updated_at = now() WHERE id = $1";

const SQL_DELETE = "DELETE FROM articles WHERE id = $1";

// --------------------------------------------------------- //

fn runPage(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    sql: []const u8,
    args: anytype,
) Error![]Article {
    var result = conn.rows(sql, args) catch return error.Database;
    defer result.deinit();

    var articles: std.ArrayList(Article) = .empty;
    errdefer articles.deinit(allocator);

    while (result.next() catch return error.Database) |row| {
        const article = postgrez.row.parseRow(Article, allocator, row.columns, row.cells, .{}) catch {
            return error.Database;
        };

        articles.append(allocator, article) catch return error.Database;
    }

    return articles.toOwnedSlice(allocator) catch error.Database;
}

fn runCount(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    sql: []const u8,
    args: anytype,
) Error!i64 {
    var result = conn.rows(sql, args) catch return error.Database;
    defer result.deinit();

    const maybe_row = result.next() catch return error.Database;
    const row = maybe_row orelse return 0;
    const value = postgrez.row.parseRow(Count, allocator, row.columns, row.cells, .{}) catch {
        return error.Database;
    };

    return value.count;
}

fn runOne(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    sql: []const u8,
    args: anytype,
) Error!?Article {
    var result = conn.rows(sql, args) catch return error.Database;
    defer result.deinit();

    const maybe_row = result.next() catch return error.Database;
    const row = maybe_row orelse return null;

    return postgrez.row.parseRow(Article, allocator, row.columns, row.cells, .{}) catch error.Database;
}

// --------------------------------------------------------- //

/// One page of articles plus the capped total.
pub fn list(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    viewer: i64,
    filter: Filter,
    limit: i64,
    offset: i64,
) Error!Page {
    return switch (filter) {
        .NONE => .{
            .articles = try runPage(conn, allocator, SQL_LIST_NONE, .{ viewer, limit, offset }),
            .count = try runCount(conn, allocator, SQL_COUNT_NONE, .{}),
        },
        .TAG => |tag| .{
            .articles = try runPage(conn, allocator, SQL_LIST_TAG, .{ viewer, limit, offset, tag }),
            .count = try runCount(conn, allocator, SQL_COUNT_TAG, .{tag}),
        },
        .AUTHOR => |author| .{
            .articles = try runPage(conn, allocator, SQL_LIST_AUTHOR, .{ viewer, limit, offset, author }),
            .count = try runCount(conn, allocator, SQL_COUNT_AUTHOR, .{author}),
        },
        .FAVORITED => |favorited| .{
            .articles = try runPage(conn, allocator, SQL_LIST_FAVORITED, .{ viewer, limit, offset, favorited }),
            .count = try runCount(conn, allocator, SQL_COUNT_FAVORITED, .{favorited}),
        },
    };
}

/// The viewer's feed, newest first.
pub fn feed(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    viewer: i64,
    limit: i64,
    offset: i64,
) Error!Page {
    return .{
        .articles = try runPage(conn, allocator, SQL_FEED, .{ viewer, limit, offset }),
        .count = try runCount(conn, allocator, SQL_FEED_COUNT, .{viewer}),
    };
}

/// One full article by slug.
pub fn findBySlug(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    viewer: i64,
    slug: []const u8,
) Error!?Article {
    return runOne(conn, allocator, SQL_BY_SLUG, .{ viewer, slug });
}

/// One full article by id.
pub fn findById(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    viewer: i64,
    id: i64,
) Error!?Article {
    return runOne(conn, allocator, SQL_BY_ID, .{ viewer, id });
}

/// The owner of one article by slug, for update and delete checks.
pub fn ownerBySlug(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    slug: []const u8,
) Error!?Owner {
    var result = conn.rows(SQL_OWNER, .{slug}) catch return error.Database;
    defer result.deinit();

    const maybe_row = result.next() catch return error.Database;
    const row = maybe_row orelse return null;

    return postgrez.row.parseRow(Owner, allocator, row.columns, row.cells, .{}) catch error.Database;
}

/// The article id for a slug, or null when the article is missing.
pub fn idBySlug(
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

// --------------------------------------------------------- //

fn createTx(
    tx: *postgrez.Transaction,
    author_id: i64,
    title: []const u8,
    description: []const u8,
    body: []const u8,
    tags: []const []const u8,
    article_id: *i64,
) !void {
    const maybe_row = try tx.queryRow(struct { id: i64 }, SQL_INSERT, .{ author_id, title, description, body });
    const row = maybe_row orelse return error.Database;
    article_id.* = row.id;

    if (tags.len > 0) {
        var tag_json_buf: [64 * 1024]u8 = undefined;
        const tag_json_len = try jzon.serialize(&tag_json_buf, tags, .{});
        const tag_json = tag_json_buf[0..tag_json_len];

        _ = try tx.exec(SQL_INSERT_TAGS, .{tag_json});
        _ = try tx.exec(SQL_INSERT_ARTICLE_TAGS, .{ row.id, tag_json });
    }
}

/// Insert one article with its tags in one transaction, then return the full row.
pub fn create(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    author_id: i64,
    title: []const u8,
    description: []const u8,
    body: []const u8,
    tags: []const []const u8,
) Error!?Article {
    var article_id: i64 = 0;

    conn.transaction(createTx, .{ author_id, title, description, body, tags, &article_id }) catch {
        return error.Database;
    };

    return findById(conn, allocator, author_id, article_id);
}

/// Update the present fields and return the full row.
pub fn update(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    id: i64,
    viewer: i64,
    title: ?[]const u8,
    description: ?[]const u8,
    body: ?[]const u8,
) Error!?Article {
    _ = conn.exec(SQL_UPDATE, .{ id, title, description, body }) catch return error.Database;

    return findById(conn, allocator, viewer, id);
}

/// Delete one article. Its tags, favorites, and comments cascade.
pub fn delete(conn: *postgrez.Conn, id: i64) Error!void {
    _ = conn.exec(SQL_DELETE, .{id}) catch return error.Database;
}
