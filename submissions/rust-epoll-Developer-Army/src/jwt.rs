//! HS256 JWTs: verified on every request (signature, alg, exp, nbf), never cached.

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use hmac::{Hmac, Mac};
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
            let mut hb = [0u8; 128];
            let n = B64.decode_slice(h, &mut hb).ok()?;
            let hv: serde_json::Value = serde_json::from_slice(&hb[..n]).ok()?;
            if hv.get("alg")?.as_str()? != "HS256" {
                return None;
            }
        }

        // Fast payload decode into stack buffer
        let mut pb = [0u8; 256];
        let n = B64.decode_slice(p, &mut pb).ok()?;
        let payload = &pb[..n];

        // Parse JSON payload
        let pv: serde_json::Value = serde_json::from_slice(payload).ok()?;
        let obj = pv.as_object()?;
        let now = now_f64();

        // exp is required and must be in the future.
        let exp = obj.get("exp")?.as_f64()?;
        if !(now < exp) {
            return None;
        }
        if let Some(nbf) = obj.get("nbf") {
            if now < nbf.as_f64()? {
                return None;
            }
        }
        if let Some(iat) = obj.get("iat") {
            iat.as_f64()?;
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
        B64.encode_string(&sig, &mut t);
        t
    }
}
