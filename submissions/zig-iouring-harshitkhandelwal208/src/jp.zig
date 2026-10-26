//! Strict JSON request-body reader for the handful of shapes the API accepts:
//! `{"<wrapper>": {<known fields>}}`. Everything else in the document is validated and skipped.
const std = @import("std");
const Scratch = @import("scratch.zig").Scratch;

pub const Error = error{ Invalid, OutOfMemory };

pub const Kind = enum { absent, null, string, number, other, strings };

pub const Field = struct {
    kind: Kind = .absent,
    s: []const u8 = "",
    /// For `.strings`: each element is a string.
    list: []const []const u8 = &.{},
};

const max_depth = 64;

const P = struct {
    src: []const u8,
    pos: usize = 0,
    sc: *Scratch,

    inline fn ws(p: *P) void {
        while (p.pos < p.src.len) : (p.pos += 1) {
            switch (p.src[p.pos]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    inline fn peek(p: *P) ?u8 {
        return if (p.pos < p.src.len) p.src[p.pos] else null;
    }

    fn expect(p: *P, c: u8) Error!void {
        if (p.peek() != c) return error.Invalid;
        p.pos += 1;
    }

    /// Parses a string starting at the opening quote. Returns a slice into the source when no escapes are present.
    fn string(p: *P) Error![]const u8 {
        try p.expect('"');
        const start = p.pos;
        // Fast scan: find the closing quote or a backslash; reject raw control characters.
        var i = start;
        while (i < p.src.len) : (i += 1) {
            const c = p.src[i];
            if (c == '"') {
                p.pos = i + 1;
                const s = p.src[start..i];
                if (!std.unicode.utf8ValidateSlice(s)) return error.Invalid;
                return s;
            }
            if (c == '\\') break;
            if (c < 0x20) return error.Invalid;
        }
        if (i >= p.src.len) return error.Invalid;
        // Slow path: unescape into scratch memory. The string ends at the first quote that no backslash escapes, and an
        // escape never decodes to more bytes than it takes, so that length is enough.
        var end = i;
        while (end < p.src.len and p.src[end] != '"') end += if (p.src[end] == '\\') 2 else 1;
        if (end >= p.src.len) return error.Invalid;
        var out = try p.sc.alloc(end - start);
        var n: usize = 0;
        @memcpy(out[0 .. i - start], p.src[start..i]);
        n = i - start;
        while (i < p.src.len) {
            const c = p.src[i];
            if (c == '"') {
                p.pos = i + 1;
                const s = out[0..n];
                if (!std.unicode.utf8ValidateSlice(s)) return error.Invalid;
                return s;
            }
            if (c < 0x20) return error.Invalid;
            if (c != '\\') {
                out[n] = c;
                n += 1;
                i += 1;
                continue;
            }
            i += 1;
            if (i >= p.src.len) return error.Invalid;
            const e = p.src[i];
            i += 1;
            switch (e) {
                '"', '\\', '/' => {
                    out[n] = e;
                    n += 1;
                },
                'b' => {
                    out[n] = 8;
                    n += 1;
                },
                'f' => {
                    out[n] = 12;
                    n += 1;
                },
                'n' => {
                    out[n] = '\n';
                    n += 1;
                },
                'r' => {
                    out[n] = '\r';
                    n += 1;
                },
                't' => {
                    out[n] = '\t';
                    n += 1;
                },
                'u' => {
                    var cp: u21 = try hex4(p.src, i);
                    i += 4;
                    if (cp >= 0xD800 and cp < 0xDC00) {
                        // High surrogate: needs a following \uDC00..DFFF, else U+FFFD (as Go's decoder does).
                        if (i + 6 <= p.src.len and p.src[i] == '\\' and p.src[i + 1] == 'u') {
                            const lo = hex4(p.src, i + 2) catch 0;
                            if (lo >= 0xDC00 and lo < 0xE000) {
                                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                                i += 6;
                            } else cp = 0xFFFD;
                        } else cp = 0xFFFD;
                    } else if (cp >= 0xDC00 and cp < 0xE000) cp = 0xFFFD;
                    n += std.unicode.utf8Encode(cp, out[n..]) catch return error.Invalid;
                },
                else => return error.Invalid,
            }
        }
        return error.Invalid;
    }

    /// Validates a string and moves past it without decoding it (skipped keys and values cost no scratch memory).
    fn skipString(p: *P) Error!void {
        try p.expect('"');
        const start = p.pos;
        var i = start;
        while (i < p.src.len) {
            const c = p.src[i];
            if (c == '"') {
                if (!std.unicode.utf8ValidateSlice(p.src[start..i])) return error.Invalid;
                p.pos = i + 1;
                return;
            }
            if (c < 0x20) return error.Invalid;
            if (c != '\\') {
                i += 1;
                continue;
            }
            i += 1;
            if (i >= p.src.len) return error.Invalid;
            switch (p.src[i]) {
                '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => i += 1,
                'u' => {
                    _ = try hex4(p.src, i + 1);
                    i += 5;
                },
                else => return error.Invalid,
            }
        }
        return error.Invalid;
    }

    fn hex4(src: []const u8, at: usize) Error!u21 {
        if (at + 4 > src.len) return error.Invalid;
        var v: u21 = 0;
        for (src[at .. at + 4]) |c| {
            const d: u21 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return error.Invalid,
            };
            v = v * 16 + d;
        }
        return v;
    }

    fn number(p: *P) Error!void {
        // -? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?
        if (p.peek() == '-') p.pos += 1;
        const c = p.peek() orelse return error.Invalid;
        if (c == '0') {
            p.pos += 1;
        } else if (c >= '1' and c <= '9') {
            while (p.peek()) |d| : (p.pos += 1) if (d < '0' or d > '9') break;
        } else return error.Invalid;
        if (p.peek() == '.') {
            p.pos += 1;
            const s = p.pos;
            while (p.peek()) |d| : (p.pos += 1) if (d < '0' or d > '9') break;
            if (p.pos == s) return error.Invalid;
        }
        if (p.peek() == 'e' or p.peek() == 'E') {
            p.pos += 1;
            if (p.peek() == '+' or p.peek() == '-') p.pos += 1;
            const s = p.pos;
            while (p.peek()) |d| : (p.pos += 1) if (d < '0' or d > '9') break;
            if (p.pos == s) return error.Invalid;
        }
    }

    fn literal(p: *P, lit: []const u8) Error!void {
        if (p.pos + lit.len > p.src.len or !std.mem.eql(u8, p.src[p.pos..][0..lit.len], lit)) return error.Invalid;
        p.pos += lit.len;
    }

    /// Validate and skip one value of any type.
    fn skip(p: *P, depth: u32) Error!void {
        if (depth > max_depth) return error.Invalid;
        p.ws();
        const c = p.peek() orelse return error.Invalid;
        switch (c) {
            '"' => try p.skipString(),
            '{' => {
                p.pos += 1;
                p.ws();
                if (p.peek() == '}') {
                    p.pos += 1;
                    return;
                }
                while (true) {
                    p.ws();
                    try p.skipString();
                    p.ws();
                    try p.expect(':');
                    try p.skip(depth + 1);
                    p.ws();
                    const d = p.peek() orelse return error.Invalid;
                    p.pos += 1;
                    if (d == '}') return;
                    if (d != ',') return error.Invalid;
                }
            },
            '[' => {
                p.pos += 1;
                p.ws();
                if (p.peek() == ']') {
                    p.pos += 1;
                    return;
                }
                while (true) {
                    try p.skip(depth + 1);
                    p.ws();
                    const d = p.peek() orelse return error.Invalid;
                    p.pos += 1;
                    if (d == ']') return;
                    if (d != ',') return error.Invalid;
                }
            },
            't' => try p.literal("true"),
            'f' => try p.literal("false"),
            'n' => try p.literal("null"),
            else => try p.number(),
        }
    }

    /// Read a field value into `f` (string / null / array of strings / anything else).
    fn field(p: *P, f: *Field, want_strings: bool) Error!void {
        p.ws();
        const c = p.peek() orelse return error.Invalid;
        switch (c) {
            '"' => f.* = .{ .kind = .string, .s = try p.string() },
            'n' => {
                try p.literal("null");
                f.* = .{ .kind = .null };
            },
            '[' => if (want_strings) {
                // Pass 1: validate the array and count its elements; pass 2: read the strings.
                const save = p.pos;
                try p.skip(0);
                const end = p.pos;
                p.pos = save + 1;
                p.ws();
                var count: usize = 0;
                var all_strings = true;
                if (p.peek() != ']') {
                    var q = p.*;
                    while (true) {
                        q.ws();
                        if (q.peek() != '"') all_strings = false;
                        try q.skip(1);
                        count += 1;
                        q.ws();
                        if (q.peek() == ',') q.pos += 1 else break;
                    }
                }
                if (!all_strings) {
                    p.pos = end;
                    f.* = .{ .kind = .other };
                    return;
                }
                const mem = try p.sc.alloc(count * @sizeOf([]const u8) + @alignOf([]const u8));
                const aligned = std.mem.alignInSlice(mem, @alignOf([]const u8)) orelse return error.OutOfMemory;
                const out: [][]const u8 = @as([*][]const u8, @ptrCast(@alignCast(aligned.ptr)))[0..count];
                var n: usize = 0;
                while (n < count) : (n += 1) {
                    p.ws();
                    out[n] = try p.string();
                    p.ws();
                    if (p.peek() == ',') p.pos += 1;
                }
                p.pos = end;
                f.* = .{ .kind = .strings, .list = out };
            } else {
                try p.skip(0);
                f.* = .{ .kind = .other };
            },
            '-', '0'...'9' => {
                const st = p.pos;
                try p.number();
                f.* = .{ .kind = .number, .s = p.src[st..p.pos] };
            },
            else => {
                try p.skip(0);
                f.* = .{ .kind = .other };
            },
        }
    }
};

/// Parse a top-level object and fill `out` with the listed keys (last duplicate wins); other keys are validated and skipped.
pub fn parseObject(src: []const u8, sc: *Scratch, comptime names: []const []const u8, out: *[names.len]Field) Error!void {
    out.* = @splat(.{});
    var p = P{ .src = src, .sc = sc };
    p.ws();
    try p.expect('{');
    p.ws();
    if (p.peek() == '}') {
        p.pos += 1;
    } else while (true) {
        p.ws();
        const k = try p.string();
        p.ws();
        try p.expect(':');
        var matched = false;
        inline for (names, 0..) |n, idx| {
            if (!matched and std.mem.eql(u8, k, n)) {
                matched = true;
                try p.field(&out[idx], false);
            }
        }
        if (!matched) try p.skip(0);
        p.ws();
        const d = p.peek() orelse return error.Invalid;
        p.pos += 1;
        if (d == '}') break;
        if (d != ',') return error.Invalid;
    }
    p.ws();
    if (p.pos != src.len) return error.Invalid;
}

/// Parse `{"wrapper": {names...}}`. `strings_field` names (a subset of `names`) may be arrays of strings.
/// Returns `error.Invalid` when the body is not valid JSON, is not an object, or the wrapper is missing or not an object.
pub fn parseWrapped(
    src: []const u8,
    sc: *Scratch,
    wrapper: []const u8,
    comptime names: []const []const u8,
    comptime array_names: []const []const u8,
    out: *[names.len]Field,
) Error!void {
    out.* = @splat(.{});
    var p = P{ .src = src, .sc = sc };
    p.ws();
    try p.expect('{');
    p.ws();
    var have_wrapper = false;
    if (p.peek() == '}') return error.Invalid;
    while (true) {
        p.ws();
        const key = try p.string();
        p.ws();
        try p.expect(':');
        p.ws();
        if (std.mem.eql(u8, key, wrapper)) {
            if (p.peek() != '{') return error.Invalid;
            have_wrapper = true;
            out.* = @splat(.{});
            p.pos += 1;
            p.ws();
            if (p.peek() == '}') {
                p.pos += 1;
            } else while (true) {
                p.ws();
                const k = try p.string();
                p.ws();
                try p.expect(':');
                var matched = false;
                inline for (names, 0..) |n, idx| {
                    if (!matched and std.mem.eql(u8, k, n)) {
                        matched = true;
                        const is_arr = comptime blk: {
                            for (array_names) |a| if (std.mem.eql(u8, a, n)) break :blk true;
                            break :blk false;
                        };
                        try p.field(&out[idx], is_arr);
                    }
                }
                if (!matched) try p.skip(0);
                p.ws();
                const d = p.peek() orelse return error.Invalid;
                p.pos += 1;
                if (d == '}') break;
                if (d != ',') return error.Invalid;
            }
        } else try p.skip(1);
        p.ws();
        const d = p.peek() orelse return error.Invalid;
        p.pos += 1;
        if (d == '}') break;
        if (d != ',') return error.Invalid;
    }
    p.ws();
    if (p.pos != src.len) return error.Invalid;
    if (!have_wrapper) return error.Invalid;
}

/// A string field that must be present, non-empty, NUL-free.
pub fn needString(f: Field) ?[]const u8 {
    if (f.kind != .string or f.s.len == 0) return null;
    if (std.mem.indexOfScalar(u8, f.s, 0) != null) return null;
    return f.s;
}

test "wrapped objects" {
    var sc = try Scratch.init(4096);
    var out: [3]Field = undefined;
    const names = [_][]const u8{ "username", "email", "tagList" };
    const arrs = [_][]const u8{"tagList"};
    try parseWrapped(
        \\ {"x": [1,2,{"a":null}], "user": {"username": "aé\n", "email": null, "extra": {"n": -1.5e3}, "tagList": ["x", "y"]}}
    , &sc, "user", &names, &arrs, &out);
    try std.testing.expectEqualStrings("aé\n", out[0].s);
    try std.testing.expectEqual(Kind.null, out[1].kind);
    try std.testing.expectEqual(@as(usize, 2), out[2].list.len);
    try std.testing.expectError(error.Invalid, parseWrapped("{\"user\": {\"username\": \"u_x\",", &sc, "user", &names, &arrs, &out));
    try std.testing.expectError(error.Invalid, parseWrapped("", &sc, "user", &names, &arrs, &out));
    try std.testing.expectError(error.Invalid, parseWrapped("{\"user\": \"s\"}", &sc, "user", &names, &arrs, &out));
    try std.testing.expectError(error.Invalid, parseWrapped("{\"user\": {}} x", &sc, "user", &names, &arrs, &out));
    try std.testing.expectError(error.Invalid, parseWrapped("{\"a\": 1}", &sc, "user", &names, &arrs, &out));
    try parseWrapped("{\"user\":{\"username\":123,\"tagList\":[1]}}", &sc, "user", &names, &arrs, &out);
    try std.testing.expectEqual(Kind.number, out[0].kind);
    try std.testing.expectEqual(Kind.other, out[2].kind);
}

test "many escaped strings do not exhaust the scratch memory" {
    var sc = try Scratch.init(4096);
    var doc = std.ArrayList(u8).empty;
    defer doc.deinit(std.testing.allocator);
    try doc.appendSlice(std.testing.allocator, "{\"user\": {\"username\": \"hi\\n\", \"pad\": [");
    for (0..400) |k| {
        if (k != 0) try doc.append(std.testing.allocator, ',');
        try doc.appendSlice(std.testing.allocator, "\"a\\/b\\u00e9c\"");
    }
    try doc.appendSlice(std.testing.allocator, "], \"also\\n\": 1}}");
    var out: [1]Field = undefined;
    try parseWrapped(doc.items, &sc, "user", &.{"username"}, &.{}, &out);
    try std.testing.expectEqualStrings("hi\n", out[0].s);
    var big = std.ArrayList(u8).empty;
    defer big.deinit(std.testing.allocator);
    try big.appendSlice(std.testing.allocator, "{\"user\": {\"username\": \"");
    for (0..1000) |_| try big.appendSlice(std.testing.allocator, "x\\n");
    try big.appendSlice(std.testing.allocator, "\"}}");
    sc.reset();
    try parseWrapped(big.items, &sc, "user", &.{"username"}, &.{}, &out);
    try std.testing.expectEqual(@as(usize, 2000), out[0].s.len);
}
