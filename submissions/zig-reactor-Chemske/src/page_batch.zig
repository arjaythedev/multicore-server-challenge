const std = @import("std");
const articles = @import("articles.zig");
const batch = @import("read_batch.zig");

pub const Input = struct { viewer: []const u8, limit: []const u8, offset: []const u8, key: []const u8 };
const requested = "WITH requested AS MATERIALIZED (SELECT * FROM unnest($1::bigint[],$2::bigint[],$3::bigint[],$4::text[]) WITH ORDINALITY AS r(viewer,lim,off,key,ordinal)), ";
const shared_feed_hubs = @import("build_options").shared_feed_hubs;
const depth = "LEAST(k.lim::numeric+k.off::numeric,9223372036854775807)::bigint";

// Proofs belong to the current statement. A followed author's depth-th ID is
// a safe page floor; 1,000 rows from one followed author prove a capped count.
fn hubKeys(comptime count: bool) []const u8 {
    const keys = if (count) "key" else "key,lim,off";
    const prefix = "keys AS MATERIALIZED (SELECT k.*,ARRAY(SELECT followee_id FROM follows WHERE follower_id=k.key::bigint) AS fids FROM (SELECT DISTINCT " ++ keys ++ " FROM requested) k), ";
    if (count) return prefix ++
        "shared_feed_hubs AS MATERIALIZED (SELECT f.fid FROM keys k CROSS JOIN LATERAL unnest(k.fids) f(fid) GROUP BY f.fid HAVING count(*)>1 ORDER BY count(*) DESC,f.fid LIMIT 16), " ++
        "shared_feed_caps AS MATERIALIZED (SELECT h.fid FROM shared_feed_hubs h WHERE EXISTS(SELECT 1 FROM articles a WHERE a.author_id=h.fid LIMIT 1 OFFSET 999)), ";
    return prefix ++
        "shared_feed_hubs AS MATERIALIZED (SELECT f.fid,max(" ++ depth ++ ") AS depth FROM keys k CROSS JOIN LATERAL unnest(k.fids) f(fid) GROUP BY f.fid HAVING count(*)>1 ORDER BY count(*) DESC,f.fid LIMIT 16), " ++
        "shared_feed_bounds AS MATERIALIZED (SELECT h.fid,(SELECT a.id FROM articles a WHERE a.author_id=h.fid ORDER BY a.id DESC LIMIT 1 OFFSET GREATEST(h.depth,1)-1) AS floor_id FROM shared_feed_hubs h WHERE h.depth<=256), ";
}

fn sharedFeedIds() []const u8 {
    return "WITH page_bound AS MATERIALIZED (SELECT COALESCE(max(b.floor_id),'-9223372036854775808'::bigint) AS lo FROM shared_feed_bounds b WHERE b.fid=ANY(k.fids)) " ++
        "SELECT x.id FROM unnest(k.fids) fo(fid) CROSS JOIN LATERAL (SELECT a.id FROM articles a WHERE a.author_id=fo.fid AND a.id>=(SELECT lo FROM page_bound) ORDER BY a.id DESC LIMIT " ++ depth ++ ") x ORDER BY x.id DESC LIMIT 100 OFFSET k.off";
}

pub fn name(family: articles.Family, count: bool) [:0]const u8 {
    return switch (family) {
        .single => unreachable,
        inline else => |f| if (count) "batch_count_" ++ @tagName(f) else "batch_page_" ++ @tagName(f),
    };
}

fn ids(comptime family: articles.Family) []const u8 {
    const bare = switch (family) {
        .all => "SELECT p.id FROM articles p ORDER BY p.id DESC LIMIT 100 OFFSET k.off",
        .tag => "SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id=(SELECT id FROM tags WHERE name=k.key) ORDER BY at.article_id DESC LIMIT 100 OFFSET k.off",
        .author => "SELECT p.id FROM articles p WHERE p.author_id=(SELECT id FROM users WHERE username=k.key) ORDER BY p.id DESC LIMIT 100 OFFSET k.off",
        .favorited => "SELECT f.article_id AS id FROM favorites f WHERE f.user_id=(SELECT id FROM users WHERE username=k.key) ORDER BY f.article_id DESC LIMIT 100 OFFSET k.off",
        .feed => if (shared_feed_hubs) sharedFeedIds() else articles.feedIds("k.key::bigint", "k.lim", "k.off", "100"),
        .single => unreachable,
    };
    // The constant inner bound also gives generic plans a realistic page size.
    return "SELECT id FROM (" ++ bare ++ ") capped LIMIT k.lim";
}

fn pageSql(comptime family: articles.Family) [:0]const u8 {
    const metadata = "a.id,a.author_id,a.slug,a.title,a.description, " ++
        "to_char(a.created_at AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"') AS created_at, " ++
        "to_char(a.updated_at AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"') AS updated_at, " ++
        "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id=at.tag_id) AS name FROM article_tags at WHERE at.article_id=a.id ORDER BY name) AS tags, " ++
        "(SELECT count(*) FROM favorites f WHERE f.article_id=a.id) AS favorites,u.username,u.bio,u.image ";
    const pages = comptime if (@import("build_options").shared_page_metadata or @import("build_options").compact_pages)
        "hits AS MATERIALIZED (SELECT k.key,k.lim,k.off,p.id FROM keys k CROSS JOIN LATERAL (" ++ ids(family) ++ ") p), " ++
            "enriched AS MATERIALIZED (SELECT " ++ metadata ++ "FROM articles a JOIN (SELECT DISTINCT id FROM hits) d ON d.id=a.id JOIN users u ON u.id=a.author_id), " ++
            "pages AS MATERIALIZED (SELECT h.key,h.lim,h.off,e.* FROM hits h JOIN enriched e ON e.id=h.id), "
    else
        "pages AS MATERIALIZED (SELECT k.key,k.lim,k.off," ++ metadata ++ "FROM keys k CROSS JOIN LATERAL (" ++ ids(family) ++ ") p JOIN articles a ON a.id=p.id JOIN users u ON u.id=a.author_id), ";
    const keys = comptime if (family == .feed and shared_feed_hubs) hubKeys(false) else "keys AS (SELECT DISTINCT key,lim,off FROM requested), ";
    const flags = "page_ids AS (SELECT key,lim,off,array_agg(id) AS ids,array_agg(DISTINCT author_id) AS authors FROM pages GROUP BY key,lim,off), " ++
        "flags AS MATERIALIZED (SELECT r.ordinal, " ++
        "ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id=r.viewer AND f.article_id=ANY(p.ids)) AS fav, " ++
        "ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id=r.viewer AND fo.followee_id=ANY(p.authors)) AS fol " ++
        "FROM requested r LEFT JOIN page_ids p ON p.key=r.key AND p.lim=r.lim AND p.off=r.off) ";
    if (@import("build_options").compact_pages) return comptime requested ++ keys ++ pages ++ flags ++
        "SELECT 0::bigint AS ordinal,e.slug,e.title,e.description,e.created_at,e.updated_at,e.tags,e.favorites,false AS favorited,e.username,e.bio,e.image,false AS following,e.id,0::bigint AS position FROM enriched e " ++
        "UNION ALL SELECT r.ordinal,NULL::text,NULL::text,NULL::text,NULL::text,NULL::text,NULL::text[],NULL::bigint,p.id=ANY(f.fav),NULL::text,NULL::text,NULL::text,p.author_id=ANY(f.fol),p.id,row_number() OVER(PARTITION BY r.ordinal ORDER BY p.id DESC) " ++
        "FROM requested r JOIN flags f ON f.ordinal=r.ordinal LEFT JOIN pages p ON p.key=r.key AND p.lim=r.lim AND p.off=r.off ORDER BY 1,15";
    return comptime requested ++ keys ++ pages ++ flags ++
        "SELECT r.ordinal,p.slug,p.title,p.description,p.created_at,p.updated_at,p.tags,p.favorites,p.id=ANY(f.fav),p.username,p.bio,p.image,p.author_id=ANY(f.fol) " ++
        "FROM requested r JOIN flags f ON f.ordinal=r.ordinal LEFT JOIN pages p ON p.key=r.key AND p.lim=r.lim AND p.off=r.off ORDER BY r.ordinal,p.id DESC";
}

fn countSql(comptime family: articles.Family) [:0]const u8 {
    const counted = switch (family) {
        .all => "SELECT count(*) FROM (SELECT 1 FROM articles LIMIT 1000) s",
        .tag => "SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id=(SELECT id FROM tags WHERE name=k.key) LIMIT 1000) s",
        .author => "SELECT count(*) FROM (SELECT 1 FROM articles WHERE author_id=(SELECT id FROM users WHERE username=k.key) LIMIT 1000) s",
        .favorited => "SELECT count(*) FROM (SELECT 1 FROM favorites WHERE user_id=(SELECT id FROM users WHERE username=k.key) LIMIT 1000) s",
        .feed => "SELECT count(*) FROM (SELECT 1 FROM articles WHERE author_id IN (SELECT followee_id FROM follows WHERE follower_id=k.key::bigint) LIMIT 1000) s",
        .single => unreachable,
    };
    const keys = comptime if (family == .feed and shared_feed_hubs) hubKeys(true) else "keys AS (SELECT DISTINCT key FROM requested), ";
    const total = comptime if (family == .feed and shared_feed_hubs)
        "CASE WHEN k.fids && ARRAY(SELECT fid FROM shared_feed_caps) THEN 1000::bigint ELSE (" ++ counted ++ ") END"
    else
        "(" ++ counted ++ ")";
    return comptime requested ++ keys ++ "totals AS MATERIALIZED (SELECT k.key," ++ total ++ " AS n FROM keys k) SELECT r.ordinal,t.n FROM requested r JOIN totals t ON t.key=r.key ORDER BY r.ordinal";
}

pub fn statement(family: articles.Family, count: bool) [:0]const u8 {
    return switch (family) {
        .single => unreachable,
        inline else => |f| if (count) countSql(f) else pageSql(f),
    };
}

fn numbers(allocator: std.mem.Allocator, inputs: []const Input, comptime field: []const u8) ![:0]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.append(allocator, '{');
    for (inputs, 0..) |input, index| {
        const number = @field(input, field);
        if (number.len == 0) return error.BatchParameter;
        for (number) |ch| if (ch < '0' or ch > '9') return error.BatchParameter;
        if (index != 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, number);
    }
    try out.append(allocator, '}');
    return allocator.dupeSentinel(u8, out.items, 0);
}

pub fn parameters(allocator: std.mem.Allocator, inputs: []const Input) ![4][:0]const u8 {
    if (inputs.len == 0 or inputs.len > batch.capacity) return error.BatchSize;
    var keys: [batch.capacity]batch.Input = undefined;
    var size: usize = 0;
    for (inputs, 0..) |input, index| {
        size += input.viewer.len + input.limit.len + input.offset.len + input.key.len;
        if (size > batch.max_parameter_bytes) return error.BatchSize;
        keys[index] = .{ .viewer = input.viewer, .slug = input.key };
    }
    const text = try batch.parameters(allocator, keys[0..inputs.len]);
    errdefer for (text) |value| allocator.free(value);
    const limits = try numbers(allocator, inputs, "limit");
    errdefer allocator.free(limits);
    const offsets = try numbers(allocator, inputs, "offset");
    return .{ text[0], limits, offsets, text[1] };
}

test "page batch parameters preserve each viewer, window and filter" {
    const a = std.testing.allocator;
    const values = try parameters(a, &.{ .{ .viewer = "1", .limit = "10", .offset = "0", .key = "a,\"b" }, .{ .viewer = "0", .limit = "0", .offset = "9223372036854775807", .key = "" } });
    defer for (values) |value| a.free(value);
    try std.testing.expectEqualStrings("{1,0}", values[0]);
    try std.testing.expectEqualStrings("{10,0}", values[1]);
    try std.testing.expectEqualStrings("{0,9223372036854775807}", values[2]);
    try std.testing.expectEqualStrings("{\"a,\\\"b\",\"\"}", values[3]);
    try std.testing.expectError(error.BatchParameter, parameters(a, &.{.{ .viewer = "1", .limit = "-1", .offset = "0", .key = "x" }}));
}
