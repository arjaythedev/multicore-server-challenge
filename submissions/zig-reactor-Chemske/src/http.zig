const std = @import("std");

const Header = extern struct { name: ?[*]const u8, name_len: usize, value: [*]const u8, value_len: usize };
extern "c" fn phr_parse_request([*]const u8, usize, *?[*]const u8, *usize, *?[*]const u8, *usize, *c_int, [*]Header, *usize, usize) c_int;

pub const max_head = 16 * 1024;
pub const max_body = 64 * 1024;
pub const Auth = enum { none, optional, required };
pub const Route = enum {
    tags,
    register,
    login,
    current,
    update,
    profile,
    follow,
    unfollow,
    articles,
    feed,
    article,
    create_article,
    update_article,
    delete_article,
    favorite,
    unfavorite,
    comments,
    create_comment,
    delete_comment,
    unknown,

    pub fn auth(self: Route) Auth {
        return switch (self) {
            .current, .update, .follow, .unfollow, .feed, .create_article, .update_article, .delete_article, .favorite, .unfavorite, .create_comment, .delete_comment => .required,
            .profile, .articles, .article, .comments => .optional,
            else => .none,
        };
    }

    pub fn isProfile(self: Route) bool {
        return self == .profile or self == .follow or self == .unfollow;
    }

    pub fn isOperation(self: Route) bool {
        return switch (self) {
            .create_article, .update_article, .delete_article, .favorite, .unfavorite, .comments, .create_comment, .delete_comment => true,
            else => false,
        };
    }
};
pub const Request = struct { consumed: usize, route: Route, argument: []const u8, secondary: []const u8, query: []const u8, keep_alive: bool, body: []const u8, authorization: ?[]const u8 };
pub const Parse = union(enum) { more, bad: u16, request: Request };

pub fn parse(bytes: []const u8) Parse {
    var method: ?[*]const u8 = null;
    var path: ?[*]const u8 = null;
    var method_len: usize = 0;
    var path_len: usize = 0;
    var minor: c_int = 0;
    var headers: [64]Header = undefined;
    var count: usize = headers.len;
    const n = phr_parse_request(bytes.ptr, bytes.len, &method, &method_len, &path, &path_len, &minor, &headers, &count, 0);
    if (n == -2) return if (bytes.len >= max_head) .{ .bad = 431 } else .more;
    if (n < 0) return .{ .bad = 400 };
    if (n > max_head) return .{ .bad = 431 };
    if (minor != 1) return .{ .bad = 505 };
    var close = false;
    var host = false;
    var length: ?usize = null;
    var authorization: ?[]const u8 = null;
    for (headers[0..count]) |h| {
        const name = (h.name orelse return .{ .bad = 400 })[0..h.name_len];
        const value = std.mem.trim(u8, h.value[0..h.value_len], " \t");
        if (std.ascii.eqlIgnoreCase(name, "host")) {
            if (host or value.len == 0) return .{ .bad = 400 };
            host = true;
        } else if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            if (value.len == 0) return .{ .bad = 400 };
            for (value) |ch| if (ch < '0' or ch > '9') return .{ .bad = 400 };
            const parsed = std.fmt.parseInt(usize, value, 10) catch return .{ .bad = 400 };
            if (length != null and length.? != parsed) return .{ .bad = 400 };
            length = parsed;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            // Chunked bodies are not supported. Close rather than reinterpret their bytes.
            return .{ .bad = 400 };
        } else if (std.ascii.eqlIgnoreCase(name, "authorization")) {
            if (authorization != null) return .{ .bad = 400 };
            authorization = value;
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            var tokens = std.mem.splitScalar(u8, value, ',');
            while (tokens.next()) |token| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, token, " \t"), "close")) {
                close = true;
            };
        }
    }
    if (!host) return .{ .bad = 400 };
    const body_len = length orelse 0;
    if (body_len > max_body) return .{ .bad = 413 };
    const head_len: usize = @intCast(n);
    if (bytes.len - head_len < body_len) return .more;
    const target = path.?[0..path_len];
    const path_end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const matched = route(method.?[0..method_len], target[0..path_end]);
    return .{ .request = .{
        .consumed = head_len + body_len,
        .route = matched.route,
        .argument = matched.argument,
        .secondary = matched.secondary,
        .query = if (path_end < target.len) target[path_end + 1 ..] else "",
        .keep_alive = !close,
        .body = bytes[head_len..][0..body_len],
        .authorization = authorization,
    } };
}

const Match = struct { route: Route, argument: []const u8 = "", secondary: []const u8 = "" };

fn route(method: []const u8, path: []const u8) Match {
    if (std.mem.eql(u8, method, "GET")) {
        if (std.mem.eql(u8, path, "/api/tags")) return .{ .route = .tags };
        if (std.mem.eql(u8, path, "/api/user")) return .{ .route = .current };
        if (std.mem.eql(u8, path, "/api/articles")) return .{ .route = .articles };
        if (std.mem.eql(u8, path, "/api/articles/feed")) return .{ .route = .feed };
    } else if (std.mem.eql(u8, method, "POST")) {
        if (std.mem.eql(u8, path, "/api/users")) return .{ .route = .register };
        if (std.mem.eql(u8, path, "/api/users/login")) return .{ .route = .login };
        if (std.mem.eql(u8, path, "/api/articles")) return .{ .route = .create_article };
    } else if (std.mem.eql(u8, method, "PUT") and std.mem.eql(u8, path, "/api/user")) return .{ .route = .update };
    const article_prefix = "/api/articles/";
    if (std.mem.startsWith(u8, path, article_prefix)) {
        const tail = path[article_prefix.len..];
        const end = std.mem.indexOfScalar(u8, tail, '/') orelse tail.len;
        if (end == 0) return .{ .route = .unknown };
        const slug = tail[0..end];
        const suffix = tail[end..];
        const matched: Route = if (suffix.len == 0) blk: {
            if (std.mem.eql(u8, method, "GET")) break :blk .article;
            if (std.mem.eql(u8, method, "PUT")) break :blk .update_article;
            if (std.mem.eql(u8, method, "DELETE")) break :blk .delete_article;
            break :blk .unknown;
        } else if (std.mem.eql(u8, suffix, "/favorite")) blk: {
            if (std.mem.eql(u8, method, "POST")) break :blk .favorite;
            if (std.mem.eql(u8, method, "DELETE")) break :blk .unfavorite;
            break :blk .unknown;
        } else if (std.mem.eql(u8, suffix, "/comments")) blk: {
            if (std.mem.eql(u8, method, "GET")) break :blk .comments;
            if (std.mem.eql(u8, method, "POST")) break :blk .create_comment;
            break :blk .unknown;
        } else .unknown;
        if (matched != .unknown) return .{ .route = matched, .argument = slug };
        const comment_prefix = "/comments/";
        if (std.mem.eql(u8, method, "DELETE") and std.mem.startsWith(u8, suffix, comment_prefix)) {
            const id = suffix[comment_prefix.len..];
            if (id.len != 0 and std.mem.indexOfScalar(u8, id, '/') == null) return .{ .route = .delete_comment, .argument = slug, .secondary = id };
        }
        return .{ .route = .unknown };
    }
    const prefix = "/api/profiles/";
    if (std.mem.startsWith(u8, path, prefix)) {
        const tail = path[prefix.len..];
        const end = std.mem.indexOfScalar(u8, tail, '/') orelse tail.len;
        if (end != 0) {
            if (end == tail.len and std.mem.eql(u8, method, "GET")) return .{ .route = .profile, .argument = tail };
            if (std.mem.eql(u8, tail[end..], "/follow")) {
                if (std.mem.eql(u8, method, "POST")) return .{ .route = .follow, .argument = tail[0..end] };
                if (std.mem.eql(u8, method, "DELETE")) return .{ .route = .unfollow, .argument = tail[0..end] };
            }
        }
    }
    return .{ .route = .unknown };
}

test "partial headers, close dominance and conflicting framing" {
    try std.testing.expect(parse("GET /api/tags HTTP/1.1\r\nHost: x\r\n") == .more);
    const request = parse("GET /api/tags HTTP/1.1\r\nHost: x\r\nConnection: close, keep-alive\r\n\r\n").request;
    try std.testing.expect(request.route == .tags and !request.keep_alive);
    try std.testing.expect(parse("GET /api/tags HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nContent-Length: 1\r\n\r\n") == .bad);
    try std.testing.expect(parse("GET /api/tags HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n") == .bad);
}

test "tags ignores auth, preserves the next pipelined request" {
    const first = "GET /api/tags?x=y HTTP/1.1\r\nHost: x\r\nAuthorization: \r\n\r\n";
    const result = parse(first ++ "GET / HTTP/1.1\r\nHost: x\r\n\r\n").request;
    try std.testing.expect(result.route == .tags and result.keep_alive);
    try std.testing.expectEqual(first.len, result.consumed);
}

test "body framing waits for all bytes and leaves the next request intact" {
    const head = "POST /api/users HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n";
    try std.testing.expect(parse(head ++ "{") == .more);
    const request = parse(head ++ "{}GET / HTTP/1.1\r\nHost: x\r\n\r\n").request;
    try std.testing.expectEqualStrings("{}", request.body);
    try std.testing.expectEqual(head.len + 2, request.consumed);
    try std.testing.expect(parse("POST /api/users HTTP/1.1\r\nHost: x\r\nContent-Length: 65537\r\n\r\n") == .bad);
}

test "profile routes match encoded segments before decoding and ignore query text" {
    const get = parse("GET /api/profiles/a%2Fb+%25?x=/follow HTTP/1.1\r\nHost: x\r\n\r\n").request;
    try std.testing.expectEqual(Route.profile, get.route);
    try std.testing.expectEqualStrings("a%2Fb+%25", get.argument);
    const follow = parse("POST /api/profiles/a%2Fb/follow HTTP/1.1\r\nHost: x\r\n\r\n").request;
    try std.testing.expectEqual(Route.follow, follow.route);
    try std.testing.expectEqualStrings("a%2Fb", follow.argument);
    try std.testing.expectEqual(Route.unknown, route("GET", "/api/profiles/a/b").route);
    try std.testing.expectEqual(Route.unknown, route("POST", "/api/profiles//follow").route);
    try std.testing.expectEqual(Route.unknown, route("PUT", "/api/profiles/a/follow").route);
    try std.testing.expectEqual(Route.unknown, route("POST", "/api/profiles/a/follow/extra").route);
}

test "article routing reserves feed and preserves raw query and encoded slug" {
    const feed = parse("GET /api/articles/feed?limit=2 HTTP/1.1\r\nHost: x\r\n\r\n").request;
    try std.testing.expectEqual(Route.feed, feed.route);
    try std.testing.expectEqualStrings("limit=2", feed.query);
    const article = parse("GET /api/articles/a%2Fb?limit=0 HTTP/1.1\r\nHost: x\r\n\r\n").request;
    try std.testing.expectEqual(Route.article, article.route);
    try std.testing.expectEqualStrings("a%2Fb", article.argument);
    try std.testing.expectEqual(Route.create_article, route("POST", "/api/articles").route);
    try std.testing.expectEqual(Route.comments, route("GET", "/api/articles/a/comments").route);
}

test "write routes preserve encoded slug and keep comment IDs separate" {
    const matched = route("DELETE", "/api/articles/a%2Fb/comments/%31");
    try std.testing.expectEqual(Route.delete_comment, matched.route);
    try std.testing.expectEqualStrings("a%2Fb", matched.argument);
    try std.testing.expectEqualStrings("%31", matched.secondary);
    try std.testing.expectEqual(Route.unknown, route("DELETE", "/api/articles/a/comments/1/more").route);
    try std.testing.expectEqual(Route.unknown, route("GET", "/api/articles/a/favorite").route);
}
