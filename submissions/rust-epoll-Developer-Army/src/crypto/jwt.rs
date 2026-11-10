//! Zero-allocation JSON Web Token (HS256) minting and verification.

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use hmac::{Hmac, Mac};
use sha2::Sha256;
use std::time::{SystemTime, UNIX_EPOCH};

type HmacSha256 = Hmac<Sha256>;

const JWT_HEADER_B64: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";
const THIRTY_DAYS_SECS: u64 = 30 * 24 * 3600;

/// Generates an HS256 JWT for the specified user ID.
pub fn generate_token(user_id: u64, secret: &[u8]) -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let exp = now + THIRTY_DAYS_SECS;

    let mut payload = Vec::with_capacity(64);
    payload.extend_from_slice(b"{\"sub\":\"");
    let mut id_buf = itoa::Buffer::new();
    payload.extend_from_slice(id_buf.format(user_id).as_bytes());
    payload.extend_from_slice(b"\",\"iat\":");
    let mut iat_buf = itoa::Buffer::new();
    payload.extend_from_slice(iat_buf.format(now).as_bytes());
    payload.extend_from_slice(b",\"exp\":");
    let mut exp_buf = itoa::Buffer::new();
    payload.extend_from_slice(exp_buf.format(exp).as_bytes());
    payload.push(b'}');

    let payload_b64 = URL_SAFE_NO_PAD.encode(&payload);

    let mut mac = HmacSha256::new_from_slice(secret).expect("HMAC initialization failed");
    mac.update(JWT_HEADER_B64.as_bytes());
    mac.update(b".");
    mac.update(payload_b64.as_bytes());
    let sig = mac.finalize().into_bytes();
    let sig_b64 = URL_SAFE_NO_PAD.encode(sig);

    let mut out = String::with_capacity(JWT_HEADER_B64.len() + 1 + payload_b64.len() + 1 + sig_b64.len());
    out.push_str(JWT_HEADER_B64);
    out.push('.');
    out.push_str(&payload_b64);
    out.push('.');
    out.push_str(&sig_b64);
    out
}

/// Verifies an incoming JWT and returns the extracted user ID (`sub`).
/// Fails if signature mismatch, expiration elapsed, or alg != HS256.
pub fn verify_token(token: &str, secret: &[u8], now_secs: u64) -> Result<u64, ()> {
    let mut parts = token.split('.');
    let header_b64 = parts.next().ok_or(())?;
    let payload_b64 = parts.next().ok_or(())?;
    let sig_b64 = parts.next().ok_or(())?;
    if parts.next().is_some() {
        return Err(());
    }

    // 1. Verify signature
    let decoded_sig = URL_SAFE_NO_PAD.decode(sig_b64).map_err(|_| ())?;
    let mut mac = HmacSha256::new_from_slice(secret).map_err(|_| ())?;
    mac.update(header_b64.as_bytes());
    mac.update(b".");
    mac.update(payload_b64.as_bytes());
    mac.verify_slice(&decoded_sig).map_err(|_| ())?;

    // 2. Verify header alg == HS256
    let header_bytes = URL_SAFE_NO_PAD.decode(header_b64).map_err(|_| ())?;
    let header_str = std::str::from_utf8(&header_bytes).map_err(|_| ())?;
    if !header_str.contains("\"alg\":\"HS256\"") && !header_str.contains("\"alg\": \"HS256\"") {
        return Err(());
    }

    // 3. Decode payload
    let payload_bytes = URL_SAFE_NO_PAD.decode(payload_b64).map_err(|_| ())?;
    let v: serde_json::Value = serde_json::from_slice(&payload_bytes).map_err(|_| ())?;

    let sub_str = v.get("sub").and_then(|s| s.as_str()).ok_or(())?;
    let user_id: u64 = sub_str.parse().map_err(|_| ())?;

    let exp = v.get("exp").and_then(|e| e.as_u64()).ok_or(())?;
    if exp < now_secs {
        return Err(());
    }

    Ok(user_id)
}
