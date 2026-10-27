//! The engine as the whole HTTP server, run in Postgres background workers (pgserve, the in-Postgres
//! submission; research/pgengine/1m.md, design A). No app process and no wire protocol between a request
//! and its data.
//!
//! A worker starts by collecting its listening socket and the JWT secret from the launcher (pgserve's own
//! process, which owns the port) over a Unix socket, the socket passed with SCM_RIGHTS. Then each epoll
//! turn reads every complete request, at most one per connection (a client's next request waits for the
//! answer to its last, so it always sees its own writes), and answers the turn's reads as one engine
//! batch per endpoint under one transaction and snapshot.

const std = @import("std");
const c = @import("pg_c");
const http = @import("web/http.zig");
const jwt = @import("web/jwt.zig");
const json = @import("web/json.zig");
const bcrypt = @import("web/bcrypt.zig");
const buf = @import("web/buf.zig");
const Buf = buf.Buf;
const linux = std.os.linux;

const gpa = std.heap.c_allocator;

// ---------------------------------------------------------------- connections and requests

// Who owns which bytes. A read lands in the worker's `inbuf`, and a complete request is started straight from
// there. An answer is built in the worker's `answers` and written after the turn. A connection owns heap only
// for what it still waits on: the bytes of requests not yet started (`in`) and the bytes of answers the socket
// would not take yet (`out`). Each is freed as soon as it is empty, so an idle connection holds no buffer.

/// One event's bytes: the connection's `in`, then what its socket held. Grows only for a large body or a
/// burst of pipelined requests, and goes back to `inbuf_size` after.
var inbuf: std.ArrayListUnmanaged(u8) = .empty;
const inbuf_size = 64 << 10;

/// This turn's answers, back to back, sent after the turn's writes commit and its reads run.
var answers: std.ArrayListUnmanaged(u8) = .empty;
/// Capacity `answers` keeps from one turn to the next; above it the buffer is freed after the turn.
const answers_keep = 4 << 20;

const Conn = struct {
    fd: i32,
    /// Its answer in `answers`. At most one of `ans` and `out` is non-empty.
    ans: struct { at: usize = 0, len: usize = 0 } = .{},
    /// Received bytes of requests not yet started.
    in: []u8 = &.{},
    /// Answer bytes not yet sent, kept past the turn.
    out: []u8 = &.{},
    /// The request being answered; the next one is not parsed until it is.
    req: ?*Req = null,
    keep_alive: bool = true,
    /// On this turn's touched list.
    touched: bool = false,
    /// Registered for EPOLLOUT: the last write met a full socket buffer.
    waiting: bool = false,
    closed: bool = false,
};

/// The engine endpoint a read runs as, with its fields in packed order (the shim's endpoint_fields).
const Field = enum { int, text };
fn fieldsOf(ep: c_int) []const Field {
    return switch (ep) {
        c.EP_ARTICLE, c.EP_COMMENTS, c.EP_PROFILE, c.EP_USER => &.{ .int, .text },
        c.EP_LIST_ALL, c.EP_FEED => &.{ .int, .int, .int },
        c.EP_LIST_TAG, c.EP_LIST_AUTHOR, c.EP_LIST_FAVORITED => &.{ .int, .int, .int, .text },
        c.EP_TAGS => &.{.int},
        else => unreachable,
    };
}
const N_EP: usize = @intCast(c.EP_MEGA);

/// Where a request waits: a read of this turn, a write of this turn, or a bcrypt thread.
const Stage = enum { read, write, hash };

const Req = struct {
    conn: *Conn,
    stage: Stage = .read,
    /// Its connection closed while a bcrypt thread held it; the thread's answer frees it.
    orphan: bool = false,
    viewer: i64 = 0,
    /// The caller's token, or the one issued by login or sign-up.
    token: []const u8 = "",
    /// The engine read that answers it.
    ep: c_int = 0,
    ints: [4]i64 = @splat(0),
    texts: [4][]const u8 = @splat(""),
    /// The status of a read that finds its row, and of one that finds nothing.
    found: Status = .ok,
    missing: Status = .not_found,
    w: c.PgsWrite = std.mem.zeroes(c.PgsWrite),
    /// A login's password, until its stored hash is read.
    password: []const u8 = "",
    tags: std.ArrayListUnmanaged(c.EngineText) = .empty,
    job: bcrypt.Job = undefined,
    /// Path values, query values, decoded body strings and the token, copied out of the connection's buffer.
    /// Sized once per request, so slices into it stay valid.
    scratch: std.ArrayListUnmanaged(u8) = .empty,

    fn keep(r: *Req, s: []const u8) []const u8 {
        const at = r.scratch.items.len;
        r.scratch.appendSliceAssumeCapacity(s);
        return r.scratch.items[at..];
    }

    fn arg(r: *Req, k: usize, v: Arg) void {
        r.w.args[k] = switch (v) {
            .null => .{ .isnull = true },
            .int => |i| .{ .i = i },
            .text => |s| .{ .ptr = s.ptr, .len = @intCast(s.len) },
        };
    }
};

const Arg = union(enum) { null, int: i64, text: []const u8 };

const Status = enum(u16) {
    ok = 200,
    created = 201,
    no_content = 204,
    bad_request = 400,
    unauthorized = 401,
    forbidden = 403,
    not_found = 404,
    unprocessable = 422,
    internal = 500,
    unavailable = 503,

    fn line(s: Status) []const u8 {
        return switch (s) {
            .ok => "200 OK",
            .created => "201 Created",
            .no_content => "204 No Content",
            .bad_request => "400 Bad Request",
            .unauthorized => "401 Unauthorized",
            .forbidden => "403 Forbidden",
            .not_found => "404 Not Found",
            .unprocessable => "422 Unprocessable Entity",
            .internal => "500 Internal Server Error",
            .unavailable => "503 Service Unavailable",
        };
    }
};

/// Queues the answer. Bodies go out uncompressed (SPEC: compression is optional).
fn respond(conn: *Conn, status: Status, body: []const u8) void {
    var head: [224]u8 = undefined;
    const close_line = if (conn.keep_alive) "" else "Connection: close\r\n";
    const h = if (status == .no_content)
        std.fmt.bufPrint(&head, "HTTP/1.1 {s}\r\n{s}\r\n", .{ status.line(), close_line }) catch unreachable
    else
        std.fmt.bufPrint(&head, "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n{s}\r\n", .{
            status.line(), body.len, close_line,
        }) catch unreachable;
    if (conn.ans.len == 0 and conn.out.len == 0) {
        conn.ans = .{ .at = answers.items.len, .len = h.len + body.len };
        answers.appendSlice(gpa, h) catch @panic("out of memory");
        answers.appendSlice(gpa, body) catch @panic("out of memory");
        return;
    }
    // it must follow an answer still waiting
    stash(conn);
    hold(conn, h);
    hold(conn, body);
}

fn answerOf(conn: *const Conn) []u8 {
    return answers.items[conn.ans.at..][0..conn.ans.len];
}

/// Moves `conn`'s answer out of `answers` into its own `out`, to outlive the turn.
fn stash(conn: *Conn) void {
    hold(conn, answerOf(conn));
    conn.ans = .{};
}

fn hold(conn: *Conn, bytes: []const u8) void {
    const n = conn.out.len;
    conn.out = gpa.realloc(conn.out, n + bytes.len) catch @panic("out of memory");
    @memcpy(conn.out[n..], bytes);
}

/// `bytes` in an allocation of its own, or nothing when it is empty.
fn own(bytes: []const u8) []u8 {
    if (bytes.len == 0) return &.{};
    return gpa.dupe(u8, bytes) catch @panic("out of memory");
}

fn fail(conn: *Conn, status: Status, comptime msg: []const u8) void {
    respond(conn, status, "{\"errors\":{\"body\":[\"" ++ msg ++ "\"]}}");
}

fn finish(r: *Req) void {
    r.conn.req = null;
    destroy(r);
}

fn destroy(r: *Req) void {
    r.scratch.deinit(gpa);
    r.tags.deinit(gpa);
    gpa.destroy(r);
}

/// Answers `r` with an error and ends it.
fn reject(r: *Req, status: Status, comptime msg: []const u8) void {
    fail(r.conn, status, msg);
    finish(r);
}

/// This turn's queues.
const Turn = struct {
    reads: [N_EP]std.ArrayListUnmanaged(*Req) = @splat(.empty),
    writes: std.ArrayListUnmanaged(*Req) = .empty,
    touched: std.ArrayListUnmanaged(*Conn) = .empty,
    /// Requests queued on `reads` and `writes`.
    n: u32 = 0,
    /// When the oldest of them was queued (monotonic ns), once the loop has dated it.
    since: ?i64 = null,

    fn read(t: *Turn, r: *Req, ep: c_int) void {
        r.stage = .read;
        r.ep = ep;
        t.reads[@intCast(ep)].append(gpa, r) catch @panic("out of memory");
        t.n += 1;
    }

    fn write(t: *Turn, r: *Req, kind: c_int) void {
        r.stage = .write;
        r.w.kind = kind;
        t.writes.append(gpa, r) catch @panic("out of memory");
        t.n += 1;
    }

    fn pending(t: *const Turn) bool {
        return t.n > 0;
    }

    fn date(t: *Turn, now: i64) void {
        if (t.n > 0 and t.since == null) t.since = now;
    }

    /// Takes a queued request off the turn: its connection closed while the turn was held.
    fn drop(t: *Turn, r: *Req) void {
        const l = switch (r.stage) {
            .read => &t.reads[@intCast(r.ep)],
            .write => &t.writes,
            .hash => return,
        };
        const i = std.mem.indexOfScalar(*Req, l.items, r) orelse return;
        _ = l.orderedRemove(i);
        t.n -= 1;
        if (t.n == 0) t.since = null;
    }

    /// The conns of every queued request, so that the turn's end flushes their answers.
    fn touchAll(t: *Turn) void {
        for (t.writes.items) |r| touch(r.conn, &t.touched);
        for (t.reads) |l| for (l.items) |r| touch(r.conn, &t.touched);
    }
};

/// The batch clock (PGSERVE_DWELL_US, PGSERVE_DWELL_CAP, PGSERVE_DWELL_MIN through the launcher). A held turn
/// keeps reading sockets and queueing requests, and runs its writes and reads only once its oldest request has
/// waited `dwell_ns` or it holds `cap` requests. A dwell of 0 runs every turn at once.
const Clock = struct {
    dwell_ns: i64 = 5 * std.time.ns_per_ms,
    cap: u32 = 256,
    /// The smallest batch that keeps the clock on for the next turn. A smaller one means light load: the next
    /// turn runs at once, so a lone request is not held for company that isn't coming.
    min: u32 = 2,
    hot: bool = false,

    const Fire = enum { now, deadline, cap };

    /// Why the turn runs now, or null to hold it until `deadline`.
    fn due(k: *const Clock, t: *const Turn, now: i64) ?Fire {
        if (k.dwell_ns == 0 or !k.hot) return .now;
        if (t.n >= k.cap) return .cap;
        if (now >= k.deadline(t)) return .deadline;
        return null;
    }

    fn deadline(k: *const Clock, t: *const Turn) i64 {
        return t.since.? + k.dwell_ns;
    }

    fn fired(k: *Clock, n: u32) void {
        k.hot = n >= k.min;
    }
};

/// Batch sizes: exact below 64, then one bucket per power of two up to 32,768.
const Hist = struct {
    turns: [64 + 10]u32 = @splat(0),
    reqs: u64 = 0,

    fn add(h: *Hist, k: usize) void {
        h.turns[bucket(k)] += 1;
        h.reqs += k;
    }

    fn bucket(k: usize) usize {
        if (k < 64) return k;
        return @min(64 + @as(usize, std.math.log2_int(usize, k)) - 6, 64 + 9);
    }

    fn floor(b: usize) usize {
        return if (b < 64) b else @as(usize, 1) << @intCast(b - 64 + 6);
    }

    fn count(h: *const Hist) u64 {
        var s: u64 = 0;
        for (h.turns) |n| s += n;
        return s;
    }

    /// The batch size at quantile `q` of the batches, or of the requests when `by_req` (the size of batch a
    /// request was served in). Sizes past 63 come out as their power of two.
    fn quantile(h: *const Hist, q: f64, by_req: bool) usize {
        var total: f64 = 0;
        for (h.turns, 0..) |n, b| total += @as(f64, @floatFromInt(n)) * if (by_req) @as(f64, @floatFromInt(floor(b))) else 1;
        var acc: f64 = 0;
        for (h.turns, 0..) |n, b| {
            acc += @as(f64, @floatFromInt(n)) * if (by_req) @as(f64, @floatFromInt(floor(b))) else 1;
            if (n > 0 and acc >= q * total) return floor(b);
        }
        return 0;
    }
};

/// Reads per batch per endpoint and writes per commit, logged every `every_ns` (PGSERVE_STATS_S; 0 keeps them
/// unlogged).
const Stats = struct {
    reads: [N_EP]Hist = @splat(.{}),
    writes: Hist = .{},
    fires: std.EnumArray(Clock.Fire, u32) = .initFill(0),
    /// Sum over turns of how long the oldest request waited for its turn to run.
    waited_ns: u64 = 0,
    from: i64 = 0,
    every_ns: i64 = 0,

    const names = [N_EP][]const u8{ "article", "list_all", "list_tag", "list_author", "list_favorited", "feed", "comments", "profile", "user", "tags" };

    fn log(s: *Stats, now: i64) void {
        var line: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(line[0 .. line.len - 1]);
        const turns = s.fires.get(.now) + s.fires.get(.deadline) + s.fires.get(.cap);
        if (turns == 0) return;
        w.print("pgserve stats secs={d:.1} turns={d} now={d} deadline={d} cap={d} wait_ms={d:.2}", .{
            @as(f64, @floatFromInt(now - s.from)) / 1e9, turns,
            s.fires.get(.now),                           s.fires.get(.deadline),
            s.fires.get(.cap),                           @as(f64, @floatFromInt(s.waited_ns)) / @as(f64, @floatFromInt(turns)) / 1e6,
        }) catch {};
        if (s.writes.reqs > 0) hist(&w, "writes", &s.writes);
        for (&s.reads, names) |*h, name| if (h.reqs > 0) hist(&w, name, h);
        line[w.end] = 0;
        c.shim_log(&line);
    }

    fn hist(w: *std.Io.Writer, name: []const u8, h: *const Hist) void {
        w.print(" | {s} turns={d} reqs={d} p50={d} p90={d} rp50={d} rp90={d}", .{
            name, h.count(), h.reqs, h.quantile(0.5, false), h.quantile(0.9, false), h.quantile(0.5, true), h.quantile(0.9, true),
        }) catch {};
    }
};

fn hash(r: *Req, kind: bcrypt.Kind, password: []const u8, stored: []const u8) void {
    r.stage = .hash;
    r.job = .{ .kind = kind, .password = password, .stored = stored, .owner = r };
    bcrypt.submit(&r.job);
}

// ---------------------------------------------------------------- routing

const Auth = union(enum) { anonymous, invalid, user: struct { id: i64, token: []const u8 } };

fn authenticate(head: *const http.Head, now: i64) Auth {
    const h = head.auth orelse return .anonymous;
    if (h.len == 0) return .anonymous;
    if (!std.mem.startsWith(u8, h, "Token ")) return .invalid;
    const token = h["Token ".len..];
    const id = jwt.verify(token, now) orelse return .invalid;
    return .{ .user = .{ .id = id, .token = token } };
}

/// ASCII digits only, fitting an int64 (the reference's parseUint).
fn parseUint(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    var n: i64 = 0;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return null;
        n = std.math.mul(i64, n, 10) catch return null;
        n = std.math.add(i64, n, ch - '0') catch return null;
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

/// Starts the request whose head is `head` and body `body`: answers it at once (an error) or queues it on
/// this turn (a read or a write) or on a bcrypt thread. Nothing in `head` or `body` is used after it returns.
fn start(conn: *Conn, head: *const http.Head, body: []const u8, now: i64, t: *Turn) void {
    conn.keep_alive = head.keep_alive;
    const m = http.route(head.method, head.target);
    if (m.route == .not_found) return fail(conn, .not_found, "not found");
    const a = authenticate(head, now);
    const r = gpa.create(Req) catch @panic("out of memory");
    r.* = .{ .conn = conn };
    conn.req = r;
    r.scratch.ensureTotalCapacity(gpa, head.target.len + 3 * body.len + 1024) catch @panic("out of memory");
    switch (m.route) {
        .tags, .register, .login => {},
        // optional auth: a present but invalid token is still 401
        .list, .article, .comments, .profile => switch (a) {
            .invalid => return reject(r, .unauthorized, "unauthorized"),
            .anonymous => {},
            .user => |u| r.viewer = u.id,
        },
        else => switch (a) {
            .user => |u| {
                r.viewer = u.id;
                r.token = r.keep(u.token);
            },
            else => return reject(r, .unauthorized, "unauthorized"),
        },
    }
    r.ints[0] = r.viewer;
    switch (m.route) {
        .tags => t.read(r, c.EP_TAGS),
        .list, .feed => {
            const lo = limitOffset(m.query) orelse return reject(r, .unprocessable, "limit must be 1-100 and offset >= 0");
            r.ints[1] = lo[0];
            r.ints[2] = lo[1];
            var ep: c_int = if (m.route == .feed) c.EP_FEED else c.EP_LIST_ALL;
            // the first non-empty filter in the order tag, author, favorited applies
            if (m.route == .list) for ([_]struct { []const u8, c_int }{
                .{ "tag", c.EP_LIST_TAG },
                .{ "author", c.EP_LIST_AUTHOR },
                .{ "favorited", c.EP_LIST_FAVORITED },
            }) |f| {
                const v = queryValue(r, m.query, f[0]);
                if (v.len > 0) {
                    ep = f[1];
                    r.texts[3] = v;
                    break;
                }
            };
            t.read(r, ep);
        },
        .article, .comments => {
            r.texts[1] = pathValue(r, m.a) orelse return reject(r, .not_found, "article not found");
            t.read(r, if (m.route == .article) c.EP_ARTICLE else c.EP_COMMENTS);
        },
        .profile => {
            r.texts[1] = pathValue(r, m.a) orelse return reject(r, .not_found, "profile not found");
            t.read(r, c.EP_PROFILE);
        },
        .user_get => {
            r.texts[1] = r.token;
            r.missing = .unauthorized;
            t.read(r, c.EP_USER);
        },
        .follow, .unfollow => {
            const name = pathValue(r, m.a) orelse return reject(r, .not_found, "profile not found");
            r.arg(0, .{ .int = r.viewer });
            r.arg(1, .{ .text = name });
            r.texts[1] = name;
            t.write(r, if (m.route == .follow) c.W_FOLLOW else c.W_UNFOLLOW);
        },
        .favorite, .unfavorite => {
            const slug = pathValue(r, m.a) orelse return reject(r, .not_found, "article not found");
            r.arg(0, .{ .int = r.viewer });
            r.arg(1, .{ .text = slug });
            r.texts[1] = slug;
            t.write(r, if (m.route == .favorite) c.W_FAVORITE else c.W_UNFAVORITE);
        },
        .article_delete => {
            const slug = pathValue(r, m.a) orelse return reject(r, .not_found, "article not found");
            r.arg(0, .{ .text = slug });
            r.arg(1, .{ .int = r.viewer });
            t.write(r, c.W_ARTICLE_DELETE);
        },
        .comment_delete => {
            const slug = pathValue(r, m.a) orelse return reject(r, .not_found, "comment not found");
            const raw_id = pathValue(r, m.b) orelse return reject(r, .not_found, "comment not found");
            const id = parseUint(raw_id) orelse return reject(r, .not_found, "comment not found");
            r.arg(0, .{ .int = id });
            r.arg(1, .{ .text = slug });
            r.arg(2, .{ .int = r.viewer });
            t.write(r, c.W_COMMENT_DELETE);
        },
        .register => if (shed.since != null) refuse(r, .register) else register(r, body),
        .login => if (shed.since != null) refuse(r, .login) else login(r, body, t),
        .user_put => updateUser(r, body, t),
        .article_create => createArticle(r, body, t),
        .article_update => updateArticle(r, m.a, body, t),
        .comment_create => createComment(r, m.a, body, t),
        .not_found => unreachable,
    }
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

const Opt = union(enum) {
    absent,
    bad,
    value: []const u8,

    fn arg(o: Opt) Arg {
        return switch (o) {
            .value => |s| .{ .text = s },
            else => .null,
        };
    }
};

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

fn register(r: *Req, body: []const u8) void {
    const obj = wrapper(body, "user") orelse return reject(r, .unprocessable, "invalid body");
    const username = reqString(r, obj, "username");
    const email = reqString(r, obj, "email");
    const password = reqString(r, obj, "password");
    if (username == null or email == null or password == null)
        return reject(r, .unprocessable, "username, email and password are required");
    if (password.?.len > 72) return reject(r, .unprocessable, "password is too long");
    r.arg(0, .{ .text = username.? });
    r.arg(1, .{ .text = email.? });
    r.w.kind = c.W_USER_INSERT;
    hash(r, .hash, password.?, "");
}

fn login(r: *Req, body: []const u8, t: *Turn) void {
    const obj = wrapper(body, "user") orelse return reject(r, .unprocessable, "invalid body");
    const email = reqString(r, obj, "email");
    const password = reqString(r, obj, "password");
    if (email == null or password == null) return reject(r, .unprocessable, "email and password are required");
    r.password = password.?;
    r.arg(0, .{ .text = email.? });
    t.write(r, c.W_USER_BY_EMAIL);
}

fn updateUser(r: *Req, body: []const u8, t: *Turn) void {
    const obj = wrapper(body, "user") orelse return reject(r, .unprocessable, "invalid body");
    const email = optString(r, obj, "email", true);
    const username = optString(r, obj, "username", true);
    const password = optString(r, obj, "password", true);
    const bio = optString(r, obj, "bio", false);
    const image = optString(r, obj, "image", false);
    for ([_]Opt{ email, username, password, bio, image }) |o| {
        if (o == .bad) return reject(r, .unprocessable, "invalid user fields");
    }
    r.arg(0, .{ .int = r.viewer });
    r.arg(1, email.arg());
    r.arg(2, username.arg());
    r.arg(3, .null);
    r.arg(4, bio.arg());
    r.arg(5, image.arg());
    r.w.kind = c.W_USER_UPDATE;
    switch (password) {
        .value => |p| {
            if (p.len > 72) return reject(r, .unprocessable, "password is too long");
            if (shed.since != null) return refuse(r, .user_put);
            hash(r, .hash, p, "");
        },
        else => t.write(r, c.W_USER_UPDATE),
    }
}

fn createArticle(r: *Req, body: []const u8, t: *Turn) void {
    const obj = wrapper(body, "article") orelse return reject(r, .unprocessable, "invalid body");
    const title = reqString(r, obj, "title");
    const description = reqString(r, obj, "description");
    const text = reqString(r, obj, "body");
    if (title == null or description == null or text == null)
        return reject(r, .unprocessable, "title, description and body are required");
    if (!tagList(r, obj)) return reject(r, .unprocessable, "tagList must be an array of non-empty strings");
    r.arg(0, .{ .int = r.viewer });
    r.arg(1, .{ .text = title.? });
    r.arg(2, .{ .text = description.? });
    r.arg(3, .{ .text = text.? });
    r.w.args[4] = .{ .items = r.tags.items.ptr, .nitems = @intCast(r.tags.items.len) };
    t.write(r, c.W_ARTICLE_CREATE);
}

/// tagList into `r.tags`: absent or null is empty; otherwise an array of non-empty strings.
fn tagList(r: *Req, obj: json.Value) bool {
    const v = obj.get("tagList") orelse return true;
    switch (v.kind()) {
        .null => return true,
        .array => {},
        else => return false,
    }
    var it = v.items();
    while (it.next()) |item| {
        if (item.kind() != .string) return false;
        const s = decode(r, item);
        if (s.len == 0) return false;
        r.tags.append(gpa, .{ .ptr = s.ptr, .len = @intCast(s.len) }) catch @panic("out of memory");
    }
    return true;
}

fn updateArticle(r: *Req, raw_slug: []const u8, body: []const u8, t: *Turn) void {
    const obj = wrapper(body, "article") orelse return reject(r, .unprocessable, "invalid body");
    const title = optString(r, obj, "title", true);
    const description = optString(r, obj, "description", true);
    const text = optString(r, obj, "body", true);
    if (title == .bad or description == .bad or text == .bad)
        return reject(r, .unprocessable, "title, description and body must be non-empty strings");
    const slug = pathValue(r, raw_slug) orelse return reject(r, .not_found, "article not found");
    r.arg(0, .{ .text = slug });
    r.arg(1, title.arg());
    r.arg(2, description.arg());
    r.arg(3, text.arg());
    r.arg(4, .{ .int = r.viewer });
    t.write(r, c.W_ARTICLE_UPDATE);
}

fn createComment(r: *Req, raw_slug: []const u8, body: []const u8, t: *Turn) void {
    const obj = wrapper(body, "comment") orelse return reject(r, .unprocessable, "invalid body");
    const text = reqString(r, obj, "body") orelse return reject(r, .unprocessable, "body is required");
    const slug = pathValue(r, raw_slug) orelse return reject(r, .not_found, "article not found");
    r.arg(0, .{ .text = slug });
    r.arg(1, .{ .int = r.viewer });
    r.arg(2, .{ .text = text });
    t.write(r, c.W_COMMENT_CREATE);
}

// ---------------------------------------------------------------- writes and bcrypt results

fn colText(r: *Req, k: usize) []const u8 {
    const col = r.w.cols[k];
    return r.keep(col.ptr[0..col.len]);
}

/// Answers a write, or queues the read that answers it, or hands it to a bcrypt thread.
fn written(r: *Req, t: *Turn) void {
    const w = &r.w;
    switch (w.status) {
        c.WS_OK => {},
        c.WS_UNIQUE => return reject(r, .unprocessable, "username or email is already taken"),
        c.WS_NONE => return switch (w.kind) {
            c.W_FOLLOW, c.W_UNFOLLOW => reject(r, .not_found, "profile not found"),
            c.W_COMMENT_DELETE => reject(r, .not_found, "comment not found"),
            c.W_USER_UPDATE => reject(r, .unauthorized, "unauthorized"),
            c.W_USER_BY_EMAIL => reject(r, .unauthorized, "invalid email or password"),
            c.W_ARTICLE_CREATE, c.W_USER_INSERT => reject(r, .internal, "internal error"),
            else => reject(r, .not_found, "article not found"),
        },
        else => return reject(r, .internal, "internal error"),
    }
    switch (w.kind) {
        c.W_FOLLOW, c.W_UNFOLLOW => t.read(r, c.EP_PROFILE),
        c.W_FAVORITE, c.W_UNFAVORITE => t.read(r, c.EP_ARTICLE),
        c.W_ARTICLE_CREATE => {
            r.texts[1] = colText(r, 0);
            r.found = .created;
            t.read(r, c.EP_ARTICLE);
        },
        c.W_ARTICLE_UPDATE => {
            if (w.cols[0].i != r.viewer) return reject(r, .forbidden, "not the author");
            r.texts[1] = colText(r, 1);
            t.read(r, c.EP_ARTICLE);
        },
        c.W_ARTICLE_DELETE, c.W_COMMENT_DELETE => {
            if (w.cols[0].i != r.viewer) return reject(r, .forbidden, "not the author");
            respond(r.conn, .no_content, "");
            finish(r);
        },
        c.W_COMMENT_CREATE => {
            commentBody(r);
            finish(r);
        },
        c.W_USER_INSERT => {
            r.viewer = w.cols[0].i;
            var tok: [256]u8 = undefined;
            r.token = r.keep(jwt.issue(r.viewer, wallSeconds(), &tok));
            r.found = .created;
            userRead(r, t);
        },
        c.W_USER_UPDATE => userRead(r, t),
        c.W_USER_BY_EMAIL => {
            r.viewer = w.cols[0].i;
            hash(r, .verify, r.password, colText(r, 1));
        },
        else => unreachable,
    }
}

fn userRead(r: *Req, t: *Turn) void {
    r.ints[0] = r.viewer;
    r.texts[1] = r.token;
    r.missing = .unauthorized;
    t.read(r, c.EP_USER);
}

/// The new comment, from the row the insert returned (its author is the caller, so not followed).
fn commentBody(r: *Req) void {
    const col = r.w.cols;
    var o = Buf.init();
    defer o.release();
    o.append("{\"comment\":{\"id\":");
    json.int(&o, col[0].i);
    o.append(",\"createdAt\":");
    json.timestamp(&o, col[2].i);
    o.append(",\"updatedAt\":");
    json.timestamp(&o, col[3].i);
    o.append(",\"body\":");
    json.str(&o, col[1].ptr[0..col[1].len]);
    o.append(",\"author\":{\"username\":");
    json.str(&o, col[4].ptr[0..col[4].len]);
    for ([_]struct { []const u8, c.PgsCol }{ .{ ",\"bio\":", col[5] }, .{ ",\"image\":", col[6] } }) |f| {
        o.append(f[0]);
        json.strOrNull(&o, if (f[1].isnull) null else f[1].ptr[0..f[1].len]);
    }
    o.append(",\"following\":false}}}");
    respond(r.conn, .created, o.body());
}

/// A bcrypt job finished.
fn hashed(j: *bcrypt.Job, t: *Turn) void {
    const r: *Req = @ptrCast(@alignCast(j.owner));
    if (r.orphan) return destroy(r);
    touch(r.conn, &t.touched);
    switch (j.kind) {
        .hash => {
            r.arg(if (r.w.kind == c.W_USER_INSERT) 2 else 3, .{ .text = &j.out });
            t.write(r, r.w.kind);
        },
        .verify => {
            if (!j.ok) return reject(r, .unauthorized, "invalid email or password");
            var tok: [256]u8 = undefined;
            r.token = r.keep(jwt.issue(r.viewer, wallSeconds(), &tok));
            userRead(r, t);
        },
    }
}

// ---------------------------------------------------------------- the engine batches

/// Runs one endpoint's reads of the turn as one engine batch and answers each. False when the batch raised an
/// ERROR: its requests got 500 and the turn's transaction is gone.
fn runReads(ep: c_int, all: []*Req, snap: ?*anyopaque) bool {
    const fields = fieldsOf(ep);
    // A value Postgres's text input would refuse (a NUL, bytes that aren't UTF-8) fails the reference's query.
    var n: usize = 0;
    for (all) |r| {
        if (refused(r.texts[0..fields.len])) {
            reject(r, .internal, "internal error");
            continue;
        }
        all[n] = r;
        n += 1;
    }
    const reqs = all[0..n];
    if (n == 0) return true;
    var x: c.EngineExec = std.mem.zeroes(c.EngineExec);
    x.endpoint = ep;
    x.nreq = @intCast(n);
    x.snapshot = snap;
    x.nparams = @intCast(fields.len);
    for (fields, 0..) |f, k| switch (f) {
        .int => {
            const v: [*]usize = @ptrCast(@alignCast(c.shim_palloc(n * @sizeOf(usize))));
            for (reqs, 0..) |r, i| v[i] = @bitCast(r.ints[k]);
            x.params[k].values = v;
        },
        .text => {
            const t: [*]c.EngineText = @ptrCast(@alignCast(c.shim_palloc(n * @sizeOf(c.EngineText))));
            for (reqs, 0..) |r, i| t[i] = .{ .ptr = r.texts[k].ptr, .len = @intCast(r.texts[k].len) };
            x.params[k].texts = t;
        },
    };
    x.out = @ptrCast(@alignCast(c.shim_palloc(n * @sizeOf(c.EngineOut))));
    if (!c.shim_http_exec(&x)) {
        for (reqs) |r| reject(r, .internal, "internal error");
        return false;
    }
    for (reqs, 0..) |r, i| {
        const o = x.out[i];
        if (o.status == c.ST_OK) {
            var len: i32 = 0;
            const p = c.shim_text_ptr(o.body, &len);
            respond(r.conn, r.found, p[0..@intCast(len)]);
        } else switch (r.missing) {
            .unauthorized => fail(r.conn, .unauthorized, "unauthorized"),
            else => fail(r.conn, .not_found, "not found"),
        }
        finish(r);
    }
    return true;
}

fn refused(texts: []const []const u8) bool {
    for (texts) |t| if (std.mem.indexOfScalar(u8, t, 0) != null or !std.unicode.utf8ValidateSlice(t)) return true;
    return false;
}

// ---------------------------------------------------------------- sockets

const MAX_FDS = 1 << 18;
const LISTENER: u64 = std.math.maxInt(u64);
const HASHED: u64 = LISTENER - 1;
var conns: []?*Conn = &.{};

fn sysFail(rc: usize, what: []const u8) noreturn {
    var msg: [96:0]u8 = @splat(0);
    _ = std.fmt.bufPrint(msg[0 .. msg.len - 1], "pgengine http: {s} failed: {s}", .{ what, @tagName(linux.errno(rc)) }) catch {};
    c.shim_ereport_str(&msg);
}

fn check(rc: usize, what: []const u8) usize {
    if (linux.errno(rc) != .SUCCESS) sysFail(rc, what);
    return rc;
}

/// The listening socket and the JWT secret, from the launcher at `path`: one message whose bytes are the
/// secret, then "\0NAME=value" per setting the launcher forwards, and whose SCM_RIGHTS control message
/// carries the socket.
fn handoff(path: []const u8, body: *std.ArrayListUnmanaged(u8)) i32 {
    const s: i32 = @intCast(check(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0), "socket(AF_UNIX)"));
    defer _ = linux.close(s);
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= addr.path.len) c.shim_ereport_str("pgengine http: launcher socket path too long");
    @memcpy(addr.path[0..path.len], path);
    _ = check(linux.connect(s, @ptrCast(&addr), @sizeOf(linux.sockaddr.un)), "connect to the launcher");
    var data: [1024]u8 = undefined;
    var iov: [1]std.posix.iovec = .{.{ .base = &data, .len = data.len }};
    var ctl: [64]u8 align(8) = undefined;
    var msg: linux.msghdr = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = &ctl, .controllen = ctl.len, .flags = 0 };
    const n = check(linux.recvmsg(s, &msg, linux.MSG.CMSG_CLOEXEC), "recvmsg from the launcher");
    // struct cmsghdr { size_t len; int level; int type; } then the fd
    const len = std.mem.readInt(usize, ctl[0..8], .little);
    const level = std.mem.readInt(i32, ctl[8..12], .little);
    const typ = std.mem.readInt(i32, ctl[12..16], .little);
    if (msg.controllen < 20 or len < 20 or level != linux.SOL.SOCKET or typ != 1) // SCM_RIGHTS
        c.shim_ereport_str("pgengine http: the launcher sent no socket");
    body.appendSlice(gpa, data[0..n]) catch @panic("out of memory");
    return std.mem.readInt(i32, ctl[16..20], .little);
}

/// A setting the launcher forwarded from its env (launcher.c, `knobs`).
fn knob(setting: []const u8) void {
    const eq = std.mem.indexOfScalar(u8, setting, '=') orelse return;
    const name = setting[0..eq];
    const value = setting[eq + 1 ..];
    if (std.mem.eql(u8, name, "PGSERVE_HASH_NICE"))
        bcrypt.nice = std.fmt.parseInt(i32, value, 10) catch c.shim_ereport_str("pgengine http: PGSERVE_HASH_NICE is not an integer");
    if (std.mem.eql(u8, name, "PGSERVE_THIN_TO")) thin_to = std.mem.eql(u8, value, "1");
    if (std.mem.eql(u8, name, "PGSERVE_DWELL_US")) clock.dwell_ns = @as(i64, knobInt("PGSERVE_DWELL_US", value, 0, 50_000)) * std.time.ns_per_us;
    if (std.mem.eql(u8, name, "PGSERVE_DWELL_CAP")) clock.cap = knobInt("PGSERVE_DWELL_CAP", value, 1, 1 << 20);
    if (std.mem.eql(u8, name, "PGSERVE_DWELL_MIN")) clock.min = knobInt("PGSERVE_DWELL_MIN", value, 1, 1 << 20);
    if (std.mem.eql(u8, name, "PGSERVE_STATS_S")) stats.every_ns = @as(i64, knobInt("PGSERVE_STATS_S", value, 0, 86_400)) * std.time.ns_per_s;
    if (std.mem.eql(u8, name, "PGSERVE_SHED")) shed.enabled = std.mem.eql(u8, value, "1");
}

fn knobInt(comptime name: []const u8, value: []const u8, min: u32, max: u32) u32 {
    const v = std.fmt.parseInt(u32, value, 10) catch c.shim_ereport_str("pgengine http: " ++ name ++ " is not a whole number");
    if (v < min or v > max) c.shim_ereport_str("pgengine http: " ++ name ++ " is out of range");
    return v;
}

/// The batch clock and the stats, as the knobs set them.
var clock: Clock = .{};
var stats: Stats = .{};

/// PGSERVE_THIN_TO (default 1; 0 turns it off): TCP_THIN_LINEAR_TIMEOUTS on every connection. An answer is 2-3 segments, so the kernel
/// sees a thin stream and backs its retransmission timeout off linearly, not exponentially.
var thin_to = true;

fn watch(ep: i32, op: u32, fd: i32, events: u32, data: u64) void {
    var ev: linux.epoll_event = .{ .events = events, .data = .{ .u64 = data } };
    _ = linux.epoll_ctl(ep, op, fd, &ev);
}

fn acceptAll(ep: i32, lfd: i32) void {
    while (true) {
        const rc = linux.accept4(lfd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return;
        const fd: i32 = @intCast(rc);
        if (fd >= MAX_FDS) {
            _ = linux.close(fd);
            continue;
        }
        if (thin_to) _ = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.THIN_LINEAR_TIMEOUTS, std.mem.asBytes(&@as(i32, 1)), 4);
        const conn = gpa.create(Conn) catch @panic("out of memory");
        conn.* = .{ .fd = fd };
        conns[@intCast(fd)] = conn;
        watch(ep, linux.EPOLL.CTL_ADD, fd, linux.EPOLL.IN | linux.EPOLL.RDHUP, @intCast(fd));
    }
}

/// Reads what the socket holds into `inbuf`, after `conn.in`; false when the peer closed or the read failed.
fn readAll(conn: *Conn) bool {
    inbuf.clearRetainingCapacity();
    inbuf.appendSlice(gpa, conn.in) catch @panic("out of memory");
    gpa.free(conn.in);
    conn.in = &.{};
    while (true) {
        inbuf.ensureUnusedCapacity(gpa, 16 << 10) catch @panic("out of memory");
        const free = inbuf.unusedCapacitySlice();
        const rc = linux.read(conn.fd, free.ptr, free.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return false;
                inbuf.items.len += rc;
                if (rc < free.len) return true;
            },
            .AGAIN => return true,
            .INTR => {},
            else => return false,
        }
    }
}

/// The socket is readable: reads it, starts the next request, and keeps the bytes not yet started.
fn received(conn: *Conn, now: i64, t: *Turn) void {
    if (!readAll(conn)) conn.closed = true;
    const used = next(conn, inbuf.items, now, t);
    conn.in = own(inbuf.items[used..]);
    if (inbuf.capacity > inbuf_size) {
        inbuf.clearAndFree(gpa);
        inbuf.ensureTotalCapacityPrecise(gpa, inbuf_size) catch @panic("out of memory");
    }
}

/// Starts the next request from the bytes already received.
fn pump(conn: *Conn, now: i64, t: *Turn) void {
    const used = next(conn, conn.in, now, t);
    if (used == 0) return;
    const rest = own(conn.in[used..]);
    gpa.free(conn.in);
    conn.in = rest;
}

/// Starts the request at the front of `data` once its head and body are complete. Returns the bytes it used.
fn next(conn: *Conn, data: []const u8, now: i64, t: *Turn) usize {
    if (conn.req != null or conn.closed) return 0;
    switch (http.parseHead(data)) {
        .incomplete => return 0,
        .bad => {
            conn.keep_alive = false;
            fail(conn, .bad_request, "bad request");
            return data.len;
        },
        .head => |head| {
            if (head.content_length > max_body) {
                conn.keep_alive = false;
                fail(conn, .unprocessable, "body too large");
                return data.len;
            }
            const total = head.len + head.content_length;
            if (data.len < total) return 0;
            start(conn, &head, data[head.len..total], now, t);
            return total;
        },
    }
}

const max_body = 1 << 20;

/// Writes `conn.out`, or else its answer in `answers`, and keeps in `conn.out` what the socket would not take;
/// false when the connection failed.
fn flush(ep: i32, conn: *Conn) bool {
    const pending: []const u8 = if (conn.out.len > 0) conn.out else answerOf(conn);
    var sent: usize = 0;
    while (sent < pending.len) {
        const rc = linux.write(conn.fd, pending[sent..].ptr, pending.len - sent);
        switch (linux.errno(rc)) {
            .SUCCESS => sent += rc,
            .AGAIN => break,
            .INTR => {},
            else => return false,
        }
    }
    if (sent > 0 or conn.ans.len > 0) {
        const rest = own(pending[sent..]);
        gpa.free(conn.out);
        conn.out = rest;
        conn.ans = .{};
    }
    const waiting = conn.out.len > 0;
    if (waiting != conn.waiting) {
        const events: u32 = linux.EPOLL.IN | linux.EPOLL.RDHUP | @as(u32, if (waiting) linux.EPOLL.OUT else 0);
        watch(ep, linux.EPOLL.CTL_MOD, conn.fd, events, @intCast(conn.fd));
    }
    conn.waiting = waiting;
    return true;
}

fn close(conn: *Conn) void {
    _ = linux.close(conn.fd);
    conns[@intCast(conn.fd)] = null;
    if (conn.req) |r| {
        // a bcrypt thread still holds it; its answer frees it
        if (r.stage == .hash) r.orphan = true else destroy(r);
    }
    gpa.free(conn.in);
    gpa.free(conn.out);
    gpa.destroy(conn);
}

fn touch(conn: *Conn, touched: *std.ArrayListUnmanaged(*Conn)) void {
    if (conn.touched) return;
    conn.touched = true;
    touched.append(gpa, conn) catch @panic("out of memory");
}

// ---------------------------------------------------------------- the worker

fn wallSeconds() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

fn monoNs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return ts.sec * std.time.ns_per_s + ts.nsec;
}

/// epoll_wait for up to `ns`, to the nanosecond (epoll_pwait2, Linux 5.11): a dwell of 2 ms can't round to 1 or 3.
fn waitNs(ep: i32, events: []linux.epoll_event, ns: i64) usize {
    const ts: linux.timespec = .{ .sec = @divTrunc(ns, std.time.ns_per_s), .nsec = @rem(ns, std.time.ns_per_s) };
    return linux.syscall6(.epoll_pwait2, @as(u32, @bitCast(ep)), @intFromPtr(events.ptr), events.len, @intFromPtr(&ts), 0, linux.NSIG / 8);
}

/// Load shedding (PGSERVE_SHED, default 1; 0 turns it off): while this worker's loop is saturated, logins, sign-ups and
/// password changes get 503 instead of a bcrypt job. Saturated means a 1 s window with under 2% of it spent in
/// epoll_wait; it ends with a window above 10%, and no sooner than 10 s after it began. Each worker decides alone.
const Shed = struct {
    enabled: bool = true,
    /// When the current window began, and its ns spent in epoll_wait so far.
    window: i64 = 0,
    idle: i64 = 0,
    /// When shedding began; null while it is off.
    since: ?i64 = null,
    logged: i64 = 0,
    refused: std.EnumArray(Refused, u64) = .initFill(0),

    const Refused = enum { login, register, user_put };
    const window_ns = std.time.ns_per_s;

    /// Once per turn, with the ns the turn waited in epoll_wait with no turn work pending.
    fn tick(s: *Shed, now: i64, waited: i64) void {
        s.idle += waited;
        const span = now - s.window;
        if (span < window_ns) return;
        const idle = @as(f64, @floatFromInt(s.idle)) / @as(f64, @floatFromInt(span));
        s.window = now;
        s.idle = 0;
        const since = s.since orelse {
            if (idle < 0.02) {
                s.since = now;
                s.logged = now;
                log("pgserve[{d}]: shed on, idle {d:.1}%\n", .{ linux.getpid(), idle * 100 });
            }
            return;
        };
        if (idle > 0.10 and now - since >= 10 * window_ns) {
            s.report("shed off after", now, since, idle);
            s.since = null;
            s.refused = .initFill(0);
        } else if (now - s.logged >= 10 * window_ns) {
            s.logged = now;
            s.report("shed on", now, since, idle);
        }
    }

    fn report(s: *const Shed, what: []const u8, now: i64, since: i64, idle: f64) void {
        const n = s.refused.values;
        log("pgserve[{d}]: {s} {d:.1}s, refused {d} (login {d}, register {d}, user_put {d}), idle {d:.1}%\n", .{
            linux.getpid(), what, @as(f64, @floatFromInt(now - since)) / 1e9, n[0] + n[1] + n[2], n[0], n[1], n[2], idle * 100,
        });
    }
};
var shed: Shed = .{};

fn log(comptime fmt: []const u8, args: anytype) void {
    if (@import("builtin").is_test) return;
    std.debug.print(fmt, args);
}

fn refuse(r: *Req, k: Shed.Refused) void {
    shed.refused.getPtr(k).* += 1;
    reject(r, .unavailable, "server busy");
}

/// The worker's loop, from pgengine_http_main once it has joined the database. `launcher` is the Unix
/// socket path pgserve's launcher listens on.
export fn engine_http_serve(launcher: [*:0]const u8) callconv(.c) void {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    const lfd = handoff(std.mem.span(launcher), &body);
    var fields = std.mem.splitScalar(u8, body.items, 0);
    jwt.init(fields.first());
    while (fields.next()) |setting| knob(setting);
    // with neither the clock nor the stats on, no turn reads the clock (a syscall where the vDSO can't read it)
    const timed = clock.dwell_ns > 0 or stats.every_ns > 0;
    var mono: i64 = if (timed) monoNs() else 0;
    stats.from = mono;
    {
        var line: [128:0]u8 = @splat(0);
        _ = std.fmt.bufPrint(line[0 .. line.len - 1], "pgengine http: dwell {d} us, cap {d}, min {d}, stats every {d} s", .{
            @divTrunc(clock.dwell_ns, std.time.ns_per_us), clock.cap, clock.min, @divTrunc(stats.every_ns, std.time.ns_per_s),
        }) catch {};
        c.shim_log(&line);
    }
    startHashers();
    conns = gpa.alloc(?*Conn, MAX_FDS) catch @panic("out of memory");
    @memset(conns, null);
    inbuf.ensureTotalCapacityPrecise(gpa, inbuf_size) catch @panic("out of memory");
    const ep: i32 = @intCast(check(linux.epoll_create1(linux.EPOLL.CLOEXEC), "epoll_create1"));
    _ = linux.fcntl(lfd, linux.F.SETFL, linux.SOCK.NONBLOCK);
    watch(ep, linux.EPOLL.CTL_ADD, lfd, linux.EPOLL.IN, LISTENER);
    watch(ep, linux.EPOLL.CTL_ADD, bcrypt.done_efd, linux.EPOLL.IN, HASHED);
    var events: [1024]linux.epoll_event = undefined;
    var t: Turn = .{};
    // connections with a request or an answer left over from the last turn, touched again this one
    var carry: std.ArrayListUnmanaged(*Conn) = .empty;
    shed.window = monoNs();
    while (true) {
        c.shim_check_interrupts();
        const busy = carry.items.len > 0 or t.pending();
        const waiting = if (shed.enabled) monoNs() else 0;
        // a held turn sleeps until its deadline, unless an answer is waiting to go out
        const rc = if (carry.items.len == 0 and t.pending() and clock.due(&t, mono) == null)
            waitNs(ep, &events, clock.deadline(&t) - mono)
        else
            linux.epoll_wait(ep, &events, events.len, if (busy) 0 else 1000);
        if (shed.enabled) {
            const woke = monoNs();
            // idle is only a wait with no turn work pending; a held turn's sleep is busy
            shed.tick(woke, if (busy) 0 else woke - waiting);
        }
        const got: usize = if (linux.errno(rc) == .SUCCESS) rc else 0;
        const now = wallSeconds();
        if (timed) mono = monoNs();
        std.mem.swap(std.ArrayListUnmanaged(*Conn), &t.touched, &carry);
        carry.clearRetainingCapacity();
        for (events[0..got]) |ev| {
            switch (ev.data.u64) {
                LISTENER => {
                    acceptAll(ep, lfd);
                    continue;
                },
                HASHED => {
                    var count: u64 = 0;
                    _ = linux.read(bcrypt.done_efd, std.mem.asBytes(&count), 8);
                    var j = bcrypt.finished();
                    while (j) |job| {
                        j = job.next;
                        hashed(job, &t);
                    }
                    continue;
                },
                else => {},
            }
            const conn = conns[@intCast(ev.data.u64)] orelse continue;
            if (ev.events & linux.EPOLL.OUT != 0 and !flush(ep, conn)) conn.closed = true;
            if (ev.events & (linux.EPOLL.IN | linux.EPOLL.RDHUP | linux.EPOLL.HUP | linux.EPOLL.ERR) != 0)
                received(conn, now, &t);
            touch(conn, &t.touched);
        }
        t.date(mono);
        if (t.pending()) if (clock.due(&t, mono)) |why| {
            const n = t.n;
            stats.fires.getPtr(why).* += 1;
            stats.waited_ns += @intCast(mono - t.since.?);
            t.touchAll();
            // writes first, in one transaction, so the reads that answer them see them
            if (t.writes.items.len > 0) {
                stats.writes.add(t.writes.items.len);
                c.shim_write_begin();
                for (t.writes.items) |r| c.shim_write(&r.w);
                // before the commit: the rows' texts live in SPI memory until then
                for (t.writes.items) |r| written(r, &t);
                c.shim_write_end();
                t.writes.clearRetainingCapacity();
            }
            var any = false;
            for (t.reads) |l| any = any or l.items.len > 0;
            if (any) {
                var snap = c.shim_http_begin();
                for (&t.reads, &stats.reads, 0..) |*l, *h, k| if (l.items.len > 0) {
                    h.add(l.items.len);
                    if (!runReads(@intCast(k), l.items, snap)) snap = c.shim_http_begin();
                    l.clearRetainingCapacity();
                };
                c.shim_http_end();
            }
            t.n = 0;
            t.since = null;
            clock.fired(n);
        };
        for (t.touched.items) |conn| {
            conn.touched = false;
            if (!conn.closed and !flush(ep, conn)) conn.closed = true;
            if (!conn.keep_alive and conn.req == null and conn.out.len == 0) conn.closed = true;
            if (conn.closed) {
                if (conn.req) |r| t.drop(r);
                close(conn);
                continue;
            }
            // its next request may be in the buffer already; an answer to it goes out next turn
            pump(conn, now, &t);
            if (conn.ans.len > 0) stash(conn);
            // a connection waiting for EPOLLOUT is woken by it; carrying it would spin the loop at timeout 0
            if (conn.out.len > 0 and !conn.waiting) touch(conn, &carry);
        }
        t.date(mono);
        if (stats.every_ns > 0 and mono - stats.from >= stats.every_ns) {
            stats.log(mono);
            stats = .{ .from = mono, .every_ns = stats.every_ns };
        }
        // one turn of unusually large answers must not stay allocated for the worker's life
        if (answers.capacity > answers_keep) answers.clearAndFree(gpa) else answers.clearRetainingCapacity();
    }
}

/// One bcrypt thread per worker, with every signal blocked: Postgres's handlers must run on the worker's
/// own thread, the only one that may touch the backend.
fn startHashers() void {
    var old: std.posix.sigset_t = undefined;
    const all = std.posix.sigfillset();
    std.posix.sigprocmask(linux.SIG.SETMASK, &all, &old);
    bcrypt.start(1) catch c.shim_ereport_str("pgengine http: starting the bcrypt thread failed");
    std.posix.sigprocmask(linux.SIG.SETMASK, &old, null);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// A connection on one end of a socket pair, with the test as the client on the other.
const Pair = struct {
    conn: Conn,
    peer: i32,
    t: Turn = .{},

    fn init() !Pair {
        var fds: [2]i32 = undefined;
        if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK, 0, &fds)) != .SUCCESS)
            return error.SocketPair;
        return .{ .conn = .{ .fd = fds[0] }, .peer = fds[1] };
    }

    fn deinit(p: *Pair) void {
        _ = linux.close(p.conn.fd);
        _ = linux.close(p.peer);
        gpa.free(p.conn.in);
        gpa.free(p.conn.out);
        for (&p.t.reads) |*l| l.deinit(gpa);
        answers.clearRetainingCapacity();
    }

    fn send(p: *Pair, bytes: []const u8) !void {
        if (linux.write(p.peer, bytes.ptr, bytes.len) != bytes.len) return error.ShortWrite;
    }

    /// Everything the server end has written so far.
    fn recv(p: *Pair, into: *std.ArrayListUnmanaged(u8)) !void {
        while (true) {
            try into.ensureUnusedCapacity(gpa, 64 << 10);
            const free = into.unusedCapacitySlice();
            const rc = linux.read(p.peer, free.ptr, free.len);
            if (linux.errno(rc) == .AGAIN) return;
            if (linux.errno(rc) != .SUCCESS or rc == 0) return error.Read;
            into.items.len += rc;
        }
    }

    fn expectAnswer(p: *Pair, want: []const u8) !void {
        var got: std.ArrayListUnmanaged(u8) = .empty;
        defer got.deinit(gpa);
        try p.recv(&got);
        try testing.expectEqualStrings(want, got.items);
    }

    /// Answers the request being served with the tags read's body, as the turn would.
    fn answerTags(p: *Pair) void {
        respond(&p.conn, .ok, "{\"tags\":[]}");
        finish(p.conn.req.?);
        for (&p.t.reads) |*l| l.clearRetainingCapacity();
        p.t.n = 0;
        p.t.since = null;
    }
};

const tags_answer = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"tags\":[]}";

test "a request split across two reads starts once it is whole, and the connection keeps no buffer" {
    var p = try Pair.init();
    defer p.deinit();
    try p.send("GET /api/ta");
    received(&p.conn, 0, &p.t);
    try testing.expect(p.conn.req == null);
    try testing.expectEqualStrings("GET /api/ta", p.conn.in);
    try p.send("gs HTTP/1.1\r\nHost: x\r\n\r\n");
    received(&p.conn, 0, &p.t);
    try testing.expectEqual(1, p.t.reads[@intCast(c.EP_TAGS)].items.len);
    try testing.expectEqual(0, p.conn.in.len);
    p.answerTags();
    try testing.expect(flush(-1, &p.conn));
    try p.expectAnswer(tags_answer);
    try testing.expectEqual(0, p.conn.out.len);
}

test "pipelined requests in one read are answered one at a time, in order" {
    var p = try Pair.init();
    defer p.deinit();
    const second = "GET /api/nope HTTP/1.1\r\n\r\n";
    try p.send("GET /api/tags HTTP/1.1\r\n\r\n" ++ second);
    received(&p.conn, 0, &p.t);
    try testing.expectEqual(1, p.t.reads[@intCast(c.EP_TAGS)].items.len);
    try testing.expectEqualStrings(second, p.conn.in);
    p.answerTags();
    try testing.expect(flush(-1, &p.conn));
    try p.expectAnswer(tags_answer);
    // the turn's end: the second starts from the kept bytes, and its answer waits for the next turn
    pump(&p.conn, 0, &p.t);
    stash(&p.conn);
    answers.clearRetainingCapacity();
    try testing.expectEqual(0, p.conn.in.len);
    try testing.expect(flush(-1, &p.conn));
    try p.expectAnswer("HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: 33\r\n\r\n" ++
        "{\"errors\":{\"body\":[\"not found\"]}}");
    try testing.expectEqual(0, p.conn.out.len);
}

test "a request that isn't HTTP gets 400 and Connection: close" {
    var p = try Pair.init();
    defer p.deinit();
    try p.send("hello\r\n\r\nGET /api/tags HTTP/1.1\r\n\r\n");
    received(&p.conn, 0, &p.t);
    try testing.expect(!p.conn.keep_alive);
    try testing.expectEqual(0, p.conn.in.len);
    try testing.expect(flush(-1, &p.conn));
    try p.expectAnswer("HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 35\r\n" ++
        "Connection: close\r\n\r\n{\"errors\":{\"body\":[\"bad request\"]}}");
}

test "an answer the socket can't take at once is kept until it is sent, then freed" {
    var p = try Pair.init();
    defer p.deinit();
    const body = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(body);
    @memset(body, 'x');
    respond(&p.conn, .ok, body);
    try testing.expect(flush(-1, &p.conn));
    try testing.expect(p.conn.out.len > 0 and p.conn.waiting);
    try testing.expectEqual(0, p.conn.ans.len);
    answers.clearRetainingCapacity();
    var got: std.ArrayListUnmanaged(u8) = .empty;
    defer got.deinit(gpa);
    while (p.conn.out.len > 0) {
        try p.recv(&got);
        try testing.expect(flush(-1, &p.conn));
    }
    try p.recv(&got);
    try testing.expect(!p.conn.waiting);
    const head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 1048576\r\n\r\n";
    try testing.expectEqualStrings(head, got.items[0..head.len]);
    try testing.expect(std.mem.eql(u8, body, got.items[head.len..]));
}

test "a held turn runs at its deadline or at its cap; a dwell of 0 or a cold clock runs it at once" {
    var p = try Pair.init();
    defer p.deinit();
    var k: Clock = .{ .dwell_ns = 10 * std.time.ns_per_ms, .cap = 2 };
    try p.send("GET /api/tags HTTP/1.1\r\n\r\n");
    received(&p.conn, 0, &p.t);
    p.t.date(1000);
    try testing.expectEqual(.now, k.due(&p.t, 1000).?);
    k.fired(1);
    try testing.expectEqual(.now, k.due(&p.t, 1000).?);
    k.fired(2);
    try testing.expectEqual(null, k.due(&p.t, 1000));
    try testing.expectEqual(null, k.due(&p.t, 1000 + 10 * std.time.ns_per_ms - 1));
    try testing.expectEqual(.deadline, k.due(&p.t, 1000 + 10 * std.time.ns_per_ms).?);
    p.t.n = 2;
    try testing.expectEqual(.cap, k.due(&p.t, 1000).?);
    p.t.n = 1;
    k.dwell_ns = 0;
    try testing.expectEqual(.now, k.due(&p.t, 1000).?);
    p.answerTags();
}

test "a connection that closes while its turn is held takes its request off the turn" {
    var a = try Pair.init();
    defer a.deinit();
    var b = try Pair.init();
    defer b.deinit();
    try a.send("GET /api/tags HTTP/1.1\r\n\r\n");
    try b.send("GET /api/tags HTTP/1.1\r\n\r\n");
    received(&a.conn, 0, &a.t);
    received(&b.conn, 0, &a.t);
    a.t.date(5);
    const tags = &a.t.reads[@intCast(c.EP_TAGS)];
    try testing.expectEqual(2, a.t.n);
    a.t.drop(a.conn.req.?);
    destroy(a.conn.req.?);
    a.conn.req = null;
    try testing.expectEqual(1, a.t.n);
    try testing.expectEqual(5, a.t.since.?);
    try testing.expectEqual(&b.conn, tags.items[0].conn);
    a.t.drop(b.conn.req.?);
    destroy(b.conn.req.?);
    b.conn.req = null;
    try testing.expectEqual(0, a.t.n);
    try testing.expectEqual(null, a.t.since);
    try testing.expectEqual(0, tags.items.len);
}

test "batch sizes by batch and by request" {
    var h: Hist = .{};
    for (0..9) |_| h.add(1);
    h.add(100);
    try testing.expectEqual(10, h.count());
    try testing.expectEqual(109, h.reqs);
    try testing.expectEqual(1, h.quantile(0.5, false));
    try testing.expectEqual(1, h.quantile(0.9, false));
    // 100 lands in the 64-127 bucket: by request, most requests were served in it
    try testing.expectEqual(64, h.quantile(0.5, true));
    try testing.expectEqual(Hist.bucket(1 << 20), Hist.bucket(1 << 15));
}

test "while shedding, a login, a sign-up and a password change get 503 and the connection stays open" {
    var p = try Pair.init();
    defer p.deinit();
    shed.since = 0;
    defer shed = .{};
    jwt.init("secret");
    var tok: [256]u8 = undefined;
    const token = jwt.issue(1, wallSeconds(), &tok);
    const login_body = "{\"user\":{\"email\":\"a@b.c\",\"password\":\"password123\"}}";
    const register_body = "{\"user\":{\"username\":\"a\",\"email\":\"a@b.c\",\"password\":\"password123\"}}";
    const put_body = "{\"user\":{\"password\":\"password456\"}}";
    var put: [512]u8 = undefined;
    const requests = [_][]const u8{
        std.fmt.comptimePrint("POST /api/users/login HTTP/1.1\r\nContent-Length: {d}\r\n\r\n{s}", .{ login_body.len, login_body }),
        std.fmt.comptimePrint("POST /api/users HTTP/1.1\r\nContent-Length: {d}\r\n\r\n{s}", .{ register_body.len, register_body }),
        try std.fmt.bufPrint(&put, "PUT /api/user HTTP/1.1\r\nAuthorization: Token {s}\r\nContent-Length: {d}\r\n\r\n{s}", .{
            token, put_body.len, put_body,
        }),
    };
    for (requests) |req| {
        try p.send(req);
        received(&p.conn, wallSeconds(), &p.t);
        try testing.expect(p.conn.req == null and p.conn.keep_alive);
        try testing.expect(flush(-1, &p.conn));
        try p.expectAnswer("HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: 35\r\n\r\n" ++
            "{\"errors\":{\"body\":[\"server busy\"]}}");
        answers.clearRetainingCapacity();
    }
    try testing.expectEqualSlices(u64, &.{ 1, 1, 1 }, &shed.refused.values);
    try testing.expectEqual(0, p.t.writes.items.len);
}

test "with shedding off, a login is queued as usual" {
    var p = try Pair.init();
    defer p.deinit();
    defer p.t.writes.deinit(gpa);
    const body = "{\"user\":{\"email\":\"a@b.c\",\"password\":\"password123\"}}";
    try p.send(std.fmt.comptimePrint("POST /api/users/login HTTP/1.1\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body }));
    received(&p.conn, 0, &p.t);
    try testing.expectEqual(1, p.t.writes.items.len);
    finish(p.conn.req.?);
}

test "shedding starts on a window under 2% idle and ends on one above 10%, no sooner than 10 s on" {
    var s: Shed = .{};
    const sec = std.time.ns_per_s;
    s.tick(sec / 2, sec / 2);
    try testing.expect(s.since == null);
    s.tick(sec, 0);
    try testing.expect(s.since == null);
    s.tick(2 * sec, sec / 100);
    try testing.expectEqual(2 * sec, s.since.?);
    s.tick(7 * sec, 5 * sec);
    try testing.expect(s.since != null);
    s.tick(13 * sec, sec / 20);
    try testing.expect(s.since != null);
    s.tick(14 * sec, sec / 2);
    try testing.expect(s.since == null);
}
