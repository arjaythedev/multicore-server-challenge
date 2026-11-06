//! JSON output straight into a response buffer, and a strict parser for the small request bodies.
//! Output has no whitespace. Strings are escaped only where JSON requires it ('"', '\\', control bytes);
//! Postgres text is already valid UTF-8.
const std = @import("std");
const Buf = @import("buf.zig").Buf;

const V = @Vector(16, u8);

pub fn str(b: *Buf, s: []const u8) void {
    b.ensure(s.len + 2);
    b.ptr[b.len] = '"';
    b.len += 1;
    escapeInto(b, s);
    b.ptr[b.len] = '"';
    b.len += 1;
}

pub fn strOrNull(b: *Buf, s: ?[]const u8) void {
    if (s) |v| str(b, v) else b.append("null");
}

/// Appends `s` escaped. The caller has reserved `s.len + 1` bytes; each escape re-reserves for what is left.
fn escapeInto(b: *Buf, s: []const u8) void {
    var i: usize = 0;
    var run: usize = 0;
    while (i + 16 <= s.len) {
        const v: V = s[i..][0..16].*;
        const bad = (v < @as(V, @splat(0x20))) | (v == @as(V, @splat('"'))) | (v == @as(V, @splat('\\')));
        const mask: u16 = @bitCast(bad);
        if (mask == 0) {
            i += 16;
            continue;
        }
        const j = i + @ctz(mask);
        flushRun(b, s[run..j]);
        escapeByte(b, s[j], s.len - j);
        i = j + 1;
        run = i;
    }
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c < 0x20 or c == '"' or c == '\\') {
            flushRun(b, s[run..i]);
            escapeByte(b, c, s.len - i);
            run = i + 1;
        }
    }
    flushRun(b, s[run..]);
}

inline fn flushRun(b: *Buf, run: []const u8) void {
    @memcpy(b.ptr[b.len..][0..run.len], run);
    b.len += @intCast(run.len);
}

/// `rest` counts this byte and the ones after it; the reservation keeps room for them plus the closing quote.
fn escapeByte(b: *Buf, c: u8, rest: usize) void {
    b.ensure(6 + rest);
    const out = b.ptr[b.len..];
    switch (c) {
        '"' => {
            out[0..2].* = "\\\"".*;
            b.len += 2;
        },
        '\\' => {
            out[0..2].* = "\\\\".*;
            b.len += 2;
        },
        '\n' => {
            out[0..2].* = "\\n".*;
            b.len += 2;
        },
        '\r' => {
            out[0..2].* = "\\r".*;
            b.len += 2;
        },
        '\t' => {
            out[0..2].* = "\\t".*;
            b.len += 2;
        },
        else => {
            const hex = "0123456789abcdef";
            out[0..6].* = .{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 15] };
            b.len += 6;
        },
    }
}

pub fn int(b: *Buf, v: i64) void {
    b.ensure(21);
    var x: u64 = @abs(v);
    if (v < 0) {
        b.ptr[b.len] = '-';
        b.len += 1;
    }
    var tmp: [20]u8 = undefined;
    var i: usize = 20;
    while (true) {
        i -= 1;
        tmp[i] = @intCast('0' + x % 10);
        x /= 10;
        if (x == 0) break;
    }
    flushRun(b, tmp[i..]);
}

pub fn boolean(b: *Buf, v: bool) void {
    b.append(if (v) "true" else "false");
}

/// Postgres binary timestamptz: microseconds since 2000-01-01 UTC. Written as "YYYY-MM-DDTHH:MM:SS.mmmZ",
/// truncated to milliseconds.
pub fn timestamp(b: *Buf, us: i64) void {
    const ms = @divFloor(us, 1000);
    const secs = @divFloor(ms, 1000);
    const milli: u32 = @intCast(ms - secs * 1000);
    const days = @divFloor(secs, 86400);
    const sod: u32 = @intCast(secs - days * 86400);
    const ymd = civil(days + 10957);
    b.ensure(26);
    const o = b.ptr[b.len..][0..26];
    o[0] = '"';
    put4(o[1..5], ymd.y);
    o[5] = '-';
    put2(o[6..8], ymd.m);
    o[8] = '-';
    put2(o[9..11], ymd.d);
    o[11] = 'T';
    put2(o[12..14], sod / 3600);
    o[14] = ':';
    put2(o[15..17], (sod / 60) % 60);
    o[17] = ':';
    put2(o[18..20], sod % 60);
    o[20] = '.';
    o[21] = @intCast('0' + milli / 100);
    o[22] = @intCast('0' + (milli / 10) % 10);
    o[23] = @intCast('0' + milli % 10);
    o[24] = 'Z';
    o[25] = '"';
    b.len += 26;
}

fn put2(o: *[2]u8, v: u32) void {
    o[0] = @intCast('0' + v / 10);
    o[1] = @intCast('0' + v % 10);
}

fn put4(o: *[4]u8, v: i64) void {
    const u: u32 = @intCast(@mod(v, 10000));
    o[0] = @intCast('0' + u / 1000);
    o[1] = @intCast('0' + (u / 100) % 10);
    o[2] = @intCast('0' + (u / 10) % 10);
    o[3] = @intCast('0' + u % 10);
}

/// Days since 1970-01-01 to a civil date (Howard Hinnant's algorithm).
fn civil(z0: i64) struct { y: i64, m: u32, d: u32 } {
    const z = z0 + 719468;
    const era = @divFloor(z, 146097);
    const doe: i64 = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u32 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .y = if (m <= 2) y + 1 else y, .m = m, .d = d };
}

// ---------------------------------------------------------------- parsing

/// A JSON value inside a request body, by its raw span. Parsing validates the whole document first, so spans
/// handed out are well-formed.
pub const Value = struct {
    raw: []const u8,

    pub fn kind(v: Value) Kind {
        return switch (v.raw[0]) {
            '"' => .string,
            '{' => .object,
            '[' => .array,
            'n' => .null,
            't', 'f' => .boolean,
            else => .number,
        };
    }

    /// Looks up `key` in an object value; the last occurrence wins, as with Go's encoding/json maps.
    pub fn get(v: Value, key: []const u8) ?Value {
        var found: ?Value = null;
        var it = v.members();
        while (it.next()) |m| if (m.keyIs(key)) {
            found = m.value;
        };
        return found;
    }

    /// Iterates the elements of an array value.
    pub fn items(v: Value) ArrayIter {
        return .{ .p = .{ .s = v.raw, .i = 1 } };
    }

    /// Iterates the members of an object value in document order.
    pub fn members(v: Value) ObjectIter {
        return .{ .p = .{ .s = v.raw, .i = 1 } };
    }
};

pub const Kind = enum { string, object, array, null, boolean, number };

pub const Member = struct {
    /// The key as written, quotes and escapes included; compare it with `keyEquals`.
    key_raw: []const u8,
    value: Value,

    pub fn keyIs(m: Member, key: []const u8) bool {
        return keyEquals(m.key_raw, key);
    }
};

pub const ObjectIter = struct {
    p: Parser,
    done: bool = false,

    pub fn next(it: *ObjectIter) ?Member {
        if (it.done) return null;
        it.p.ws();
        if (it.p.peek() == '}') {
            it.done = true;
            return null;
        }
        const k_start = it.p.i;
        it.p.skipString() catch unreachable;
        const key_raw = it.p.s[k_start..it.p.i];
        it.p.ws();
        it.p.i += 1; // ':'
        it.p.ws();
        const v_start = it.p.i;
        it.p.skipValue(0) catch unreachable;
        const out: Member = .{ .key_raw = key_raw, .value = .{ .raw = it.p.s[v_start..it.p.i] } };
        it.p.ws();
        if (it.p.peek() == ',') it.p.i += 1 else it.done = true;
        return out;
    }
};

pub const ArrayIter = struct {
    p: Parser,
    done: bool = false,

    pub fn next(it: *ArrayIter) ?Value {
        if (it.done) return null;
        it.p.ws();
        if (it.p.peek() == ']') {
            it.done = true;
            return null;
        }
        const start = it.p.i;
        it.p.skipValue(0) catch unreachable;
        const out: Value = .{ .raw = it.p.s[start..it.p.i] };
        it.p.ws();
        if (it.p.peek() == ',') it.p.i += 1 else it.done = true;
        return out;
    }
};

fn keyEquals(raw: []const u8, key: []const u8) bool {
    const inner = raw[1 .. raw.len - 1];
    if (std.mem.indexOfScalar(u8, inner, '\\') == null) return std.mem.eql(u8, inner, key);
    var tmp: [256]u8 = undefined;
    if (inner.len > tmp.len) return false;
    const d = decodeString(raw, &tmp) orelse return false;
    return std.mem.eql(u8, d, key);
}

/// Parses and validates a whole document. Returns the top-level value, or null when it isn't valid JSON.
pub fn parse(s: []const u8) ?Value {
    var p: Parser = .{ .s = s, .i = 0 };
    p.ws();
    const start = p.i;
    p.skipValue(0) catch return null;
    const end = p.i;
    p.ws();
    if (p.i != s.len) return null;
    return .{ .raw = s[start..end] };
}

const Parser = struct {
    s: []const u8,
    i: usize,

    fn peek(p: *Parser) u8 {
        return if (p.i < p.s.len) p.s[p.i] else 0;
    }

    fn ws(p: *Parser) void {
        while (p.i < p.s.len) : (p.i += 1) {
            switch (p.s[p.i]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    fn skipValue(p: *Parser, depth: u32) error{Bad}!void {
        if (depth > 64) return error.Bad;
        switch (p.peek()) {
            '"' => try p.skipString(),
            '{' => {
                p.i += 1;
                p.ws();
                if (p.peek() == '}') {
                    p.i += 1;
                    return;
                }
                while (true) {
                    p.ws();
                    if (p.peek() != '"') return error.Bad;
                    try p.skipString();
                    p.ws();
                    if (p.peek() != ':') return error.Bad;
                    p.i += 1;
                    p.ws();
                    try p.skipValue(depth + 1);
                    p.ws();
                    switch (p.peek()) {
                        ',' => p.i += 1,
                        '}' => {
                            p.i += 1;
                            return;
                        },
                        else => return error.Bad,
                    }
                }
            },
            '[' => {
                p.i += 1;
                p.ws();
                if (p.peek() == ']') {
                    p.i += 1;
                    return;
                }
                while (true) {
                    p.ws();
                    try p.skipValue(depth + 1);
                    p.ws();
                    switch (p.peek()) {
                        ',' => p.i += 1,
                        ']' => {
                            p.i += 1;
                            return;
                        },
                        else => return error.Bad,
                    }
                }
            },
            't' => try p.literal("true"),
            'f' => try p.literal("false"),
            'n' => try p.literal("null"),
            '-', '0'...'9' => try p.number(),
            else => return error.Bad,
        }
    }

    fn literal(p: *Parser, lit: []const u8) error{Bad}!void {
        if (!std.mem.startsWith(u8, p.s[p.i..], lit)) return error.Bad;
        p.i += lit.len;
    }

    fn number(p: *Parser) error{Bad}!void {
        if (p.peek() == '-') p.i += 1;
        if (p.peek() == '0') {
            p.i += 1;
        } else if (p.peek() >= '1' and p.peek() <= '9') {
            while (p.peek() >= '0' and p.peek() <= '9') p.i += 1;
        } else return error.Bad;
        if (p.peek() == '.') {
            p.i += 1;
            if (!(p.peek() >= '0' and p.peek() <= '9')) return error.Bad;
            while (p.peek() >= '0' and p.peek() <= '9') p.i += 1;
        }
        if (p.peek() == 'e' or p.peek() == 'E') {
            p.i += 1;
            if (p.peek() == '+' or p.peek() == '-') p.i += 1;
            if (!(p.peek() >= '0' and p.peek() <= '9')) return error.Bad;
            while (p.peek() >= '0' and p.peek() <= '9') p.i += 1;
        }
    }

    fn skipString(p: *Parser) error{Bad}!void {
        p.i += 1;
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            if (c == '"') {
                p.i += 1;
                return;
            }
            if (c < 0x20) return error.Bad;
            if (c == '\\') {
                if (p.i + 1 >= p.s.len) return error.Bad;
                switch (p.s[p.i + 1]) {
                    '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => p.i += 2,
                    'u' => {
                        if (p.i + 6 > p.s.len) return error.Bad;
                        for (p.s[p.i + 2 .. p.i + 6]) |h| if (!std.ascii.isHex(h)) return error.Bad;
                        p.i += 6;
                    },
                    else => return error.Bad,
                }
                continue;
            }
            p.i += 1;
        }
        return error.Bad;
    }
};

/// Decodes a raw JSON string (with quotes) into `out`. Invalid UTF-8 and lone surrogates become U+FFFD, as Go's
/// encoding/json does. Returns null if `out` is too small (it never needs more than raw.len bytes).
pub fn decodeString(raw: []const u8, out: []u8) ?[]u8 {
    const s = raw[1 .. raw.len - 1];
    if (out.len < s.len) return null;
    var o: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '\\') {
            const e = s[i + 1];
            switch (e) {
                'u' => {
                    var cp: u21 = hex4(s[i + 2 ..][0..4]);
                    i += 6;
                    if (cp >= 0xD800 and cp < 0xDC00) {
                        if (i + 6 <= s.len and s[i] == '\\' and s[i + 1] == 'u') {
                            const lo = hex4(s[i + 2 ..][0..4]);
                            if (lo >= 0xDC00 and lo < 0xE000) {
                                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                                i += 6;
                            } else cp = 0xFFFD;
                        } else cp = 0xFFFD;
                    } else if (cp >= 0xDC00 and cp < 0xE000) cp = 0xFFFD;
                    o += std.unicode.utf8Encode(cp, out[o..]) catch unreachable;
                },
                else => {
                    out[o] = switch (e) {
                        'b' => 8,
                        'f' => 12,
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        else => e,
                    };
                    o += 1;
                    i += 2;
                },
            }
            continue;
        }
        if (c < 0x80) {
            out[o] = c;
            o += 1;
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(c) catch 0;
        if (n == 0 or i + n > s.len or !validUtf8Seq(s[i..][0..n])) {
            // Three replacement bytes; the decoded form can then exceed the raw length by at most 2 per byte, so
            // a lone bad byte (1 raw byte -> 3 out) is the only growth. Callers size `out` at 3x raw for safety.
            if (o + 3 > out.len) return null;
            out[o..][0..3].* = .{ 0xEF, 0xBF, 0xBD };
            o += 3;
            i += 1;
            continue;
        }
        @memcpy(out[o..][0..n], s[i..][0..n]);
        o += n;
        i += n;
    }
    return out[0..o];
}

fn validUtf8Seq(seq: []const u8) bool {
    _ = std.unicode.utf8Decode(seq) catch return false;
    return true;
}

fn hex4(h: *const [4]u8) u21 {
    var v: u21 = 0;
    for (h) |c| v = v * 16 + @as(u21, std.fmt.charToDigit(c, 16) catch 0);
    return v;
}

test "timestamp" {
    var b = Buf.init();
    defer b.release();
    // 2025-04-01T12:00:00.123456Z
    timestamp(&b, 796737600_123456 + 86400_000000);
    try std.testing.expectEqualStrings("\"2025-04-01T12:00:00.123Z\"", b.body());
    b.resetBody();
    timestamp(&b, -1);
    try std.testing.expectEqualStrings("\"1999-12-31T23:59:59.999Z\"", b.body());
}

test "escape" {
    var b = Buf.init();
    defer b.release();
    str(&b, "a\"b\\c\n\x01 0123456789abcdef \"quoted\" ünï");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\n\\u0001 0123456789abcdef \\\"quoted\\\" ünï\"", b.body());
}

test "parse" {
    const v = parse(" {\"user\": {\"email\": \"a\\u00e9\", \"email\": \"x@y\", \"n\": null, \"t\": [\"a\", \"\"]}} ").?;
    const u = v.get("user").?;
    try std.testing.expectEqual(Kind.object, u.kind());
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("x@y", decodeString(u.get("email").?.raw, &out).?);
    try std.testing.expectEqual(Kind.null, u.get("n").?.kind());
    try std.testing.expect(u.get("missing") == null);
    var it = u.get("t").?.items();
    try std.testing.expectEqualStrings("\"a\"", it.next().?.raw);
    try std.testing.expectEqualStrings("\"\"", it.next().?.raw);
    try std.testing.expect(it.next() == null);
    try std.testing.expect(parse("{\"user\": {\"username\": \"u_x\",") == null);
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parse("{} x") == null);
}
