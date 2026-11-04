//! HS256 tokens, verified on every request (signature, alg, exp, nbf); nothing is cached between requests.
//!
//! The HMAC key schedule (the ipad/opad blocks) is computed once at startup and cloned per token: that caches the
//! key's setup, not any token's verification.

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use hmac::{Hmac, Mac};
use serde_json::Value;
use sha2::Sha256;

type HmacSha256 = Hmac<Sha256>;

/// `{"alg":"HS256","typ":"JWT"}`, the header every token we issue carries.
const HEADER: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";

pub struct Keys {
    mac: HmacSha256,
}

fn now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

fn number(v: &Value) -> Option<f64> {
    v.as_f64()
}

impl Keys {
    pub fn new(secret: &[u8]) -> Keys {
        Keys { mac: HmacSha256::new_from_slice(secret).expect("hmac key") }
    }

    /// The user id of a valid token.
    pub fn verify(&self, token: &[u8]) -> Option<i64> {
        let d1 = memchr::memchr(b'.', token)?;
        let d2 = d1 + 1 + memchr::memchr(b'.', &token[d1 + 1..])?;
        let (h, p, s) = (&token[..d1], &token[d1 + 1..d2], &token[d2 + 1..]);
        if s.len() != 43 {
            return None; // 32 bytes, unpadded base64url
        }
        let mut sig = [0u8; 33];
        if B64.decode_slice(s, &mut sig).ok()? != 32 {
            return None;
        }
        let mut mac = self.mac.clone();
        mac.update(&token[..d2]);
        mac.verify_slice(&sig[..32]).ok()?;
        if h != HEADER.as_bytes() {
            let hv: Value = serde_json::from_slice(&B64.decode(h).ok()?).ok()?;
            if hv.get("alg")?.as_str()? != "HS256" {
                return None;
            }
        }
        let mut pb = [0u8; 512];
        let n = B64.decode_slice(p, &mut pb).ok()?;
        let claims: Claims = serde_json::from_slice(&pb[..n]).ok()?;
        let t = now();
        if !(t < number(claims.exp.as_ref()?)?) {
            return None;
        }
        if let Some(nbf) = &claims.nbf {
            if t < number(nbf)? {
                return None;
            }
        }
        if let Some(iat) = &claims.iat {
            number(iat)?;
        }
        let sub = claims.sub?;
        if sub.is_empty() || sub.len() > 18 || !sub.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        let id: i64 = sub.parse().ok()?;
        (id > 0).then_some(id)
    }

    /// A fresh token for user `id`, valid for 30 days.
    pub fn issue(&self, id: i64) -> String {
        let iat = now() as i64;
        let payload = format!("{{\"sub\":\"{id}\",\"iat\":{iat},\"exp\":{}}}", iat + 30 * 24 * 3600);
        let mut t = String::with_capacity(160);
        t.push_str(HEADER);
        t.push('.');
        B64.encode_string(payload.as_bytes(), &mut t);
        let mut mac = self.mac.clone();
        mac.update(t.as_bytes());
        t.push('.');
        B64.encode_string(mac.finalize().into_bytes(), &mut t);
        t
    }
}

/// The claims we read; anything else in the payload is ignored.
#[derive(serde::Deserialize)]
struct Claims {
    sub: Option<String>,
    exp: Option<Value>,
    nbf: Option<Value>,
    iat: Option<Value>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_and_tamper() {
        let k = Keys::new(b"secret");
        let t = k.issue(42);
        assert_eq!(k.verify(t.as_bytes()), Some(42));
        let mut bad = t.clone().into_bytes();
        let l = bad.len();
        bad[l - 2] ^= 1;
        assert_eq!(k.verify(&bad), None);
        assert_eq!(Keys::new(b"other").verify(t.as_bytes()), None);
        assert_eq!(k.verify(b"a.b"), None);
        assert_eq!(k.verify(b""), None);
    }

    fn sign(k: &Keys, header: &str, payload: &str) -> String {
        let mut t = format!("{}.{}", B64.encode(header), B64.encode(payload));
        let mut mac = k.mac.clone();
        mac.update(t.as_bytes());
        t.push('.');
        t.push_str(&B64.encode(mac.finalize().into_bytes()));
        t
    }

    #[test]
    fn claims() {
        let k = Keys::new(b"s");
        let hs = r#"{"alg":"HS256","typ":"JWT"}"#;
        let far = now() as i64 + 1000;
        assert_eq!(k.verify(sign(&k, hs, &format!(r#"{{"sub":"7","exp":{far}}}"#)).as_bytes()), Some(7));
        // expired, missing exp, non-numeric sub, other alg, not-yet-valid
        assert_eq!(k.verify(sign(&k, hs, r#"{"sub":"7","exp":1}"#).as_bytes()), None);
        assert_eq!(k.verify(sign(&k, hs, r#"{"sub":"7"}"#).as_bytes()), None);
        assert_eq!(k.verify(sign(&k, hs, &format!(r#"{{"sub":"x","exp":{far}}}"#)).as_bytes()), None);
        assert_eq!(k.verify(sign(&k, r#"{"alg":"none"}"#, &format!(r#"{{"sub":"7","exp":{far}}}"#)).as_bytes()), None);
        assert_eq!(k.verify(sign(&k, hs, &format!(r#"{{"sub":"7","exp":{far},"nbf":{far}}}"#)).as_bytes()), None);
    }
}
