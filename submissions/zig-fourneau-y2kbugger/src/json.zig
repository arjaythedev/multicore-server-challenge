//! JSON both ways: responses written into a fixed buffer (no allocation, no
//! `std.fmt`), and request bodies, `{"<wrapper>": {...}}`, read with std's
//! scanner over a fixed buffer.

const std = @import("std");
const assert = std.debug.assert;

/// A response body, appended into a fixed buffer. Past its end it stops
/// appending and says so once, at `result`: a body never comes out cut short.
pub const Out = struct {
    buffer: []u8,
    used: usize = 0,
    overflow: bool = false,

    pub fn init(buffer: []u8) Out {
        assert(buffer.len > 0);
        return .{ .buffer = buffer };
    }

    pub fn result(out: *const Out) ?[]const u8 {
        if (out.overflow) return null;
        return out.buffer[0..out.used];
    }

    pub fn bytes(out: *Out, text: []const u8) void {
        if (out.overflow or out.buffer.len - out.used < text.len) {
            out.overflow = true;
            return;
        }
        @memcpy(out.buffer[out.used..][0..text.len], text);
        out.used += text.len;
    }

    pub fn int(out: *Out, value: i64) void {
        var digits: [20]u8 = undefined;
        var magnitude: u64 = @abs(value);
        var start: usize = digits.len;
        // Bounded: a u64 has at most 20 digits.
        for (0..digits.len) |_| {
            start -= 1;
            digits[start] = @intCast('0' + magnitude % 10);
            magnitude /= 10;
            if (magnitude == 0) break;
        }
        assert(magnitude == 0);
        if (value < 0) out.bytes("-");
        out.bytes(digits[start..]);
    }

    pub fn boolean(out: *Out, value: bool) void {
        out.bytes(if (value) "true" else "false");
    }

    /// A JSON string: quoted, with `"`, `\` and control characters escaped.
    /// Everything else goes out as it is (the database's text is UTF-8).
    pub fn string(out: *Out, text: []const u8) void {
        out.bytes("\"");
        var start: usize = 0;
        // Bounded: each pass moves `start` past an escaped byte.
        for (0..text.len + 1) |_| {
            const index = start + plain_prefix(text[start..]);
            out.bytes(text[start..index]);
            if (index == text.len) break;
            out.escape(text[index]);
            start = index + 1;
        } else unreachable;
        out.bytes("\"");
    }

    pub fn string_or_null(out: *Out, text: ?[]const u8) void {
        if (text) |value| out.string(value) else out.bytes("null");
    }

    fn escape(out: *Out, byte: u8) void {
        switch (byte) {
            '"' => out.bytes("\\\""),
            '\\' => out.bytes("\\\\"),
            '\n' => out.bytes("\\n"),
            '\r' => out.bytes("\\r"),
            '\t' => out.bytes("\\t"),
            else => {
                assert(byte < 0x20);
                const hex = "0123456789abcdef";
                out.bytes(&.{ '\\', 'u', '0', '0', hex[byte >> 4], hex[byte & 0xf] });
            },
        }
    }

    /// How many bytes from the start need no escape: sixteen at a time
    /// (Zig 0.17's LLVM vectorizes no loops itself).
    fn plain_prefix(text: []const u8) usize {
        const lanes = 16;
        const Vector = @Vector(lanes, u8);
        var index: usize = 0;
        while (index + lanes <= text.len) : (index += lanes) {
            const chunk: Vector = text[index..][0..lanes].*;
            const special = (chunk < @as(Vector, @splat(0x20))) |
                (chunk == @as(Vector, @splat('"'))) | (chunk == @as(Vector, @splat('\\')));
            const mask: u16 = @bitCast(special);
            if (mask != 0) return index + @ctz(mask);
        }
        while (index < text.len) : (index += 1) {
            const byte = text[index];
            if (byte < 0x20 or byte == '"' or byte == '\\') return index;
        }
        return index;
    }
};

pub const fields_max = 16;
pub const items_max = 64;

/// A field of the wrapper's object: what kind of value it had.
pub const Value = union(enum) {
    string: []const u8,
    null,
    /// A number, a boolean, an object, or an array (but `items`'s).
    other,
};

/// `{"<wrapper>": {fields...}}`, as Go's `encoding/json` reads it into a
/// map: keys are case-sensitive, a later duplicate wins, anything else in
/// the document is ignored, and the document must be whole and valid.
pub const Body = struct {
    names: [fields_max][]const u8 = undefined,
    values: [fields_max]Value = undefined,
    count: u8 = 0,
    /// The field named `items_name`, if an array: its items, each a string
    /// or not (`items_valid` false then).
    items: [items_max][]const u8 = undefined,
    items_count: u8 = 0,
    items_present: bool = false,
    items_valid: bool = true,

    pub fn get(body: *const Body, name: []const u8) ?Value {
        var found: ?Value = null;
        for (body.names[0..body.count], body.values[0..body.count]) |field, value| {
            if (std.mem.eql(u8, field, name)) found = value;
        }
        return found;
    }

    pub const Optional = union(enum) { absent, value: []const u8, invalid };

    /// Absent or null: absent; a string: it (empty refused when
    /// `non_empty`); anything else: invalid.
    pub fn optional(body: *const Body, name: []const u8, non_empty: bool) Optional {
        const value = body.get(name) orelse return .absent;
        return switch (value) {
            .null => .absent,
            .other => .invalid,
            .string => |text| if (non_empty and text.len == 0) .invalid else .{ .value = text },
        };
    }

    /// A non-empty string, or null.
    pub fn required(body: *const Body, name: []const u8) ?[]const u8 {
        return switch (body.optional(name, true)) {
            .value => |text| text,
            .absent, .invalid => null,
        };
    }
};

/// The wrapper's fields, or null: malformed JSON, not an object at the top,
/// no wrapper, or a wrapper that is not an object. `memory` holds the
/// scanner's nesting and any string with escapes.
pub fn parse_body(input: []const u8, wrapper: []const u8, items_name: []const u8, memory: []u8) ?Body {
    var fixed: std.heap.FixedBufferAllocator = .init(memory);
    const gpa = fixed.allocator();
    var scanner: std.json.Scanner = .initCompleteInput(gpa, input);
    var body: Body = .{};
    var found = false;
    if ((scanner.next() catch return null) != .object_begin) return null;
    // Bounded: each pass consumes a key and its value from a finite input.
    for (0..input.len + 1) |_| {
        const key = next_key(&scanner, gpa) catch return null;
        const name = key orelse break;
        if (!std.mem.eql(u8, name, wrapper)) {
            scanner.skipValue() catch return null;
            continue;
        }
        if ((scanner.peekNextTokenType() catch return null) != .object_begin) {
            scanner.skipValue() catch return null;
            found = false; // a later wrapper that is not an object wins
            continue;
        }
        body = .{};
        parse_fields(&scanner, gpa, items_name, &body) catch return null;
        found = true;
    } else unreachable;
    if ((scanner.next() catch return null) != .end_of_document) return null;
    if (!found) return null;
    return body;
}

/// The next key of the object being read, or null at its end.
fn next_key(scanner: *std.json.Scanner, gpa: std.mem.Allocator) !?[]const u8 {
    return switch (try scanner.nextAlloc(gpa, .alloc_if_needed)) {
        .object_end => null,
        .string => |text| text,
        .allocated_string => |text| text,
        else => error.SyntaxError,
    };
}

fn parse_fields(scanner: *std.json.Scanner, gpa: std.mem.Allocator, items_name: []const u8, body: *Body) !void {
    assert(try scanner.next() == .object_begin);
    // Bounded: each pass consumes a key and its value from a finite input.
    for (0..scanner.input.len + 1) |_| {
        const name = try next_key(scanner, gpa) orelse return;
        const kind = try scanner.peekNextTokenType();
        if (items_name.len > 0 and std.mem.eql(u8, name, items_name) and kind == .array_begin) {
            try parse_items(scanner, gpa, body);
            try add_field(body, name, .other);
            continue;
        }
        const value: Value = switch (kind) {
            .string => switch (try scanner.nextAlloc(gpa, .alloc_if_needed)) {
                .string => |text| .{ .string = text },
                .allocated_string => |text| .{ .string = text },
                else => unreachable,
            },
            .null => blk: {
                _ = try scanner.next();
                break :blk .null;
            },
            else => blk: {
                try scanner.skipValue();
                break :blk .other;
            },
        };
        if (std.mem.eql(u8, name, items_name)) {
            // Present but not an array: null is absent, anything else invalid.
            body.items_present = value != .null;
            body.items_valid = value == .null;
            body.items_count = 0;
        }
        try add_field(body, name, value);
    } else unreachable;
}

fn add_field(body: *Body, name: []const u8, value: Value) !void {
    if (body.count == fields_max) return error.TooManyFields;
    body.names[body.count] = name;
    body.values[body.count] = value;
    body.count += 1;
}

fn parse_items(scanner: *std.json.Scanner, gpa: std.mem.Allocator, body: *Body) !void {
    assert(try scanner.next() == .array_begin);
    body.items_present = true;
    body.items_valid = true;
    body.items_count = 0;
    // Bounded: each pass consumes an item from a finite input.
    for (0..scanner.input.len + 1) |_| {
        switch (try scanner.peekNextTokenType()) {
            .array_end => {
                _ = try scanner.next();
                return;
            },
            .string => {
                const text = switch (try scanner.nextAlloc(gpa, .alloc_if_needed)) {
                    .string => |text| text,
                    .allocated_string => |text| text,
                    else => unreachable,
                };
                if (text.len == 0) body.items_valid = false;
                if (body.items_count == items_max) return error.TooManyItems;
                body.items[body.items_count] = text;
                body.items_count += 1;
            },
            else => {
                try scanner.skipValue();
                body.items_valid = false;
            },
        }
    } else unreachable;
}

const testing = std.testing;

test "Out escapes what JSON must, sixteen bytes at a time" {
    var buffer: [256]u8 = undefined;
    var out: Out = .init(&buffer);
    out.string("0123456789abcde\"0123456789abcdef\\x\x1f0123456789abcdefg");
    out.bytes(",");
    out.int(-120);
    out.string_or_null(null);
    try testing.expectEqualStrings(
        "\"0123456789abcde\\\"0123456789abcdef\\\\x\\u001f0123456789abcdefg\",-120null",
        out.result().?,
    );
}

test "parse_body: Conduit's bodies as Go reads them" {
    var memory: [8192]u8 = undefined;
    const user = parse_body(
        "{\"extra\":1,\"user\":{\"username\":\"u\",\"email\":null,\"n\":5,\"x\":{\"y\":[1]}}}",
        "user",
        "",
        &memory,
    ).?;
    try testing.expectEqualStrings("u", user.required("username").?);
    try testing.expect(user.required("email") == null);
    try testing.expect(user.optional("email", true) == .absent);
    try testing.expect(user.optional("n", false) == .invalid);
    try testing.expect(user.optional("missing", false) == .absent);
    try testing.expect(parse_body("{\"user\":\"x\"}", "user", "", &memory) == null);
    try testing.expect(parse_body("{\"username\":\"x\"}", "user", "", &memory) == null);
    try testing.expect(parse_body("{\"user\": {\"username\": \"u_x\",", "user", "", &memory) == null);
    try testing.expect(parse_body("", "user", "", &memory) == null);
    try testing.expect(parse_body("{\"user\":{}} x", "user", "", &memory) == null);

    const article = parse_body(
        "{\"article\":{\"title\":\"t\",\"tagList\":[\"a\",\"b\\u0041\"]}}",
        "article",
        "tagList",
        &memory,
    ).?;
    try testing.expect(article.items_present and article.items_valid);
    try testing.expectEqual(2, article.items_count);
    try testing.expectEqualStrings("bA", article.items[1]);
    const bad_items = parse_body("{\"article\":{\"tagList\":[\"ok\",\"\"]}}", "article", "tagList", &memory).?;
    try testing.expect(!bad_items.items_valid);
    const null_item = parse_body("{\"article\":{\"tagList\":[null]}}", "article", "tagList", &memory).?;
    try testing.expect(!null_item.items_valid);
    const not_array = parse_body("{\"article\":{\"tagList\":\"x\"}}", "article", "tagList", &memory).?;
    try testing.expect(not_array.items_present and !not_array.items_valid);
    const null_list = parse_body("{\"article\":{\"tagList\":null}}", "article", "tagList", &memory).?;
    try testing.expect(!null_list.items_present and null_list.items_valid);
}
