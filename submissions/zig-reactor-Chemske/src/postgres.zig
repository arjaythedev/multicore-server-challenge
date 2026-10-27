const std = @import("std");
const c = std.c;
const http = @import("http.zig");
const profiles = @import("profiles.zig");
const articles = @import("articles.zig");
const operations = @import("operations.zig");
const read_batch = @import("read_batch.zig");
pub const prepared_queries = @import("build_options").prepared_queries;

// Minimal declarations from PostgreSQL 18's public libpq-fe.h ABI.
pub const Conn = opaque {};
pub const Result = opaque {};
extern "c" fn PQconnectStart([*:0]const u8) ?*Conn;
extern "c" fn PQconnectPoll(*Conn) c_int;
pub extern "c" fn PQsocket(*const Conn) c_int;
extern "c" fn PQsetnonblocking(*Conn, c_int) c_int;
pub extern "c" fn PQfinish(*Conn) void;
pub extern "c" fn PQtransactionStatus(*const Conn) c_int;
extern "c" fn PQsendQueryParams(*Conn, [*:0]const u8, c_int, ?[*]const u32, ?[*]const ?[*:0]const u8, ?[*]const c_int, ?[*]const c_int, c_int) c_int;
extern "c" fn PQsendPrepare(*Conn, [*:0]const u8, [*:0]const u8, c_int, ?[*]const u32) c_int;
extern "c" fn PQsendQueryPrepared(*Conn, [*:0]const u8, c_int, ?[*]const ?[*:0]const u8, ?[*]const c_int, ?[*]const c_int, c_int) c_int;
pub extern "c" fn PQflush(*Conn) c_int;
pub extern "c" fn PQconsumeInput(*Conn) c_int;
pub extern "c" fn PQisBusy(*Conn) c_int;
pub extern "c" fn PQgetResult(*Conn) ?*Result;
pub extern "c" fn PQclear(*Result) void;
extern "c" fn PQresultStatus(*const Result) c_int;
extern "c" fn PQntuples(*const Result) c_int;
extern "c" fn PQnfields(*const Result) c_int;
extern "c" fn PQgetisnull(*const Result, c_int, c_int) c_int;
extern "c" fn PQgetvalue(*const Result, c_int, c_int) [*]const u8;
extern "c" fn PQgetlength(*const Result, c_int, c_int) c_int;
extern "c" fn PQresultErrorField(*const Result, c_int) ?[*:0]const u8;

pub const Interest = struct { read: bool = false, write: bool = false, ready: bool = false };

// One owner advances both authentication and statement preparation from readiness
// events. A replacement is never published until all prepared queries are drained.
pub const Connector = struct {
    conn: *Conn,
    authenticating: bool = true,
    query_index: usize = 0,
    waiting: bool = false,
    successful: bool = false,

    pub fn start(url: [*:0]const u8) !Connector {
        const conn = PQconnectStart(url) orelse return error.DatabaseConnect;
        errdefer PQfinish(conn);
        if (PQsocket(conn) < 0) return error.DatabaseConnect;
        return .{ .conn = conn };
    }

    pub fn advance(self: *Connector, readable: bool) !Interest {
        if (self.authenticating) {
            switch (PQconnectPoll(self.conn)) {
                1 => return .{ .read = true },
                2 => return .{ .write = true },
                3 => {
                    if (PQsetnonblocking(self.conn, 1) != 0) return error.DatabaseNonblocking;
                    self.authenticating = false;
                },
                else => return error.DatabaseConnect,
            }
        } else if (readable and PQconsumeInput(self.conn) != 1) return error.DatabasePrepare;
        while (true) {
            if (!self.waiting) {
                if (self.query_index == 0) {
                    // Bound abandoned backend work as well as the reactor's own
                    // deadline. This SET affects only the connection I own.
                    if (PQsendQueryParams(self.conn, "SET statement_timeout = '8s'", 0, null, null, null, null, 0) != 1) return error.DatabasePrepare;
                } else if (self.query_index < 3) {
                    const setting = if (self.query_index == 1) "SET jit = off" else if (@import("build_options").generic_plans)
                        "SET plan_cache_mode = force_generic_plan"
                    else
                        "SET plan_cache_mode = auto";
                    if (PQsendQueryParams(self.conn, setting, 0, null, null, null, null, 0) != 1) return error.DatabasePrepare;
                } else {
                    if (!prepared_queries) return .{ .ready = true };
                    const item = prepareItem(self.query_index - 3) orelse return .{ .ready = true };
                    if (PQsendPrepare(self.conn, item.name.ptr, item.sql.ptr, 0, null) != 1) return error.DatabasePrepare;
                }
                self.waiting = true;
                self.successful = false;
            }
            const flush = PQflush(self.conn);
            if (flush < 0) return error.DatabasePrepare;
            if (PQisBusy(self.conn) != 0) return .{ .read = true, .write = flush == 1 };
            const result = PQgetResult(self.conn) orelse {
                if (!self.successful or PQtransactionStatus(self.conn) != 0) return error.DatabasePrepare;
                self.query_index += 1;
                self.waiting = false;
                continue;
            };
            const ok = PQresultStatus(result) == 1;
            PQclear(result);
            if (!ok) return error.DatabasePrepare;
            self.successful = true;
        }
    }
};

pub fn connect(url: [*:0]const u8, io: std.Io) !*Conn {
    var connector = try Connector.start(url);
    errdefer PQfinish(connector.conn);
    const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + 20_000;
    var interest: Interest = .{ .write = true };
    while (std.Io.Clock.awake.now(io).toMilliseconds() < deadline) {
        var fds = [_]c.pollfd{.{ .fd = PQsocket(connector.conn), .events = @as(i16, if (interest.read) c.POLL.IN else 0) | @as(i16, if (interest.write) c.POLL.OUT else 0), .revents = 0 }};
        if (fds[0].fd < 0) return error.DatabaseConnect;
        const count = c.poll(&fds, 1, 100);
        if (count < 0) {
            if (c.errno(count) == .INTR) continue;
            return error.DatabasePoll;
        }
        if (count == 0) continue;
        interest = try connector.advance(fds[0].revents & c.POLL.IN != 0);
        if (interest.ready) return connector.conn;
    }
    return error.DatabaseConnectTimeout;
}

fn querySql(route: http.Route, read: ?articles.Read) [:0]const u8 {
    return if (read) |r| r.statement() else switch (route) {
        .tags => "SELECT name FROM tags ORDER BY name",
        .register => "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image",
        .login => "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1",
        .current => "SELECT id, username, email, bio, image FROM users WHERE id = $1",
        .update => "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) WHERE id = $1 RETURNING id, username, email, bio, image",
        .profile => profiles.get_sql,
        .follow => profiles.follow_sql,
        .unfollow => profiles.unfollow_sql,
        .comments => operations.list_comments_sql,
        else => unreachable,
    };
}

fn statementName(route: http.Route, read: ?articles.Read) [:0]const u8 {
    const r = read orelse return @tagName(route);
    const pages = [_][:0]const u8{ "page_all", "page_tag", "page_author", "page_favorited", "page_feed", "page_single" };
    const counts = [_][:0]const u8{ "count_all", "count_tag", "count_author", "count_favorited", "count_feed" };
    return if (r.phase == .page) pages[@backingInt(r.family)] else counts[@backingInt(r.family)];
}

fn prepareItem(index: usize) ?struct { name: [:0]const u8, sql: [:0]const u8 } {
    const routes = [_]http.Route{ .tags, .register, .login, .current, .update, .profile, .follow, .unfollow, .comments };
    if (index < routes.len) return .{ .name = statementName(routes[index], null), .sql = querySql(routes[index], null) };
    const offset = index - routes.len;
    if (offset == 11) return .{ .name = "batch_single", .sql = read_batch.single_sql };
    if (offset > 11) return null;
    const read: articles.Read = .{
        .family = @fromBackingInt(@intCast(if (offset < 6) offset else offset - 6)),
        .phase = if (offset < 6) .page else .count,
    };
    return .{ .name = statementName(.articles, read), .sql = read.statement() };
}

pub fn query(conn: *Conn, route: http.Route, params: []const ?[:0]const u8, read: ?articles.Read) !void {
    var actual = params;
    if (read) |r| {
        if (r.phase == .count) actual = switch (r.family) {
            .all => &.{},
            .feed => params[0..1],
            .single => unreachable,
            else => params[3..4],
        };
    }
    if (prepared_queries) {
        var values: [6]?[*:0]const u8 = @splat(null);
        for (actual, 0..) |param, i| values[i] = if (param) |p| p.ptr else null;
        if (PQsendQueryPrepared(conn, statementName(route, read).ptr, @intCast(actual.len), &values, null, null, 0) != 1) return error.DatabaseQuery;
    } else try send(conn, querySql(route, read), actual);
}

pub fn send(conn: *Conn, statement: [:0]const u8, params: []const ?[:0]const u8) !void {
    var values: [6]?[*:0]const u8 = @splat(null);
    for (params, 0..) |param, i| values[i] = if (param) |p| p.ptr else null;
    // libpq copies the parameter bytes before this call returns.
    if (PQsendQueryParams(conn, statement.ptr, @intCast(params.len), null, &values, null, null, 0) != 1) return error.DatabaseQuery;
}

pub fn status(result: *Result) u16 {
    if (PQresultStatus(result) == 2 or PQresultStatus(result) == 1) return 200;
    const code = PQresultErrorField(result, 'C') orelse return 503;
    return if (std.mem.eql(u8, std.mem.span(code), "23505")) 422 else 503;
}

pub const User = struct {
    id: []const u8,
    username: []const u8,
    email: []const u8,
    bio: ?[]const u8,
    image: ?[]const u8,
    hash: ?[]const u8,
};

fn field(result: *Result, column: c_int, allocator: std.mem.Allocator) !?[]const u8 {
    if (PQgetisnull(result, 0, column) != 0) return null;
    const len: usize = @intCast(PQgetlength(result, 0, column));
    if (len > 1024 * 1024) return error.ResponseTooLarge;
    return try allocator.dupe(u8, PQgetvalue(result, 0, column)[0..len]);
}

pub fn user(result: *Result, allocator: std.mem.Allocator, login: bool) !?User {
    if (PQresultStatus(result) != 2 or PQnfields(result) != @as(c_int, if (login) 6 else 5)) return error.DatabaseResult;
    if (PQntuples(result) == 0) return null;
    if (PQntuples(result) != 1) return error.DatabaseResult;
    return .{
        .id = (try field(result, 0, allocator)) orelse return error.DatabaseResult,
        .username = (try field(result, 1, allocator)) orelse return error.DatabaseResult,
        .email = (try field(result, 2, allocator)) orelse return error.DatabaseResult,
        .bio = try field(result, 3, allocator),
        .image = try field(result, 4, allocator),
        .hash = if (login) try field(result, 5, allocator) else null,
    };
}

pub fn profileJson(result: *Result, allocator: std.mem.Allocator) !?[]const u8 {
    if (PQresultStatus(result) != 2 or PQnfields(result) != 5) return error.DatabaseResult;
    if (PQntuples(result) == 0) return null;
    if (PQntuples(result) != 1 or PQgetisnull(result, 0, 4) != 0 or PQgetlength(result, 0, 4) != 1) return error.DatabaseResult;
    const flag = PQgetvalue(result, 0, 4)[0];
    if (flag != 't' and flag != 'f') return error.DatabaseResult;
    const profile: profiles.Profile = .{
        .username = (try field(result, 1, allocator)) orelse return error.DatabaseResult,
        .bio = try field(result, 2, allocator),
        .image = try field(result, 3, allocator),
        .following = flag == 't',
    };
    return try std.json.Stringify.valueAlloc(allocator, .{ .profile = profile }, .{});
}

pub fn tagsJson(result: *Result, allocator: std.mem.Allocator) ![]u8 {
    if (PQresultStatus(result) != 2 or PQnfields(result) != 1) return error.DatabaseResult;
    const count: usize = @intCast(PQntuples(result));
    const names = try allocator.alloc([]const u8, count);
    defer allocator.free(names);
    var total: usize = 0;
    for (names, 0..) |*name, index| {
        const row: c_int = @intCast(index);
        if (PQgetisnull(result, row, 0) != 0) return error.DatabaseResult;
        const len: usize = @intCast(PQgetlength(result, row, 0));
        total += len;
        if (total > 1024 * 1024) return error.ResponseTooLarge;
        name.* = PQgetvalue(result, row, 0)[0..len];
    }
    return std.json.Stringify.valueAlloc(allocator, .{ .tags = names }, .{});
}

fn cell(result: *Result, row: c_int, column: c_int) ?[]const u8 {
    if (PQgetisnull(result, row, column) != 0) return null;
    return PQgetvalue(result, row, column)[0..@intCast(PQgetlength(result, row, column))];
}

fn required(result: *Result, row: c_int, column: c_int) ![]const u8 {
    return cell(result, row, column) orelse error.DatabaseResult;
}

fn textCell(result: *Result, row: c_int, column: c_int, allocator: std.mem.Allocator) ![]const u8 {
    return allocator.dupe(u8, try required(result, row, column));
}

fn nullableCell(result: *Result, row: c_int, column: c_int, allocator: std.mem.Allocator) !?[]const u8 {
    return if (cell(result, row, column)) |value| try allocator.dupe(u8, value) else null;
}

fn boolean(result: *Result, row: c_int, column: c_int) !bool {
    const value = try required(result, row, column);
    if (std.mem.eql(u8, value, "t")) return true;
    if (std.mem.eql(u8, value, "f")) return false;
    return error.DatabaseResult;
}

pub fn articlePage(result: *Result, allocator: std.mem.Allocator, full: bool) ![]articles.Article {
    const columns: c_int = if (full) 13 else 12;
    if (PQresultStatus(result) != 2 or PQnfields(result) != columns) return error.DatabaseResult;
    const count: usize = @intCast(PQntuples(result));
    if (count > @as(usize, if (full) 1 else 100)) return error.DatabaseResult;
    const rows = try allocator.alloc(articles.Article, count);
    var total: usize = 0;
    for (rows, 0..) |*article, index| article.* = try articleAt(result, @intCast(index), 0, allocator, full, &total);
    return rows;
}

fn articleAt(result: *Result, row: c_int, offset: c_int, allocator: std.mem.Allocator, full: bool, total: *usize) !articles.Article {
    const columns: usize = if (full) 13 else 12;
    for (0..columns) |column| {
        total.* += @intCast(PQgetlength(result, row, offset + @as(c_int, @intCast(column))));
        if (total.* > 4 * 1024 * 1024) return error.ResponseTooLarge;
    }
    const favorites = std.fmt.parseInt(i64, try required(result, row, offset + 6), 10) catch return error.DatabaseResult;
    if (favorites < 0) return error.DatabaseResult;
    return .{
        .slug = try textCell(result, row, offset + 0, allocator),
        .title = try textCell(result, row, offset + 1, allocator),
        .description = try textCell(result, row, offset + 2, allocator),
        .createdAt = try textCell(result, row, offset + 3, allocator),
        .updatedAt = try textCell(result, row, offset + 4, allocator),
        .tagList = try articles.tags(allocator, try required(result, row, offset + 5)),
        .favoritesCount = favorites,
        .favorited = try boolean(result, row, offset + 7),
        .author = .{
            .username = try textCell(result, row, offset + 8, allocator),
            .bio = try nullableCell(result, row, offset + 9, allocator),
            .image = try nullableCell(result, row, offset + 10, allocator),
            .following = try boolean(result, row, offset + 11),
        },
        .body = if (full) try textCell(result, row, offset + 12, allocator) else null,
    };
}

pub fn sendSingleBatch(conn: *Conn, inputs: []const read_batch.Input, allocator: std.mem.Allocator) !void {
    const params = try read_batch.parameters(allocator, inputs);
    if (prepared_queries) {
        const values = [_]?[*:0]const u8{ params[0].ptr, params[1].ptr };
        if (PQsendQueryPrepared(conn, "batch_single", 2, &values, null, null, 0) != 1) return error.DatabaseQuery;
    } else try send(conn, read_batch.single_sql, &.{ params[0], params[1] });
}

pub fn checkSingleBatch(result: *Result, expected: usize) !void {
    if (PQresultStatus(result) != 2 or PQnfields(result) != 14 or PQntuples(result) != expected) return error.DatabaseResult;
    for (0..expected) |index| {
        const ordinal = std.fmt.parseInt(usize, try required(result, @intCast(index), 0), 10) catch return error.DatabaseResult;
        if (ordinal != index + 1) return error.DatabaseResult;
    }
}

pub fn singleBatchRow(result: *Result, index: usize, allocator: std.mem.Allocator) ![]articles.Article {
    const row: c_int = @intCast(index);
    if (cell(result, row, 1) == null) return &.{};
    var total: usize = 0;
    const rows = try allocator.alloc(articles.Article, 1);
    rows[0] = try articleAt(result, row, 1, allocator, true, &total);
    return rows;
}

pub fn articleCount(result: *Result) !i64 {
    if (PQresultStatus(result) != 2 or PQntuples(result) != 1 or PQnfields(result) != 1) return error.DatabaseResult;
    const count = std.fmt.parseInt(i64, try required(result, 0, 0), 10) catch return error.DatabaseResult;
    if (count < 0 or count > 1000) return error.DatabaseResult;
    return count;
}

fn identifier(result: *Result, allocator: std.mem.Allocator) !?[:0]const u8 {
    if (PQresultStatus(result) != 2 or PQnfields(result) != 1 or PQntuples(result) > 1) return error.DatabaseResult;
    if (PQntuples(result) == 0) return null;
    const value = try required(result, 0, 0);
    const number = std.fmt.parseInt(i64, value, 10) catch return error.DatabaseResult;
    if (number <= 0) return error.DatabaseResult;
    return try allocator.dupeSentinel(u8, value, 0);
}

fn commentRows(result: *Result, allocator: std.mem.Allocator, single: bool, offset: c_int) ![]operations.Comment {
    if (PQresultStatus(result) != 2 or PQnfields(result) != 8 + offset) return error.DatabaseResult;
    const count: usize = @intCast(PQntuples(result));
    if (count > @as(usize, if (single) 1 else 100)) return error.DatabaseResult;
    if (offset == 1 and count == 1 and PQgetisnull(result, 0, 1) != 0) return &.{};
    const comments = try allocator.alloc(operations.Comment, count);
    var total: usize = 0;
    for (comments, 0..) |*comment, index| {
        const row: c_int = @intCast(index);
        for (0..8) |column| {
            total += @intCast(PQgetlength(result, row, @as(c_int, @intCast(column)) + offset));
            if (total > 4 * 1024 * 1024) return error.ResponseTooLarge;
        }
        const id = std.fmt.parseInt(i64, try required(result, row, offset + 0), 10) catch return error.DatabaseResult;
        if (id <= 0) return error.DatabaseResult;
        comment.* = .{
            .id = id,
            .body = try textCell(result, row, offset + 1, allocator),
            .createdAt = try textCell(result, row, offset + 2, allocator),
            .updatedAt = try textCell(result, row, offset + 3, allocator),
            .author = .{
                .username = try textCell(result, row, offset + 4, allocator),
                .bio = try nullableCell(result, row, offset + 5, allocator),
                .image = try nullableCell(result, row, offset + 6, allocator),
                .following = try boolean(result, row, offset + 7),
            },
        };
    }
    return comments;
}

pub fn operationResult(result: *Result, operation: *operations.Operation, allocator: std.mem.Allocator) !u16 {
    switch (operation.stage) {
        .begin, .insert_tags, .link_tags, .commit, .rollback => {
            if (PQresultStatus(result) != 1) return error.DatabaseResult;
        },
        .insert_article, .lookup => operation.id = (try identifier(result, allocator)) orelse return 404,
        .mutate => switch (operation.kind) {
            .favorite, .unfavorite => operation.id = (try identifier(result, allocator)) orelse return 404,
            .create_comment => {
                operation.comments = try commentRows(result, allocator, true, 0);
                if (operation.comments.len != 1) return error.DatabaseResult;
            },
            .update_article, .delete_article, .delete_comment => {
                if (PQresultStatus(result) != 2 or PQnfields(result) != 2 or PQntuples(result) != 1) return error.DatabaseResult;
                const code = std.fmt.parseInt(u16, try required(result, 0, 0), 10) catch return error.DatabaseResult;
                if (code != 200) return if (code == 403 or code == 404) code else error.DatabaseResult;
                const id = try required(result, 0, 1);
                operation.id = try allocator.dupeSentinel(u8, id, 0);
            },
            else => unreachable,
        },
        .article_row => {
            operation.article = try articlePage(result, allocator, true);
            if (operation.article.len == 0) return 404;
        },
        .comment_rows => {
            if (PQresultStatus(result) != 2 or PQnfields(result) != 9) return error.DatabaseResult;
            if (PQntuples(result) == 0) return 404;
            if (PQgetisnull(result, 0, 0) != 0) return error.DatabaseResult;
            operation.comments = try commentRows(result, allocator, false, 1);
        },
    }
    return 200;
}
