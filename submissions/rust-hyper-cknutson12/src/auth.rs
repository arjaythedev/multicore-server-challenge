//! HS256 JWTs, checked in full on every request (signature, `alg`, `exp`, `nbf`); nothing is cached.

use std::time::{SystemTime, UNIX_EPOCH};

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use hmac::{Hmac, Mac};
use serde_json::{Map, Value};
use sha2::Sha256;

const TOKEN_TTL_SECS: u64 = 30 * 24 * 60 * 60;
/// base64url(`{"alg":"HS256","typ":"JWT"}`)
const HEADER: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";

pub struct Jwt {
    mac: Hmac<Sha256>,
}

impl Jwt {
    pub fn new(secret: &str) -> Self {
        Jwt { mac: Hmac::new_from_slice(secret.as_bytes()).expect("HMAC takes any key length") }
    }

    /// A fresh token: claims exactly `{"sub": "<id>", "iat": now, "exp": now + 30 days}`.
    pub fn issue(&self, user_id: i64) -> String {
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
        let payload = format!(r#"{{"sub":"{user_id}","iat":{now},"exp":{}}}"#, now + TOKEN_TTL_SECS);
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
        let sig = URL_SAFE_NO_PAD.decode(sig).ok()?;
        let mut mac = self.mac.clone();
        mac.update(signed.as_bytes());
        mac.verify_slice(&sig).ok()?;

        let header: Map<String, Value> = serde_json::from_slice(&URL_SAFE_NO_PAD.decode(header).ok()?).ok()?;
        if header.get("alg").and_then(Value::as_str) != Some("HS256") {
            return None;
        }
        let claims: Map<String, Value> = serde_json::from_slice(&URL_SAFE_NO_PAD.decode(payload).ok()?).ok()?;
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs_f64();
        let exp = claims.get("exp")?.as_f64()?;
        if now >= exp {
            return None;
        }
        if let Some(nbf) = claims.get("nbf") {
            if now < nbf.as_f64()? {
                return None;
            }
        }
        let sub = claims.get("sub")?.as_str()?;
        crate::parse_uint(sub).filter(|id| *id > 0)
    }
}
