// SHA-256 (FIPS 180-4), HMAC-SHA256 (RFC 2104), PBKDF2-HMAC-SHA256 (RFC 8018) and unpadded base64url (RFC 4648 §5):
// what JWT HS256 and Postgres's SCRAM-SHA-256 sign-in need.

let K256: u32[64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

struct Sha256 { h: u32[8], buf: u8[64], fill: i64, total: u64 }

fn sha256() -> Sha256 {
    Sha256 {
        h: [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19],
        buf: [0; 64], fill: 0, total: 0,
    }
}

inline fn rotr(x: u32, n: u32) -> u32 { (x >> n) | (x << (32 - n)) }

fn compress(h: u32[8]&, blk: const u8[:]) {
    assert(blk.len == 64);
    var w: u32[64] = [0; 64];
    for i in 16 {
        w[i] = (blk[4 * i] as u32) << 24 | (blk[4 * i + 1] as u32) << 16 | (blk[4 * i + 2] as u32) << 8
             | blk[4 * i + 3];
    }
    for i in 16..64 {
        let a = w[i - 15];
        let b = w[i - 2];
        let s0 = rotr(a, 7) ^ rotr(a, 18) ^ (a >> 3);
        let s1 = rotr(b, 17) ^ rotr(b, 19) ^ (b >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    var a = h[0]; var b = h[1]; var c = h[2]; var d = h[3];
    var e = h[4]; var f = h[5]; var g = h[6]; var k = h[7];
    for i in 64 {
        let t1 = k + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + K256[i] + w[i];
        let t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
        k = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d;
    h[4] += e; h[5] += f; h[6] += g; h[7] += k;
}

fn update(s: Sha256&, data: const u8[:]) {
    s.total += data.len as u64;
    var i = 0;
    if s.fill > 0 {
        while s.fill < 64 && i < data.len { s.buf[s.fill] = data[i]; s.fill += 1; i += 1; }
        if s.fill < 64 { return; }
        compress(s.h, s.buf);
        s.fill = 0;
    }
    while data.len - i >= 64 { compress(s.h, data[i..i + 64]); i += 64; }
    while i < data.len { s.buf[s.fill] = data[i]; s.fill += 1; i += 1; }
}

fn finish(s: Sha256&, out: u8[32]&) {
    let bits = s.total * 8;
    var tail: u8[72] = [0; 72];
    tail[0] = 0x80;
    let n = if s.fill < 56 { 56 - s.fill } else { 120 - s.fill };
    for i in 8 { tail[n + i] = (bits >> (56 - 8 * i) as! u64) as! u8; }
    update(s, tail[..n + 8]);
    for i in 8 {
        out[4 * i] = (s.h[i] >> 24) as! u8;
        out[4 * i + 1] = (s.h[i] >> 16) as! u8;
        out[4 * i + 2] = (s.h[i] >> 8) as! u8;
        out[4 * i + 3] = s.h[i] as! u8;
    }
}

fn sha256_of(data: const u8[:], out: u8[32]&) {
    var s = sha256();
    update(s, data);
    finish(s, out);
}

// HMAC with the key's two padded blocks already absorbed, so each MAC costs the message plus two blocks.
struct Hmac { inner: Sha256, outer: Sha256 }

fn hmac_key(key: const u8[:]) -> Hmac {
    var k: u8[64] = [0; 64];
    if key.len > 64 {
        var d: u8[32] = [0; 32];
        sha256_of(key, d);
        for i in 32 { k[i] = d[i]; }
    } else {
        for c, i in key { k[i] = c; }
    }
    var ipad: u8[64] = [0; 64];
    var opad: u8[64] = [0; 64];
    for i in 64 { ipad[i] = k[i] ^ 0x36; opad[i] = k[i] ^ 0x5c; }
    var m = Hmac { inner: sha256(), outer: sha256() };
    update(m.inner, ipad);
    update(m.outer, opad);
    return m;
}

fn hmac(key: const Hmac&, parts: const u8[:][:], out: u8[32]&) {
    var s = key.inner;
    for p in parts { update(s, p); }
    var d: u8[32] = [0; 32];
    finish(s, d);
    var o = key.outer;
    update(o, d);
    finish(o, out);
}

fn hmac1(key: const Hmac&, msg: const u8[:], out: u8[32]&) {
    let parts: const u8[:][1] = [msg];
    hmac(key, parts, out);
}

// PBKDF2-HMAC-SHA256 with a 32-byte output: one block.
fn pbkdf2(password: const u8[:], salt: const u8[:], iterations: i64, out: u8[32]&) {
    let key = hmac_key(password);
    let one: u8[4] = [0, 0, 0, 1];
    let parts: const u8[:][2] = [salt, one[..]];
    var u: u8[32] = [0; 32];
    hmac(key, parts, u);
    out = u;
    for n in 1..iterations {
        var next: u8[32] = [0; 32];
        hmac1(key, u, next);
        u = next;
        for i in 32 { out[i] ^= u[i]; }
    }
}

// ---------- base64url without padding ----------

let B64URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

fn b64url_encode(out: u8[>..]&, data: const u8[:]) {
    var i = 0;
    while i + 3 <= data.len {
        let v = (data[i] as i64) << 16 | (data[i + 1] as i64) << 8 | data[i + 2];
        out.push(B64URL[v >> 18]); out.push(B64URL[(v >> 12) & 63]);
        out.push(B64URL[(v >> 6) & 63]); out.push(B64URL[v & 63]);
        i += 3;
    }
    let rest = data.len - i;
    if rest == 1 {
        let v = (data[i] as i64) << 16;
        out.push(B64URL[v >> 18]); out.push(B64URL[(v >> 12) & 63]);
    } else if rest == 2 {
        let v = (data[i] as i64) << 16 | (data[i + 1] as i64) << 8;
        out.push(B64URL[v >> 18]); out.push(B64URL[(v >> 12) & 63]); out.push(B64URL[(v >> 6) & 63]);
    }
}

fn b64url_value(c: u8) -> i64 {
    if c >= 'A' && c <= 'Z' { return c - 'A'; }
    if c >= 'a' && c <= 'z' { return c - 'a' + 26; }
    if c >= '0' && c <= '9' { return c - '0' + 52; }
    if c == '-' { return 62; }
    if c == '_' { return 63; }
    return -1;
}

// Decodes text into out; false on a character outside the alphabet, a length no encoding has, or leftover bits.
fn b64url_decode(out: u8[>..]&, text: const u8[:]) -> bool {
    if text.len % 4 == 1 { return false; }
    var acc = 0;
    var bits = 0;
    for c in text {
        let v = b64url_value(c);
        if v < 0 { return false; }
        acc = (acc << 6 | v) & 0xffffff;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push(((acc >> bits) & 0xff) as! u8);
        }
    }
    return acc & ((1 << bits) - 1) == 0;
}

// Constant-time equality of two MACs.
fn same_bytes(a: const u8[:], b: const u8[:]) -> bool {
    if a.len != b.len { return false; }
    var d: u8 = 0;
    for i in a.len { d |= a[i] ^ b[i]; }
    return d == 0;
}
