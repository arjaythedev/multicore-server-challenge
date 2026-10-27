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

const SQL_LIST_NONE =
    \\SELECT a.id, a.slug, a.title, a.description,
    \\to_char(a.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS created_at,
    \\to_char(a.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS updated_at,
    \\jsonb_build_object('tags', ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id WHERE at.article_id = a.id ORDER BY t.name)) AS tag_list,
    \\(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
    \\a.id IN (SELECT article_id FROM favorites WHERE user_id = $1) AS favorited,
    \\u.username, u.bio, u.image,
    \\a.author_id IN (SELECT followee_id FROM follows WHERE follower_id = $1) AS following
    \\FROM articles a JOIN users u ON u.id = a.author_id
    \\ORDER BY a.id DESC LIMIT $2 OFFSET $3
;

const SQL_LIST_TAG =
    \\SELECT a.id, a.slug, a.title, a.description,
    \\to_char(a.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS created_at,
    \\to_char(a.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS updated_at,
    \\jsonb_build_object('tags', ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id WHERE at.article_id = a.id ORDER BY t.name)) AS tag_list,
    \\(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
    \\a.id IN (SELECT article_id FROM favorites WHERE user_id = $1) AS favorited,
    \\u.username, u.bio, u.image,
    \\a.author_id IN (SELECT followee_id FROM follows WHERE follower_id = $1) AS following
    \\FROM articles a JOIN users u ON u.id = a.author_id
    \\WHERE a.id IN (
    \\  SELECT at.article_id FROM article_tags at
    \\  WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4)
    \\  ORDER BY at.article_id DESC LIMIT $2 OFFSET $3
    \\)
    \\ORDER BY a.id DESC
;

const SQL_LIST_AUTHOR =
    \\SELECT a.id, a.slug, a.title, a.description,
    \\to_char(a.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS created_at,
    \\to_char(a.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS updated_at,
    \\jsonb_build_object('tags', ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id WHERE at.article_id = a.id ORDER BY t.name)) AS tag_list,
    \\(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
    \\a.id IN (SELECT article_id FROM favorites WHERE user_id = $1) AS favorited,
    \\u.username, u.bio, u.image,
    \\a.author_id IN (SELECT followee_id FROM follows WHERE follower_id = $1) AS following
    \\FROM articles a JOIN users u ON u.id = a.author_id
    \\WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4)
    \\ORDER BY a.id DESC LIMIT $2 OFFSET $3
;

const SQL_LIST_FAVORITED =
    \\SELECT a.id, a.slug, a.title, a.description,
    \\to_char(a.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS created_at,
    \\to_char(a.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS updated_at,
    \\jsonb_build_object('tags', ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id WHERE at.article_id = a.id ORDER BY t.name)) AS tag_list,
    \\(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
    \\a.id IN (SELECT article_id FROM favorites WHERE user_id = $1) AS favorited,
    \\u.username, u.bio, u.image,
    \\a.author_id IN (SELECT followee_id FROM follows WHERE follower_id = $1) AS following
    \\FROM articles a JOIN users u ON u.id = a.author_id
    \\WHERE a.id IN (
    \\  SELECT f.article_id FROM favorites f
    \\  WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4)
    \\  ORDER BY f.article_id DESC LIMIT $2 OFFSET $3
    \\)
    \\ORDER BY a.id DESC
;

const SQL_COUNT_NONE = "SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s";

const SQL_COUNT_TAG =
    \\SELECT count(*) FROM (
    \\  SELECT 1 FROM article_tags at
    \\  WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1)
    \\  LIMIT 1000
    \\) s
;

const SQL_COUNT_AUTHOR =
    \\SELECT count(*) FROM (
    \\  SELECT 1 FROM articles a
    \\  WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1)
    \\  LIMIT 1000
    \\) s
;

const SQL_COUNT_FAVORITED =
    \\SELECT count(*) FROM (
    \\  SELECT 1 FROM favorites f
    \\  WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1)
    \\  LIMIT 1000
    \\) s
;

const SQL_FEED =
    \\SELECT a.id, a.slug, a.title, a.description,
    \\to_char(a.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS created_at,
    \\to_char(a.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS updated_at,
    \\jsonb_build_object('tags', ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id WHERE at.article_id = a.id ORDER BY t.name)) AS tag_list,
    \\(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
    \\a.id IN (SELECT article_id FROM favorites WHERE user_id = $1) AS favorited,
    \\u.username, u.bio, u.image,
    \\TRUE AS following
    \\FROM articles a JOIN users u ON u.id = a.author_id
    \\WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1)
    \\ORDER BY a.id DESC LIMIT $2 OFFSET $3
;

const SQL_FEED_COUNT =
    \\SELECT count(*) FROM (
    \\  SELECT 1 FROM articles a
    \\  WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1)
    \\  LIMIT 1000
    \\) s
;

const SQL_BY_SLUG =
    \\SELECT a.id, a.slug, a.title, a.description, a.body,
    \\to_char(a.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS created_at,
    \\to_char(a.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS updated_at,
    \\jsonb_build_object('tags', ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id WHERE at.article_id = a.id ORDER BY t.name)) AS tag_list,
    \\(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
    \\EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
    \\u.username, u.bio, u.image,
    \\EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
    \\FROM articles a JOIN users u ON u.id = a.author_id
    \\WHERE a.slug = $2
;

const SQL_BY_ID =
    \\SELECT a.id, a.slug, a.title, a.description, a.body,
    \\to_char(a.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS created_at,
    \\to_char(a.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS updated_at,
    \\jsonb_build_object('tags', ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id WHERE at.article_id = a.id ORDER BY t.name)) AS tag_list,
    \\(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
    \\EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
    \\u.username, u.bio, u.image,
    \\EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
    \\FROM articles a JOIN users u ON u.id = a.author_id
    \\WHERE a.id = $2
;

const SQL_ARTICLE_ID = "SELECT id FROM articles WHERE slug = $1";

const SQL_INSERT =
    \\INSERT INTO articles (id, slug, author_id, title, description, body)
    \\SELECT n.id,
    \\  trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id,
    \\  $1, $2, $3, $4
    \\FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
    \\RETURNING id
;

const SQL_INSERT_TAGS =
    \\INSERT INTO tags (name)
    \\SELECT DISTINCT value FROM jsonb_array_elements_text($1::jsonb) ON CONFLICT (name) DO NOTHING
;

const SQL_INSERT_ARTICLE_TAGS =
    \\INSERT INTO article_tags (article_id, tag_id)
    \\SELECT $1, t.id FROM tags t
    \\WHERE t.name IN (SELECT value FROM jsonb_array_elements_text($2::jsonb))
;

const SQL_OWNER =
    \\SELECT id, author_id FROM articles WHERE slug = $1
;

const SQL_UPDATE =
    \\UPDATE articles SET
    \\  title = COALESCE($2, title),
    \\  description = COALESCE($3, description),
    \\  body = COALESCE($4, body),
    \\  slug = CASE WHEN $2::text IS NULL THEN slug ELSE
    \\    trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id
    \\  END,
    \\  updated_at = now()
    \\WHERE id = $1
;

const SQL_DELETE = "DELETE FROM articles WHERE id = $1";

// --------------------------------------------------------- //

fn parsePage(result: *postgrez.Result, allocator: std.mem.Allocator) Error![]Article {
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

fn parseCount(result: *postgrez.Result, allocator: std.mem.Allocator) Error!i64 {
    const maybe_row = result.next() catch return error.Database;
    const row = maybe_row orelse return 0;
    const value = postgrez.row.parseRow(Count, allocator, row.columns, row.cells, .{}) catch {
        return error.Database;
    };

    return value.count;
}

fn parseOne(result: *postgrez.Result, allocator: std.mem.Allocator) Error!?Article {
    const maybe_row = result.next() catch return error.Database;
    const row = maybe_row orelse return null;

    return postgrez.row.parseRow(Article, allocator, row.columns, row.cells, .{}) catch error.Database;
}

fn parseArticleId(result: *postgrez.Result, allocator: std.mem.Allocator) Error!?i64 {
    const maybe_row = result.next() catch return error.Database;
    const row = maybe_row orelse return null;
    const found = postgrez.row.parseRow(ArticleId, allocator, row.columns, row.cells, .{}) catch {
        return error.Database;
    };

    return found.id;
}

fn listPage(
    list_stmt: *postgrez.Statement,
    count_stmt: *postgrez.Statement,
    allocator: std.mem.Allocator,
    list_args: anytype,
    count_args: anytype,
) Error!Page {
    list_stmt.sendRows(list_args) catch return error.Database;
    count_stmt.sendRows(count_args) catch return error.Database;

    var list_result = list_stmt.awaitRows() catch return error.Database;
    defer list_result.deinit();
    const articles = parsePage(&list_result, allocator) catch return error.Database;

    var count_result = count_stmt.awaitRows() catch return error.Database;
    defer count_result.deinit();
    const count = parseCount(&count_result, allocator) catch return error.Database;

    return .{ .articles = articles, .count = count };
}

fn plainPage(
    conn: *postgrez.Conn,
    list_sql: []const u8,
    count_sql: []const u8,
    allocator: std.mem.Allocator,
    list_args: anytype,
    count_args: anytype,
) Error!Page {
    var list_result = conn.rows(list_sql, list_args) catch return error.Database;
    defer list_result.deinit();
    const articles = parsePage(&list_result, allocator) catch return error.Database;

    var count_result = conn.rows(count_sql, count_args) catch return error.Database;
    defer count_result.deinit();
    const count = parseCount(&count_result, allocator) catch return error.Database;

    return .{ .articles = articles, .count = count };
}

// --------------------------------------------------------- //

/// Prepared read statements for the hot article endpoints. Each statement
/// keeps its plan on the connection, not the rows.
pub const Prepared = struct {
    id_by_slug: postgrez.Statement,
    by_slug: postgrez.Statement,
    list_none: postgrez.Statement,
    list_tag: postgrez.Statement,
    list_author: postgrez.Statement,
    list_favorited: postgrez.Statement,
    count_none: postgrez.Statement,
    count_tag: postgrez.Statement,
    count_author: postgrez.Statement,
    count_favorited: postgrez.Statement,
    feed_stmt: postgrez.Statement,
    feed_count: postgrez.Statement,

    /// Prepare the read statements once on this connection.
    pub fn init(conn: *postgrez.Conn) Error!Prepared {
        var id_by_slug = conn.prepare(SQL_ARTICLE_ID) catch return error.Database;
        errdefer id_by_slug.deinit();
        var by_slug = conn.prepare(SQL_BY_SLUG) catch return error.Database;
        errdefer by_slug.deinit();
        var list_none = conn.prepare(SQL_LIST_NONE) catch return error.Database;
        errdefer list_none.deinit();
        var list_tag = conn.prepare(SQL_LIST_TAG) catch return error.Database;
        errdefer list_tag.deinit();
        var list_author = conn.prepare(SQL_LIST_AUTHOR) catch return error.Database;
        errdefer list_author.deinit();
        var list_favorited = conn.prepare(SQL_LIST_FAVORITED) catch return error.Database;
        errdefer list_favorited.deinit();
        var count_none = conn.prepare(SQL_COUNT_NONE) catch return error.Database;
        errdefer count_none.deinit();
        var count_tag = conn.prepare(SQL_COUNT_TAG) catch return error.Database;
        errdefer count_tag.deinit();
        var count_author = conn.prepare(SQL_COUNT_AUTHOR) catch return error.Database;
        errdefer count_author.deinit();
        var count_favorited = conn.prepare(SQL_COUNT_FAVORITED) catch return error.Database;
        errdefer count_favorited.deinit();
        var feed_stmt = conn.prepare(SQL_FEED) catch return error.Database;
        errdefer feed_stmt.deinit();
        var feed_count = conn.prepare(SQL_FEED_COUNT) catch return error.Database;
        errdefer feed_count.deinit();

        return .{
            .id_by_slug = id_by_slug,
            .by_slug = by_slug,
            .list_none = list_none,
            .list_tag = list_tag,
            .list_author = list_author,
            .list_favorited = list_favorited,
            .count_none = count_none,
            .count_tag = count_tag,
            .count_author = count_author,
            .count_favorited = count_favorited,
            .feed_stmt = feed_stmt,
            .feed_count = feed_count,
        };
    }

    /// Close every server-side statement (best effort).
    pub fn deinit(self: *Prepared) void {
        self.id_by_slug.deinit();
        self.by_slug.deinit();
        self.list_none.deinit();
        self.list_tag.deinit();
        self.list_author.deinit();
        self.list_favorited.deinit();
        self.count_none.deinit();
        self.count_tag.deinit();
        self.count_author.deinit();
        self.count_favorited.deinit();
        self.feed_stmt.deinit();
        self.feed_count.deinit();
    }

    /// The article id for a slug.
    pub fn idBySlug(self: *Prepared, allocator: std.mem.Allocator, slug: []const u8) Error!?i64 {
        var result = self.id_by_slug.rows(.{slug}) catch return error.Database;
        defer result.deinit();

        return parseArticleId(&result, allocator);
    }

    /// One full article by slug.
    pub fn findBySlug(self: *Prepared, allocator: std.mem.Allocator, viewer: i64, slug: []const u8) Error!?Article {
        var result = self.by_slug.rows(.{ viewer, slug }) catch return error.Database;
        defer result.deinit();

        return parseOne(&result, allocator);
    }

    /// One page of articles plus the capped total.
    pub fn list(
        self: *Prepared,
        allocator: std.mem.Allocator,
        viewer: i64,
        filter: Filter,
        limit: i64,
        offset: i64,
    ) Error!Page {
        return switch (filter) {
            .NONE => listPage(&self.list_none, &self.count_none, allocator, .{ viewer, limit, offset }, .{}),
            .TAG => |tag| listPage(&self.list_tag, &self.count_tag, allocator, .{ viewer, limit, offset, tag }, .{tag}),
            .AUTHOR => |author| listPage(&self.list_author, &self.count_author, allocator, .{ viewer, limit, offset, author }, .{author}),
            .FAVORITED => |favorited| listPage(&self.list_favorited, &self.count_favorited, allocator, .{ viewer, limit, offset, favorited }, .{favorited}),
        };
    }

    /// The viewer's feed, newest first.
    pub fn feed(
        self: *Prepared,
        allocator: std.mem.Allocator,
        viewer: i64,
        limit: i64,
        offset: i64,
    ) Error!Page {
        return listPage(&self.feed_stmt, &self.feed_count, allocator, .{ viewer, limit, offset }, .{viewer});
    }
};

threadlocal var tl_prepared: ?Prepared = null;
threadlocal var tl_prepared_conn: ?*postgrez.Conn = null;

/// The prepared read statements for this worker's connection, prepared once.
pub fn prepared(conn: *postgrez.Conn) Error!*Prepared {
    if (tl_prepared != null and tl_prepared_conn == conn) {
        return &tl_prepared.?;
    }

    if (tl_prepared) |*instance| {
        instance.deinit();
        tl_prepared = null;
    }

    tl_prepared = try Prepared.init(conn);
    tl_prepared_conn = conn;

    return &tl_prepared.?;
}

// --------------------------------------------------------- //

/// One page of articles plus the capped total, via the unnamed statements.
pub fn list(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    viewer: i64,
    filter: Filter,
    limit: i64,
    offset: i64,
) Error!Page {
    return switch (filter) {
        .NONE => plainPage(conn, SQL_LIST_NONE, SQL_COUNT_NONE, allocator, .{ viewer, limit, offset }, .{}),
        .TAG => |tag| plainPage(conn, SQL_LIST_TAG, SQL_COUNT_TAG, allocator, .{ viewer, limit, offset, tag }, .{tag}),
        .AUTHOR => |author| plainPage(conn, SQL_LIST_AUTHOR, SQL_COUNT_AUTHOR, allocator, .{ viewer, limit, offset, author }, .{author}),
        .FAVORITED => |favorited| plainPage(conn, SQL_LIST_FAVORITED, SQL_COUNT_FAVORITED, allocator, .{ viewer, limit, offset, favorited }, .{favorited}),
    };
}

/// The viewer's feed, newest first, via the unnamed statements.
pub fn feed(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    viewer: i64,
    limit: i64,
    offset: i64,
) Error!Page {
    return plainPage(conn, SQL_FEED, SQL_FEED_COUNT, allocator, .{ viewer, limit, offset }, .{viewer});
}

/// One full article by slug, via the unnamed statement.
pub fn findBySlug(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    viewer: i64,
    slug: []const u8,
) Error!?Article {
    var result = conn.rows(SQL_BY_SLUG, .{ viewer, slug }) catch return error.Database;
    defer result.deinit();

    return parseOne(&result, allocator);
}

/// One full article by id.
pub fn findById(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    viewer: i64,
    id: i64,
) Error!?Article {
    var result = conn.rows(SQL_BY_ID, .{ viewer, id }) catch return error.Database;
    defer result.deinit();

    return parseOne(&result, allocator);
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

/// The article id for a slug, via the unnamed statement.
pub fn idBySlug(
    conn: *postgrez.Conn,
    allocator: std.mem.Allocator,
    slug: []const u8,
) Error!?i64 {
    var result = conn.rows(SQL_ARTICLE_ID, .{slug}) catch return error.Database;
    defer result.deinit();

    return parseArticleId(&result, allocator);
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
        const tag_json_len = try jzon.serialize(&tag_json_buf, tags, .{ .strategy = .GENERATED });
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
