//! HS256 JWTs, checked in full on every request (signature, `alg`, `exp`, `nbf`); nothing is cached.

use std::time::{SystemTime, UNIX_EPOCH};

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use hmac::{Hmac, Mac};
use serde::Deserialize;
use sha2::Sha256;
use std::borrow::Cow;

const TOKEN_TTL_SECS: u64 = 30 * 24 * 60 * 60;
/// base64url(`{"alg":"HS256","typ":"JWT"}`)
const HEADER: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";

pub struct Jwt {
    mac: Hmac<Sha256>,
}

impl Jwt {
    pub fn new(secret: &str) -> Self {
        Jwt {
            mac: Hmac::new_from_slice(secret.as_bytes()).expect("HMAC takes any key length"),
        }
    }

    /// A fresh token: claims exactly `{"sub": "<id>", "iat": now, "exp": now + 30 days}`.
    pub fn issue(&self, user_id: i64) -> String {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let payload = format!(
            r#"{{"sub":"{user_id}","iat":{now},"exp":{}}}"#,
            now + TOKEN_TTL_SECS
        );
        let mut token = String::with_capacity(160);
        token.push_str(HEADER);
        token.push('.');
        URL_SAFE_NO_PAD.encode_string(payload, &mut token);
        let mut mac = self.mac.clone();
        mac.update(token.as_bytes());
        let sig = mac.finalize().into_bytes();
        token.push('.');
        URL_SAFE_NO_PAD.encode_string(sig, &mut token);
        token
    }

    /// The user id in a valid token, or None (→ 401).
    pub fn verify(&self, token: &str) -> Option<i64> {
        let (signed, sig) = token.rsplit_once('.')?;
        let (header, payload) = signed.split_once('.')?;
        if payload.contains('.') {
            return None;
        }
        let mut sig_bytes = [0u8; 32];
        let n = URL_SAFE_NO_PAD.decode_slice(sig, &mut sig_bytes).ok()?;
        if n != 32 {
            return None;
        }
        let mut mac = self.mac.clone();
        mac.update(signed.as_bytes());
        mac.verify_slice(&sig_bytes).ok()?;

        // The standard header has a known HS256 algorithm. Its signature is
        // still verified above on every request; other valid headers use JSON.
        if header != HEADER {
            let mut header_buf = [0u8; 512];
            let bytes = decode(header, &mut header_buf)?;
            if bytes.trim_ascii_start().first() != Some(&b'{') {
                return None;
            }
            #[derive(Deserialize)]
            struct Header<'a> {
                #[serde(borrow)]
                alg: Cow<'a, str>,
            }
            let decoded: Header<'_> = serde_json::from_slice(&bytes).ok()?;
            if decoded.alg != "HS256" {
                return None;
            }
        }
        let mut payload_buf = [0u8; 2048];
        let payload_bytes = decode(payload, &mut payload_buf)?;
        if payload_bytes.trim_ascii_start().first() != Some(&b'{') {
            return None;
        }
        #[derive(Deserialize)]
        struct Claims<'a> {
            #[serde(borrow)]
            sub: Cow<'a, str>,
            exp: f64,
            nbf: Option<f64>,
        }
        // Tokens issued by this service and by the load generator use this exact
        // compact layout. Signature verification has already happened above, so a
        // strict byte-level parse avoids serde's general JSON machinery on the hot
        // path. Any other valid claim layout falls back to the full parser below.
        if let Some((sub, exp)) = fast_claims(&payload_bytes) {
            let now = SystemTime::now().duration_since(UNIX_EPOCH).ok()?.as_secs();
            return (now < exp).then_some(sub);
        }
        let claims: Claims<'_> = serde_json::from_slice(&payload_bytes).ok()?;
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .ok()?
            .as_secs_f64();
        if now >= claims.exp || claims.nbf.is_some_and(|nbf| now < nbf) {
            return None;
        }
        crate::parse_uint(&claims.sub).filter(|id| *id > 0)
    }
}

/// Parse the canonical claims emitted by `issue` and the benchmark loadgen:
/// `{"sub":"<digits>","iat":<digits>,"exp":<digits>}`.
///
/// This intentionally accepts only the exact shape. Claims with reordered fields,
/// whitespace, escapes, fractional numbers, or an optional `nbf` use serde_json's
/// complete validation path instead.
fn fast_claims(bytes: &[u8]) -> Option<(i64, u64)> {
    const SUB: &[u8] = b"{\"sub\":\"";
    const IAT: &[u8] = b"\",\"iat\":";
    const EXP: &[u8] = b",\"exp\":";
    if !bytes.starts_with(SUB) {
        return None;
    }
    let mut at = SUB.len();
    let sub_start = at;
    while bytes.get(at).is_some_and(u8::is_ascii_digit) {
        at += 1;
    }
    let sub = crate::parse_uint(std::str::from_utf8(bytes.get(sub_start..at)?).ok()?)?;
    if sub <= 0 || bytes.get(at) != Some(&b'"') || !bytes.get(at + 1..)?.starts_with(IAT) {
        return None;
    }
    at += 1 + IAT.len();
    let iat_start = at;
    while bytes.get(at).is_some_and(u8::is_ascii_digit) {
        at += 1;
    }
    if bytes.get(iat_start) == Some(&b'0')
        && bytes.get(iat_start + 1).is_some_and(u8::is_ascii_digit)
    {
        return None;
    }
    crate::parse_uint(std::str::from_utf8(bytes.get(iat_start..at)?).ok()?)?;
    if !bytes.get(at..)?.starts_with(EXP) {
        return None;
    }
    at += EXP.len();
    let exp_start = at;
    while bytes.get(at).is_some_and(u8::is_ascii_digit) {
        at += 1;
    }
    if bytes.get(exp_start) == Some(&b'0')
        && bytes.get(exp_start + 1).is_some_and(u8::is_ascii_digit)
    {
        return None;
    }
    let exp = crate::parse_uint(std::str::from_utf8(bytes.get(exp_start..at)?).ok()?)?;
    if bytes.get(at) != Some(&b'}') || at + 1 != bytes.len() {
        return None;
    }
    Some((sub, exp as u64))
}

fn decode<'a>(s: &str, stack: &'a mut [u8]) -> Option<Cow<'a, [u8]>> {
    if base64::decoded_len_estimate(s.len()) <= stack.len() {
        let n = URL_SAFE_NO_PAD.decode_slice(s, stack).ok()?;
        Some(Cow::Borrowed(&stack[..n]))
    } else {
        Some(Cow::Owned(URL_SAFE_NO_PAD.decode(s).ok()?))
    }
}
