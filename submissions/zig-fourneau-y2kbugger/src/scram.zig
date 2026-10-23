//! SCRAM-SHA-256 (RFC 5802, RFC 7677), the client's half, as Postgres
//! speaks it: no channel binding (`n,,`), the user name left to the
//! startup message (`n=`).

const std = @import("std");
const assert = std.debug.assert;

const Sha256 = std.crypto.hash.sha2.Sha256;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const base64 = std.base64.standard;

pub const nonce_random_bytes = 24;
const nonce_text_bytes = base64.Encoder.calcSize(nonce_random_bytes);

pub const Error = error{ ScramMalformed, ScramServerSignature, NoSpaceLeft };

pub const Client = struct {
    password: []const u8,
    /// Printable, no commas: base64 of random bytes.
    nonce: []const u8,
    nonce_buffer: [nonce_text_bytes]u8 = undefined,
    first_bare_buffer: [128]u8 = undefined,
    first_bare: []const u8 = "",
    server_signature: [Hmac.mac_length]u8 = undefined,

    /// In place: `nonce` points into the client.
    pub fn init(client: *Client, password: []const u8, random: *const [nonce_random_bytes]u8) void {
        client.* = .{ .password = password, .nonce = "" };
        _ = base64.Encoder.encode(&client.nonce_buffer, random);
        client.nonce = &client.nonce_buffer;
    }

    /// `n,,n=,r=<nonce>`: SASLInitialResponse's data.
    pub fn first(client: *Client, out: []u8) Error![]const u8 {
        client.first_bare = try std.fmt.bufPrint(&client.first_bare_buffer, "n=,r={s}", .{client.nonce});
        return std.fmt.bufPrint(out, "n,,{s}", .{client.first_bare});
    }

    /// The answer to the server's first message (`r=..,s=..,i=..`):
    /// `c=biws,r=<nonce>,p=<proof>`.
    pub fn final(client: *Client, server_first: []const u8, out: []u8) Error![]const u8 {
        const fields = try parse_server_first(server_first);
        // The server's nonce extends ours.
        if (!std.mem.startsWith(u8, fields.nonce, client.nonce)) return error.ScramMalformed;
        var salt: [64]u8 = undefined;
        const salt_bytes = base64.Decoder.calcSizeForSlice(fields.salt) catch
            return error.ScramMalformed;
        if (salt_bytes > salt.len) return error.ScramMalformed;
        base64.Decoder.decode(salt[0..salt_bytes], fields.salt) catch return error.ScramMalformed;

        var salted: [Sha256.digest_length]u8 = undefined;
        std.crypto.pwhash.pbkdf2(&salted, client.password, salt[0..salt_bytes], fields.iterations, Hmac) catch
            return error.ScramMalformed;
        var client_key: [Hmac.mac_length]u8 = undefined;
        Hmac.create(&client_key, "Client Key", &salted);
        var stored_key: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(&client_key, &stored_key, .{});
        var server_key: [Hmac.mac_length]u8 = undefined;
        Hmac.create(&server_key, "Server Key", &salted);

        var without_proof_buffer: [256]u8 = undefined;
        const without_proof = try std.fmt.bufPrint(&without_proof_buffer, "c=biws,r={s}", .{fields.nonce});
        var signature: [Hmac.mac_length]u8 = undefined;
        var mac: Hmac = .init(&stored_key);
        update_auth_message(&mac, client.first_bare, server_first, without_proof);
        mac.final(&signature);
        var server_mac: Hmac = .init(&server_key);
        update_auth_message(&server_mac, client.first_bare, server_first, without_proof);
        server_mac.final(&client.server_signature);

        var proof: [Hmac.mac_length]u8 = undefined;
        for (&proof, client_key, signature) |*byte, key, sign| byte.* = key ^ sign;
        var proof_text: [base64.Encoder.calcSize(Hmac.mac_length)]u8 = undefined;
        _ = base64.Encoder.encode(&proof_text, &proof);
        return std.fmt.bufPrint(out, "{s},p={s}", .{ without_proof, proof_text });
    }

    /// The server's last message, `v=<signature>`: it knew the password too.
    pub fn verify(client: *const Client, server_final: []const u8) Error!void {
        if (!std.mem.startsWith(u8, server_final, "v=")) return error.ScramMalformed;
        var expected: [base64.Encoder.calcSize(Hmac.mac_length)]u8 = undefined;
        _ = base64.Encoder.encode(&expected, &client.server_signature);
        const given = std.mem.trimEnd(u8, server_final[2..], ",");
        if (!std.mem.eql(u8, given, &expected)) return error.ScramServerSignature;
    }
};

const ServerFirst = struct { nonce: []const u8, salt: []const u8, iterations: u32 };

fn parse_server_first(text: []const u8) Error!ServerFirst {
    var result: ServerFirst = .{ .nonce = "", .salt = "", .iterations = 0 };
    var fields = std.mem.splitScalar(u8, text, ',');
    while (fields.next()) |field| {
        if (field.len < 2 or field[1] != '=') return error.ScramMalformed;
        const value = field[2..];
        switch (field[0]) {
            'r' => result.nonce = value,
            's' => result.salt = value,
            'i' => result.iterations = std.fmt.parseInt(u32, value, 10) catch
                return error.ScramMalformed,
            else => {},
        }
    }
    if (result.iterations == 0 or result.iterations > 1_000_000) return error.ScramMalformed;
    return result;
}

/// AuthMessage = client-first-bare "," server-first "," client-final-without-proof.
fn update_auth_message(mac: *Hmac, bare: []const u8, server_first: []const u8, without_proof: []const u8) void {
    mac.update(bare);
    mac.update(",");
    mac.update(server_first);
    mac.update(",");
    mac.update(without_proof);
}

// RFC 7677, section 3: its exchange, its user name in the bare first
// message as the RFC has it (Postgres sends none; the rest is the same).
test "scram: RFC 7677's exchange" {
    var client: Client = .{ .password = "pencil", .nonce = "rOprNGfwEbeRWgbNEkqO" };
    client.first_bare = "n=user,r=rOprNGfwEbeRWgbNEkqO";
    var out: [256]u8 = undefined;
    const server_first = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0," ++
        "s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096";
    const final = try client.final(server_first, &out);
    try std.testing.expectEqualStrings(
        "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0," ++
            "p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=",
        final,
    );
    try client.verify("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=");
    try std.testing.expectError(error.ScramServerSignature, client.verify("v=AAAA"));
}
