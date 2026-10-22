// HS256 JWTs: {"sub": "<id>", "iat", "exp": iat + 30 days}. Every request checks the signature first, then the
// header (the one issued here is compared as text), then exp.

import crypto;
import http;
import json;

// Native HMAC retains only per-thread keyed state, never token results.
extern fn native_hmac_sha256(secret: const u8[:], message: const u8[:], digest: u8[:]) -> i32;

let JWT_HEADER = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";      // {"alg":"HS256","typ":"JWT"}
let JWT_TTL = 2592000;
let TOKEN_MAX = 4096;

fn jwt_issue(out: u8[>..]&, key: const u8[:], id: i64, now: i64) -> bool {
    let start = out.len;
    out.append(JWT_HEADER);
    out.push('.');
    let payload = str("{\"sub\":\"", id, "\",\"iat\":", now, ",\"exp\":", now + JWT_TTL, "}");
    b64url_encode(out, payload);
    var mac: u8[32] = [0; 32];
    if native_hmac_sha256(key, out[start..], mac) != 1 { out.resize(start); return false; }
    out.push('.');
    b64url_encode(out, mac);
    return true;
}

fn token_char(c: u8) -> bool {
    (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.'
}

fn header_is_hs256(text: const u8[:]) -> bool {
    var r = json::reader(text);
    var scratch: u8[>..] = [];
    var hs256 = false;
    json::each_member(r) { name =>
        if name == "alg" {
            scratch.clear();
            hs256 = json::read_string(r, scratch) == "HS256";
        } else {
            json::skip(r);
        }
    };
    return json::finish(r) && hs256;
}

// The token's user id, or 0 when it is malformed, badly signed, not HS256, expired, or has no decimal string sub.
fn jwt_verify(key: const u8[:], token: const u8[:], now_ms: i64) -> i64 {
    if token.len == 0 || token.len > TOKEN_MAX { return 0; }
    var d1 = -1;
    var d2 = -1;
    for c, i in token {
        if !token_char(c) { return 0; }
        if c == '.' {
            if d1 < 0 { d1 = i; } else if d2 < 0 { d2 = i; } else { return 0; }
        }
    }
    if d1 <= 0 || d2 <= d1 + 1 { return 0; }

    var mac: u8[32] = [0; 32];
    if native_hmac_sha256(key, token[..d2], mac) != 1 { return 0; }
    var given: u8[>..] = [];
    if !b64url_decode(given, token[d2 + 1..]) || given.len != 32 || !same_bytes(mac, given) { return 0; }

    if token[..d1] != JWT_HEADER {
        var header: u8[>..] = [];
        if !b64url_decode(header, token[..d1]) || !header_is_hs256(header) { return 0; }
    }
    var payload: u8[>..] = [];
    if !b64url_decode(payload, token[d1 + 1..d2]) { return 0; }

    var r = json::reader(payload);
    var scratch: u8[>..] = [];
    var sub = 0;
    var exp = 0.0;
    var has_exp = false;
    var nbf = 0.0;
    var has_nbf = false;
    var bad = false;
    json::each_member(r) { name =>
        if name == "sub" {
            scratch.clear();
            let s = json::read_string(r, scratch);
            let v, ok = parse_uint(s);
            if ok && s.len <= 20 { sub = v; } else { bad = true; }
        } else if name == "exp" {
            exp = json::read_number(r);
            has_exp = true;
        } else if name == "nbf" {
            nbf = json::read_number(r);
            has_nbf = true;
        } else {
            json::skip(r);
        }
    };
    if !json::finish(r) || bad || !has_exp { return 0; }
    let now = now_ms as f64 / 1000.0;
    if !(now < exp) || (has_nbf && now < nbf) { return 0; }
    return sub;
}
