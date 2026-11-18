const std = @import("std");
const http = @import("http.zig");
const articles = @import("articles.zig");
const profiles = @import("profiles.zig");

const target = "WITH target AS MATERIALIZED (SELECT id, author_id FROM articles WHERE slug = $2), ";
const ownership =
    \\SELECT CASE WHEN t.id IS NULL THEN 404 WHEN t.author_id <> $1 THEN 403
    \\            WHEN c.id IS NULL THEN 404 ELSE 200 END, c.id
    \\  FROM (VALUES (1)) seed(n) LEFT JOIN target t ON true LEFT JOIN changed c ON true
;
const update_sql = target ++
    \\changed AS (UPDATE articles SET title = COALESCE($3, title), description = COALESCE($4, description), body = COALESCE($5, body),
    \\    slug = CASE WHEN $3::text IS NULL THEN slug ELSE trim(both '-' from lower(regexp_replace($3, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END,
    \\    updated_at = now()
    \\ WHERE id IN (SELECT id FROM target) AND author_id = $1 RETURNING id)
    \\ 
++ ownership;
const delete_sql = target ++ "changed AS (DELETE FROM articles WHERE id IN (SELECT id FROM target) AND author_id = $1 RETURNING id) " ++ ownership;
const delete_comment_sql =
    \\WITH target AS MATERIALIZED (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $3 AND a.slug = $2),
    \\changed AS (DELETE FROM comments WHERE id IN (SELECT id FROM target) AND author_id = $1 RETURNING id)
    \\ 
++ ownership;
const favorite_sql =
    \\WITH target AS MATERIALIZED (SELECT id FROM articles WHERE slug = $2), changed AS (
    \\ INSERT INTO favorites(user_id, article_id) SELECT $1, id FROM target ON CONFLICT DO NOTHING RETURNING article_id)
    \\SELECT t.id FROM target t CROSS JOIN (SELECT count(*) FROM changed) applied
;
const unfavorite_sql =
    \\WITH target AS MATERIALIZED (SELECT id FROM articles WHERE slug = $2), changed AS (
    \\ DELETE FROM favorites WHERE user_id = $1 AND article_id IN (SELECT id FROM target) RETURNING article_id)
    \\SELECT t.id FROM target t CROSS JOIN (SELECT count(*) FROM changed) applied
;
pub const list_comments_sql =
    \\SELECT a.id, c.id, c.body,
    \\ to_char(c.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    \\ to_char(c.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    \\ c.username, c.bio, c.image, c.following
    \\ FROM articles a LEFT JOIN LATERAL (
    \\ SELECT c.id,c.body,c.created_at,c.updated_at,u.username,u.bio,u.image,
    \\ EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following
    \\ FROM comments c JOIN users u ON u.id=c.author_id
    \\ WHERE c.article_id=a.id ORDER BY c.created_at DESC,c.id DESC LIMIT 100
    \\ ) c ON true WHERE a.slug=$2 ORDER BY c.created_at DESC,c.id DESC
;
const insert_comment_sql =
    \\WITH c AS (INSERT INTO comments(article_id, author_id, body) VALUES ($2, $1, $3) RETURNING *)
    \\SELECT c.id, c.body,
    \\ to_char(c.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    \\ to_char(c.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    \\ u.username, u.bio, u.image, false
    \\ FROM c JOIN users u ON u.id = c.author_id
;

pub const Comment = struct {
    id: i64,
    body: []const u8,
    createdAt: []const u8,
    updatedAt: []const u8,
    author: profiles.Profile,
    encoded: ?struct { bytes: []const u8, flag_offset: usize } = null,

    pub fn jsonStringify(self: Comment, writer: *std.json.Stringify) !void {
        if (self.encoded) |shared| {
            try writer.beginWriteRaw();
            try writer.writer.writeAll(shared.bytes[0..shared.flag_offset]);
            try writer.writer.writeAll(if (self.author.following) "true" else "false");
            try writer.writer.writeAll(shared.bytes[shared.flag_offset + 5 ..]);
            writer.endWriteRaw();
            return;
        }
        try writer.beginObject();
        inline for (.{ "id", "body", "createdAt", "updatedAt", "author" }) |key| {
            try writer.objectField(key);
            try writer.write(@field(self, key));
        }
        try writer.endObject();
    }

    // The complete standard-encoded object and its flag offset belong to the
    // primary task's arena. Followers finish before that arena is released.
    pub fn encodeForGroup(self: *Comment, allocator: std.mem.Allocator) !void {
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        var writer: std.json.Stringify = .{ .writer = &output.writer };
        try writer.beginObject();
        inline for (.{ "id", "body", "createdAt", "updatedAt" }) |key| {
            try writer.objectField(key);
            try writer.write(@field(self, key));
        }
        try writer.objectField("author");
        try writer.beginObject();
        inline for (.{ "username", "bio", "image" }) |key| {
            try writer.objectField(key);
            try writer.write(@field(self.author, key));
        }
        try writer.objectField("following");
        try writer.beginWriteRaw();
        const offset = output.written().len;
        try output.writer.writeAll("false");
        writer.endWriteRaw();
        try writer.endObject();
        try writer.endObject();
        self.encoded = .{ .bytes = try output.toOwnedSlice(), .flag_offset = offset };
    }
};

test "group comment encoding retains escaping, nulls and each recipient flag" {
    const allocator = std.testing.allocator;
    var comment: Comment = .{ .id = 42, .body = "quotes \" slash \\ newline\n é", .createdAt = "2030-01-01T00:00:00.000Z", .updatedAt = "2030-01-01T00:00:00.001Z", .author = .{ .username = "user-é", .bio = null, .image = "image\"\\", .following = false } };
    try comment.encodeForGroup(allocator);
    defer allocator.free(comment.encoded.?.bytes);
    inline for (.{ false, true }) |following| {
        comment.author.following = following;
        var plain = comment;
        plain.encoded = null;
        const expected = try std.json.Stringify.valueAlloc(allocator, plain, .{});
        defer allocator.free(expected);
        const actual = try std.json.Stringify.valueAlloc(allocator, comment, .{});
        defer allocator.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
}
pub const Query = struct {
    statement: [:0]const u8,
    prepared_name: ?[:0]const u8 = null,
    params: [6]?[:0]const u8 = @splat(null),
    count: usize = 0,
};

pub const prepared = [_]struct { name: [:0]const u8, sql: [:0]const u8 }{
    .{ .name = "op_insert_article", .sql = "INSERT INTO articles(id,slug,author_id,title,description,body) SELECT n.id, trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id, $1,$2,$3,$4 FROM (SELECT nextval(pg_get_serial_sequence('articles','id')) AS id) n RETURNING id" },
    .{ .name = "op_insert_tags", .sql = "INSERT INTO tags(name) SELECT DISTINCT value FROM jsonb_array_elements_text($1::jsonb) ON CONFLICT(name) DO NOTHING" },
    .{ .name = "op_link_tags", .sql = "INSERT INTO article_tags(article_id,tag_id) SELECT $1::bigint,t.id FROM tags t WHERE t.name IN (SELECT value FROM jsonb_array_elements_text($2::jsonb))" },
    .{ .name = "op_lookup", .sql = "SELECT id FROM articles WHERE slug = $1" },
    .{ .name = "op_article", .sql = articles.by_id },
    .{ .name = "op_update_article", .sql = update_sql },
    .{ .name = "op_delete_article", .sql = delete_sql },
    .{ .name = "op_favorite", .sql = favorite_sql },
    .{ .name = "op_unfavorite", .sql = unfavorite_sql },
    .{ .name = "op_insert_comment", .sql = insert_comment_sql },
    .{ .name = "op_delete_comment", .sql = delete_comment_sql },
};

pub const Operation = struct {
    kind: http.Route,
    stage: enum { begin, insert_article, insert_tags, link_tags, commit, rollback, lookup, mutate, article_row, comment_rows },
    transaction: bool = false,
    has_tags: bool = false,
    failure: ?u16 = null,
    http_status: u16,
    id: ?[:0]const u8 = null,
    article: []articles.Article = &.{},
    comments: []Comment = &.{},

    pub fn init(kind: http.Route) Operation {
        return .{
            .kind = kind,
            .stage = switch (kind) {
                .create_article => .begin,
                .comments => .comment_rows,
                .create_comment => .lookup,
                else => .mutate,
            },
            .http_status = switch (kind) {
                .create_article, .create_comment => 201,
                .delete_article, .delete_comment => 204,
                else => 200,
            },
        };
    }

    pub fn query(self: Operation, input: []const ?[:0]const u8) Query {
        var q: Query = .{ .statement = "" };
        const args: []const ?[:0]const u8 = switch (self.stage) {
            .begin, .commit, .rollback => &.{},
            .insert_article => input[0..4],
            .insert_tags => input[4..5],
            .link_tags => &.{ self.id, input[4] },
            .lookup => input[1..2],
            .article_row => &.{ input[0], self.id },
            .comment_rows => input[0..2],
            .mutate => if (self.kind == .create_comment) &.{ input[0], self.id, input[2] } else input,
        };
        q.count = args.len;
        @memcpy(q.params[0..args.len], args);
        const prepared_index: ?usize = switch (self.stage) {
            .begin, .commit, .rollback, .comment_rows => null,
            .insert_article => 0,
            .insert_tags => 1,
            .link_tags => 2,
            .lookup => 3,
            .article_row => 4,
            .mutate => switch (self.kind) {
                .update_article => 5,
                .delete_article => 6,
                .favorite => 7,
                .unfavorite => 8,
                .create_comment => 9,
                .delete_comment => 10,
                else => unreachable,
            },
        };
        if (prepared_index) |index| {
            q.statement = prepared[index].sql;
            q.prepared_name = prepared[index].name;
            return q;
        }
        q.statement = switch (self.stage) {
            .begin => "BEGIN",
            .commit => "COMMIT",
            .rollback => "ROLLBACK",
            .comment_rows => list_comments_sql,
            else => unreachable,
        };
        return q;
    }

    // Called only after PQgetResult reaches NULL. False means the operation is finished.
    pub fn advance(self: *Operation, status: u16) bool {
        if (self.stage == .rollback) {
            self.transaction = false;
            self.http_status = self.failure orelse 503;
            return false;
        }
        if (status != 200) {
            self.http_status = status;
            if (!self.transaction) return false;
            self.failure = status;
            self.stage = .rollback;
            return true;
        }
        switch (self.stage) {
            .begin => {
                self.transaction = true;
                self.stage = .insert_article;
            },
            .insert_article => self.stage = if (self.has_tags) .insert_tags else .commit,
            .insert_tags => self.stage = .link_tags,
            .link_tags => self.stage = .commit,
            .commit => {
                self.transaction = false;
                self.stage = .article_row;
            },
            .lookup => self.stage = if (self.kind == .comments) .comment_rows else .mutate,
            .mutate => switch (self.kind) {
                .update_article, .favorite, .unfavorite => self.stage = .article_row,
                else => return false,
            },
            .article_row, .comment_rows => return false,
            .rollback => unreachable,
        }
        return true;
    }

    pub fn json(self: Operation, allocator: std.mem.Allocator) ![]const u8 {
        const body = if (self.kind == .comments)
            try std.json.Stringify.valueAlloc(allocator, .{ .comments = self.comments }, .{})
        else if (self.kind == .create_comment)
            try std.json.Stringify.valueAlloc(allocator, .{ .comment = self.comments[0] }, .{})
        else
            try std.json.Stringify.valueAlloc(allocator, .{ .article = self.article[0] }, .{});
        if (body.len > 4 * 1024 * 1024) return error.ResponseTooLarge;
        return body;
    }
};
