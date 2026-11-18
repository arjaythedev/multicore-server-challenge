const std = @import("std");
const profiles = @import("profiles.zig");

// Reference page/count semantics from SPEC.md. Only the selected page is enriched.
const fields =
    \\SELECT a.slug, a.title, a.description,
    \\       to_char(a.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    \\       to_char(a.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    \\       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id WHERE at.article_id = a.id ORDER BY t.name),
    \\       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
    \\       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1),
    \\       u.username, u.bio, u.image,
    \\       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id)
;
const from = " FROM articles a JOIN users u ON u.id = a.author_id ";
const select = fields ++ from;
pub const by_id = fields ++ ", a.body" ++ from ++ " WHERE a.id = $2";
pub const Family = enum { all, tag, author, favorited, feed, single };

// An author's depth-th row proves that older rows cannot enter the combined
// first depth rows. This bound is derived afresh in the same page statement.
pub fn feedIds(comptime viewer: []const u8, comptime limit: []const u8, comptime offset: []const u8, comptime cap: []const u8) []const u8 {
    const depth = "LEAST((" ++ limit ++ ")::numeric+(" ++ offset ++ ")::numeric,9223372036854775807)::bigint";
    if (!@import("build_options").feed_prune)
        return "SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id=fo.followee_id ORDER BY a2.id DESC LIMIT " ++ depth ++ ") x WHERE fo.follower_id=" ++ viewer ++ " ORDER BY x.id DESC LIMIT " ++ cap ++ " OFFSET " ++ offset;
    return "WITH followed AS MATERIALIZED (SELECT followee_id FROM follows WHERE follower_id=" ++ viewer ++ " ORDER BY followee_id), " ++
        "rank_bound AS MATERIALIZED (SELECT ranked.id FROM (SELECT followee_id FROM followed WHERE " ++ depth ++ "<=256 LIMIT 8) fo CROSS JOIN LATERAL " ++
        "(SELECT a.id FROM articles a WHERE a.author_id=fo.followee_id ORDER BY a.id DESC LIMIT 1 OFFSET GREATEST(" ++ depth ++ ",1)-1) ranked LIMIT 1) " ++
        "SELECT x.id FROM followed fo CROSS JOIN LATERAL " ++
        "(SELECT a2.id FROM articles a2 WHERE a2.author_id=fo.followee_id AND a2.id>=COALESCE((SELECT id FROM rank_bound),'-9223372036854775808'::bigint) " ++
        "ORDER BY a2.id DESC LIMIT " ++ depth ++ ") x ORDER BY x.id DESC LIMIT " ++ cap ++ " OFFSET " ++ offset;
}

pub const Read = struct {
    family: Family,
    phase: enum { page, count } = .page,
    rows: []Article = &.{},
    count: i64 = 0,

    pub fn statement(self: Read) [:0]const u8 {
        if (self.phase == .count) return switch (self.family) {
            .all => "SELECT count(*) FROM (SELECT 1 FROM articles LIMIT 1000) s",
            .tag => "SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT id FROM tags WHERE name = $1) LIMIT 1000) s",
            .author => "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT id FROM users WHERE username = $1) LIMIT 1000) s",
            .favorited => "SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT id FROM users WHERE username = $1) LIMIT 1000) s",
            .feed => "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT followee_id FROM follows WHERE follower_id = $1) LIMIT 1000) s",
            .single => unreachable,
        };
        return switch (self.family) {
            .all => select ++ " WHERE a.id IN (SELECT p.id FROM articles p ORDER BY p.id DESC LIMIT $2::bigint OFFSET $3::bigint) ORDER BY a.id DESC",
            .tag => select ++ " WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT id FROM tags WHERE name = $4) ORDER BY at.article_id DESC LIMIT $2::bigint OFFSET $3::bigint) ORDER BY a.id DESC",
            .author => select ++ " WHERE a.id IN (SELECT p.id FROM articles p WHERE p.author_id = (SELECT id FROM users WHERE username = $4) ORDER BY p.id DESC LIMIT $2::bigint OFFSET $3::bigint) ORDER BY a.id DESC",
            .favorited => select ++ " WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT id FROM users WHERE username = $4) ORDER BY f.article_id DESC LIMIT $2::bigint OFFSET $3::bigint) ORDER BY a.id DESC",
            // Numeric addition avoids both the reference's int32 overflow and int64 wraparound.
            .feed => select ++ " WHERE a.id IN (" ++ (comptime feedIds("$1", "$2", "$3", "$2::bigint")) ++ ") ORDER BY a.id DESC",
            .single => fields ++ ", a.body" ++ from ++ " WHERE a.slug = $2",
        };
    }

    pub fn json(self: Read, allocator: std.mem.Allocator) ![]const u8 {
        const body = if (self.family == .single)
            try std.json.Stringify.valueAlloc(allocator, .{ .article = self.rows[0] }, .{})
        else
            try std.json.Stringify.valueAlloc(allocator, .{ .articles = self.rows, .articlesCount = self.count }, .{});
        if (body.len > 4 * 1024 * 1024) return error.ResponseTooLarge;
        return body;
    }
};

pub const Article = struct {
    slug: []const u8,
    title: []const u8,
    description: []const u8,
    createdAt: []const u8,
    updatedAt: []const u8,
    tagList: []const []const u8,
    favoritesCount: i64,
    favorited: bool,
    author: profiles.Profile,
    body: ?[]const u8 = null,
    encoded: ?struct { bytes: []const u8, favorite_offset: usize, following_offset: usize } = null,

    pub fn jsonStringify(self: Article, writer: *std.json.Stringify) !void {
        if (self.encoded) |shared| {
            try writer.beginWriteRaw();
            try writer.writer.writeAll(shared.bytes[0..shared.favorite_offset]);
            try writer.writer.writeAll(if (self.favorited) "true" else "false");
            try writer.writer.writeAll(shared.bytes[shared.favorite_offset + 5 .. shared.following_offset]);
            try writer.writer.writeAll(if (self.author.following) "true" else "false");
            try writer.writer.writeAll(shared.bytes[shared.following_offset + 5 ..]);
            writer.endWriteRaw();
            return;
        }
        try writer.beginObject();
        inline for (.{ "slug", "title", "description", "createdAt", "updatedAt", "tagList", "favoritesCount", "favorited", "author" }) |key| {
            try writer.objectField(key);
            try writer.write(@field(self, key));
        }
        if (self.body) |body| {
            try writer.objectField("body");
            try writer.write(body);
        }
        try writer.endObject();
    }

    // Only standard-encoded bytes and two recorded boolean positions are shared.
    // The primary request owns these bytes until every group recipient finishes.
    pub fn encodeForGroup(self: *Article, allocator: std.mem.Allocator) !void {
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        var writer: std.json.Stringify = .{ .writer = &output.writer };
        try writer.beginObject();
        inline for (.{ "slug", "title", "description", "createdAt", "updatedAt", "tagList", "favoritesCount" }) |key| {
            try writer.objectField(key);
            try writer.write(@field(self, key));
        }
        try writer.objectField("favorited");
        try writer.beginWriteRaw();
        const favorite_offset = output.written().len;
        try output.writer.writeAll("false");
        writer.endWriteRaw();
        try writer.objectField("author");
        try writer.beginObject();
        inline for (.{ "username", "bio", "image" }) |key| {
            try writer.objectField(key);
            try writer.write(@field(self.author, key));
        }
        try writer.objectField("following");
        try writer.beginWriteRaw();
        const following_offset = output.written().len;
        try output.writer.writeAll("false");
        writer.endWriteRaw();
        try writer.endObject();
        if (self.body) |body| {
            try writer.objectField("body");
            try writer.write(body);
        }
        try writer.endObject();
        self.encoded = .{ .bytes = try output.toOwnedSlice(), .favorite_offset = favorite_offset, .following_offset = following_offset };
    }
};

test "shared article encoding preserves escaped text and independent viewer booleans" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const original: Article = .{ .slug = "quoted\"slug", .title = "é\n\\", .description = "following:false", .createdAt = "date", .updatedAt = "date", .tagList = &.{ "a,b", "\"" }, .favoritesCount = 12, .favorited = false, .author = .{ .username = "name", .bio = "\"following\":false}", .image = null, .following = false }, .body = "body\n\"favorited\":false" };
    for ([_]?[]const u8{ original.body, null }) |body| {
        var encoded = original;
        encoded.body = body;
        try encoded.encodeForGroup(allocator);
        for ([_]bool{ false, true }) |favorited| for ([_]bool{ false, true }) |following| {
            var plain = original;
            plain.body = body;
            plain.favorited = favorited;
            plain.author.following = following;
            encoded.favorited = favorited;
            encoded.author.following = following;
            try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(allocator, plain, .{}), try std.json.Stringify.valueAlloc(allocator, encoded, .{}));
        };
    }
}

// ARRAY(SELECT non-null text) emits one dimension without an explicit dimension prefix.
pub fn tags(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    if (text.len < 2 or text[0] != '{' or text[text.len - 1] != '}') return error.DatabaseResult;
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    var i: usize = 1;
    const end = text.len - 1;
    while (i < end) {
        var name: std.ArrayList(u8) = .empty;
        defer name.deinit(allocator);
        const quoted = text[i] == '"';
        if (quoted) i += 1;
        var closed = !quoted;
        while (i < end) {
            const byte = text[i];
            if (quoted and byte == '"') {
                i += 1;
                closed = true;
                break;
            }
            if (!quoted and byte == ',') break;
            if (byte == '\\') {
                i += 1;
                if (i >= end) return error.DatabaseResult;
            } else if (!quoted and (byte == '"' or byte == '{' or byte == '}')) return error.DatabaseResult;
            try name.append(allocator, text[i]);
            i += 1;
        }
        if (!closed or (!quoted and (name.items.len == 0 or std.mem.eql(u8, name.items, "NULL")))) return error.DatabaseResult;
        const owned = try allocator.dupe(u8, name.items);
        names.append(allocator, owned) catch |err| {
            allocator.free(owned);
            return err;
        };
        if (i == end) break;
        if (text[i] != ',') return error.DatabaseResult;
        i += 1;
        if (i == end) return error.DatabaseResult;
    }
    return names.toOwnedSlice(allocator);
}

test "PostgreSQL tag arrays preserve quoted punctuation and reject incomplete fields" {
    const a = std.testing.allocator;
    const names = try tags(a, "{plain,\"a,b\",\"a\\\"b\",\"a\\\\b\",\"NULL\",\"\",é}");
    defer {
        for (names) |name| a.free(name);
        a.free(names);
    }
    try std.testing.expectEqual(@as(usize, 7), names.len);
    try std.testing.expectEqualStrings("a,b", names[1]);
    try std.testing.expectEqualStrings("a\"b", names[2]);
    try std.testing.expectEqualStrings("a\\b", names[3]);
    for ([_][]const u8{ "{NULL}", "{a,}", "{\"open}", "{a,,b}" }) |invalid| try std.testing.expectError(error.DatabaseResult, tags(a, invalid));
}
