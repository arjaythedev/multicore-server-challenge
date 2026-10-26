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
        // Issued payloads are ~60 bytes; longer ones decode on the heap.
        let mut payload_buf = [0u8; 256];
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
        // Claims exactly as `issue` writes them are read directly; anything else goes through serde_json.
        let claims = match issued_claims(&payload_bytes) {
            Some((sub, exp)) => Claims {
                sub: Cow::Borrowed(sub),
                exp,
                nbf: None,
            },
            None => serde_json::from_slice(&payload_bytes).ok()?,
        };
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .ok()?
            .as_secs_f64();
        if now >= claims.exp || claims.nbf.is_some_and(|nbf| now < nbf) {
            return None;
        }
        let sub = &claims.sub;
        crate::parse_uint(sub).filter(|id| *id > 0)
    }
}

/// `(sub, exp)` from a payload of exactly the form `issue` writes, `{"sub":"<digits>","iat":<n>,"exp":<n>}`, with
/// canonical JSON integers of at most 15 digits (exact as f64, as serde_json reads them); None for anything else.
fn issued_claims(payload: &[u8]) -> Option<(&str, f64)> {
    fn digits(s: &[u8]) -> usize {
        s.iter().take_while(|b| b.is_ascii_digit()).count()
    }
    fn number(s: &[u8]) -> Option<(f64, &[u8])> {
        let n = digits(s);
        if n == 0 || n > 15 || (n > 1 && s[0] == b'0') {
            return None;
        }
        let v = s[..n].iter().fold(0u64, |v, d| v * 10 + u64::from(d - b'0'));
        Some((v as f64, &s[n..]))
    }
    let rest = payload.strip_prefix(br#"{"sub":""#)?;
    let n = digits(rest);
    let (sub, rest) = rest.split_at(n);
    if n == 0 {
        return None;
    }
    let (_, rest) = number(rest.strip_prefix(br#"","iat":"#)?)?;
    let (exp, rest) = number(rest.strip_prefix(br#","exp":"#)?)?;
    if rest != b"}" {
        return None;
    }
    // ASCII digits.
    Some((std::str::from_utf8(sub).ok()?, exp))
}

fn decode<'a>(s: &str, stack: &'a mut [u8]) -> Option<Cow<'a, [u8]>> {
    if base64::decoded_len_estimate(s.len()) <= stack.len() {
        let n = URL_SAFE_NO_PAD.decode_slice(s, stack).ok()?;
        Some(Cow::Borrowed(&stack[..n]))
    } else {
        Some(Cow::Owned(URL_SAFE_NO_PAD.decode(s).ok()?))
    }
}
