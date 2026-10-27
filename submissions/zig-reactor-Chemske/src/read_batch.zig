const std = @import("std");

pub const Input = struct { viewer: []const u8, slug: []const u8 };
pub const capacity = 32;
pub const max_parameter_bytes = 256 * 1024;

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
