//! Zero-allocation JSON Web Token (JWT) HS256 engine.
//! Verified on every authenticated request with precomputed HMAC midstates.

use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};
use crate::types::Viewer;
use crate::sec::hmac::PrecomputedHmac;

/// Global precomputed HMAC signer initialized with SECRET_KEY (defaults to "secret").
static SIGNER: OnceLock<PrecomputedHmac> = OnceLock::new();

pub fn get_signer() -> &'static PrecomputedHmac {
    SIGNER.get_or_init(|| {
        let secret = std::env::var("JWT_SECRET")
            .or_else(|_| std::env::var("SECRET_KEY"))
            .unwrap_or_else(|_| "secret".to_string());
        PrecomputedHmac::new(secret.as_bytes())
    })
}

/// Standard Base64URL encoding without padding (RFC 7515).
const B64_URL: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

pub fn b64url_encode(data: &[u8], out: &mut String) {
    let mut i = 0;
    while i < data.len() {
        let b0 = data[i];
        i += 1;
        out.push(B64_URL[(b0 >> 2) as usize] as char);
        let mut v = (b0 & 0x03) << 4;
        if i >= data.len() {
            out.push(B64_URL[v as usize] as char);
            break;
        }
        let b1 = data[i];
        i += 1;
        v |= b1 >> 4;
        out.push(B64_URL[v as usize] as char);
        v = (b1 & 0x0f) << 2;
        if i >= data.len() {
            out.push(B64_URL[v as usize] as char);
            break;
        }
        let b2 = data[i];
        i += 1;
        v |= b2 >> 6;
        out.push(B64_URL[v as usize] as char);
        out.push(B64_URL[(b2 & 0x3f) as usize] as char);
    }
}

pub fn b64url_decode(src: &[u8], out: &mut [u8]) -> Option<usize> {
    const fn build_dec_table() -> [u8; 256] {
        let mut t = [0xff; 256];
        let mut i = 0;
        while i < 26 {
            t[(b'A' + i) as usize] = i;
            t[(b'a' + i) as usize] = i + 26;
            i += 1;
        }
        let mut j = 0;
        while j < 10 {
            t[(b'0' + j) as usize] = j + 52;
            j += 1;
        }
        t[b'-' as usize] = 62;
        t[b'_' as usize] = 63;
        t
    }
    const DEC: [u8; 256] = build_dec_table();

    let mut i = 0;
    let mut o = 0;
    while i < src.len() {
        let c0 = DEC[src[i] as usize];
        if c0 == 0xff { return None; }
        i += 1;
        if i >= src.len() { return None; }
        let c1 = DEC[src[i] as usize];
        if c1 == 0xff { return None; }
        i += 1;
        if o < out.len() {
            out[o] = (c0 << 2) | ((c1 & 0x30) >> 4);
            o += 1;
        }
        if i >= src.len() { break; }
        let c2 = DEC[src[i] as usize];
        if c2 == 0xff { return None; }
        i += 1;
        if o < out.len() {
            out[o] = ((c1 & 0x0f) << 4) | ((c2 & 0x3c) >> 2);
            o += 1;
        }
        if i >= src.len() { break; }
        let c3 = DEC[src[i] as usize];
        if c3 == 0xff { return None; }
        i += 1;
        if o < out.len() {
            out[o] = ((c2 & 0x03) << 6) | c3;
            o += 1;
        }
    }
    Some(o)
}

/// Constant-time 32-byte equality check
#[inline(always)]
fn ct_eq32(a: &[u8; 32], b: &[u8; 32]) -> bool {
    let mut diff = 0u8;
    for i in 0..32 {
        diff |= a[i] ^ b[i];
    }
    diff == 0
}

/// Verifies a JWT token and extracts the `Viewer` (user id).
/// - Alg must be HS256
/// - Expiration must be valid (exp >= current timestamp)
/// - Sub must be a valid decimal user ID
pub fn jwt_verify(token: &str) -> Option<Viewer> {
    // Reject Bearer scheme explicitly (SPEC line 31: RealWorld's scheme is Token, not Bearer)
    if token.starts_with("Bearer ") || token.starts_with("bearer ") {
        return None;
    }

    // Strip "Token " / "token " prefix if present
    let token = if let Some(stripped) = token.strip_prefix("Token ") {
        stripped.trim()
    } else if let Some(stripped) = token.strip_prefix("token ") {
        stripped.trim()
    } else {
        token.trim()
    };

    // A valid JWT cannot contain whitespace
    if token.is_empty() || token.contains(' ') || token.contains('\t') {
        return None;
    }

    let token_bytes = token.as_bytes();
    let dot1 = memchr(b'.', token_bytes)?;
    let dot2 = dot1 + 1 + memchr(b'.', &token_bytes[dot1 + 1..])?;

    let signing_input = &token_bytes[..dot2];
    let signature_b64 = &token_bytes[dot2 + 1..];

    // Decode signature
    let mut sig = [0u8; 32];
    let n = b64url_decode(signature_b64, &mut sig)?;
    if n != 32 {
        return None;
    }

    // Verify HMAC
    let expected_sig = get_signer().sign(signing_input);
    if !ct_eq32(&sig, &expected_sig) {
        return None;
    }

    // Decode header: must specify HS256
    let mut header_buf = [0u8; 128];
    let hn = b64url_decode(&token_bytes[..dot1], &mut header_buf)?;
    let header_str = std::str::from_utf8(&header_buf[..hn]).ok()?;
    if !header_str.contains("HS256") {
        return None;
    }

    // Decode payload
    let mut payload_buf = [0u8; 512];
    let pn = b64url_decode(&token_bytes[dot1 + 1..dot2], &mut payload_buf)?;
    let payload = std::str::from_utf8(&payload_buf[..pn]).ok()?;

    // Parse exp: must be >= now
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;

    let exp = parse_json_number(payload, "exp")?;
    if exp < now {
        return None;
    }

    // Parse sub: decimal user ID
    let sub = parse_json_sub(payload)?;
    Some(sub)
}

/// Signs a JWT token for user_id with iat=now and exp=now+30d.
pub fn jwt_sign(user_id: Viewer) -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;
    let exp = now + 30 * 86400; // 30 days

    // Standard header: {"alg":"HS256","typ":"JWT"} -> eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9
    const HEADER_B64: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";

    let payload_json = format!(r#"{{"sub":"{}","iat":{},"exp":{}}}"#, user_id, now, exp);
    let mut payload_b64 = String::with_capacity(64);
    b64url_encode(payload_json.as_bytes(), &mut payload_b64);

    let mut token = String::with_capacity(HEADER_B64.len() + 1 + payload_b64.len() + 1 + 44);
    token.push_str(HEADER_B64);
    token.push('.');
    token.push_str(&payload_b64);

    let sig = get_signer().sign(token.as_bytes());
    token.push('.');
    b64url_encode(&sig, &mut token);

    token
}

#[inline(always)]
fn memchr(needle: u8, haystack: &[u8]) -> Option<usize> {
    haystack.iter().position(|&b| b == needle)
}

fn parse_json_number(json: &str, field: &str) -> Option<i64> {
    let idx = json.find(field)?;
    let rem = &json[idx + field.len()..];
    let colon = rem.find(':')?;
    let val_start = colon + 1;
    let s = rem[val_start..].trim_start();
    let num_str: String = s.chars().take_while(|c| c.is_ascii_digit() || *c == '-').collect();
    num_str.parse::<i64>().ok()
}

fn parse_json_sub(json: &str) -> Option<i64> {
    let mut search = json;
    while let Some(idx) = search.find(r#""sub""#) {
        let rem = &search[idx + 5..];
        let colon = rem.find(':')?;
        // Check that between "sub" and ':' there is only whitespace
        if !rem[..colon].trim().is_empty() {
            search = rem;
            continue;
        }
        let s = rem[colon + 1..].trim_start();
        // SPEC line 32: sub must be a JSON STRING of decimal digits (reject numeric sub)
        if !s.starts_with('"') {
            return None;
        }
        let s = &s[1..];
        let end = s.find('"')?;
        let digits = &s[..end];
        if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        let id = digits.parse::<i64>().ok()?;
        if id <= 0 {
            return None;
        }
        return Some(id);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_test_token(payload_json: &str) -> String {
        const HEADER_B64: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";
        let mut payload_b64 = String::new();
        b64url_encode(payload_json.as_bytes(), &mut payload_b64);
        let mut token = String::new();
        token.push_str(HEADER_B64);
        token.push('.');
        token.push_str(&payload_b64);
        let sig = get_signer().sign(token.as_bytes());
        token.push('.');
        b64url_encode(&sig, &mut token);
        token
    }

    #[test]
    fn test_jwt_roundtrip() {
        let user_id = 424242i64;
        let token = jwt_sign(user_id);
        let viewer = jwt_verify(&token);
        assert_eq!(viewer, Some(user_id));
    }

    #[test]
    fn test_jwt_numeric_sub_rejected() {
        // Conformance test user.get.401.numeric-sub
        let token = make_test_token(r#"{"sub":424242,"iat":1700000000,"exp":2500000000}"#);
        assert_eq!(jwt_verify(&token), None, "numeric sub must be rejected with 401");

        let token_space = make_test_token(r#"{"sub": 424242,"iat":1700000000,"exp":2500000000}"#);
        assert_eq!(jwt_verify(&token_space), None, "numeric sub with space must be rejected with 401");
    }

    #[test]
    fn test_jwt_string_sub_accepted() {
        let token = make_test_token(r#"{"sub":"424242","iat":1700000000,"exp":2500000000}"#);
        assert_eq!(jwt_verify(&token), Some(424242));

        let token_prefixed = format!("Token {}", token);
        assert_eq!(jwt_verify(&token_prefixed), Some(424242));
    }

    #[test]
    fn test_jwt_bearer_scheme_rejected() {
        // Conformance test user.get.401.bearer-scheme
        let token = make_test_token(r#"{"sub":"424242","iat":1700000000,"exp":2500000000}"#);
        let bearer_token = format!("Bearer {}", token);
        assert_eq!(jwt_verify(&bearer_token), None, "Bearer scheme must be rejected");
    }

    #[test]
    fn test_jwt_invalid_sub_cases() {
        // Non-digits, negative, empty string, zero
        let t1 = make_test_token(r#"{"sub":"abc","iat":1700000000,"exp":2500000000}"#);
        assert_eq!(jwt_verify(&t1), None);

        let t2 = make_test_token(r#"{"sub":"-42","iat":1700000000,"exp":2500000000}"#);
        assert_eq!(jwt_verify(&t2), None);

        let t3 = make_test_token(r#"{"sub":"","iat":1700000000,"exp":2500000000}"#);
        assert_eq!(jwt_verify(&t3), None);

        let t4 = make_test_token(r#"{"sub":"0","iat":1700000000,"exp":2500000000}"#);
        assert_eq!(jwt_verify(&t4), None);
    }

    #[test]
    fn test_jwt_tampering_rejected() {
        let user_id = 12345i64;
        let token = jwt_sign(user_id);
        // Tamper signature
        let mut tampered_sig = token.clone().into_bytes();
        let sig_pos = tampered_sig.iter().rposition(|&b| b == b'.').unwrap() + 1;
        tampered_sig[sig_pos] ^= 0x01;
        let tampered_sig_str = String::from_utf8(tampered_sig).unwrap();
        assert_eq!(jwt_verify(&tampered_sig_str), None);

        // Tamper payload
        let mut tampered_pay = token.into_bytes();
        let dot1 = tampered_pay.iter().position(|&b| b == b'.').unwrap();
        tampered_pay[dot1 + 5] ^= 0x01;
        let tampered_pay_str = String::from_utf8(tampered_pay).unwrap();
        assert_eq!(jwt_verify(&tampered_pay_str), None);
    }
}
