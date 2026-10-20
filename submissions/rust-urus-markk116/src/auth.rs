//! HS256 JWT issue and verify (claims sub/iat/exp), per SPEC.md "Authentication".

use std::time::{SystemTime, UNIX_EPOCH};

use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use base64::Engine as _;
use hmac::{Hmac, Mac};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use sha2::Sha256;

type HmacSha256 = Hmac<Sha256>;

const TOKEN_TTL_SECS: u64 = 30 * 24 * 60 * 60;

#[derive(Serialize, Deserialize)]
struct Header {
    alg: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    typ: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct Claims {
    /// The user id, as a decimal string.
    sub: String,
    #[serde(default)]
    iat: u64,
    exp: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    nbf: Option<u64>,
}

pub struct Jwt {
    mac: HmacSha256,
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs())
}

fn encode_json(value: &impl Serialize) -> String {
    B64.encode(serde_json::to_vec(value).unwrap_or_default())
}

fn decode_json<T: DeserializeOwned>(part: &str) -> Option<T> {
    serde_json::from_slice(&B64.decode(part).ok()?).ok()
}

impl Jwt {
    pub fn new(secret: &str) -> Jwt {
        Jwt { mac: HmacSha256::new_from_slice(secret.as_bytes()).expect("HMAC takes keys of any length") }
    }

    pub fn issue(&self, user_id: i64) -> String {
        let iat = now();
        let header = Header { alg: "HS256".into(), typ: Some("JWT".into()) };
        let claims = Claims { sub: user_id.to_string(), iat, exp: iat + TOKEN_TTL_SECS, nbf: None };
        let signed = format!("{}.{}", encode_json(&header), encode_json(&claims));
        let signature = B64.encode(self.sign(&signed));
        format!("{signed}.{signature}")
    }

    /// The user id of a valid token: HS256 signature, alg must be HS256, `exp` required and
    /// not past, `nbf` (if present) not in the future, `sub` a positive decimal id.
    pub fn verify(&self, token: &str) -> Option<i64> {
        let mut parts = token.split('.');
        let (header, claims, signature) = (parts.next()?, parts.next()?, parts.next()?);
        if parts.next().is_some() {
            return None;
        }
        let signed = &token[..header.len() + 1 + claims.len()];
        let mut mac = self.mac.clone();
        mac.update(signed.as_bytes());
        mac.verify_slice(&B64.decode(signature).ok()?).ok()?;

        if decode_json::<Header>(header)?.alg != "HS256" {
            return None;
        }
        let claims: Claims = decode_json(claims)?;
        let t = now();
        if claims.exp < t || claims.nbf.is_some_and(|nbf| nbf > t) {
            return None;
        }
        crate::http::parse_uint(&claims.sub).filter(|&id| id > 0)
    }

    fn sign(&self, data: &str) -> Vec<u8> {
        let mut mac = self.mac.clone();
        mac.update(data.as_bytes());
        mac.finalize().into_bytes().to_vec()
    }
}
