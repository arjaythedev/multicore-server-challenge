//! HS256 JWTs: verified on every request (signature, alg, exp, nbf), never cached.

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use hmac::{Hmac, Mac};
use serde_json::Value;
use sha2::Sha256;

type HmacSha256 = Hmac<Sha256>;

pub struct Keys {
    mac: HmacSha256,
}

pub fn now_secs() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

fn now_f64() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

const HEADER_B64: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"; // {"alg":"HS256","typ":"JWT"}

fn numeric(v: &Value) -> Option<f64> {
    match v {
        Value::Number(n) => n.as_f64(),
        _ => None,
    }
}

impl Keys {
    pub fn new(secret: &[u8]) -> Keys {
        Keys { mac: HmacSha256::new_from_slice(secret).expect("hmac key") }
    }

    /// Returns the user id of a valid token, or None.
    pub fn verify(&self, token: &[u8]) -> Option<i64> {
        let d1 = memchr::memchr(b'.', token)?;
        let d2 = d1 + 1 + memchr::memchr(b'.', &token[d1 + 1..])?;
        let (h, p, s) = (&token[..d1], &token[d1 + 1..d2], &token[d2 + 1..]);
        if memchr::memchr(b'.', s).is_some() {
            return None;
        }
        let mut sig = [0u8; 48];
        let n = B64.decode_slice(s, &mut sig).ok()?;
        if n != 32 {
            return None;
        }
        let mut mac = self.mac.clone();
        mac.update(&token[..d2]);
        mac.verify_slice(&sig[..32]).ok()?;
        // Header: alg must be exactly HS256.
        if h != HEADER_B64.as_bytes() {
            let hb = B64.decode(h).ok()?;
            let hv: Value = serde_json::from_slice(&hb).ok()?;
            if hv.get("alg")?.as_str()? != "HS256" {
                return None;
            }
        }
        let pb = B64.decode(p).ok()?;
        let pv: Value = serde_json::from_slice(&pb).ok()?;
        let obj = pv.as_object()?;
        let now = now_f64();
        // exp is required and must be in the future.
        let exp = numeric(obj.get("exp")?)?;
        if !(now < exp) {
            return None;
        }
        if let Some(nbf) = obj.get("nbf") {
            if now < numeric(nbf)? {
                return None;
            }
        }
        if let Some(iat) = obj.get("iat") {
            numeric(iat)?;
        }
        let sub = obj.get("sub")?.as_str()?;
        if sub.is_empty() || !sub.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        let id: i64 = sub.parse().ok()?;
        if id <= 0 {
            return None;
        }
        Some(id)
    }

    /// A fresh token for user `id`: {"exp","iat","sub"} with exp = iat + 30 days.
    pub fn issue(&self, id: i64) -> String {
        let iat = now_secs();
        let payload = format!("{{\"exp\":{},\"iat\":{},\"sub\":\"{}\"}}", iat + 30 * 24 * 3600, iat, id);
        let mut t = String::with_capacity(160);
        t.push_str(HEADER_B64);
        t.push('.');
        B64.encode_string(payload.as_bytes(), &mut t);
        let mut mac = self.mac.clone();
        mac.update(t.as_bytes());
        let sig = mac.finalize().into_bytes();
        t.push('.');
        B64.encode_string(sig, &mut t);
        t
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn roundtrip() {
        let k = Keys::new(b"secret");
        let t = k.issue(42);
        assert_eq!(k.verify(t.as_bytes()), Some(42));
        let mut bad = t.clone().into_bytes();
        let l = bad.len();
        bad[l - 2] ^= 1;
        assert_eq!(k.verify(&bad), None);
        assert_eq!(Keys::new(b"other").verify(t.as_bytes()), None);
    }
}
