//! Password hashing, fixed to bcrypt cost 10 by the challenge spec.

const std = @import("std");

// --------------------------------------------------------- //

/// Bytes one bcrypt hash may occupy. The crypt format is 60 bytes.
pub const HASH_MAX: usize = 128;

/// bcrypt cost 10, the parameter the challenge requires.
pub const params = std.crypto.pwhash.bcrypt.Params{
    .rounds_log = 10,
    .silently_truncate_password = false,
};

/// Length of a modular crypt format bcrypt hash.
const CRYPT_HASH_LEN: usize = 60;

// --------------------------------------------------------- //

/// Rewrite a `$2a$` or `$2y$` marker to `$2b$` in `out`.
///
/// Note:
/// - Zig's verifier recomputes the hash as `$2b$` and compares the whole
///   string, so it rejects a `$2a$` hash even though the algorithm is the same
///   for passwords up to 72 bytes. The seed database stores `$2a$` hashes.
fn normalizePrefix(encoded: []const u8, out: []u8) []const u8 {
    if (encoded.len != CRYPT_HASH_LEN) return encoded;
    if (encoded[0] != '$' or encoded[1] != '2') return encoded;
    if (encoded[2] == 'b') return encoded;
    if (encoded[2] != 'a' and encoded[2] != 'y') return encoded;
    if (encoded.len > out.len) return encoded;

    @memcpy(out[0..encoded.len], encoded);
    out[2] = 'b';

    return out[0..encoded.len];
}

// --------------------------------------------------------- //

/// Hash a password into `out`, returning the written slice.
pub fn hash(io: std.Io, allocator: std.mem.Allocator, raw: []const u8, out: []u8) ![]const u8 {
    return std.crypto.pwhash.bcrypt.strHash(raw, .{
        .allocator = allocator,
        .params = params,
        .encoding = .crypt,
    }, out, io);
}

/// Verify a password against a stored bcrypt hash.
pub fn verify(allocator: std.mem.Allocator, raw: []const u8, encoded: []const u8) !void {
    var normalized_buf: [HASH_MAX]u8 = undefined;
    const hash_text = normalizePrefix(encoded, &normalized_buf);

    try std.crypto.pwhash.bcrypt.strVerify(hash_text, raw, .{
        .allocator = allocator,
        .silently_truncate_password = false,
    });
}

// --------------------------------------------------------- //

/// The hash every seeded user carries, a `$2a$` cost 10 hash of `password123`.
const SEED_HASH = "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq";

test "password: hash then verify round trip" {
    var buf: [HASH_MAX]u8 = undefined;

    const encoded = try hash(std.testing.io, std.testing.allocator, "password123", &buf);

    try std.testing.expect(encoded.len > 0);
    try verify(std.testing.allocator, "password123", encoded);
}

test "password: wrong password is rejected" {
    var buf: [HASH_MAX]u8 = undefined;

    const encoded = try hash(std.testing.io, std.testing.allocator, "password123", &buf);

    try std.testing.expectError(
        error.PasswordVerificationFailed,
        verify(std.testing.allocator, "password124", encoded),
    );
}

test "password: a seeded 2a hash verifies" {
    try verify(std.testing.allocator, "password123", SEED_HASH);
}

test "password: a seeded 2a hash rejects the wrong password" {
    try std.testing.expectError(
        error.PasswordVerificationFailed,
        verify(std.testing.allocator, "wrong-password", SEED_HASH),
    );
}

test "password: a 2y prefix verifies" {
    var hash_buf: [HASH_MAX]u8 = undefined;
    @memcpy(hash_buf[0..SEED_HASH.len], SEED_HASH);
    hash_buf[2] = 'y';

    try verify(std.testing.allocator, "password123", hash_buf[0..SEED_HASH.len]);
}

test "password: a malformed hash is rejected" {
    try std.testing.expectError(
        error.InvalidEncoding,
        verify(std.testing.allocator, "password123", "not-a-bcrypt-hash"),
    );
}
