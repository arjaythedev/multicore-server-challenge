//! The API: one `Req` per request in flight, the endpoint logic, and the JSON each endpoint writes.
//!
//! A request runs as a short chain of steps. `start` validates it and queues its first statement (or a bcrypt job);
//! rows stream straight from the Postgres receive buffer into the response as JSON (`onRow`); the end of a
//! statement (`onDone`) either answers or queues the next step. Status codes, messages and validation order follow
//! the reference server (examples/go).
//!
//! With `shed` (shed.zig), a sign-up or login is refused under overload right after routing, before any other work.
const std = @import("std");
const db = @import("db.zig");
const sql = @import("sql.zig");
const pg = @import("pg.zig");
const http = @import("http.zig");
const json = @import("json.zig");
const jwt = @import("jwt.zig");
const bcrypt = @import("bcrypt.zig");
const sys = @import("sys.zig");
const loop = @import("loop.zig");
const shed = @import("shed.zig");
const Flags = @import("flags.zig").Flags;
const Buf = @import("buf.zig").Buf;
const Status = @import("buf.zig").Status;
const Stmt = sql.Stmt;
const Row = pg.Row;

const gpa = std.heap.smp_allocator;

pub const Req = struct {
    // Owned by db while queued or executing.
    q: db.Query = .{},

    keep_alive: bool = true,
    /// The connection's TCP payload per segment, read once at accept.
    mss: u16 = 1448,
    gzip: bool = false,
    viewer: i64 = 0,
    /// The caller's token, echoed in user responses.
    token: []const u8 = "",
    out: Buf = .{},
    rows: u32 = 0,
    /// Articles or comments written so far (for the separating commas).
    items: u32 = 0,
    count: i64 = 0,
    id: i64 = 0,
    author: i64 = 0,
    /// Copies of everything the steps need from the request (path values, decoded body strings, the token), so the
    /// receive buffer can move on. Sized once per request, so slices into it stay valid.
    scratch: std.ArrayList(u8) = .empty,
    job: bcrypt.Job = undefined,
    /// A body string is text Postgres rejects. The request runs only the lookup the reference makes before its
    /// write, and answers its 404 or 403, or else the 500 of the reference's failed write.
    bad_text: bool = false,

    fn keep(r: *Req, s: []const u8) []const u8 {
        std.debug.assert(r.scratch.unusedCapacitySlice().len >= s.len);
        const at = r.scratch.items.len;
        r.scratch.appendSliceAssumeCapacity(s);
        return r.scratch.items[at..];
    }
};

// ---------------------------------------------------------------- responses

fn errorBody(comptime msg: []const u8) []const u8 {
    return "{\"errors\":{\"body\":[\"" ++ msg ++ "\"]}}";
}

fn done(r: *Req, status: Status) void {
    loop.respond(r, r.out.finish(status, r.keep_alive, r.gzip, r.mss));
}

fn fail(r: *Req, status: Status, comptime msg: []const u8) void {
    r.out.resetBody();
    r.out.append(errorBody(msg));
    done(r, status);
}

fn noContent(r: *Req) void {
    r.out.resetBody();
    done(r, .no_content);
}

/// Queues `s`. A text parameter Postgres would reject never reaches a queue, where it would fail every request
/// sharing its statement or group: it can match no row, so the request fails here as the reference's statement does.
fn run(r: *Req, s: Stmt, params: []const db.Param) void {
    for (params) |p| switch (p) {
        .text => |t| if (!pg.textOk(t)) return fail(r, .internal, "internal error"),
        else => {},
    };
    r.q.stmt = s;
    r.rows = 0;
    r.q.solo = false;
    @memcpy(r.q.params[0..params.len], params);
    db.enqueue(&r.q);
}

// ---------------------------------------------------------------- JSON shapes, generated at comptime

/// A JSON object field and where its value comes from: a column of the current row, or a literal.
const Field = struct {
    key: []const u8,
    v: Val,
};

const Val = union(enum) {
    text: u8,
    text_or_null: u8,
    int: u8,
    boolean: u8,
    ts: u8,
    tags: u8,
    lit: []const u8,
    obj: []const Field,
};

/// Writes `fields` from `row` as one object. The keys and punctuation between values are comptime strings, so an
/// object is a fixed sequence of constant copies and value encoders.
fn object(comptime fields: []const Field, o: *Buf, row: *const Row) void {
    members(fields, o, row);
    o.byte('}');
}

/// The object without its closing brace.
fn members(comptime fields: []const Field, o: *Buf, row: *const Row) void {
    inline for (fields, 0..) |f, i| {
        o.append(comptime (if (i == 0) "{\"" else ",\"") ++ f.key ++ "\":");
        switch (f.v) {
            .text => |c| json.str(o, row.text(c)),
            .text_or_null => |c| json.strOrNull(o, row.textOrNull(c)),
            .int => |c| json.int(o, row.int(c)),
            .boolean => |c| json.boolean(o, row.boolean(c)),
            .ts => |c| json.timestamp(o, row.int(c)),
            .tags => |c| tagArray(o, row, c),
            .lit => |s| o.append(s),
            .obj => |sub| object(sub, o, row),
        }
    }
}

fn tagArray(o: *Buf, row: *const Row, c: usize) void {
    o.byte('[');
    var it = row.textArray(c);
    var first = true;
    while (it.next()) |t| {
        if (!first) o.byte(',');
        first = false;
        json.str(o, t);
    }
    o.byte(']');
}

fn profileFields(comptime username: u8, comptime following: Val) []const Field {
    return &.{
        .{ .key = "username", .v = .{ .text = username } },
        .{ .key = "bio", .v = .{ .text_or_null = username + 1 } },
        .{ .key = "image", .v = .{ .text_or_null = username + 2 } },
        .{ .key = "following", .v = following },
    };
}

/// Article columns from `id`: id, slug, title, description, [body], created_at, updated_at, tags, favorites
/// count, favorited, username, bio, image, following (sql.zig).
fn articleFields(comptime id: u8, comptime full: bool) []const Field {
    const k: u8 = if (full) 1 else 0;
    const head = [_]Field{
        .{ .key = "slug", .v = .{ .text = id + 1 } },
        .{ .key = "title", .v = .{ .text = id + 2 } },
        .{ .key = "description", .v = .{ .text = id + 3 } },
    };
    const body = if (full) [_]Field{.{ .key = "body", .v = .{ .text = id + 4 } }} else [_]Field{};
    const tail = [_]Field{
        .{ .key = "tagList", .v = .{ .tags = id + 6 + k } },
        .{ .key = "createdAt", .v = .{ .ts = id + 4 + k } },
        .{ .key = "updatedAt", .v = .{ .ts = id + 5 + k } },
        .{ .key = "favorited", .v = .{ .boolean = id + 8 + k } },
        .{ .key = "favoritesCount", .v = .{ .int = id + 7 + k } },
        .{ .key = "author", .v = .{ .obj = profileFields(id + 9 + k, .{ .boolean = id + 12 + k }) } },
    };
    return &(head ++ body ++ tail);
}

const list_article = articleFields(1, false);
const full_article = articleFields(0, true);

fn commentFields(comptime id: u8, comptime following: Val) []const Field {
    return &.{
        .{ .key = "id", .v = .{ .int = id } },
        .{ .key = "createdAt", .v = .{ .ts = id + 2 } },
        .{ .key = "updatedAt", .v = .{ .ts = id + 3 } },
        .{ .key = "body", .v = .{ .text = id + 1 } },
        .{ .key = "author", .v = .{ .obj = profileFields(id + 4, following) } },
    };
}

/// User columns: id, username, email, bio, image. The token goes last, written by the caller after `,"token":"`.
const user_fields = [_]Field{
    .{ .key = "email", .v = .{ .text = 2 } },
    .{ .key = "username", .v = .{ .text = 1 } },
    .{ .key = "bio", .v = .{ .text_or_null = 3 } },
    .{ .key = "image", .v = .{ .text_or_null = 4 } },
};

fn userOpen(o: *Buf, row: *const Row) void {
    o.append("{\"user\":");
    members(&user_fields, o, row);
    o.append(",\"token\":\"");
}

fn userClose(o: *Buf, token: []const u8) void {
    o.append(token);
    o.append("\"}}");
}

// ---------------------------------------------------------------- request entry

const Auth = union(enum) { anonymous, invalid, user: i64 };

fn authenticate(r: *Req, head: *const http.Head, now: i64) Auth {
    const h = head.auth orelse return .anonymous;
    if (h.len == 0) return .anonymous;
    if (!std.mem.startsWith(u8, h, "Token ")) return .invalid;
    const token = h["Token ".len..];
    const id = jwt.verify(token, now) orelse return .invalid;
    r.token = r.keep(token);
    return .{ .user = id };
}

/// Called once the head and the whole body are in memory. Nothing in `head` or `body` is used after it returns.
pub fn start(comptime F: Flags, r: *Req, head: *const http.Head, body: []const u8, now: i64) void {
    r.keep_alive = head.keep_alive;
    r.gzip = F.gzip and head.gzip;
    if (!r.out.active()) r.out = Buf.init() else r.out.resetBody();
    r.scratch.clearRetainingCapacity();
    r.scratch.ensureTotalCapacity(gpa, head.target.len + 3 * body.len + 1024) catch @panic("oom");
    r.viewer = 0;
    r.token = "";
    r.rows = 0;
    r.items = 0;
    r.count = 0;
    r.bad_text = false;

    const m = http.route(head.method, head.target);
    if (F.shed and shed.ctl.refuse(m.route)) return fail(r, .unavailable, "server overloaded");
    switch (m.route) {
        .not_found => return fail(r, .not_found, "not found"),
        .register => return register(r, body),
        .login => return login(r, body),
        .tags => return run(r, .tags, &.{}),
        else => {},
    }
    const a = authenticate(r, head, now);
    switch (m.route) {
        // Optional auth: a present but invalid token is still 401.
        .list, .article, .comments, .profile => switch (a) {
            .invalid => return fail(r, .unauthorized, "unauthorized"),
            .anonymous => {},
            .user => |id| r.viewer = id,
        },
        else => switch (a) {
            .user => |id| r.viewer = id,
            else => return fail(r, .unauthorized, "unauthorized"),
        },
    }
    const v: db.Param = .{ .int = r.viewer };
    switch (m.route) {
        .list => list(r, m.query),
        .feed => {
            const lo = limitOffset(m.query) orelse return fail(r, .unprocessable, "limit must be 1-100 and offset >= 0");
            const per_author = std.math.add(i64, lo[0], lo[1]) catch std.math.maxInt(i64);
            run(r, .list_feed, &.{ v, .{ .int = lo[0] }, .{ .int = lo[1] }, .{ .int = per_author } });
        },
        .article => {
            const slug = pathValue(r, m.a) orelse return fail(r, .not_found, "article not found");
            run(r, .article_by_slug, &.{ v, .{ .text = slug } });
        },
        .comments => {
            const slug = pathValue(r, m.a) orelse return fail(r, .not_found, "article not found");
            run(r, .comments_list_set, &.{ v, .{ .text = slug } });
        },
        .profile, .follow, .unfollow => {
            const name = pathValue(r, m.a) orelse return fail(r, .not_found, "profile not found");
            const s: Stmt = switch (m.route) {
                .profile => .profile,
                .follow => .follow,
                else => .unfollow,
            };
            run(r, s, &.{ v, .{ .text = name } });
        },
        .user_get => run(r, .user_by_id, &.{v}),
        .user_put => updateUser(r, body),
        .favorite, .unfavorite => {
            const slug = pathValue(r, m.a) orelse return fail(r, .not_found, "article not found");
            run(r, if (m.route == .favorite) .favorite else .unfavorite, &.{ v, .{ .text = slug } });
        },
        .article_create => createArticle(r, body),
        .article_update => updateArticle(r, m.a, body),
        .article_delete => {
            const slug = pathValue(r, m.a) orelse return fail(r, .not_found, "article not found");
            run(r, .article_delete, &.{ .{ .text = slug }, v });
        },
        .comment_create => createComment(r, m.a, body),
        .comment_delete => {
            const slug = pathValue(r, m.a) orelse return fail(r, .not_found, "comment not found");
            const raw_id = pathValue(r, m.b) orelse return fail(r, .not_found, "comment not found");
            const id = parseUint(raw_id) orelse return fail(r, .not_found, "comment not found");
            run(r, .comment_delete, &.{ .{ .int = id }, .{ .text = slug }, v });
        },
        .not_found, .register, .login, .tags => unreachable,
    }
}

fn pathValue(r: *Req, raw: []const u8) ?[]const u8 {
    const dst = r.scratch.unusedCapacitySlice();
    const s = http.unescape(raw, dst, false) orelse return null;
    r.scratch.items.len += s.len;
    return s;
}

/// Go's url.Values.Get: the first value, unescaped, or "".
fn queryValue(r: *Req, query: []const u8, key: []const u8) []const u8 {
    const raw = http.queryGet(query, key) orelse return "";
    const dst = r.scratch.unusedCapacitySlice();
    const s = http.unescape(raw, dst, true) orelse return "";
    r.scratch.items.len += s.len;
    return s;
}

/// ASCII digits only, fitting an int64 (the reference's parseUint).
fn parseUint(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    var n: i64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        n = std.math.mul(i64, n, 10) catch return null;
        n = std.math.add(i64, n, c - '0') catch return null;
    }
    return n;
}

/// limit (default 20, 1..100) and offset (default 0); a parameter that is present, even empty, must be valid.
fn limitOffset(query: []const u8) ?[2]i64 {
    var out: [2]i64 = .{ 20, 0 };
    var tmp: [64]u8 = undefined;
    if (http.queryGet(query, "limit")) |raw| {
        if (raw.len > tmp.len) return null;
        const n = parseUint(http.unescape(raw, &tmp, true) orelse return null) orelse return null;
        if (n < 1 or n > 100) return null;
        out[0] = n;
    }
    if (http.queryGet(query, "offset")) |raw| {
        if (raw.len > tmp.len) return null;
        out[1] = parseUint(http.unescape(raw, &tmp, true) orelse return null) orelse return null;
    }
    return out;
}

fn list(r: *Req, query: []const u8) void {
    const lo = limitOffset(query) orelse return fail(r, .unprocessable, "limit must be 1-100 and offset >= 0");
    const base = [3]db.Param{ .{ .int = r.viewer }, .{ .int = lo[0] }, .{ .int = lo[1] } };
    // The first non-empty filter in the order tag, author, favorited applies.
    const filters = [_]struct { []const u8, Stmt }{
        .{ "tag", .list_tag },
        .{ "author", .list_author },
        .{ "favorited", .list_favorited },
    };
    for (filters) |f| {
        const value = queryValue(r, query, f[0]);
        if (value.len > 0) return run(r, f[1], &(base ++ [1]db.Param{.{ .text = value }}));
    }
    run(r, .list_all, &base);
}

// ---------------------------------------------------------------- bodies

/// The object under `key` in a JSON object body, as the reference's readWrapper.
fn wrapper(body: []const u8, key: []const u8) ?json.Value {
    const top = json.parse(body) orelse return null;
    if (top.kind() != .object) return null;
    const inner = top.get(key) orelse return null;
    if (inner.kind() != .object) return null;
    return inner;
}

const Opt = union(enum) { absent, bad, value: []const u8 };

/// Absent or null: `.absent`; a string: its decoded value; anything else (or "" with `non_empty`): `.bad`.
fn optString(r: *Req, obj: json.Value, key: []const u8, non_empty: bool) Opt {
    const v = obj.get(key) orelse return .absent;
    switch (v.kind()) {
        .null => return .absent,
        .string => {},
        else => return .bad,
    }
    const s = decode(r, v);
    if (non_empty and s.len == 0) return .bad;
    return .{ .value = s };
}

fn reqString(r: *Req, obj: json.Value, key: []const u8) ?[]const u8 {
    return switch (optString(r, obj, key, true)) {
        .value => |s| s,
        else => null,
    };
}

fn decode(r: *Req, v: json.Value) []const u8 {
    const dst = r.scratch.unusedCapacitySlice();
    const s = json.decodeString(v.raw, dst) orelse @panic("scratch too small");
    r.scratch.items.len += s.len;
    return s;
}

fn optParam(o: Opt) db.Param {
    return switch (o) {
        .value => |s| .{ .text = s },
        else => .null,
    };
}

fn register(r: *Req, body: []const u8) void {
    const obj = wrapper(body, "user") orelse return fail(r, .unprocessable, "invalid body");
    const username = reqString(r, obj, "username");
    const email = reqString(r, obj, "email");
    const password = reqString(r, obj, "password");
    if (username == null or email == null or password == null)
        return fail(r, .unprocessable, "username, email and password are required");
    if (password.?.len > 72) return fail(r, .unprocessable, "password is too long");
    r.q.params[0] = .{ .text = username.? };
    r.q.params[1] = .{ .text = email.? };
    r.q.stmt = .user_insert;
    hash(r, password.?);
}

fn login(r: *Req, body: []const u8) void {
    const obj = wrapper(body, "user") orelse return fail(r, .unprocessable, "invalid body");
    const email = reqString(r, obj, "email");
    const password = reqString(r, obj, "password");
    if (email == null or password == null) return fail(r, .unprocessable, "email and password are required");
    r.job = .{ .kind = .verify, .password = password.?, .owner = r };
    run(r, .user_by_email, &.{.{ .text = email.? }});
}

fn updateUser(r: *Req, body: []const u8) void {
    const obj = wrapper(body, "user") orelse return fail(r, .unprocessable, "invalid body");
    const email = optString(r, obj, "email", true);
    const username = optString(r, obj, "username", true);
    const password = optString(r, obj, "password", true);
    const bio = optString(r, obj, "bio", false);
    const image = optString(r, obj, "image", false);
    for ([_]Opt{ email, username, password, bio, image }) |o| {
        if (o == .bad) return fail(r, .unprocessable, "invalid user fields");
    }
    r.q.params[0] = .{ .int = r.viewer };
    r.q.params[1] = optParam(email);
    r.q.params[2] = optParam(username);
    r.q.params[3] = .null;
    r.q.params[4] = optParam(bio);
    r.q.params[5] = optParam(image);
    r.q.stmt = .user_update;
    switch (password) {
        .value => |p| {
            if (p.len > 72) return fail(r, .unprocessable, "password is too long");
            hash(r, p);
        },
        else => run(r, .user_update, r.q.params[0..6]),
    }
}

fn hash(r: *Req, password: []const u8) void {
    r.job = .{ .kind = .hash, .password = password, .owner = r };
    bcrypt.submit(&r.job);
}

/// A bcrypt job finished (called on the event loop).
pub fn onBcrypt(j: *bcrypt.Job) void {
    const r: *Req = @fieldParentPtr("job", j);
    switch (j.kind) {
        .hash => {
            if (r.q.stmt == .user_insert) {
                r.q.params[2] = .{ .text = &j.out };
                run(r, .user_insert, r.q.params[0..3]);
            } else {
                r.q.params[3] = .{ .text = &j.out };
                run(r, .user_update, r.q.params[0..6]);
            }
        },
        .verify => {
            if (!j.ok) return fail(r, .unauthorized, "invalid email or password");
            var tok: [256]u8 = undefined;
            userClose(&r.out, jwt.issue(r.id, sys.nowSec(), &tok));
            done(r, .ok);
        },
    }
}

fn createArticle(r: *Req, body: []const u8) void {
    const obj = wrapper(body, "article") orelse return fail(r, .unprocessable, "invalid body");
    const title = reqString(r, obj, "title");
    const description = reqString(r, obj, "description");
    const text = reqString(r, obj, "body");
    if (title == null or description == null or text == null)
        return fail(r, .unprocessable, "title, description and body are required");
    var tags_ok = true;
    const tags = tagParam(r, obj, &tags_ok) orelse return fail(r, .unprocessable, "tagList must be an array of non-empty strings");
    if (!tags_ok) return fail(r, .internal, "internal error");
    run(r, .article_create, &.{ .{ .int = r.viewer }, .{ .text = title.? }, .{ .text = description.? }, .{ .text = text.? }, .{ .raw = tags } });
}

/// tagList as a binary text[] parameter: absent or null is empty; otherwise an array of non-empty strings.
/// `text_ok` turns false when a tag is text Postgres rejects.
fn tagParam(r: *Req, obj: json.Value, text_ok: *bool) ?[]const u8 {
    const at = r.scratch.items.len;
    const hdr = r.scratch.addManyAsSliceAssumeCapacity(20);
    std.mem.writeInt(u32, hdr[0..4], 1, .big); // ndim
    std.mem.writeInt(u32, hdr[4..8], 0, .big); // no nulls
    std.mem.writeInt(u32, hdr[8..12], @intFromEnum(sql.Oid.text), .big);
    std.mem.writeInt(u32, hdr[16..20], 1, .big); // lower bound
    var n: u32 = 0;
    if (obj.get("tagList")) |list_v| switch (list_v.kind()) {
        .null => {},
        .array => {
            var it = list_v.items();
            while (it.next()) |item| {
                if (item.kind() != .string) return null;
                const len_at = r.scratch.items.len;
                r.scratch.items.len += 4;
                const s = decode(r, item);
                if (s.len == 0) return null;
                if (!pg.textOk(s)) text_ok.* = false;
                std.mem.writeInt(u32, r.scratch.items[len_at..][0..4], @intCast(s.len), .big);
                n += 1;
            }
        },
        else => return null,
    };
    const arr = r.scratch.items[at..];
    if (n == 0) {
        // An empty array: ndim 0, then flags and element type only.
        std.mem.writeInt(u32, arr[0..4], 0, .big);
        r.scratch.items.len = at + 12;
        return r.scratch.items[at..];
    }
    std.mem.writeInt(u32, arr[12..16], n, .big);
    return arr;
}

fn updateArticle(r: *Req, raw_slug: []const u8, body: []const u8) void {
    const obj = wrapper(body, "article") orelse return fail(r, .unprocessable, "invalid body");
    const title = optString(r, obj, "title", true);
    const description = optString(r, obj, "description", true);
    const text = optString(r, obj, "body", true);
    if (title == .bad or description == .bad or text == .bad)
        return fail(r, .unprocessable, "title, description and body must be non-empty strings");
    const slug = pathValue(r, raw_slug) orelse return fail(r, .not_found, "article not found");
    for ([_]Opt{ title, description, text }) |o| switch (o) {
        .value => |s| if (!pg.textOk(s)) {
            r.bad_text = true;
        },
        else => {},
    };
    // With bad text, the lookup alone: author 0 is nobody, so the statement changes nothing.
    if (r.bad_text) return run(r, .article_update, &.{ .{ .text = slug }, .null, .null, .null, .{ .int = 0 } });
    run(r, .article_update, &.{ .{ .text = slug }, optParam(title), optParam(description), optParam(text), .{ .int = r.viewer } });
}

fn createComment(r: *Req, raw_slug: []const u8, body: []const u8) void {
    const obj = wrapper(body, "comment") orelse return fail(r, .unprocessable, "invalid body");
    const text = reqString(r, obj, "body") orelse return fail(r, .unprocessable, "body is required");
    const slug = pathValue(r, raw_slug) orelse return fail(r, .not_found, "article not found");
    if (!pg.textOk(text)) {
        r.bad_text = true;
        return run(r, .article_by_slug, &.{ .{ .int = r.viewer }, .{ .text = slug } });
    }
    run(r, .comment_create, &.{ .{ .text = slug }, .{ .int = r.viewer }, .{ .text = text } });
}

// ---------------------------------------------------------------- results (called by db)

pub fn request(q: *db.Query) *Req {
    return @fieldParentPtr("q", q);
}

pub fn onRow(r: *Req, row: *const Row) void {
    const o = &r.out;
    defer r.rows += 1;
    switch (r.q.stmt) {
        .list_all, .list_tag, .list_author, .list_favorited, .list_feed => {
            if (r.rows == 0) {
                r.count = row.int(0);
                o.append("{\"articles\":[");
            }
            // An empty page is one row of NULL article columns next to the count.
            if (row.isNull(1)) return;
            if (r.items != 0) o.byte(',');
            r.items += 1;
            object(list_article, o, row);
        },
        .article_by_slug, .article_by_id, .article_create => {
            o.append("{\"article\":");
            object(full_article, o, row);
            o.byte('}');
        },
        .comments_list_set => {
            if (r.rows == 0) o.append("{\"comments\":[");
            // An article without comments is one row of NULL comment columns.
            if (row.isNull(0)) return;
            if (r.items != 0) o.byte(',');
            r.items += 1;
            object(commentFields(0, .{ .boolean = 7 }), o, row);
        },
        .profile => {
            o.append("{\"profile\":");
            object(profileFields(0, .{ .boolean = 3 }), o, row);
            o.byte('}');
        },
        .follow, .unfollow => {
            o.append("{\"profile\":");
            if (r.q.stmt == .follow)
                object(profileFields(0, .{ .lit = "true" }), o, row)
            else
                object(profileFields(0, .{ .lit = "false" }), o, row);
            o.byte('}');
        },
        .user_by_id, .user_update => {
            userOpen(o, row);
            userClose(o, r.token);
        },
        .user_insert => {
            userOpen(o, row);
            var tok: [256]u8 = undefined;
            userClose(o, jwt.issue(row.int(0), sys.nowSec(), &tok));
        },
        .user_by_email => {
            r.id = row.int(0);
            userOpen(o, row);
            r.job.stored = r.keep(row.text(5));
        },
        .tags => {
            o.append("{\"tags\":");
            tagArray(o, row, 0);
            o.byte('}');
        },
        .comment_create => {
            o.append("{\"comment\":");
            object(commentFields(0, .{ .lit = "false" }), o, row);
            o.byte('}');
        },
        .favorite, .unfavorite => r.id = row.int(0),
        .article_update => {
            r.id = row.int(0);
            r.author = row.int(1);
        },
        .article_delete, .comment_delete => r.author = row.int(0),
    }
}

pub fn onDone(r: *Req) void {
    switch (r.q.stmt) {
        .list_all, .list_tag, .list_author, .list_favorited, .list_feed => {
            r.out.append("],\"articlesCount\":");
            json.int(&r.out, r.count);
            r.out.byte('}');
            done(r, .ok);
        },
        .article_by_slug, .article_by_id => {
            if (r.rows == 0) return fail(r, .not_found, "article not found");
            if (r.bad_text) return fail(r, .internal, "internal error");
            done(r, .ok);
        },
        .article_create => if (r.rows == 0) fail(r, .internal, "internal error") else done(r, .created),
        .comments_list_set => {
            if (r.rows == 0) return fail(r, .not_found, "article not found");
            r.out.append("]}");
            done(r, .ok);
        },
        .profile, .follow, .unfollow => if (r.rows == 0) fail(r, .not_found, "profile not found") else done(r, .ok),
        .user_by_id, .user_update => if (r.rows == 0) fail(r, .unauthorized, "unauthorized") else done(r, .ok),
        .user_insert => done(r, .created),
        .user_by_email => {
            if (r.rows == 0) return fail(r, .unauthorized, "invalid email or password");
            bcrypt.submit(&r.job);
        },
        .tags => done(r, .ok),
        .comment_create => if (r.rows == 0) fail(r, .not_found, "article not found") else done(r, .created),
        .favorite, .unfavorite => {
            if (r.rows == 0) return fail(r, .not_found, "article not found");
            run(r, .article_by_id, &.{ .{ .int = r.viewer }, .{ .int = r.id } });
        },
        .article_update => {
            if (r.rows == 0) return fail(r, .not_found, "article not found");
            if (r.author != r.viewer) return fail(r, .forbidden, "not the author");
            if (r.bad_text) return fail(r, .internal, "internal error");
            run(r, .article_by_id, &.{ .{ .int = r.viewer }, .{ .int = r.id } });
        },
        .article_delete => {
            if (r.rows == 0) return fail(r, .not_found, "article not found");
            if (r.author != r.viewer) return fail(r, .forbidden, "not the author");
            noContent(r);
        },
        .comment_delete => {
            if (r.rows == 0) return fail(r, .not_found, "comment not found");
            if (r.author != r.viewer) return fail(r, .forbidden, "not the author");
            noContent(r);
        },
    }
}

/// The statement failed for this request alone.
pub fn onFail(r: *Req, e: *const pg.ErrorInfo) void {
    if ((r.q.stmt == .user_insert or r.q.stmt == .user_update) and e.is("23505"))
        return fail(r, .unprocessable, "username or email is already taken");
    sys.log("{s} failed: {s} {s}", .{ @tagName(r.q.stmt), &e.code, e.message() });
    fail(r, .internal, "internal error");
}

/// The statement will run again; forget what it produced.
pub fn onReset(r: *Req) void {
    r.out.resetBody();
    r.rows = 0;
    r.items = 0;
    r.count = 0;
}
