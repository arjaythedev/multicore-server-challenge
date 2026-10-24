use std::time::{SystemTime, UNIX_EPOCH};

use ring::hmac;

use crate::json;

const HEADER: &[u8] = br#"{"alg":"HS256","typ":"JWT"}"#;
const THIRTY_DAYS: u64 = 30 * 24 * 3600;

pub struct Jwt {
    key: hmac::Key,
}

pub fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

impl Jwt {
    pub fn new(secret: &[u8]) -> Self {
        Jwt {
            key: hmac::Key::new(hmac::HMAC_SHA256, secret),
        }
    }

    pub fn issue(&self, user_id: i64, out: &mut Vec<u8>) {
        let now = now_secs();
        let start = out.len();
        json::b64url_encode(out, HEADER);
        out.push(b'.');
        let mut claims = Vec::with_capacity(64);
        claims.extend_from_slice(b"{\"sub\":\"");
        json::int(&mut claims, user_id);
        claims.extend_from_slice(b"\",\"iat\":");
        json::int(&mut claims, now as i64);
        claims.extend_from_slice(b",\"exp\":");
        json::int(&mut claims, (now + THIRTY_DAYS) as i64);
        claims.push(b'}');
        json::b64url_encode(out, &claims);
        let tag = hmac::sign(&self.key, &out[start..]);
        out.push(b'.');
        json::b64url_encode(out, tag.as_ref());
    }

    pub fn verify(&self, token: &[u8]) -> Option<i64> {
        let first = token.iter().position(|&c| c == b'.')?;
        let second = first + 1 + token[first + 1..].iter().position(|&c| c == b'.')?;
        let (signed, sig) = (&token[..second], &token[second + 1..]);
        let mut buf = Vec::with_capacity(128);
        if !json::b64_decode(sig, &mut buf) || buf.len() != 32 {
            return None;
        }
        hmac::verify(&self.key, signed, &buf).ok()?;
        buf.clear();
        if !json::b64_decode(&token[..first], &mut buf) {
            return None;
        }
        if buf != HEADER {
            let header: serde_json::Value = serde_json::from_slice(&buf).ok()?;
            if header.get("alg")?.as_str()? != "HS256" {
                return None;
            }
        }
        buf.clear();
        if !json::b64_decode(&token[first + 1..second], &mut buf) {
            return None;
        }
        let claims: serde_json::Value = serde_json::from_slice(&buf).ok()?;
        let exp = claims.get("exp")?.as_f64()?;
        if exp <= now_secs() as f64 {
            return None;
        }
        let sub = claims.get("sub")?.as_str()?;
        if sub.is_empty() || sub.len() > 18 || !sub.bytes().all(|c| c.is_ascii_digit()) {
            return None;
        }
        sub.parse().ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip() {
        let jwt = Jwt::new(b"secret");
        let mut tok = Vec::new();
        jwt.issue(42, &mut tok);
        assert_eq!(jwt.verify(&tok), Some(42));
        assert_eq!(Jwt::new(b"other").verify(&tok), None);
        tok.pop();
        assert_eq!(jwt.verify(&tok), None);
    }
}
