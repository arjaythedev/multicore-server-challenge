const std = @import("std");

pub const Input = struct { viewer: []const u8, slug: []const u8 };
pub const capacity = @import("build_options").read_batch_size;
pub const lookahead = @max(64, capacity * 4);
pub const max_parameter_bytes = 256 * 1024;

pub const favorite_sql = "WITH requested AS MATERIALIZED (SELECT * FROM unnest($1::bigint[],$2::text[]) WITH ORDINALITY r(viewer,slug,ordinal)), targets AS MATERIALIZED (SELECT r.ordinal,r.viewer,a.id FROM requested r LEFT JOIN articles a ON a.slug=r.slug), changed AS (INSERT INTO favorites(user_id,article_id) SELECT DISTINCT viewer,id FROM targets WHERE id IS NOT NULL ON CONFLICT DO NOTHING RETURNING article_id) SELECT t.ordinal,t.id FROM targets t CROSS JOIN (SELECT count(*) FROM changed) applied ORDER BY t.ordinal";
pub const unfavorite_sql = "WITH requested AS MATERIALIZED (SELECT * FROM unnest($1::bigint[],$2::text[]) WITH ORDINALITY r(viewer,slug,ordinal)), targets AS MATERIALIZED (SELECT r.ordinal,r.viewer,a.id FROM requested r LEFT JOIN articles a ON a.slug=r.slug), changed AS (DELETE FROM favorites f USING targets t WHERE f.user_id=t.viewer AND f.article_id=t.id RETURNING f.article_id) SELECT t.ordinal,t.id FROM targets t CROSS JOIN (SELECT count(*) FROM changed) applied ORDER BY t.ordinal";

pub const by_id_sql =
    \\WITH requested AS MATERIALIZED (
    \\ SELECT * FROM unnest($1::bigint[],$2::bigint[]) WITH ORDINALITY r(viewer,id,ordinal)
    \\), selected AS MATERIALIZED (
    \\ SELECT a.id,a.slug,a.title,a.description,a.body,a.author_id,
    \\ to_char(a.created_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS created_at,
    \\ to_char(a.updated_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS updated_at,
    \\ ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id=at.tag_id WHERE at.article_id=a.id ORDER BY t.name) AS tags,
    \\ (SELECT count(*) FROM favorites f WHERE f.article_id=a.id) AS favorites,
    \\ u.username,u.bio,u.image FROM articles a JOIN users u ON u.id=a.author_id
    \\ JOIN (SELECT DISTINCT id FROM requested) wanted ON wanted.id=a.id
    \\) SELECT r.ordinal,a.slug,a.title,a.description,a.created_at,a.updated_at,a.tags,a.favorites,
    \\ EXISTS(SELECT 1 FROM favorites f WHERE f.article_id=a.id AND f.user_id=r.viewer),a.username,a.bio,a.image,
    \\ EXISTS(SELECT 1 FROM follows fo WHERE fo.follower_id=r.viewer AND fo.followee_id=a.author_id),a.body
    \\ FROM requested r LEFT JOIN selected a ON a.id=r.id ORDER BY r.ordinal
;

// Only requests captured before dispatch share this statement snapshot. Article
// metadata is computed once per distinct slug; viewer flags remain per request.
pub const single_sql =
    \\WITH requested AS MATERIALIZED (
    \\ SELECT * FROM unnest($1::bigint[], $2::text[]) WITH ORDINALITY AS r(viewer, slug, ordinal)
    \\), selected AS MATERIALIZED (
    \\ SELECT a.id,a.slug,a.title,a.description,a.body,a.author_id,
    \\ to_char(a.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS created_at,
    \\ to_char(a.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS updated_at,
    \\ ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id=at.tag_id WHERE at.article_id=a.id ORDER BY t.name) AS tags,
    \\ (SELECT count(*) FROM favorites f WHERE f.article_id=a.id) AS favorites,
    \\ u.username,u.bio,u.image FROM articles a JOIN users u ON u.id=a.author_id
    \\ JOIN (SELECT DISTINCT slug FROM requested) wanted ON wanted.slug=a.slug
    \\) SELECT r.ordinal,a.slug,a.title,a.description,a.created_at,a.updated_at,a.tags,a.favorites,
    \\ EXISTS(SELECT 1 FROM favorites f WHERE f.article_id=a.id AND f.user_id=r.viewer),
    \\ a.username,a.bio,a.image,
    \\ EXISTS(SELECT 1 FROM follows fo WHERE fo.follower_id=r.viewer AND fo.followee_id=a.author_id),a.body
    \\ FROM requested r LEFT JOIN selected a ON a.slug=r.slug ORDER BY r.ordinal
;

// The article and newest-comment rows are read once per distinct slug inside
// this statement. Following flags remain specific to each captured viewer.
pub const comments_sql =
    \\WITH requested AS MATERIALIZED (
    \\ SELECT * FROM unnest($1::bigint[], $2::text[]) WITH ORDINALITY AS r(viewer, slug, ordinal)
    \\), targets AS MATERIALIZED (
    \\ SELECT a.id,a.slug FROM articles a JOIN (SELECT DISTINCT slug FROM requested) k ON k.slug=a.slug
    \\), content AS MATERIALIZED (
    \\ SELECT t.slug,t.id AS article_id,c.id,c.body,c.created_at AS created_sort,
    \\ to_char(c.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS created_at,
    \\ to_char(c.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS updated_at,
    \\ c.author_id,c.username,c.bio,c.image FROM targets t LEFT JOIN LATERAL (
    \\ SELECT c.id,c.body,c.created_at,c.updated_at,c.author_id,u.username,u.bio,u.image
    \\ FROM comments c JOIN users u ON u.id=c.author_id WHERE c.article_id=t.id
    \\ ORDER BY c.created_at DESC,c.id DESC LIMIT 100
    \\ ) c ON true
    \\), viewers AS MATERIALIZED (
    \\ SELECT k.viewer,ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id=k.viewer) AS followed
    \\ FROM (SELECT DISTINCT viewer FROM requested) k
    \\) SELECT r.ordinal,c.article_id,c.id,c.body,c.created_at,c.updated_at,c.username,c.bio,c.image,
    \\ c.author_id=ANY(v.followed) FROM requested r JOIN viewers v ON v.viewer=r.viewer
    \\ LEFT JOIN content c ON c.slug=r.slug ORDER BY r.ordinal,c.created_sort DESC,c.id DESC
;

// Metadata crosses the wire once per comment. Recipient rows retain only the
// IDs, ordering position and viewer-specific flag. No data survives the group.
pub const compact_comments_sql =
    \\WITH requested AS MATERIALIZED (
    \\ SELECT * FROM unnest($1::bigint[], $2::text[]) WITH ORDINALITY AS r(viewer,slug,ordinal)
    \\), targets AS MATERIALIZED (
    \\ SELECT a.id,a.slug FROM articles a JOIN (SELECT DISTINCT slug FROM requested) k ON k.slug=a.slug
    \\), content AS MATERIALIZED (
    \\ SELECT t.slug,t.id AS article_id,c.id,c.body,c.created_at AS created_sort,
    \\ to_char(c.created_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS created_at,
    \\ to_char(c.updated_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS updated_at,
    \\ c.author_id,c.username,c.bio,c.image FROM targets t LEFT JOIN LATERAL (
    \\ SELECT c.id,c.body,c.created_at,c.updated_at,c.author_id,u.username,u.bio,u.image
    \\ FROM comments c JOIN users u ON u.id=c.author_id WHERE c.article_id=t.id
    \\ ORDER BY c.created_at DESC,c.id DESC LIMIT 100
    \\ ) c ON true
    \\), ranked AS MATERIALIZED (
    \\ SELECT content.*,row_number() OVER(PARTITION BY article_id ORDER BY created_sort DESC,id DESC) AS position FROM content
    \\), viewers AS MATERIALIZED (
    \\ SELECT k.viewer,ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id=k.viewer) AS followed
    \\ FROM (SELECT DISTINCT viewer FROM requested) k
    \\) SELECT 0::bigint AS ordinal,c.article_id,c.id,c.body,c.created_at,c.updated_at,c.username,c.bio,c.image,false AS following,c.position
    \\ FROM ranked c WHERE c.id IS NOT NULL
    \\ UNION ALL
    \\ SELECT r.ordinal,c.article_id,c.id,NULL::text,NULL::text,NULL::text,NULL::text,NULL::text,NULL::text,c.author_id=ANY(v.followed),c.position
    \\ FROM requested r JOIN viewers v ON v.viewer=r.viewer LEFT JOIN ranked c ON c.slug=r.slug
    \\ ORDER BY 1,11,3 DESC
;

pub fn overlappingComments(inputs: []const Input) bool {
    if (inputs.len < 2) return false;
    var unique: [capacity][]const u8 = undefined;
    var count: usize = 0;
    for (inputs) |input| {
        var found = false;
        for (unique[0..count]) |slug| if (std.mem.eql(u8, slug, input.slug)) {
            found = true;
            break;
        };
        if (!found) {
            count += 1;
            if (count > inputs.len / 2) return false;
            unique[count - 1] = input.slug;
        }
    }
    return true;
}

test "compact comment selection requires substantial captured overlap" {
    try std.testing.expect(!overlappingComments(&.{.{ .viewer = "1", .slug = "a" }}));
    try std.testing.expect(overlappingComments(&.{ .{ .viewer = "1", .slug = "a" }, .{ .viewer = "2", .slug = "a" } }));
    try std.testing.expect(!overlappingComments(&.{ .{ .viewer = "1", .slug = "a" }, .{ .viewer = "2", .slug = "b" }, .{ .viewer = "3", .slug = "a" } }));
    try std.testing.expect(overlappingComments(&.{ .{ .viewer = "1", .slug = "a" }, .{ .viewer = "2", .slug = "b" }, .{ .viewer = "3", .slug = "a" }, .{ .viewer = "4", .slug = "b" } }));
}

pub fn parameters(allocator: std.mem.Allocator, inputs: []const Input) ![2][:0]const u8 {
    if (inputs.len == 0 or inputs.len > capacity) return error.BatchSize;
    var viewers: std.ArrayList(u8) = .empty;
    defer viewers.deinit(allocator);
    var slugs: std.ArrayList(u8) = .empty;
    defer slugs.deinit(allocator);
    try viewers.append(allocator, '{');
    try slugs.append(allocator, '{');
    var bytes: usize = 0;
    for (inputs, 0..) |input, index| {
        bytes += input.viewer.len + input.slug.len;
        if (bytes > max_parameter_bytes) return error.BatchSize;
        if (index != 0) {
            try viewers.append(allocator, ',');
            try slugs.append(allocator, ',');
        }
        if (input.viewer.len == 0) return error.BatchParameter;
        for (input.viewer) |byte| if (byte < '0' or byte > '9') return error.BatchParameter;
        try viewers.appendSlice(allocator, input.viewer);
        try slugs.append(allocator, '"');
        for (input.slug) |byte| {
            if (byte == 0) return error.BatchParameter;
            if (byte == '"' or byte == '\\') try slugs.append(allocator, '\\');
            try slugs.append(allocator, byte);
        }
        try slugs.append(allocator, '"');
    }
    try viewers.append(allocator, '}');
    try slugs.append(allocator, '}');
    const viewer_param = try allocator.dupeSentinel(u8, viewers.items, 0);
    errdefer allocator.free(viewer_param);
    return .{ viewer_param, try allocator.dupeSentinel(u8, slugs.items, 0) };
}

test "batched text arrays preserve punctuation, empty and Unicode slugs" {
    const a = std.testing.allocator;
    const params = try parameters(a, &.{ .{ .viewer = "0", .slug = "a,\"b\\c" }, .{ .viewer = "17", .slug = "" }, .{ .viewer = "2", .slug = "é" } });
    defer for (params) |param| a.free(param);
    try std.testing.expectEqualStrings("{0,17,2}", params[0]);
    try std.testing.expectEqualStrings("{\"a,\\\"b\\\\c\",\"\",\"é\"}", params[1]);
    try std.testing.expectError(error.BatchParameter, parameters(a, &.{.{ .viewer = "1;", .slug = "x" }}));
    try std.testing.expectError(error.BatchParameter, parameters(a, &.{.{ .viewer = "1", .slug = "x\x00y" }}));
}
