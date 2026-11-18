//! JWT (HS256) handling. Nothing is cached: every request re-verifies signature and `exp`.

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use memchr::memchr;
use ring::hmac;
use serde_json::Value;

use crate::json::push_i64;

/// base64url of `{"alg":"HS256","typ":"JWT"}` — the header we emit, so the common case needs no decode.
const HEADER_B64: &[u8] = b"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";
const TTL_SECS: i64 = 30 * 24 * 3600;

pub enum AuthState {
    /// No Authorization header.
    Anonymous,
    User(i64),
    /// Header present but malformed, wrong algorithm, bad signature or expired (=> 401).
    Invalid,
}

pub struct Jwt {
    key: hmac::Key,
}

impl Jwt {
    pub fn new(secret: &[u8]) -> Jwt {
        Jwt {
            key: hmac::Key::new(hmac::HMAC_SHA256, secret),
        }
    }

    pub fn check(&self, header: Option<&[u8]>, now: i64) -> AuthState {
        match header {
            None => AuthState::Anonymous,
            Some(h) => match self.verify(h, now) {
                Some(id) => AuthState::User(id),
                None => AuthState::Invalid,
            },
        }
    }

    fn verify(&self, raw: &[u8], now: i64) -> Option<i64> {
        let token = raw.strip_prefix(b"Token ")?;
        let d1 = memchr(b'.', token)?;
        let rest = &token[d1 + 1..];
        let d2 = memchr(b'.', rest)?;
        let header_b64 = &token[..d1];
        let payload_b64 = &rest[..d2];
        let sig_b64 = &rest[d2 + 1..];

        if !header_ok(header_b64) {
            return None;
        }

        let mut sig = [0u8; 64];
        let sig_len = URL_SAFE_NO_PAD.decode_slice(sig_b64, &mut sig).ok()?;
        let signed = &token[..d1 + 1 + d2];
        hmac::verify(&self.key, signed, &sig[..sig_len]).ok()?;

        let (sub, exp) = claims(payload_b64)?;
        if exp <= now || sub <= 0 {
            return None;
        }
        Some(sub)
    }

    /// Appends `header.payload.signature` for user `id` to `out`.
    pub fn sign(&self, id: i64, now: i64, out: &mut Vec<u8>) {
        let start = out.len();
        out.extend_from_slice(HEADER_B64);
        out.push(b'.');
        let mut payload: Vec<u8> = Vec::with_capacity(64);
        payload.extend_from_slice(b"{\"sub\":\"");
        push_i64(&mut payload, id);
        payload.extend_from_slice(b"\",\"iat\":");
        push_i64(&mut payload, now);
        payload.extend_from_slice(b",\"exp\":");
        push_i64(&mut payload, now + TTL_SECS);
        payload.push(b'}');
        let enc = URL_SAFE_NO_PAD.encode(&payload);
        out.extend_from_slice(enc.as_bytes());
        let tag = hmac::sign(&self.key, &out[start..]);
        out.push(b'.');
        let sig = URL_SAFE_NO_PAD.encode(tag.as_ref());
        out.extend_from_slice(sig.as_bytes());
    }
}

/// Accepts exactly `alg == "HS256"`. (The user's original substring search for "HS256" also accepted
/// headers like {"alg":"none","x":"HS256"}.)
fn header_ok(header_b64: &[u8]) -> bool {
    if header_b64 == HEADER_B64 {
        return true;
    }
    let mut buf = [0u8; 160];
    let n = match URL_SAFE_NO_PAD.decode_slice(header_b64, &mut buf) {
        Ok(n) => n,
        Err(_) => return false,
    };
    match serde_json::from_slice::<Value>(&buf[..n]) {
        Ok(v) => v.get("alg").and_then(|a| a.as_str()) == Some("HS256"),
        Err(_) => false,
    }
}

/// (sub, exp) from a payload that has already passed signature verification.
fn claims(payload_b64: &[u8]) -> Option<(i64, i64)> {
    let mut buf = [0u8; 256];
    let n = URL_SAFE_NO_PAD.decode_slice(payload_b64, &mut buf).ok()?;
    let p = &buf[..n];

    // Fast path: tokens we minted ourselves (and most libraries) look like {"sub":"123","iat":..,"exp":..}
    if let (Some(sub), Some(exp)) = (scan_sub(p), scan_exp(p)) {
        return Some((sub, exp));
    }

    // Slow path: anything else that is still valid JSON.
    let v: Value = serde_json::from_slice(p).ok()?;
    // SPEC: `sub` is the user id as a decimal *string*; a JSON number is not a valid token.
    let sub = match v.get("sub")? {
        Value::String(s) => s.parse::<i64>().ok()?,
        _ => return None,
    };
    let exp = match v.get("exp")? {
        Value::Number(num) => match num.as_i64() {
            Some(x) => x,
            None => num.as_f64()? as i64,
        },
        _ => return None,
    };
    Some((sub, exp))
}

fn after_key(p: &[u8], key: &[u8]) -> Option<usize> {
    let mut i = memchr::memmem::find(p, key)? + key.len();
    while i < p.len() && p[i] == b' ' {
        i += 1;
    }
    if i >= p.len() || p[i] != b':' {
        return None;
    }
    i += 1;
    while i < p.len() && p[i] == b' ' {
        i += 1;
    }
    Some(i)
}

fn scan_exp(p: &[u8]) -> Option<i64> {
    let mut i = after_key(p, b"\"exp\"")?;
    let start = i;
    let mut v: i64 = 0;
    while i < p.len() && p[i].is_ascii_digit() {
        v = v.checked_mul(10)?.checked_add((p[i] - b'0') as i64)?;
        i += 1;
    }
    if i == start {
        return None;
    }
    // Only plain integers on the fast path (floats go through serde_json).
    if i < p.len() && !(p[i] == b',' || p[i] == b'}' || p[i] == b' ') {
        return None;
    }
    Some(v)
}

fn scan_sub(p: &[u8]) -> Option<i64> {
    let mut i = after_key(p, b"\"sub\"")?;
    // Only a quoted decimal string is accepted ({"sub":100} must give 401).
    if i >= p.len() || p[i] != b'"' {
        return None;
    }
    i += 1;
    let start = i;
    let mut v: i64 = 0;
    while i < p.len() && p[i].is_ascii_digit() {
        v = v.checked_mul(10)?.checked_add((p[i] - b'0') as i64)?;
        i += 1;
    }
    if i == start || i >= p.len() || p[i] != b'"' {
        return None;
    }
    Some(v)
}
