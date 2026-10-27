//! The 19 Conduit endpoints: routing, authentication, validation, SQL batch construction and JSON rendering.
//! A request is parsed on arrival; the Postgres batch (usually a single statement) is queued; when the reply
//! arrives the response is rendered straight from the binary rows.
const std = @import("std");
const server = @import("server.zig");
const http = @import("http.zig");
const pg = @import("pg.zig");
const sql = @import("sql.zig");
const jw = @import("jw.zig");
const jp = @import("jp.zig");
const jwt = @import("jwt.zig");
const bcrypt = @import("bcrypt.zig");
const bcpool = @import("bcpool.zig");
const sys = @import("sys.zig");
const Buf = @import("buf.zig").Buf;
const gpa = @import("buf.zig").gpa;

const Worker = server.Worker;
const Req = server.Req;

pub const Kind = enum(u8) {
    tags,
    login_sql,
    login_verify,
    register_hash,
    register_sql,
    user_get,
    user_update_hash,
    user_update_sql,
    profile,
    follow,
    unfollow,
    list,
    feed,
    article_get,
    comments_list,
    comment_create,
    comment_delete,
    article_create,
    article_update,
    article_delete,
    favorite,
    unfavorite,
};

const Ctx = struct {
    w: *Worker,
    fd: i32,
    gen: u32,
    head: http.Head,
    body: []const u8,
    viewer: i64 = 0,
    token: []const u8 = "",
};

// ---------------------------------------------------------------------------------------------
// Responses
// ---------------------------------------------------------------------------------------------

fn errorBody(w: *Worker, msg: []const u8) void {
    const o = &w.out;
    o.putSlice("{\"errors\":{\"body\":[");
    jw.str(o, msg);
    o.putSlice("]}}");
}

/// Send the body currently in `w.out` (after the reserved head room).
fn finish(w: *Worker, fd: i32, gen: u32, code: u16, keep_alive: bool) void {
    w.finishResponse(fd, gen, code, keep_alive);
}

fn fail(c: *const Ctx, code: u16, msg: []const u8) void {
    c.w.beginBody();
    errorBody(c.w, msg);
    finish(c.w, c.fd, c.gen, code, c.head.keep_alive);
}

fn failReq(w: *Worker, r: *Req, code: u16, msg: []const u8) void {
    w.beginBody();
    errorBody(w, msg);
    doneReq(w, r, code);
}

pub fn doneReq(w: *Worker, r: *Req, code: u16) void {
    if (r.remote_owner != std.math.maxInt(u16)) return w.proxyBody(r, code);
    finish(w, r.fd, r.gen, code, r.keep_alive);
    w.freeReq(r);
}

// ---------------------------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------------------------

const AuthError = error{Unauthorized};

fn authenticate(c: *Ctx, required: bool) AuthError!void {
    const h = c.head.auth orelse {
        if (required) return error.Unauthorized;
        return;
    };
    if (!std.mem.startsWith(u8, h, "Token ")) return error.Unauthorized;
    const tok = std.mem.trim(u8, h[6..], " ");
    if (tok.len == 0 or tok.len > Req.max_token) return error.Unauthorized;
    const uid = c.w.shared.jwt.verify(tok, c.w.now, &c.w.scratch) orelse return error.Unauthorized;
    c.viewer = @intCast(uid);
    c.token = tok;
}

// ---------------------------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------------------------

pub fn handle(w: *Worker, fd: i32, gen: u32, head: http.Head, body: []const u8) void {
    w.negotiateEncoding(fd, head.gzip, head.identity);
    var c = Ctx{ .w = w, .fd = fd, .gen = gen, .head = head, .body = body };
    route(&c) catch |e| switch (e) {
        error.Unauthorized => fail(&c, 401, "unauthorized"),
        error.OutOfMemory => fail(&c, 500, "out of memory"),
    };
}

const RouteError = error{ Unauthorized, OutOfMemory };

fn route(c: *Ctx) RouteError!void {
    const path = c.head.path;
    if (!std.mem.startsWith(u8, path, "/api/")) return fail(c, 404, "not found");
    const rest = path[5..];
    const m = c.head.method;
    if (rest.len < 4) return fail(c, 404, "not found");

    const pfx = std.mem.readInt(u32, rest[0..4], .little);
    switch (pfx) {
        std.mem.readInt(u32, "tags", .little) => {
            if (rest.len != 4) return fail(c, 404, "not found");
            if (m != .get) return fail(c, 405, "method not allowed");
            return tags(c);
        },
        std.mem.readInt(u32, "user", .little) => {
            if (rest.len == 4) {
                return switch (m) {
                    .get => userGet(c),
                    .put => userUpdate(c),
                    else => fail(c, 405, "method not allowed"),
                };
            }
            if (rest[4] == 's') {
                if (rest.len == 5) {
                    if (m != .post) return fail(c, 405, "method not allowed");
                    return register(c);
                }
                if (std.mem.eql(u8, rest[5..], "/login")) {
                    if (m != .post) return fail(c, 405, "method not allowed");
                    return login(c);
                }
            }
            return fail(c, 404, "not found");
        },
        std.mem.readInt(u32, "prof", .little) => {
            if (!std.mem.startsWith(u8, rest[4..], "iles/")) return fail(c, 404, "not found");
            const seg = rest[9..];
            if (std.mem.endsWith(u8, seg, "/follow")) {
                const name = seg[0 .. seg.len - 7];
                if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) return fail(c, 404, "not found");
                return switch (m) {
                    .post => follow(c, name, true),
                    .delete => follow(c, name, false),
                    else => fail(c, 405, "method not allowed"),
                };
            }
            if (seg.len == 0 or std.mem.indexOfScalar(u8, seg, '/') != null) return fail(c, 404, "not found");
            if (m != .get) return fail(c, 405, "method not allowed");
            return profile(c, seg);
        },
        std.mem.readInt(u32, "arti", .little) => {
            if (!std.mem.startsWith(u8, rest[4..], "cles")) return fail(c, 404, "not found");
            const after = rest[8..];
            if (after.len == 0) {
                return switch (m) {
                    .get => articleList(c),
                    .post => articleCreate(c),
                    else => fail(c, 405, "method not allowed"),
                };
            }
            if (after[0] != '/') return fail(c, 404, "not found");
            const seg = after[1..];
            if (std.mem.eql(u8, seg, "feed")) {
                if (m != .get) return fail(c, 405, "method not allowed");
                return feed(c);
            }
            const slash = std.mem.indexOfScalar(u8, seg, '/');
            const slug = if (slash) |s| seg[0..s] else seg;
            if (slug.len == 0) return fail(c, 404, "not found");
            if (slash == null) {
                return switch (m) {
                    .get => articleGet(c, slug),
                    .put => articleUpdate(c, slug),
                    .delete => articleDelete(c, slug),
                    else => fail(c, 405, "method not allowed"),
                };
            }
            const tail = seg[slash.? + 1 ..];
            if (std.mem.eql(u8, tail, "favorite")) {
                return switch (m) {
                    .post => favorite(c, slug, true),
                    .delete => favorite(c, slug, false),
                    else => fail(c, 405, "method not allowed"),
                };
            }
            if (std.mem.eql(u8, tail, "comments")) {
                return switch (m) {
                    .get => commentsList(c, slug),
                    .post => commentCreate(c, slug),
                    else => fail(c, 405, "method not allowed"),
                };
            }
            if (std.mem.startsWith(u8, tail, "comments/")) {
                const id = tail[9..];
                if (std.mem.indexOfScalar(u8, id, '/') != null) return fail(c, 404, "not found");
                if (m != .delete) return fail(c, 405, "method not allowed");
                return commentDelete(c, slug, id);
            }
            return fail(c, 404, "not found");
        },
        else => return fail(c, 404, "not found"),
    }
}

fn decodeSeg(c: *Ctx, raw: []const u8) RouteError![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '%') == null) return if (validText(raw)) raw else "";
    const out = try c.w.scratch.alloc(raw.len);
    const dec = http.pctDecode(out, raw, false) orelse return "";
    return if (validText(dec)) dec else "";
}

// ---------------------------------------------------------------------------------------------
// Request helpers
// ---------------------------------------------------------------------------------------------

fn newReq(c: *Ctx, kind: Kind) *Req {
    const r = c.w.newReq(c.fd, c.gen, kind, c.head.keep_alive, c.viewer);
    r.setToken(c.token);
    return r;
}

fn beginBatch(w: *Worker) pg.Enc {
    w.enc.reset();
    return pg.Enc.init(&w.enc);
}

fn parseIntParam(raw: ?[]const u8, default: i64, c: *Ctx) RouteError!?i64 {
    const v = raw orelse return default;
    const dec = if (std.mem.indexOfScalar(u8, v, '%') != null or std.mem.indexOfScalar(u8, v, '+') != null) blk: {
        const out = try c.w.scratch.alloc(v.len);
        break :blk http.pctDecode(out, v, true) orelse return null;
    } else v;
    if (dec.len == 0) return null;
    var n: u64 = 0;
    for (dec) |ch| {
        if (ch < '0' or ch > '9') return null;
        const d: u64 = ch - '0';
        if (n > (@as(u64, std.math.maxInt(i64)) - d) / 10) return null; // beyond int64: invalid
        n = n * 10 + d;
    }
    return @intCast(n);
}

/// Rows past this offset cannot exist; clamping keeps every integer parameter in int4 range.
const max_offset: i64 = 1_000_000_000;

fn queryText(c: *Ctx, key: []const u8) RouteError!?[]const u8 {
    const raw = http.queryGet(c.head.query, key) orelse return null;
    if (raw.len == 0) return null;
    if (std.mem.indexOfScalar(u8, raw, '%') == null and std.mem.indexOfScalar(u8, raw, '+') == null) return raw;
    const out = try c.w.scratch.alloc(raw.len);
    return http.pctDecode(out, raw, true) orelse return null;
}

fn pageParams(c: *Ctx) RouteError!?struct { limit: i32, offset: i32 } {
    const lim = (try parseIntParam(http.queryGet(c.head.query, "limit"), 20, c)) orelse return null;
    const off = (try parseIntParam(http.queryGet(c.head.query, "offset"), 0, c)) orelse return null;
    if (lim < 1 or lim > 100) return null;
    return .{ .limit = @intCast(lim), .offset = @intCast(@min(off, max_offset)) };
}

/// Valid UTF-8 without NUL: anything else cannot match a stored name and would only provoke a database error.
fn validText(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, 0) == null and std.unicode.utf8ValidateSlice(s);
}

fn unprocessable(c: *Ctx, msg: []const u8) void {
    fail(c, 422, msg);
}

// ---------------------------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------------------------

fn optStr(o: *Buf, v: ?[]const u8) void {
    if (v) |s| jw.str(o, s) else o.putSlice("null");
}

fn boolOf(v: ?[]const u8) bool {
    return v != null and v.?.len > 0 and v.?[0] != 0;
}

fn writeUser(w: *Worker, id_unused: void, row: [5]?[]const u8, token: []const u8) void {
    _ = id_unused;
    const o = &w.out;
    o.putSlice("{\"user\":{\"email\":");
    jw.str(o, row[2].?);
    o.putSlice(",\"token\":");
    jw.str(o, token);
    o.putSlice(",\"username\":");
    jw.str(o, row[1].?);
    o.putSlice(",\"bio\":");
    optStr(o, row[3]);
    o.putSlice(",\"image\":");
    optStr(o, row[4]);
    o.putSlice("}}");
}

pub fn writeProfile(w: *Worker, username: []const u8, bio: ?[]const u8, image: ?[]const u8, following: bool) void {
    const o = &w.out;
    o.putSlice("{\"username\":");
    jw.str(o, username);
    o.putSlice(",\"bio\":");
    optStr(o, bio);
    o.putSlice(",\"image\":");
    optStr(o, image);
    o.putSlice(if (following) ",\"following\":true}" else ",\"following\":false}");
}

/// Article object from the 13/14-column layout starting at `c[0]` (id, slug, title, description, created_at,
/// updated_at, tag_list, favorites_count, favorited, username, bio, image, following [, body]).
pub fn writeArticle(w: *Worker, c: []const ?[]const u8, full: bool) void {
    const o = &w.out;
    o.ensure(512 + (c[3].?.len + (if (full) c[13].?.len else 0)) * 2);
    o.putSlice("{\"slug\":");
    jw.str(o, c[1].?);
    o.putSlice(",\"title\":");
    jw.str(o, c[2].?);
    o.putSlice(",\"description\":");
    jw.str(o, c[3].?);
    if (full) {
        o.putSlice(",\"body\":");
        jw.str(o, c[13].?);
    }
    o.putSlice(",\"tagList\":[");
    var ta = pg.TextArray.init(c[6].?);
    var first = true;
    while (ta.next()) |t| {
        if (!first) o.put(',');
        first = false;
        jw.str(o, t);
    }
    o.putSlice("],\"createdAt\":");
    jw.putTimestamp(o, pg.i64Of(c[4].?));
    o.putSlice(",\"updatedAt\":");
    jw.putTimestamp(o, pg.i64Of(c[5].?));
    o.putSlice(if (boolOf(c[8])) ",\"favorited\":true,\"favoritesCount\":" else ",\"favorited\":false,\"favoritesCount\":");
    jw.putInt(o, pg.i64Of(c[7].?));
    o.putSlice(",\"author\":");
    writeProfile(w, c[9].?, c[10], c[11], boolOf(c[12]));
    o.put('}');
}

fn writeComment(w: *Worker, id: i64, body: []const u8, created: i64, updated: i64, username: []const u8, bio: ?[]const u8, image: ?[]const u8, following: bool) void {
    const o = &w.out;
    o.ensure(256 + body.len * 2);
    o.putSlice("{\"id\":");
    jw.putInt(o, id);
    o.putSlice(",\"createdAt\":");
    jw.putTimestamp(o, created);
    o.putSlice(",\"updatedAt\":");
    jw.putTimestamp(o, updated);
    o.putSlice(",\"body\":");
    jw.str(o, body);
    o.putSlice(",\"author\":");
    writeProfile(w, username, bio, image, following);
    o.put('}');
}

// ---------------------------------------------------------------------------------------------
// Postgres reply cursor
// ---------------------------------------------------------------------------------------------

const Reply = struct {
    rd: pg.Reader,
    sqlstate: ?[]const u8 = null,
    errored: bool = false,
    stmt: u32 = 0, // statements completed so far (CommandComplete count)

    fn init(batch: []const u8) Reply {
        return .{ .rd = .{ .data = batch } };
    }

    /// Next DataRow body, or null at the end of the current statement / on error / at ReadyForQuery.
    fn row(self: *Reply) ?[]const u8 {
        while (self.rd.next()) |m| {
            switch (m.kind) {
                'D' => return m.body,
                'C' => {
                    self.stmt += 1;
                    return null;
                },
                'E' => {
                    self.errored = true;
                    self.sqlstate = pg.sqlstate(m.body);
                    return null;
                },
                'Z' => return null,
                else => {},
            }
        }
        return null;
    }

    /// Skip to the end of the current statement (consumes its CommandComplete).
    fn drain(self: *Reply) void {
        while (self.row() != null) {}
    }
};

// ---------------------------------------------------------------------------------------------
// Endpoints
// ---------------------------------------------------------------------------------------------

fn tags(c: *Ctx) RouteError!void {
    const r = newReq(c, .tags);
    c.w.readSubmit(.tags, r, .{});
}

fn onTags(w: *Worker, r: *Req, batch: []const u8) void {
    var rep = Reply.init(batch);
    if (!beginOk(w, r, &rep)) return;
    const o = &w.out;
    o.putSlice("{\"tags\":[");
    var first = true;
    while (rep.row()) |body| {
        if (!first) o.put(',');
        first = false;
        const col = pg.cols(body, 1);
        jw.str(o, col[0].?);
    }
    o.putSlice("]}");
    doneReq(w, r, 200);
}

/// Common prologue for reply handlers: starts the body and bails out with 500 on a database error.
fn beginOk(w: *Worker, r: *Req, rep: *Reply) bool {
    w.beginBody();
    // Peek for an error without consuming rows.
    var probe = rep.*;
    while (probe.rd.next()) |m| {
        if (m.kind == 'E') {
            rep.errored = true;
            rep.sqlstate = pg.sqlstate(m.body);
            return handleDbError(w, r, rep);
        }
        if (m.kind == 'Z') break;
    }
    return true;
}

fn handleDbError(w: *Worker, r: *Req, rep: *Reply) bool {
    if (rep.sqlstate) |s| {
        if (std.mem.eql(u8, s, "23505") and (r.kind == .register_sql or r.kind == .user_update_sql)) {
            w.out.len = http.head_room;
            errorBody(w, "username or email has already been taken");
            doneReq(w, r, 422);
            return false;
        }
    }
    std.log.err("database error {s} in {s}", .{ rep.sqlstate orelse "?", @tagName(r.kind) });
    w.out.len = http.head_room;
    errorBody(w, "internal error");
    doneReq(w, r, 500);
    return false;
}

pub fn notFound(w: *Worker, r: *Req, msg: []const u8) void {
    w.out.len = http.head_room;
    errorBody(w, msg);
    doneReq(w, r, 404);
}

// ---- users -------------------------------------------------------------------------------------

const user_fields = [_][]const u8{ "username", "email", "password", "bio", "image" };

fn issueToken(w: *Worker, uid: i64, buf: *[jwt.max_token_len]u8) []const u8 {
    const n = w.shared.jwt.issue(buf, @intCast(uid), w.now);
    return buf[0..n];
}

fn register(c: *Ctx) RouteError!void {
    const w = c.w;
    var f: [5]jp.Field = undefined;
    jp.parseWrapped(c.body, &w.scratch, "user", &user_fields, &.{}, &f) catch return unprocessable(c, "invalid request body");
    _ = jp.needString(f[0]) orelse return unprocessable(c, "username can't be blank");
    _ = jp.needString(f[1]) orelse return unprocessable(c, "email can't be blank");
    const pw = jp.needString(f[2]) orelse return unprocessable(c, "password can't be blank");
    if (pw.len > 72) return unprocessable(c, "password must be at most 72 bytes");
    const r = newReq(c, .register_hash);
    r.blob = gpa.dupe(u8, c.body) catch return fail(c, 500, "out of memory");
    w.bcryptSubmit(r, .hash, pw, null);
}

fn onRegisterHashed(w: *Worker, r: *Req, d: bcpool.Done) void {
    w.scratch.reset();
    var f: [5]jp.Field = undefined;
    jp.parseWrapped(r.blob, &w.scratch, "user", &user_fields, &.{}, &f) catch return failReq(w, r, 500, "internal error");
    var enc_hash: [bcrypt.hash_len]u8 = undefined;
    bcrypt.encode(&enc_hash, d.cost, &d.salt, &d.hash);
    var e = beginBatch(w);
    e.bind(sql.id(.user_insert));
    e.pText(f[0].s);
    e.pText(f[1].s);
    e.pText(&enc_hash);
    e.exec();
    e.sync();
    r.kind = .register_sql;
    w.pgSubmit(.write, r, w.enc.slice());
}

fn onUserRow(w: *Worker, r: *Req, batch: []const u8, code: u16) void {
    var rep = Reply.init(batch);
    if (!beginOk(w, r, &rep)) return;
    const body = rep.row() orelse return failReq(w, r, 401, "unauthorized");
    const col = pg.cols(body, 5);
    var tokbuf: [jwt.max_token_len]u8 = undefined;
    const tok = if (r.kind == .register_sql) issueToken(w, pg.i64Of(col[0].?), &tokbuf) else r.token();
    writeUser(w, {}, col, tok);
    doneReq(w, r, code);
}

fn login(c: *Ctx) RouteError!void {
    const w = c.w;
    var f: [2]jp.Field = undefined;
    jp.parseWrapped(c.body, &w.scratch, "user", &.{ "email", "password" }, &.{}, &f) catch return unprocessable(c, "invalid request body");
    const email = jp.needString(f[0]) orelse return unprocessable(c, "email can't be blank");
    const pw = jp.needString(f[1]) orelse return unprocessable(c, "password can't be blank");
    // bcrypt only uses 72 bytes, and no registered password is longer: a longer one cannot match.
    if (pw.len > 72) return fail(c, 401, "invalid email or password");
    var e = beginBatch(w);
    e.bind(sql.id(.user_login));
    e.pText(email);
    e.exec();
    e.sync();
    const r = newReq(c, .login_sql);
    r.blob = gpa.dupe(u8, pw) catch return fail(c, 500, "out of memory");
    r.aux = pw.len;
    w.pgSubmit(.read, r, w.enc.slice());
}

fn onLoginRow(w: *Worker, r: *Req, batch: []const u8) void {
    var rep = Reply.init(batch);
    if (!beginOk(w, r, &rep)) return;
    const body = rep.row() orelse return failReq(w, r, 401, "invalid email or password");
    const col = pg.cols(body, 6);
    const parsed = bcrypt.parse(col[5].?) orelse return failReq(w, r, 401, "invalid email or password");
    // blob = password ++ DataRow body (kept for rendering once the hash is verified)
    const plen: usize = @intCast(r.aux);
    const nb = gpa.alloc(u8, plen + body.len) catch return failReq(w, r, 500, "out of memory");
    @memcpy(nb[0..plen], r.blob[0..plen]);
    @memcpy(nb[plen..], body);
    gpa.free(r.blob);
    r.blob = nb;
    r.kind = .login_verify;
    w.bcryptSubmit(r, .verify, nb[0..plen], parsed);
}

fn onLoginVerified(w: *Worker, r: *Req, d: bcpool.Done) void {
    if (!d.ok) return failReq(w, r, 401, "invalid email or password");
    const plen: usize = @intCast(r.aux);
    const col = pg.cols(r.blob[plen..], 6);
    w.beginBody();
    var tokbuf: [jwt.max_token_len]u8 = undefined;
    const tok = issueToken(w, pg.i64Of(col[0].?), &tokbuf);
    writeUser(w, {}, .{ col[0], col[1], col[2], col[3], col[4] }, tok);
    doneReq(w, r, 200);
}

fn userGet(c: *Ctx) RouteError!void {
    try authenticate(c, true);
    const w = c.w;
    var e = beginBatch(w);
    e.bind(sql.id(.user_by_id));
    e.pInt8(c.viewer);
    e.exec();
    e.sync();
    const r = newReq(c, .user_get);
    w.pgSubmit(.read, r, w.enc.slice());
}

fn userUpdate(c: *Ctx) RouteError!void {
    try authenticate(c, true);
    const w = c.w;
    var f: [5]jp.Field = undefined;
    jp.parseWrapped(c.body, &w.scratch, "user", &user_fields, &.{}, &f) catch return unprocessable(c, "invalid request body");
    if (!validUpdate(f)) return unprocessable(c, "invalid user fields");
    const r = newReq(c, .user_update_sql);
    if (f[2].kind == .string) {
        if (f[2].s.len > 72) {
            w.freeReq(r);
            return unprocessable(c, "password must be at most 72 bytes");
        }
        r.kind = .user_update_hash;
        r.blob = gpa.dupe(u8, c.body) catch {
            w.freeReq(r);
            return fail(c, 500, "out of memory");
        };
        w.bcryptSubmit(r, .hash, f[2].s, null);
        return;
    }
    submitUserUpdate(w, r, f, null);
}

/// username/email/password: absent or null, or a non-empty string. bio/image: absent, null or any string.
fn validUpdate(f: [5]jp.Field) bool {
    for (f[0..3]) |x| switch (x.kind) {
        .absent, .null => {},
        .string => if (jp.needString(x) == null) return false,
        else => return false,
    };
    for (f[3..5]) |x| switch (x.kind) {
        .absent, .null => {},
        .string => if (std.mem.indexOfScalar(u8, x.s, 0) != null) return false,
        else => return false,
    };
    return true;
}

fn optField(f: jp.Field) ?[]const u8 {
    return if (f.kind == .string) f.s else null;
}

fn submitUserUpdate(w: *Worker, r: *Req, f: [5]jp.Field, hash: ?[]const u8) void {
    var e = beginBatch(w);
    e.bind(sql.id(.user_update));
    e.pInt8(r.viewer);
    e.pTextOpt(optField(f[1])); // email
    e.pTextOpt(optField(f[0])); // username
    e.pTextOpt(hash);
    e.pTextOpt(optField(f[3])); // bio
    e.pTextOpt(optField(f[4])); // image
    e.exec();
    e.sync();
    r.kind = .user_update_sql;
    w.pgSubmit(.write, r, w.enc.slice());
}

fn onUpdateHashed(w: *Worker, r: *Req, d: bcpool.Done) void {
    w.scratch.reset();
    var f: [5]jp.Field = undefined;
    jp.parseWrapped(r.blob, &w.scratch, "user", &user_fields, &.{}, &f) catch return failReq(w, r, 500, "internal error");
    var enc_hash: [bcrypt.hash_len]u8 = undefined;
    bcrypt.encode(&enc_hash, d.cost, &d.salt, &d.hash);
    submitUserUpdate(w, r, f, &enc_hash);
}

// ---- profiles ----------------------------------------------------------------------------------

fn profile(c: *Ctx, raw_name: []const u8) RouteError!void {
    try authenticate(c, false);
    const name = try decodeSeg(c, raw_name);
    if (!validText(name)) return fail(c, 404, "profile not found");
    const r = newReq(c, .profile);
    c.w.readSubmit(.profile, r, .{ .viewer = c.viewer, .text = name });
}

fn onProfile(w: *Worker, r: *Req, batch: []const u8) void {
    var rep = Reply.init(batch);
    if (!beginOk(w, r, &rep)) return;
    const body = rep.row() orelse return notFound(w, r, "profile not found");
    const col = pg.cols(body, 5);
    const o = &w.out;
    o.putSlice("{\"profile\":");
    writeProfile(w, col[1].?, col[2], col[3], boolOf(col[4]));
    o.put('}');
    doneReq(w, r, 200);
}

fn follow(c: *Ctx, raw_name: []const u8, on: bool) RouteError!void {
    try authenticate(c, true);
    const name = try decodeSeg(c, raw_name);
    const w = c.w;
    var e = beginBatch(w);
    e.bind(sql.id(if (on) .follow else .unfollow));
    e.pInt8(c.viewer);
    e.pText(name);
    e.exec();
    e.sync();
    const r = newReq(c, if (on) .follow else .unfollow);
    w.writeSubmit(r, w.enc.slice(), e.n_exec);
}

fn onFollow(w: *Worker, r: *Req, batch: []const u8) void {
    var rep = Reply.init(batch);
    if (!beginOk(w, r, &rep)) return;
    const body = rep.row() orelse return notFound(w, r, "profile not found");
    const col = pg.cols(body, 3);
    const o = &w.out;
    o.putSlice("{\"profile\":");
    writeProfile(w, col[0].?, col[1], col[2], r.kind == .follow);
    o.put('}');
    doneReq(w, r, 200);
}

// ---- article lists -----------------------------------------------------------------------------

fn articleList(c: *Ctx) RouteError!void {
    try authenticate(c, false);
    const w = c.w;
    const pp = (try pageParams(c)) orelse return unprocessable(c, "invalid limit or offset");
    var stmt: sql.Stmt = .list_global;
    var arg: ?[]const u8 = null;
    if (try queryText(c, "tag")) |v| {
        stmt = .list_tag;
        arg = v;
    } else if (try queryText(c, "author")) |v| {
        stmt = .list_author;
        arg = v;
    } else if (try queryText(c, "favorited")) |v| {
        stmt = .list_fav;
        arg = v;
    }
    if (arg) |a| if (!validText(a)) {
        // not valid text, so it cannot name any tag or user: an empty page
        w.beginBody();
        w.out.putSlice("{\"articles\":[],\"articlesCount\":0}");
        return finish(w, c.fd, c.gen, 200, c.head.keep_alive);
    };
    const r = newReq(c, .list);
    w.readSubmit(stmt, r, .{ .viewer = c.viewer, .limit = pp.limit, .offset = pp.offset, .text = arg orelse "" });
}

fn feed(c: *Ctx) RouteError!void {
    try authenticate(c, true);
    const w = c.w;
    const pp = (try pageParams(c)) orelse return unprocessable(c, "invalid limit or offset");
    const r = newReq(c, .feed);
    w.readSubmit(.feed, r, .{ .viewer = c.viewer, .limit = pp.limit, .offset = pp.offset });
}

fn onList(w: *Worker, r: *Req, batch: []const u8) void {
    var rep = Reply.init(batch);
    if (!beginOk(w, r, &rep)) return;
    const o = &w.out;
    o.putSlice("{\"articles\":[");
    var count: i64 = 0;
    var first = true;
    while (rep.row()) |body| {
        const col = pg.cols(body, 14);
        count = pg.i64Of(col[0].?);
        if (col[1] == null) continue;
        if (!first) o.put(',');
        first = false;
        writeArticle(w, col[1..14], false);
    }
    o.putSlice("],\"articlesCount\":");
    jw.putInt(o, count);
    o.put('}');
    doneReq(w, r, 200);
}

// ---- single article ----------------------------------------------------------------------------

fn articleGet(c: *Ctx, raw_slug: []const u8) RouteError!void {
    try authenticate(c, false);
    const slug = try decodeSeg(c, raw_slug);
    if (!validText(slug)) return fail(c, 404, "article not found");
    const r = newReq(c, .article_get);
    c.w.readSubmit(.article, r, .{ .viewer = c.viewer, .text = slug });
}

/// `{"article": {...}}` from the first row of the current statement, or 404.
fn renderArticle(w: *Worker, r: *Req, rep: *Reply, code: u16) void {
    const body = rep.row() orelse return notFound(w, r, "article not found");
    const col = pg.cols(body, 14);
    w.out.putSlice("{\"article\":");
    writeArticle(w, &col, true);
    w.out.put('}');
    doneReq(w, r, code);
}

fn onArticle(w: *Worker, r: *Req, batch: []const u8) void {
    var rep = Reply.init(batch);
    if (!beginOk(w, r, &rep)) return;
    renderArticle(w, r, &rep, 200);
}

fn onFavorite(w: *Worker, r: *Req, batch: []const u8) void {
    var rep = Reply.init(batch);
    if (!beginOk(w, r, &rep)) return;
    renderArticle(w, r, &rep, 200);
}

fn favorite(c: *Ctx, raw_slug: []const u8, on: bool) RouteError!void {
    try authenticate(c, true);
    const slug = try decodeSeg(c, raw_slug);
    const w = c.w;
    var e = beginBatch(w);
    e.bind(sql.id(if (on) .fav_add else .fav_del));
    e.pInt8(c.viewer);
    e.pText(slug);
    e.exec();
    e.sync();
    const r = newReq(c, if (on) .favorite else .unfavorite);
    w.writeSubmit(r, w.enc.slice(), e.n_exec);
}

// ---- article create / update / delete ----------------------------------------------------------

const article_fields = [_][]const u8{ "title", "description", "body", "tagList" };

fn slugBase(w: *Worker, title: []const u8) RouteError![]const u8 {
    const out = try w.scratch.alloc(title.len);
    var n: usize = 0;
    var pending_dash = false;
    for (title) |ch| {
        const alnum = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9');
        if (alnum) {
            if (pending_dash and n > 0) {
                out[n] = '-';
                n += 1;
            }
            pending_dash = false;
            out[n] = std.ascii.toLower(ch);
            n += 1;
        } else pending_dash = true;
    }
    return out[0..n];
}

fn articleCreate(c: *Ctx) RouteError!void {
    try authenticate(c, true);
    const w = c.w;
    var f: [4]jp.Field = undefined;
    jp.parseWrapped(c.body, &w.scratch, "article", &article_fields, &.{"tagList"}, &f) catch return unprocessable(c, "invalid request body");
    const title = jp.needString(f[0]) orelse return unprocessable(c, "title can't be blank");
    const desc = jp.needString(f[1]) orelse return unprocessable(c, "description can't be blank");
    const body = jp.needString(f[2]) orelse return unprocessable(c, "body can't be blank");
    var tag_list: []const []const u8 = &.{};
    switch (f[3].kind) {
        .absent, .null => {},
        .strings => {
            for (f[3].list) |t| {
                if (t.len == 0 or std.mem.indexOfScalar(u8, t, 0) != null) return unprocessable(c, "invalid tag");
            }
            tag_list = f[3].list;
        },
        else => return unprocessable(c, "tagList must be an array of strings"),
    }
    const base = try slugBase(w, title);
    var e = beginBatch(w);
    e.bind(sql.id(.art_insert));
    e.pInt8(c.viewer);
    e.pText(base);
    e.pText(title);
    e.pText(desc);
    e.pText(body);
    e.exec();
    if (tag_list.len != 0) {
        e.bind(sql.id(.art_tags));
        e.pTextArray(tag_list);
        e.exec();
        e.bind(sql.id(.art_attach));
        e.pTextArray(tag_list);
        e.exec();
    }
    e.bind(sql.id(.art_new));
    e.pInt8(c.viewer);
    e.exec();
    e.sync();
    const r = newReq(c, .article_create);
    w.writeSubmit(r, w.enc.slice(), e.n_exec);
}

fn onArticleCreated(w: *Worker, r: *Req, batch: []const u8) void {
    var rep = Reply.init(batch);
    if (!beginOk(w, r, &rep)) return;
    // Statements before the final SELECT return no rows; the SELECT is the last statement.
    var body: ?[]const u8 = null;
    while (rep.rd.next()) |m| {
        if (m.kind == 'D') body = m.body;
    }
    const row = body orelse return failReq(w, r, 500, "internal error");
    const col = pg.cols(row, 14);
    w.out.putSlice("{\"article\":");
    writeArticle(w, &col, true);
    w.out.put('}');
    doneReq(w, r, 201);
}

fn articleUpdate(c: *Ctx, raw_slug: []const u8) RouteError!void {
    try authenticate(c, true);
    const slug = try decodeSeg(c, raw_slug);
    const w = c.w;
    var f: [4]jp.Field = undefined;
    jp.parseWrapped(c.body, &w.scratch, "article", &article_fields, &.{"tagList"}, &f) catch return unprocessable(c, "invalid request body");
    for (f[0..3]) |x| switch (x.kind) {
        .absent, .null => {},
        .string => if (jp.needString(x) == null) return unprocessable(c, "fields can't be blank"),
        else => return unprocessable(c, "fields must be strings"),
    };
    const title = optField(f[0]);
    const base: ?[]const u8 = if (title) |t| try slugBase(w, t) else null;
    var e = beginBatch(w);
    e.bind(sql.id(.art_update));
    e.pInt8(c.viewer);
    e.pText(slug);
    e.pTextOpt(title);
    e.pTextOpt(optField(f[1]));
    e.pTextOpt(optField(f[2]));
    e.pTextOpt(base);
    e.exec();
    e.sync();
    const r = newReq(c, .article_update);
    w.writeSubmit(r, w.enc.slice(), e.n_exec);
}

fn onArticleUpdated(w: *Worker, r: *Req, batch: []const u8) void {
    var rep = Reply.init(batch);
    if (!beginOk(w, r, &rep)) return;
    const row = rep.row() orelse return notFound(w, r, "article not found");
    const col = pg.cols(row, 16);
    if (pg.i64Of(col[1].?) != r.viewer) {
        w.out.len = http.head_room;
        errorBody(w, "forbidden");
        return doneReq(w, r, 403);
    }
    // The author's UPDATE found nothing to change (the article was deleted or renamed after the statement's
    // snapshot): the updated-row columns are all NULL.
    if (col[2] == null) return notFound(w, r, "article not found");
    w.out.putSlice("{\"article\":");
    writeArticle(w, col[2..16], true);
    w.out.put('}');
    doneReq(w, r, 200);
}

fn articleDelete(c: *Ctx, raw_slug: []const u8) RouteError!void {
    try authenticate(c, true);
    const slug = try decodeSeg(c, raw_slug);
    const w = c.w;
    var e = beginBatch(w);
    e.bind(sql.id(.art_delete));
    e.pInt8(c.viewer);
    e.pText(slug);
    e.exec();
    e.sync();
    const r = newReq(c, .article_delete);
    w.writeSubmit(r, w.enc.slice(), e.n_exec);
}

/// Shared by article and comment deletes: columns (author_id, deleted).
fn onDeleted(w: *Worker, r: *Req, batch: []const u8, what: []const u8) void {
    var rep = Reply.init(batch);
    if (!beginOk(w, r, &rep)) return;
    const row = rep.row() orelse return notFound(w, r, what);
    const col = pg.cols(row, 2);
    if (pg.i64Of(col[0].?) != r.viewer) {
        w.out.len = http.head_room;
        errorBody(w, "forbidden");
        return doneReq(w, r, 403);
    }
    doneReq(w, r, 204);
}

// ---- comments ----------------------------------------------------------------------------------

fn commentsList(c: *Ctx, raw_slug: []const u8) RouteError!void {
    try authenticate(c, false);
    const slug = try decodeSeg(c, raw_slug);
    if (!validText(slug)) return fail(c, 404, "article not found");
    const r = newReq(c, .comments_list);
    c.w.readSubmit(.comments, r, .{ .viewer = c.viewer, .text = slug });
}

fn onComments(w: *Worker, r: *Req, batch: []const u8) void {
    var rep = Reply.init(batch);
    if (!beginOk(w, r, &rep)) return;
    const o = &w.out;
    var any = false;
    var first = true;
    while (rep.row()) |body| {
        if (!any) {
            any = true;
            o.putSlice("{\"comments\":[");
        }
        const col = pg.cols(body, 8);
        if (col[0] == null) continue;
        if (!first) o.put(',');
        first = false;
        writeComment(w, pg.i64Of(col[0].?), col[1].?, pg.i64Of(col[2].?), pg.i64Of(col[3].?), col[4].?, col[5], col[6], boolOf(col[7]));
    }
    if (!any) return notFound(w, r, "article not found");
    o.putSlice("]}");
    doneReq(w, r, 200);
}

fn commentCreate(c: *Ctx, raw_slug: []const u8) RouteError!void {
    try authenticate(c, true);
    const slug = try decodeSeg(c, raw_slug);
    const w = c.w;
    var f: [1]jp.Field = undefined;
    jp.parseWrapped(c.body, &w.scratch, "comment", &.{"body"}, &.{}, &f) catch return unprocessable(c, "invalid request body");
    const body = jp.needString(f[0]) orelse return unprocessable(c, "body can't be blank");
    var e = beginBatch(w);
    e.bind(sql.id(.comment_insert));
    e.pInt8(c.viewer);
    e.pText(slug);
    e.pText(body);
    e.exec();
    e.sync();
    const r = newReq(c, .comment_create);
    w.writeSubmit(r, w.enc.slice(), e.n_exec);
}

fn onCommentCreated(w: *Worker, r: *Req, batch: []const u8) void {
    var rep = Reply.init(batch);
    if (!beginOk(w, r, &rep)) return;
    const row = rep.row() orelse return notFound(w, r, "article not found");
    const col = pg.cols(row, 7);
    w.out.putSlice("{\"comment\":");
    writeComment(w, pg.i64Of(col[0].?), col[1].?, pg.i64Of(col[2].?), pg.i64Of(col[3].?), col[4].?, col[5], col[6], false);
    w.out.put('}');
    doneReq(w, r, 201);
}

fn commentDelete(c: *Ctx, raw_slug: []const u8, raw_id: []const u8) RouteError!void {
    try authenticate(c, true);
    const w = c.w;
    // ASCII digits only (parseInt would also take a sign and `_` separators)
    if (raw_id.len == 0 or raw_id.len > 18) return fail(c, 404, "comment not found");
    for (raw_id) |ch| if (ch < '0' or ch > '9') return fail(c, 404, "comment not found");
    const id = std.fmt.parseInt(i64, raw_id, 10) catch return fail(c, 404, "comment not found");
    const slug = try decodeSeg(c, raw_slug);
    var e = beginBatch(w);
    e.bind(sql.id(.comment_delete));
    e.pInt8(c.viewer);
    e.pInt8(id);
    e.pText(slug);
    e.exec();
    e.sync();
    const r = newReq(c, .comment_delete);
    w.writeSubmit(r, w.enc.slice(), e.n_exec);
}

// ---------------------------------------------------------------------------------------------
// Completion dispatch (called by the event loop)
// ---------------------------------------------------------------------------------------------

pub fn onPg(w: *Worker, r: *Req, batch: []const u8) void {
    if (r.remote_owner != std.math.maxInt(u16)) return w.proxyReply(r, 0, 200, batch);
    switch (r.kind) {
        .tags => onTags(w, r, batch),
        .login_sql => onLoginRow(w, r, batch),
        .register_sql => onUserRow(w, r, batch, 201),
        .user_get, .user_update_sql => onUserRow(w, r, batch, 200),
        .profile => onProfile(w, r, batch),
        .follow, .unfollow => onFollow(w, r, batch),
        .list, .feed => onList(w, r, batch),
        .article_get => onArticle(w, r, batch),
        .comments_list => onComments(w, r, batch),
        .comment_create => onCommentCreated(w, r, batch),
        .comment_delete => onDeleted(w, r, batch, "comment not found"),
        .article_create => onArticleCreated(w, r, batch),
        .article_update => onArticleUpdated(w, r, batch),
        .article_delete => onDeleted(w, r, batch, "article not found"),
        .favorite, .unfavorite => onFavorite(w, r, batch),
        .login_verify, .register_hash, .user_update_hash => unreachable,
    }
}

pub fn onBcrypt(w: *Worker, r: *Req, d: bcpool.Done) void {
    if (d.stale) return failReq(w, r, 503, "busy");
    switch (r.kind) {
        .register_hash => onRegisterHashed(w, r, d),
        .user_update_hash => onUpdateHashed(w, r, d),
        .login_verify => onLoginVerified(w, r, d),
        else => unreachable,
    }
}

/// The database connection failed while this request was in flight.
pub fn onPgFailure(w: *Worker, r: *Req) void {
    if (r.remote_owner != std.math.maxInt(u16)) return w.proxyReply(r, 2, 503, "");
    failReq(w, r, 503, "database unavailable");
}
