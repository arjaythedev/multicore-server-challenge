//! The Conduit API (SPEC.md): routing, authentication, validation in the
//! reference server's order, one group of statements per request, and the
//! JSON written from the binary rows.

const std = @import("std");
const assert = std.debug.assert;
const fourneau = @import("fourneau");
const pg = @import("pg.zig");
const sql = @import("sql.zig");
const json = @import("json.zig");
const jwt = @import("jwt.zig");
const url = @import("url.zig");
const time = @import("time.zig");
const password = @import("password.zig");
const shard_module = @import("shard.zig");
const Shard = shard_module.Shard;

const S = sql.S;
const Header = fourneau.http1_response.Header;
const Out = json.Out;

pub const Response = struct {
    status: u16,
    headers: []const Header,
    body: []const u8,
    /// The result slot holding `body` (and the rows it was made from),
    /// given back once the response is sent.
    slot: ?u32 = null,
};

const json_headers: []const Header = &.{.{ .name = "Content-Type", .value = "application/json" }};

fn failure(status: u16, comptime message: []const u8) Response {
    return .{ .status = status, .headers = json_headers, .body = "{\"errors\":{\"body\":[\"" ++ message ++ "\"]}}" };
}

const not_found = failure(404, "not found");
const unauthorized = failure(401, "unauthorized");
const unprocessable = failure(422, "invalid body");
const forbidden = failure(403, "not the author");
const internal = failure(500, "internal error");
const no_content: Response = .{ .status = 204, .headers = &.{}, .body = "" };

/// One request's context, between the router and its handler.
pub const Context = struct {
    shard: *Shard,
    head: *const fourneau.http1_head.Head,
    request: *shard_module.Server.Request,
    /// The viewer: the token's user id, 0 when anonymous.
    viewer: i64 = 0,
    /// The token as presented (GET and PUT /api/user answer with it).
    token: []const u8 = "",
};

const Auth = enum { none, optional, required };

/// The viewer from `Authorization: Token <jwt>`: null means 401.
fn authenticate(context: *Context, auth: Auth) bool {
    if (auth == .none) return true;
    var header: ?[]const u8 = null;
    for (context.head.headers) |field| {
        if (std.ascii.eqlIgnoreCase(field.name, "authorization")) {
            header = field.value;
            break;
        }
    }
    const value = header orelse return auth == .optional;
    if (value.len == 0) return auth == .optional;
    const prefix = "Token ";
    if (!std.mem.startsWith(u8, value, prefix)) return false;
    const token = value[prefix.len..];
    const shard = context.shard;
    const viewer = jwt.verify(shard.key, token, now_s(), shard.jwt_memory) orelse return false;
    context.viewer = viewer;
    context.token = token;
    return true;
}

pub fn now_s() i64 {
    var spec: std.os.linux.timespec = undefined;
    const result = std.os.linux.clock_gettime(.REALTIME, &spec);
    assert(std.os.linux.errno(result) == .SUCCESS);
    return spec.sec;
}

const Method = fourneau.http1_head.Method;

/// The route for a method and a path, its path parameters still escaped.
pub fn route(context: *Context) Response {
    const head = context.head;
    const method = head.method;
    const path = head.path();
    const api = "/api/";
    if (!std.mem.startsWith(u8, path, api)) return not_found;
    var segments_buffer: [6][]const u8 = undefined;
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, path[api.len..], '/');
    while (parts.next()) |part| {
        if (count == segments_buffer.len) return not_found;
        segments_buffer[count] = part;
        count += 1;
    }
    const segments = segments_buffer[0..count];
    for (segments) |segment| if (segment.len == 0) return not_found;
    const get = method == .get or method == .head;
    const first = segments[0];
    if (std.mem.eql(u8, first, "articles")) return route_articles(context, method, get, segments[1..]);
    if (std.mem.eql(u8, first, "tags") and segments.len == 1 and get) return tags(context);
    if (std.mem.eql(u8, first, "profiles") and segments.len >= 2) {
        if (segments.len == 2 and get) return guarded(context, .optional, profile, segments[1]);
        if (segments.len == 3 and std.mem.eql(u8, segments[2], "follow")) {
            if (method == .post) return guarded(context, .required, follow, segments[1]);
            if (method == .delete) return guarded(context, .required, unfollow, segments[1]);
        }
        return not_found;
    }
    if (std.mem.eql(u8, first, "user") and segments.len == 1) {
        if (get) return guarded(context, .required, current_user, "");
        if (method == .put) return guarded(context, .required, update_user, "");
        return not_found;
    }
    if (std.mem.eql(u8, first, "users") and method == .post) {
        if (segments.len == 1) return register(context);
        if (segments.len == 2 and std.mem.eql(u8, segments[1], "login")) return login(context);
    }
    return not_found;
}

fn route_articles(context: *Context, method: Method, get: bool, rest: []const []const u8) Response {
    if (rest.len == 0) {
        if (get) return guarded(context, .optional, list_articles, "");
        if (method == .post) return guarded(context, .required, create_article, "");
        return not_found;
    }
    const slug = rest[0];
    if (rest.len == 1) {
        if (get and std.mem.eql(u8, slug, "feed")) return guarded(context, .required, feed, "");
        if (get) return guarded(context, .optional, get_article, slug);
        if (method == .put) return guarded(context, .required, update_article, slug);
        if (method == .delete) return guarded(context, .required, delete_article, slug);
        return not_found;
    }
    const what = rest[1];
    if (rest.len == 2 and std.mem.eql(u8, what, "favorite")) {
        if (method == .post) return guarded(context, .required, favorite, slug);
        if (method == .delete) return guarded(context, .required, unfavorite, slug);
        return not_found;
    }
    if (std.mem.eql(u8, what, "comments")) {
        if (rest.len == 2 and get) return guarded(context, .optional, list_comments, slug);
        if (rest.len == 2 and method == .post) return guarded(context, .required, create_comment, slug);
        if (rest.len == 3 and method == .delete) return guarded_two(context, delete_comment, slug, rest[2]);
    }
    return not_found;
}

const Handler = fn (context: *Context, parameter: []const u8) Response;

/// Authenticate, decode the path parameter, then the handler.
fn guarded(context: *Context, auth: Auth, comptime handler: Handler, raw: []const u8) Response {
    if (!authenticate(context, auth)) return unauthorized;
    var buffer: [512]u8 = undefined;
    const parameter = url.decode(raw, &buffer, false) orelse return not_found;
    return handler(context, parameter);
}

fn guarded_two(
    context: *Context,
    comptime handler: fn (*Context, []const u8, []const u8) Response,
    raw_slug: []const u8,
    raw_id: []const u8,
) Response {
    if (!authenticate(context, .required)) return unauthorized;
    var slug_buffer: [512]u8 = undefined;
    var id_buffer: [64]u8 = undefined;
    const slug = url.decode(raw_slug, &slug_buffer, false) orelse return not_found;
    const id = url.decode(raw_id, &id_buffer, false) orelse return not_found;
    return handler(context, slug, id);
}

// ---------- a group of statements, its slot, its answers ----------

/// A request's group: a result slot, a connection, the statements.
const Group = struct {
    context: *Context,
    slot: u32,
    query: pg.Query,

    fn begin(context: *Context, kind: pg_kind) Group {
        const shard = context.shard;
        const slot = shard.slots.acquire(shard.io);
        const connection = switch (kind) {
            .read => shard.pick_read(),
            .write => shard.pick_write(),
        };
        return .{
            .context = context,
            .slot = slot,
            .query = .init(connection, shard.slots.rows(slot)),
        };
    }

    fn run(group: *Group, statement: S, params: []const pg.Param) void {
        group.query.run(@intFromEnum(statement), params);
    }

    /// The answers, or null after the slot is given back: the request then
    /// answers 500 (or 422 for a unique violation, `unique`).
    fn wait(group: *Group) pg.Results {
        return group.query.wait();
    }

    fn out(group: *Group) Out {
        return .init(group.context.shard.slots.output(group.slot));
    }

    /// The response made in this group's slot, which it keeps until sent.
    fn respond(group: *Group, status: u16, writer: *const Out) Response {
        const body = writer.result() orelse {
            group.release();
            return internal;
        };
        return .{ .status = status, .headers = json_headers, .body = body, .slot = group.slot };
    }

    fn release(group: *Group) void {
        group.context.shard.slots.release(group.context.shard.io, group.slot);
    }

    /// A response that needs nothing of the slot: given back now.
    fn finish(group: *Group, response: Response) Response {
        group.release();
        return response;
    }
};

const pg_kind = enum { read, write };

// ---------- JSON objects from rows ----------

fn write_profile(out: *Out, username: []const u8, bio: ?[]const u8, image: ?[]const u8, following: bool) void {
    out.bytes("{\"username\":");
    out.string(username);
    out.bytes(",\"bio\":");
    out.string_or_null(bio);
    out.bytes(",\"image\":");
    out.string_or_null(image);
    out.bytes(",\"following\":");
    out.boolean(following);
    out.bytes("}");
}

fn write_timestamp(out: *Out, microseconds: i64) void {
    var text: [time.text_bytes]u8 = undefined;
    time.format(microseconds, &text);
    out.bytes("\"");
    out.bytes(&text);
    out.bytes("\"");
}

/// An article from a row of the list's columns, or the full one's (with
/// the body at 3).
fn write_article(out: *Out, row: pg.Row, full: bool) void {
    const shift: usize = @intFromBool(full);
    out.bytes("{\"slug\":");
    out.string(row.text(0));
    out.bytes(",\"title\":");
    out.string(row.text(1));
    out.bytes(",\"description\":");
    out.string(row.text(2));
    if (full) {
        out.bytes(",\"body\":");
        out.string(row.text(3));
    }
    out.bytes(",\"tagList\":[");
    var tags_array = row.text_array(5 + shift);
    var index: usize = 0;
    while (tags_array.next()) |tag| : (index += 1) {
        if (index > 0) out.bytes(",");
        out.string(tag);
    }
    out.bytes("],\"createdAt\":");
    write_timestamp(out, row.timestamp(3 + shift));
    out.bytes(",\"updatedAt\":");
    write_timestamp(out, row.timestamp(4 + shift));
    out.bytes(",\"favorited\":");
    out.boolean(row.boolean(7 + shift));
    out.bytes(",\"favoritesCount\":");
    out.int(row.int8(6 + shift));
    out.bytes(",\"author\":");
    write_profile(out, row.text(8 + shift), row.text_or_null(9 + shift), row.text_or_null(10 + shift), row.boolean(11 + shift));
    out.bytes("}");
}

fn write_user(out: *Out, email: []const u8, token: []const u8, username: []const u8, bio: ?[]const u8, image: ?[]const u8) void {
    out.bytes("{\"user\":{\"email\":");
    out.string(email);
    out.bytes(",\"token\":");
    out.string(token);
    out.bytes(",\"username\":");
    out.string(username);
    out.bytes(",\"bio\":");
    out.string_or_null(bio);
    out.bytes(",\"image\":");
    out.string_or_null(image);
    out.bytes("}}");
}

fn write_comment(out: *Out, row: pg.Row, following: bool) void {
    out.bytes("{\"id\":");
    out.int(row.int8(0));
    out.bytes(",\"createdAt\":");
    write_timestamp(out, row.timestamp(2));
    out.bytes(",\"updatedAt\":");
    write_timestamp(out, row.timestamp(3));
    out.bytes(",\"body\":");
    out.string(row.text(1));
    out.bytes(",\"author\":");
    write_profile(out, row.text(4), row.text_or_null(5), row.text_or_null(6), following);
    out.bytes("}");
}

// ---------- tags, users ----------

fn tags(context: *Context) Response {
    var group: Group = .begin(context, .read);
    group.run(.tags, &.{});
    const results = group.wait();
    if (results.waiter.failure != null) return group.finish(internal);
    var out = group.out();
    out.bytes("{\"tags\":[");
    var rows = results.rows(0);
    var index: usize = 0;
    while (rows.next()) |row| : (index += 1) {
        if (index > 0) out.bytes(",");
        out.string(row.text(0));
    }
    out.bytes("]}");
    return group.respond(200, &out);
}

fn current_user(context: *Context, _: []const u8) Response {
    var group: Group = .begin(context, .read);
    group.run(.user_by_id, &.{.{ .int8 = context.viewer }});
    const results = group.wait();
    if (results.waiter.failure != null) return group.finish(internal);
    const row = results.rows(0).first() orelse return group.finish(unauthorized);
    var out = group.out();
    write_user(&out, row.text(1), context.token, row.text(0), row.text_or_null(2), row.text_or_null(3));
    return group.respond(200, &out);
}

/// The request's body, read whole into the connection's scratch memory.
fn read_body(context: *Context) ?[]const u8 {
    const request = context.request;
    const buffer = request.scratch;
    var used: usize = 0;
    for (0..buffer.len + 1) |_| {
        if (used == buffer.len) return null;
        const got = request.read_body(buffer[used..]) catch return null;
        if (got == 0) return buffer[0..used];
        used += got;
    } else unreachable;
}

fn parse(context: *Context, wrapper: []const u8, items: []const u8) ?json.Body {
    const text = read_body(context) orelse return null;
    return json.parse_body(text, wrapper, items, context.shard.json_memory);
}

fn register(context: *Context) Response {
    const body = parse(context, "user", "") orelse return unprocessable;
    const username = body.required("username") orelse return failure(422, "username, email and password are required");
    const email = body.required("email") orelse return failure(422, "username, email and password are required");
    const secret = body.required("password") orelse return failure(422, "username, email and password are required");
    if (secret.len > password.password_bytes_max) return failure(422, "password is too long");
    var job: password.Job = .{ .kind = .hash, .password = secret };
    context.shard.passwords.run(context.shard.io, &job);
    var group: Group = .begin(context, .write);
    group.run(.user_insert, &.{ .{ .text = username }, .{ .text = email }, .{ .text = &job.hashed } });
    const results = group.wait();
    if (results.waiter.failure) |failed| {
        if (failed.unique_violation()) return group.finish(failure(422, "username or email is already taken"));
        return group.finish(internal);
    }
    const row = results.rows(0).first() orelse return group.finish(internal);
    var token: [jwt.token_bytes_max]u8 = undefined;
    const issued = jwt.issue(context.shard.key, row.int8(0), now_s(), &token);
    var out = group.out();
    write_user(&out, row.text(2), issued, row.text(1), row.text_or_null(3), row.text_or_null(4));
    return group.respond(201, &out);
}

fn login(context: *Context) Response {
    const body = parse(context, "user", "") orelse return unprocessable;
    const email = body.required("email") orelse return failure(422, "email and password are required");
    const secret = body.required("password") orelse return failure(422, "email and password are required");
    var group: Group = .begin(context, .read);
    group.run(.user_by_email, &.{.{ .text = email }});
    const results = group.wait();
    if (results.waiter.failure != null) return group.finish(internal);
    const row = results.rows(0).first() orelse return group.finish(failure(401, "invalid email or password"));
    var job: password.Job = .{ .kind = .verify, .password = secret, .stored = row.text(5) };
    context.shard.passwords.run(context.shard.io, &job);
    if (!job.matched) return group.finish(failure(401, "invalid email or password"));
    var token: [jwt.token_bytes_max]u8 = undefined;
    const issued = jwt.issue(context.shard.key, row.int8(0), now_s(), &token);
    var out = group.out();
    write_user(&out, row.text(2), issued, row.text(1), row.text_or_null(3), row.text_or_null(4));
    return group.respond(200, &out);
}

fn optional_param(value: json.Body.Optional) pg.Param {
    return switch (value) {
        .value => |text| .{ .text = text },
        .absent => .null,
        .invalid => unreachable,
    };
}

fn update_user(context: *Context, _: []const u8) Response {
    const body = parse(context, "user", "") orelse return unprocessable;
    const email = body.optional("email", true);
    const username = body.optional("username", true);
    const new_password = body.optional("password", true);
    const bio = body.optional("bio", false);
    const image = body.optional("image", false);
    for ([_]json.Body.Optional{ email, username, new_password, bio, image }) |field| {
        if (field == .invalid) return failure(422, "invalid user fields");
    }
    var job: password.Job = .{ .kind = .hash, .password = "" };
    var hash_param: pg.Param = .null;
    if (new_password == .value) {
        if (new_password.value.len > password.password_bytes_max) return failure(422, "password is too long");
        job.password = new_password.value;
        context.shard.passwords.run(context.shard.io, &job);
        hash_param = .{ .text = &job.hashed };
    }
    var group: Group = .begin(context, .write);
    group.run(.user_update, &.{
        .{ .int8 = context.viewer },
        optional_param(email),
        optional_param(username),
        hash_param,
        optional_param(bio),
        optional_param(image),
    });
    const results = group.wait();
    if (results.waiter.failure) |failed| {
        if (failed.unique_violation()) return group.finish(failure(422, "username or email is already taken"));
        return group.finish(internal);
    }
    const row = results.rows(0).first() orelse return group.finish(unauthorized);
    var out = group.out();
    write_user(&out, row.text(1), context.token, row.text(0), row.text_or_null(2), row.text_or_null(3));
    return group.respond(200, &out);
}

// ---------- profiles ----------

fn profile(context: *Context, username: []const u8) Response {
    var group: Group = .begin(context, .read);
    group.run(.profile, &.{ .{ .int8 = context.viewer }, .{ .text = username } });
    const results = group.wait();
    if (results.waiter.failure != null) return group.finish(internal);
    const row = results.rows(0).first() orelse return group.finish(failure(404, "profile not found"));
    var out = group.out();
    out.bytes("{\"profile\":");
    write_profile(&out, row.text(0), row.text_or_null(1), row.text_or_null(2), row.boolean(3));
    out.bytes("}");
    return group.respond(200, &out);
}

fn follow(context: *Context, username: []const u8) Response {
    return follow_toggle(context, username, true);
}

fn unfollow(context: *Context, username: []const u8) Response {
    return follow_toggle(context, username, false);
}

fn follow_toggle(context: *Context, username: []const u8, following: bool) Response {
    var group: Group = .begin(context, .write);
    const params: []const pg.Param = &.{ .{ .int8 = context.viewer }, .{ .text = username } };
    group.run(if (following) .follow_insert else .follow_delete, params);
    group.run(.profile_by_username, &.{.{ .text = username }});
    const results = group.wait();
    if (results.waiter.failure != null) return group.finish(internal);
    const row = results.rows(1).first() orelse return group.finish(failure(404, "profile not found"));
    var out = group.out();
    out.bytes("{\"profile\":");
    write_profile(&out, row.text(0), row.text_or_null(1), row.text_or_null(2), following);
    out.bytes("}");
    return group.respond(200, &out);
}

// ---------- articles ----------

const Page = struct { limit: i64, offset: i64 };

/// `limit` (1-100, default 20) and `offset` (default 0): present (even
/// empty) means it must be valid.
fn page_of(query: []const u8) ?Page {
    var page: Page = .{ .limit = 20, .offset = 0 };
    var buffer: [64]u8 = undefined;
    switch (url.query_value(query, "limit", &buffer)) {
        .absent => {},
        .invalid => return null,
        .value => |text| {
            const limit = jwt.unsigned_integer(text) orelse return null;
            if (limit < 1 or limit > 100) return null;
            page.limit = limit;
        },
    }
    switch (url.query_value(query, "offset", &buffer)) {
        .absent => {},
        .invalid => return null,
        .value => |text| page.offset = jwt.unsigned_integer(text) orelse return null,
    }
    return page;
}

fn query_of(head: *const fourneau.http1_head.Head) []const u8 {
    const whole = head.path_and_query;
    const mark = std.mem.indexOfScalar(u8, whole, '?') orelse return "";
    return whole[mark + 1 ..];
}

fn list_articles(context: *Context, _: []const u8) Response {
    const query = query_of(context.head);
    const page = page_of(query) orelse return failure(422, "limit must be 1-100 and offset >= 0");
    // The first non-empty filter of tag, author, favorited applies.
    const filters = [_]struct { []const u8, S, S }{
        .{ "tag", .list_tag, .count_tag },
        .{ "author", .list_author, .count_author },
        .{ "favorited", .list_favorited, .count_favorited },
    };
    var buffer: [512]u8 = undefined;
    for (filters) |filter| {
        const value = switch (url.query_value(query, filter[0], &buffer)) {
            .value => |text| text,
            .absent, .invalid => continue,
        };
        if (value.len == 0) continue;
        return write_list(context, page, filter[1], filter[2], value);
    }
    return write_list(context, page, .list_all, .count_all, null);
}

fn feed(context: *Context, _: []const u8) Response {
    const page = page_of(query_of(context.head)) orelse return failure(422, "limit must be 1-100 and offset >= 0");
    return write_list(context, page, .list_feed, .count_feed, null);
}

fn write_list(context: *Context, page: Page, list: S, count: S, filter: ?[]const u8) Response {
    var group: Group = .begin(context, .read);
    const viewer: pg.Param = .{ .int8 = context.viewer };
    if (filter) |value| {
        group.run(list, &.{ viewer, .{ .int8 = page.limit }, .{ .int8 = page.offset }, .{ .text = value } });
        group.run(count, &.{.{ .text = value }});
    } else {
        group.run(list, &.{ viewer, .{ .int8 = page.limit }, .{ .int8 = page.offset } });
        if (count == .count_feed) group.run(count, &.{viewer}) else group.run(count, &.{});
    }
    const results = group.wait();
    if (results.waiter.failure != null) return group.finish(internal);
    var out = group.out();
    out.bytes("{\"articles\":[");
    var rows = results.rows(0);
    var index: usize = 0;
    while (rows.next()) |row| : (index += 1) {
        if (index > 0) out.bytes(",");
        write_article(&out, row, false);
    }
    out.bytes("],\"articlesCount\":");
    const counted = results.rows(1).first() orelse return group.finish(internal);
    out.int(counted.int8(0));
    out.bytes("}");
    return group.respond(200, &out);
}

fn respond_article(group: *Group, results: pg.Results, statement: u8, status: u16) Response {
    const row = results.rows(statement).first() orelse return group.finish(failure(404, "article not found"));
    var out = group.out();
    out.bytes("{\"article\":");
    write_article(&out, row, true);
    out.bytes("}");
    return group.respond(status, &out);
}

fn get_article(context: *Context, slug: []const u8) Response {
    var group: Group = .begin(context, .read);
    group.run(.article_by_slug, &.{ .{ .int8 = context.viewer }, .{ .text = slug } });
    const results = group.wait();
    if (results.waiter.failure != null) return group.finish(internal);
    return respond_article(&group, results, 0, 200);
}

fn favorite(context: *Context, slug: []const u8) Response {
    return favorite_toggle(context, slug, .favorite_insert);
}

fn unfavorite(context: *Context, slug: []const u8) Response {
    return favorite_toggle(context, slug, .favorite_delete);
}

fn favorite_toggle(context: *Context, slug: []const u8, statement: S) Response {
    var group: Group = .begin(context, .write);
    group.run(statement, &.{ .{ .int8 = context.viewer }, .{ .text = slug } });
    group.run(.article_by_slug, &.{ .{ .int8 = context.viewer }, .{ .text = slug } });
    const results = group.wait();
    if (results.waiter.failure != null) return group.finish(internal);
    return respond_article(&group, results, 1, 200);
}

fn create_article(context: *Context, _: []const u8) Response {
    const body = parse(context, "article", "tagList") orelse return unprocessable;
    const title = body.required("title") orelse return failure(422, "title, description and body are required");
    const description = body.required("description") orelse return failure(422, "title, description and body are required");
    const text = body.required("body") orelse return failure(422, "title, description and body are required");
    if (!body.items_valid) return failure(422, "tagList must be an array of non-empty strings");
    var group: Group = .begin(context, .write);
    group.run(.article_insert, &.{ .{ .int8 = context.viewer }, .{ .text = title }, .{ .text = description }, .{ .text = text } });
    const tag_list = body.items[0..body.items_count];
    if (tag_list.len > 0) {
        group.run(.tags_insert, &.{.{ .text_array = tag_list }});
        group.run(.article_tags_insert, &.{.{ .text_array = tag_list }});
    }
    group.run(.article_by_current, &.{.{ .int8 = context.viewer }});
    const results = group.wait();
    if (results.waiter.failure != null) return group.finish(internal);
    return respond_article(&group, results, if (tag_list.len > 0) 3 else 1, 201);
}

fn update_article(context: *Context, slug: []const u8) Response {
    const body = parse(context, "article", "") orelse return unprocessable;
    const title = body.optional("title", true);
    const description = body.optional("description", true);
    const text = body.optional("body", true);
    for ([_]json.Body.Optional{ title, description, text }) |field| {
        if (field == .invalid) return failure(422, "title, description and body must be non-empty strings");
    }
    var owner: Group = .begin(context, .read);
    owner.run(.article_owner, &.{.{ .text = slug }});
    const found = owner.wait();
    if (found.waiter.failure != null) return owner.finish(internal);
    const row = found.rows(0).first() orelse return owner.finish(failure(404, "article not found"));
    const id = row.int8(0);
    const author = row.int8(1);
    owner.release();
    if (author != context.viewer) return forbidden;
    var group: Group = .begin(context, .write);
    group.run(.article_update, &.{ .{ .int8 = id }, optional_param(title), optional_param(description), optional_param(text) });
    group.run(.article_by_id, &.{ .{ .int8 = context.viewer }, .{ .int8 = id } });
    const results = group.wait();
    if (results.waiter.failure != null) return group.finish(internal);
    return respond_article(&group, results, 1, 200);
}

fn delete_article(context: *Context, slug: []const u8) Response {
    var group: Group = .begin(context, .write);
    group.run(.article_owner, &.{.{ .text = slug }});
    group.run(.article_delete, &.{ .{ .text = slug }, .{ .int8 = context.viewer } });
    const results = group.wait();
    if (results.waiter.failure != null) return group.finish(internal);
    const row = results.rows(0).first() orelse return group.finish(failure(404, "article not found"));
    if (row.int8(1) != context.viewer) return group.finish(forbidden);
    return group.finish(no_content);
}

// ---------- comments ----------

fn list_comments(context: *Context, slug: []const u8) Response {
    var group: Group = .begin(context, .read);
    group.run(.article_exists, &.{.{ .text = slug }});
    group.run(.comments_by_slug, &.{ .{ .int8 = context.viewer }, .{ .text = slug } });
    const results = group.wait();
    if (results.waiter.failure != null) return group.finish(internal);
    if (results.rows(0).first() == null) return group.finish(failure(404, "article not found"));
    var out = group.out();
    out.bytes("{\"comments\":[");
    var rows = results.rows(1);
    var index: usize = 0;
    while (rows.next()) |row| : (index += 1) {
        if (index > 0) out.bytes(",");
        write_comment(&out, row, row.boolean(7));
    }
    out.bytes("]}");
    return group.respond(200, &out);
}

fn create_comment(context: *Context, slug: []const u8) Response {
    const body = parse(context, "comment", "") orelse return unprocessable;
    const text = body.required("body") orelse return failure(422, "body is required");
    var group: Group = .begin(context, .write);
    group.run(.comment_insert, &.{ .{ .int8 = context.viewer }, .{ .text = slug }, .{ .text = text } });
    const results = group.wait();
    if (results.waiter.failure != null) return group.finish(internal);
    const row = results.rows(0).first() orelse return group.finish(failure(404, "article not found"));
    var out = group.out();
    out.bytes("{\"comment\":");
    write_comment(&out, row, false);
    out.bytes("}");
    return group.respond(201, &out);
}

fn delete_comment(context: *Context, slug: []const u8, id_text: []const u8) Response {
    const id = jwt.unsigned_integer(id_text) orelse return failure(404, "comment not found");
    var group: Group = .begin(context, .write);
    group.run(.comment_owner, &.{ .{ .int8 = id }, .{ .text = slug } });
    group.run(.comment_delete, &.{ .{ .int8 = id }, .{ .text = slug }, .{ .int8 = context.viewer } });
    const results = group.wait();
    if (results.waiter.failure != null) return group.finish(internal);
    const row = results.rows(0).first() orelse return group.finish(failure(404, "comment not found"));
    if (row.int8(0) != context.viewer) return group.finish(forbidden);
    return group.finish(no_content);
}
