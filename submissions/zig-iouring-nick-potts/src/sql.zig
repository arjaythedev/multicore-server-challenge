//! Every SQL statement the server runs, with its parameter and result types. The texts live in `sql/<NAME>.sql`,
//! one file per statement, named like the SQL packs' statements (LIST_ALL, ARTICLE_BY_SLUG, FAVORITE, ...), so a
//! statement or a whole family can be swapped by replacing files. A statement batched by hand instead of the
//! generic wrap reads its `sql/BATCH_<NAME>.sql` into `batched`.
//!
//! The texts start from #7 (rust-tokio-Scooter1337, rank 1): list page + capped count in one statement, tag names
//! by primary key, the write CTEs that fold the slug lookup into the mutation. Each statement is prepared once per
//! connection, and startup refuses to serve unless every one prepares and describes exactly these result types.
//! `$1` is the viewer (0 = anonymous) wherever `favorited` / `following` are computed.
const std = @import("std");
const threads = @import("threads.zig");

pub const Oid = enum(u32) {
    bool = 16,
    int8 = 20,
    int4 = 23,
    text = 25,
    timestamptz = 1184,
    int4_array = 1007,
    text_array = 1009,
    int8_array = 1016,
    _,
};

/// How a statement may be combined across queued requests.
pub const Batch = enum {
    /// Always one execution per request.
    none,
    /// Queued requests run as one execution of the batched form, which takes one array per parameter, in order,
    /// and returns `cols` and then the request's 1-based ordinal: `batched` when set, else the generic
    /// `unnest(...) WITH ORDINALITY CROSS JOIN LATERAL (stmt)` wrap.
    arrays,
    /// No parameters and viewer-independent: one execution answers every request already waiting.
    broadcast,
};

pub const Def = struct {
    sql: []const u8,
    params: []const Oid,
    cols: []const Oid,
    write: bool = false,
    batch: Batch = .none,
    /// Extra ORDER BY keys after the request ordinal in the generic batched form.
    order: []const u8 = "",
    /// A batched form written by hand (`sql/BATCH_<NAME>.sql`), used instead of the generic wrap.
    batched: ?[]const u8 = null,
    /// The batched form's columns when it returns each distinct thread once instead of `cols` and the ordinal per
    /// request; threads.zig rebuilds each request's rows.
    thread_cols: ?[]const Oid = null,
    /// How the statement's requests ride in the mega statement; null: never.
    mega: ?Mega = null,
};

/// MEGA (branch sql-stack, stack-14-fcset: sql-proto's MEGA2 with the stack's count, feed, tag, list-count, list-flag and favorite-count edits, without comments):
/// every mega-able read of a drain in one execution. It takes one array element per read in six arrays, kind int4
/// and the slots v, i1, i2, i3 int8 and t1 text, and returns the read's 1-based position as the last column. Each
/// article comes once, as an entity row with ordinal -1 keyed by `keys`. A slug or by-id read's row carries its key
/// and viewer flags. A list read comes as one row: its count and the page's article ids, their authors, and the
/// viewer's favorites and followees among them as int8 arrays (`page`); mega.zig turns it into one row per article
/// with the flags (a feed row's followees array is NULL: the feed only holds followed authors, so following is true).
/// Comments, tags, profiles and users stay out of it, so the article is the only entity type.
pub const mega = struct {
    pub const sql = std.mem.trimEnd(u8, @embedFile("sql/MEGA.sql"), "\n; ");
    pub const params = [_]Oid{ .int4_array, .int8_array, .int8_array, .int8_array, .int8_array, .text_array };
    pub const cols = [_]Oid{ .int8, .int8, .text, .text, .text, .text, .timestamptz, .timestamptz, .text_array, .int8, .bool, .text, .text, .text, .bool, .int8_array, .int8_array, .int8_array, .int8_array, .int8 };
    pub const keys = [_]u8{1};
    pub const ordinal = cols.len - 1;
    /// A list read's page arrays and the columns filled per article from them.
    pub const page = struct {
        pub const ids = 15;
        pub const aus = 16;
        pub const fa = 17;
        pub const fw = 18;
        pub const id = 1;
        pub const favorited = 10;
        pub const following = 14;
    };
};

pub const Slot = enum { v, i1, i2, i3, t1 };

pub const Mega = struct {
    kind: i32,
    /// The slot of each parameter. The viewer goes in `v` as NULL when anonymous.
    args: []const Slot,
    /// The mega column of each of the statement's result columns.
    cols: []const u8,
    /// The entity type whose row fills the read's NULL columns, matched on its key column; 0: none.
    fill: u8 = 0,
    /// Result columns (the statement's numbering) the read's rows are sorted on, each descending, NULL last.
    order: []const u8 = &.{},
};

pub const Stmt = enum(u8) {
    list_all,
    list_tag,
    list_author,
    list_favorited,
    list_feed,
    article_by_slug,
    article_by_id,
    comments_list_set,
    profile,
    user_by_id,
    user_by_email,
    tags,
    favorite,
    unfavorite,
    article_create,
    article_update,
    article_delete,
    comment_create,
    comment_delete,
    follow,
    unfollow,
    user_insert,
    user_update,

    pub fn def(s: Stmt) *const Def {
        return &defs[@intFromEnum(s)];
    }
};

pub const count = @typeInfo(Stmt).@"enum".field_names.len;

const list_cols = [_]Oid{ .int8, .int8, .text, .text, .text, .timestamptz, .timestamptz, .text_array, .int8, .bool, .text, .text, .text, .bool };
const full_cols = [_]Oid{ .int8, .text, .text, .text, .text, .timestamptz, .timestamptz, .text_array, .int8, .bool, .text, .text, .text, .bool };
const user_cols = [_]Oid{ .int8, .text, .text, .text, .text };
const list_params = [_]Oid{ .int8, .int8, .int8, .text };

const list_mega_cols = [_]u8{ 0, 1, 2, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14 };
const full_mega_cols = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 };
fn listMega(kind: i32, args: []const Slot) Mega {
    return .{ .kind = kind, .args = args, .cols = &list_mega_cols, .fill = 1, .order = &.{1} };
}

/// The text of `s`: `sql/<NAME>.sql`, where NAME is the statement's name in capitals.
fn text(comptime s: Stmt) []const u8 {
    return file("", s);
}

/// The hand-written batched form of `s`: `sql/BATCH_<NAME>.sql`.
fn batchText(comptime s: Stmt) []const u8 {
    return file("BATCH_", s);
}

fn file(comptime prefix: []const u8, comptime s: Stmt) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var name: [@tagName(s).len]u8 = undefined;
        _ = std.ascii.upperString(&name, @tagName(s));
        return std.mem.trimEnd(u8, @embedFile("sql/" ++ prefix ++ name ++ ".sql"), "\n; ");
    }
}

// Result columns, in order:
//   lists:   articlesCount, then per article id, slug, title, description, created_at, updated_at, tags, favorites
//            count, favorited, username, bio, image, following (one row of NULL article columns for an empty page)
//   article: id, slug, title, description, body, created_at, updated_at, tags, favorites count, favorited, username,
//            bio, image, following
// Notes on the texts:
//   LIST_ALL counts by walking the primary key from the oldest end: those pages are frozen and all-visible, so it
//   stays an index-only scan while new articles keep the newest pages dirty (#7).
//   COMMENTS_LIST_SET returns up to 100 comments newest first (one row of NULL comment columns when there are
//   none; no row means no article): comment id, body, created_at, updated_at, username, bio, image, following.
//   Its batched form reads each distinct article's thread once, in that order (a parameterized LATERAL, which the
//   plan can only run as a nested loop's inner side: sql-articlepage's contract), after one row per request with
//   the viewer's followee ids; threads.zig hands every request its thread's rows.
//   USER_BY_EMAIL stays out of MEGA: it reads the password hash. PROFILE, USER_BY_ID and TAGS stay out too: each is
//   a few index lookups, so they run as units of their own ahead of MEGA and are answered before it runs.
const defs = [count]Def{
    // lists (branch sql-lists)
    .{ .sql = text(.list_all), .params = &.{ .int8, .int8, .int8 }, .cols = &list_cols, .batch = .arrays, .order = ", q.id DESC", .mega = listMega(1, &.{ .v, .i1, .i2 }) },
    .{ .sql = text(.list_tag), .params = &list_params, .cols = &list_cols, .batch = .arrays, .order = ", q.id DESC", .mega = listMega(2, &.{ .v, .i1, .i2, .t1 }) },
    .{ .sql = text(.list_author), .params = &list_params, .cols = &list_cols, .batch = .arrays, .order = ", q.id DESC", .mega = listMega(3, &.{ .v, .i1, .i2, .t1 }) },
    .{ .sql = text(.list_favorited), .params = &list_params, .cols = &list_cols, .batch = .arrays, .order = ", q.id DESC", .mega = listMega(4, &.{ .v, .i1, .i2, .t1 }) },
    // feed (branch sql-feed)
    .{ .sql = text(.list_feed), .params = &.{ .int8, .int8, .int8, .int8 }, .cols = &list_cols, .batch = .arrays, .order = ", q.id DESC", .mega = listMega(5, &.{ .v, .i1, .i2, .i3 }) },
    // article page (branch sql-articlepage)
    .{ .sql = text(.article_by_slug), .params = &.{ .int8, .text }, .cols = &full_cols, .batch = .arrays, .mega = .{ .kind = 6, .args = &.{ .v, .t1 }, .cols = &full_mega_cols, .fill = 1 } },
    .{ .sql = text(.article_by_id), .params = &.{ .int8, .int8 }, .cols = &full_cols, .batch = .arrays, .mega = .{ .kind = 7, .args = &.{ .v, .i1 }, .cols = &full_mega_cols, .fill = 1 } },
    .{ .sql = text(.comments_list_set), .params = &.{ .int8, .text }, .cols = &.{ .int8, .text, .timestamptz, .timestamptz, .text, .text, .text, .bool }, .batch = .arrays, .batched = batchText(.comments_list_set), .thread_cols = &threads.cols },
    .{ .sql = text(.profile), .params = &.{ .int8, .text }, .cols = &.{ .text, .text, .text, .bool }, .batch = .arrays },
    // users and tags
    .{ .sql = text(.user_by_id), .params = &.{.int8}, .cols = &user_cols, .batch = .arrays },
    .{ .sql = text(.user_by_email), .params = &.{.text}, .cols = &.{ .int8, .text, .text, .text, .text, .text }, .batch = .arrays, .batched = batchText(.user_by_email) },
    .{ .sql = text(.tags), .params = &.{}, .cols = &.{.text_array}, .batch = .broadcast },
    // writes (branch sql-writes): a group's writes of one of these statements share one execution of its batched form
    .{ .write = true, .sql = text(.favorite), .params = &.{ .int8, .text }, .cols = &.{.int8}, .batch = .arrays, .batched = batchText(.favorite) },
    .{ .write = true, .sql = text(.unfavorite), .params = &.{ .int8, .text }, .cols = &.{.int8}, .batch = .arrays, .batched = batchText(.unfavorite) },
    .{ .write = true, .sql = text(.article_create), .params = &.{ .int8, .text, .text, .text, .text_array }, .cols = &full_cols },
    .{ .write = true, .sql = text(.article_update), .params = &.{ .text, .text, .text, .text, .int8 }, .cols = &.{ .int8, .int8, .int8 } },
    .{ .write = true, .sql = text(.article_delete), .params = &.{ .text, .int8 }, .cols = &.{.int8} },
    .{ .write = true, .sql = text(.comment_create), .params = &.{ .text, .int8, .text }, .cols = &.{ .int8, .text, .timestamptz, .timestamptz, .text, .text, .text }, .batch = .arrays, .batched = batchText(.comment_create) },
    .{ .write = true, .sql = text(.comment_delete), .params = &.{ .int8, .text, .int8 }, .cols = &.{.int8} },
    .{ .write = true, .sql = text(.follow), .params = &.{ .int8, .text }, .cols = &.{ .text, .text, .text }, .batch = .arrays, .batched = batchText(.follow) },
    .{ .write = true, .sql = text(.unfollow), .params = &.{ .int8, .text }, .cols = &.{ .text, .text, .text }, .batch = .arrays, .batched = batchText(.unfollow) },
    .{ .write = true, .sql = text(.user_insert), .params = &.{ .text, .text, .text }, .cols = &user_cols },
    .{ .write = true, .sql = text(.user_update), .params = &.{ .int8, .text, .text, .text, .text, .text }, .cols = &user_cols },
};

/// Statements that can fail on data (unique violations) run alone, so their failure never rolls back a group.
pub fn fallible(s: Stmt) bool {
    return s == .user_insert or s == .user_update;
}

/// The batched form: `$n` becomes `r.pn`, the request rows come from unnest of one array per parameter.
pub fn batchedSql(gpa: std.mem.Allocator, s: Stmt) ![]u8 {
    const d = s.def();
    if (d.batched) |b| return gpa.dupe(u8, b);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(gpa, "SELECT q.*, r.ord FROM unnest(");
    for (d.params, 0..) |p, i| {
        if (i > 0) try out.append(gpa, ',');
        try out.print(gpa, "${d}::{s}", .{ i + 1, switch (p) {
            .int8 => "int8[]",
            .text => "text[]",
            else => unreachable,
        } });
    }
    try out.appendSlice(gpa, ") WITH ORDINALITY AS r(");
    for (d.params, 0..) |_, i| try out.print(gpa, "p{d},", .{i + 1});
    try out.appendSlice(gpa, "ord) CROSS JOIN LATERAL (");
    var i: usize = 0;
    while (i < d.sql.len) {
        if (d.sql[i] == '$') {
            var j = i + 1;
            while (j < d.sql.len and std.ascii.isDigit(d.sql[j])) j += 1;
            try out.appendSlice(gpa, "r.p");
            try out.appendSlice(gpa, d.sql[i + 1 .. j]);
            i = j;
        } else {
            try out.append(gpa, d.sql[i]);
            i += 1;
        }
    }
    try out.appendSlice(gpa, ") q ORDER BY r.ord");
    try out.appendSlice(gpa, d.order);
    return out.toOwnedSlice(gpa);
}

pub fn batchedCols(gpa: std.mem.Allocator, s: Stmt) ![]Oid {
    const d = s.def();
    if (d.thread_cols) |t| return gpa.dupe(Oid, t);
    const cols = try gpa.alloc(Oid, d.cols.len + 1);
    @memcpy(cols[0..d.cols.len], d.cols);
    cols[d.cols.len] = .int8;
    return cols;
}

pub fn arrayOid(p: Oid) Oid {
    return switch (p) {
        .int8 => .int8_array,
        .text => .text_array,
        else => unreachable,
    };
}
