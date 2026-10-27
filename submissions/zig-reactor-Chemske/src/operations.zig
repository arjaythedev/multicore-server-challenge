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

pub const Comment = struct { id: i64, body: []const u8, createdAt: []const u8, updatedAt: []const u8, author: profiles.Profile };
pub const Query = struct {
    statement: [:0]const u8,
    params: [6]?[:0]const u8 = @splat(null),
    count: usize = 0,
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
        q.statement = switch (self.stage) {
            .begin => "BEGIN",
            .commit => "COMMIT",
            .rollback => "ROLLBACK",
            .insert_article => "INSERT INTO articles(id,slug,author_id,title,description,body) SELECT n.id, trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id, $1,$2,$3,$4 FROM (SELECT nextval(pg_get_serial_sequence('articles','id')) AS id) n RETURNING id",
            .insert_tags => "INSERT INTO tags(name) SELECT DISTINCT value FROM jsonb_array_elements_text($1::jsonb) ON CONFLICT(name) DO NOTHING",
            .link_tags => "INSERT INTO article_tags(article_id,tag_id) SELECT $1::bigint,t.id FROM tags t WHERE t.name IN (SELECT value FROM jsonb_array_elements_text($2::jsonb))",
            .lookup => "SELECT id FROM articles WHERE slug = $1",
            .article_row => articles.by_id,
            .comment_rows => list_comments_sql,
            .mutate => switch (self.kind) {
                .update_article => update_sql,
                .delete_article => delete_sql,
                .favorite => favorite_sql,
                .unfavorite => unfavorite_sql,
                .create_comment => insert_comment_sql,
                .delete_comment => delete_comment_sql,
                else => unreachable,
            },
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
