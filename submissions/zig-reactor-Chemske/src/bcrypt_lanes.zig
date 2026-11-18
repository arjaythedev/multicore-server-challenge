// Parallel schedule adapted from Zig 0.17.0's std/crypto/bcrypt.zig (MIT).
// Copyright (c) Zig contributors. See vendor/zig-LICENSE.
const std = @import("std");
const bcrypt = std.crypto.pwhash.bcrypt;
const State = bcrypt.State;
const alphabet = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".*;
const encoder: std.base64.Base64Encoder = .init(alphabet, null);
const decoder: std.base64.Base64Decoder = .init(alphabet, null);

pub fn verifyScalar(hash: *const [60:0]u8, password: []const u8) bool {
    if (!std.mem.startsWith(u8, hash, "$2a$10$") and !std.mem.startsWith(u8, hash, "$2b$10$")) return false;
    var normalized = hash.*;
    normalized[2] = 'b';
    bcrypt.strVerify(normalized[0..60], password, .{ .silently_truncate_password = false }) catch return false;
    return true;
}

fn render(salt: [16]u8, digest: [23]u8) [60]u8 {
    var encoded: [60]u8 = undefined;
    @memcpy(encoded[0..7], "$2b$10$");
    _ = encoder.encode(encoded[7..29], &salt);
    _ = encoder.encode(encoded[29..60], &digest);
    return encoded;
}

fn processWidth(comptime Job: type, comptime width: usize, jobs: [width]*Job, salts: [width][16]u8) void {
    var passwords: [width][]const u8 = undefined;
    inline for (0..width) |lane| passwords[lane] = jobs[lane].password[0..jobs[lane].password_len];
    var digests = derive(width, passwords, salts, 10);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&digests));
    inline for (0..width) |lane| {
        const encoded = render(salts[lane], digests[lane]);
        const job = jobs[lane];
        if (job.mode == .hash) {
            @memcpy(job.hash[0..60], &encoded);
            job.hash[60] = 0;
            job.ok = true;
        } else {
            var stored = job.hash[0..60].*;
            stored[2] = 'b';
            job.ok = std.crypto.timing_safe.eql([60]u8, stored, encoded);
        }
    }
}

// Invalid stored encodings fail individually, without shifting another job's
// result. A singleton retains the original standard-library execution path.
pub fn process(comptime Job: type, jobs: []*Job) usize {
    std.debug.assert(jobs.len > 0 and jobs.len <= 4);
    var valid: [4]*Job = undefined;
    var salts: [4][16]u8 = undefined;
    var count: usize = 0;
    for (jobs) |job| {
        job.ok = false;
        std.debug.assert(job.password_len <= 72);
        if (job.mode == .hash) {
            salts[count] = job.salt;
        } else {
            if (!std.mem.startsWith(u8, &job.hash, "$2a$10$") and !std.mem.startsWith(u8, &job.hash, "$2b$10$")) continue;
            decoder.decode(&salts[count], job.hash[7..29]) catch continue;
        }
        valid[count] = job;
        count += 1;
    }
    switch (count) {
        0 => {},
        1 => {
            const job = valid[0];
            const password = job.password[0..job.password_len];
            job.ok = switch (job.mode) {
                .verify => verifyScalar(&job.hash, password),
                .hash => if (bcrypt.strHashWithSalt(password, .{ .params = .{ .rounds_log = 10, .silently_truncate_password = false }, .encoding = .crypt }, job.hash[0..60], job.salt)) |_| true else |_| false,
            };
        },
        inline 2...4 => |width| processWidth(Job, width, valid[0..width].*, salts[0..width].*),
        else => unreachable,
    }
    return count;
}

fn word(bytes: []const u8, position: *usize) u32 {
    var value: u32 = 0;
    inline for (0..4) |_| {
        if (position.* == bytes.len) position.* = 0;
        value = (value << 8) | bytes[position.*];
        position.* += 1;
    }
    return value;
}

inline fn half(state: *const State, current: u32, other: u32, comptime round: usize) u32 {
    var value = state.sboxes[0][@as(u8, @truncate(other >> 24))];
    value +%= state.sboxes[1][@as(u8, @truncate(other >> 16))];
    value ^= state.sboxes[2][@as(u8, @truncate(other >> 8))];
    value +%= state.sboxes[3][@as(u8, @truncate(other))];
    return current ^ value ^ state.subkeys[round];
}

// Independent hashes expose instruction-level parallelism between dependent
// Blowfish lookups. Every lane keeps its own salt, state and complete rounds.
inline fn encipher(comptime width: usize, states: *const [width]State, left: *[width]u32, right: *[width]u32) void {
    var l = left.*;
    var r = right.*;
    inline for (0..width) |lane| l[lane] ^= states[lane].subkeys[0];
    inline for (1..17) |round| {
        inline for (0..width) |lane| {
            if (round % 2 == 1) r[lane] = half(&states[lane], r[lane], l[lane], round) else l[lane] = half(&states[lane], l[lane], r[lane], round);
        }
    }
    inline for (0..width) |lane| {
        left[lane] = r[lane] ^ states[lane].subkeys[17];
        right[lane] = l[lane];
    }
}

inline fn mixSalt(comptime width: usize, salts: *const [width][4]u32, position: *usize, left: *[width]u32, right: *[width]u32) void {
    inline for (0..width) |lane| {
        left[lane] ^= salts[lane][position.*];
        right[lane] ^= salts[lane][position.* + 1];
    }
    position.* = (position.* + 2) & 3;
}

fn expand(comptime width: usize, comptime salted: bool, states: *[width]State, keys: *const [width][18]u32, salts: *const [width][4]u32) void {
    for (0..18) |index| {
        inline for (0..width) |lane| states[lane].subkeys[index] ^= keys[lane][index];
    }
    var left: [width]u32 = @splat(0);
    var right: [width]u32 = @splat(0);
    var position: usize = 0;
    for (0..9) |pair| {
        if (salted) mixSalt(width, salts, &position, &left, &right);
        encipher(width, states, &left, &right);
        inline for (0..width) |lane| {
            states[lane].subkeys[pair * 2] = left[lane];
            states[lane].subkeys[pair * 2 + 1] = right[lane];
        }
    }
    for (0..4) |box| {
        for (0..128) |pair| {
            if (salted) mixSalt(width, salts, &position, &left, &right);
            encipher(width, states, &left, &right);
            inline for (0..width) |lane| {
                states[lane].sboxes[box][pair * 2] = left[lane];
                states[lane].sboxes[box][pair * 2 + 1] = right[lane];
            }
        }
    }
}

pub fn derive(comptime width: usize, passwords: [width][]const u8, salts: [width][16]u8, comptime cost: u6) [width][23]u8 {
    if (width < 1 or width > 6) @compileError("bcrypt width must be 1-6");
    if (cost < 4 or cost > 31) @compileError("bcrypt cost must be 4-31");
    var states: [width]State = @splat(.{});
    defer std.crypto.secureZero(u8, std.mem.asBytes(&states));
    var password_bytes: [width][73]u8 = undefined;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&password_bytes));
    var password_words: [width][18]u32 = undefined;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&password_words));
    var salt_words: [width][4]u32 = undefined;
    var repeated_salt: [width][18]u32 = undefined;
    inline for (0..width) |lane| {
        const length = @min(passwords[lane].len, 72);
        @memcpy(password_bytes[lane][0..length], passwords[lane][0..length]);
        password_bytes[lane][length] = 0;
        var position: usize = 0;
        for (&password_words[lane]) |*value| value.* = word(password_bytes[lane][0 .. length + 1], &position);
        for (&salt_words[lane], 0..) |*value, index| value.* = std.mem.readInt(u32, salts[lane][index * 4 ..][0..4], .big);
        for (&repeated_salt[lane], 0..) |*value, index| value.* = salt_words[lane][index % 4];
    }
    expand(width, true, &states, &password_words, &salt_words);
    for (0..(@as(u64, 1) << cost)) |_| {
        expand(width, false, &states, &password_words, &salt_words);
        expand(width, false, &states, &repeated_salt, &salt_words);
    }
    var text: [width][6]u32 = @splat(.{ 0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274 });
    for (0..64) |_| {
        for (0..3) |pair| {
            var left: [width]u32 = undefined;
            var right: [width]u32 = undefined;
            inline for (0..width) |lane| {
                left[lane] = text[lane][pair * 2];
                right[lane] = text[lane][pair * 2 + 1];
            }
            encipher(width, &states, &left, &right);
            inline for (0..width) |lane| {
                text[lane][pair * 2] = left[lane];
                text[lane][pair * 2 + 1] = right[lane];
            }
        }
    }
    var result: [width][23]u8 = undefined;
    inline for (0..width) |lane| {
        var bytes: [24]u8 = undefined;
        for (text[lane], 0..) |value, index| std.mem.writeInt(u32, bytes[index * 4 ..][0..4], value, .big);
        result[lane] = bytes[0..23].*;
    }
    return result;
}

test "independent bcrypt lanes match standard-library output for byte and length boundaries" {
    const long: [80]u8 = @splat(0xe9);
    const inputs = [_][]const u8{ "", "a", "password123", "pässword ☕", long[0..71], long[0..72], &long };
    inline for (1..7) |width| {
        for (inputs, 0..) |_, index| {
            var passwords: [width][]const u8 = undefined;
            var salts: [width][16]u8 = undefined;
            inline for (0..width) |lane| {
                passwords[lane] = inputs[(index + lane) % inputs.len];
                for (&salts[lane], 0..) |*byte, salt_index| byte.* = @truncate(index * 31 + lane * 47 + salt_index * 13);
            }
            const actual = derive(width, passwords, salts, 4);
            inline for (0..width) |lane| {
                const expected = bcrypt.bcrypt(passwords[lane], &salts[lane], .{ .rounds_log = 4, .silently_truncate_password = true });
                try std.testing.expectEqualSlices(u8, &expected, &actual[lane]);
            }
        }
    }
}

test "every supported width retains every cost-ten round" {
    const passwords = [6][]const u8{ "password123", "different password", "non-ascii é", "", "five independent", "six independent" };
    var salts: [6][16]u8 = undefined;
    for (&salts, 0..) |*salt, lane| {
        for (salt, 0..) |*byte, index| byte.* = @truncate(lane * 53 + index * 19);
    }
    inline for (1..7) |width| {
        const actual = derive(width, passwords[0..width].*, salts[0..width].*, 10);
        for (passwords[0..width], salts[0..width], actual) |password, salt, digest| {
            const expected = bcrypt.bcrypt(password, &salt, .{ .rounds_log = 10, .silently_truncate_password = true });
            try std.testing.expectEqualSlices(u8, &expected, &digest);
        }
    }
}

test "mixed password jobs retain salts, markers and recipient ownership" {
    const Job = struct {
        mode: enum { hash, verify } = .hash,
        password: [72]u8 = @splat(0),
        password_len: usize = 0,
        hash: [60:0]u8 = @splat(0),
        salt: [16]u8 = undefined,
        ok: bool = false,
    };
    const passwords = [_][]const u8{ "password123", "another password", "correct é", "unused" };
    var storage: [4]Job = @splat(.{});
    var jobs: [4]*Job = undefined;
    for (&storage, 0..) |*job, index| {
        job.password_len = passwords[index].len;
        @memcpy(job.password[0..job.password_len], passwords[index]);
        for (&job.salt, 0..) |*byte, position| byte.* = @truncate(index * 43 + position * 17);
        jobs[index] = job;
    }
    try std.testing.expectEqual(@as(usize, 3), process(Job, jobs[0..3]));
    for (storage[0..3], passwords[0..3]) |job, password| {
        try std.testing.expect(job.ok);
        try std.testing.expect(verifyScalar(&job.hash, password));
    }
    storage[0].mode = .verify;
    storage[0].hash[2] = 'a';
    storage[2].mode = .verify;
    storage[2].password[0] ^= 1;
    storage[3].mode = .verify;
    storage[3].hash = storage[0].hash;
    storage[3].hash[2] = 'x';
    try std.testing.expectEqual(@as(usize, 3), process(Job, &jobs));
    try std.testing.expect(storage[0].ok and storage[1].ok and !storage[2].ok and !storage[3].ok);
    // All-invalid and partially valid groups cannot inherit an earlier success.
    storage[0].hash[2] = 'x';
    storage[2].hash[2] = 'x';
    storage[1].mode = .verify;
    storage[1].hash[2] = 'x';
    try std.testing.expectEqual(@as(usize, 0), process(Job, &jobs));
    for (storage) |job| try std.testing.expect(!job.ok);
}
