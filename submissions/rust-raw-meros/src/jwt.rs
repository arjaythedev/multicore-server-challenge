//! HS256 JSON Web Tokens, as the challenge defines them (SPEC.md, "Authentication").
//!
//! * Claims we mint: `{"sub":"<user id>","iat":<now>,"exp":<now + 30 d>}`, exactly in this key order.
//! * Rules when verifying: `alg` must be `HS256`; the HMAC signature is compared in constant time; `exp` is
//!   required and the token is expired when `now >= exp`; `sub` must be a string of decimal digits that fits a
//!   `u64`; `iat` and `nbf` are ignored; nothing is cached, every call recomputes the MAC.
//! * Verification order: shape (three segments, at most [`MAX_TOKEN_LEN`] bytes), header, signature, claims. A
//!   token is therefore never parsed past the header unless its signature is valid.
//!
//! # Hot path
//!
//! Verification runs on every authenticated request, so the two layouts that real minters produce are matched
//! byte for byte without a JSON parser and without allocating: the header `{"alg":"HS256","typ":"JWT"}` is
//! compared as base64 text against a constant, and the payload is decoded into a stack buffer and matched
//! against `{"sub":"<digits>","iat":<digits>,"exp":<digits>}`. Anything else (the conformance suite's
//! alphabetical key order, whitespace, extra claims, escapes) takes the slower flat-object scanner in
//! [`scanner`], which gives the authoritative answer. The fast path may only say "yes, here are the claims" or
//! "not my layout"; it never rejects, so both paths agree by construction (and a test pins that).
//!
//! Not handled on purpose: other algorithms, `crit`/`kid` headers (ignored), nested claim values (rejected),
//! numeric claims written as floats or exponents (rejected).

mod scanner;

use crate::crypto::base64::{self, decoded_capacity};
use crate::crypto::{ct, hmac::HmacSha256, sha256::DIGEST_LEN};
use scanner::{ScanError, Value, parse_decimal_u64, scan_object};
use std::fmt;
use std::io::Write;

/// Tokens longer than this are rejected before any work is done (a real token is about 150 bytes).
pub const MAX_TOKEN_LEN: usize = 1024;

/// `base64url({"alg":"HS256","typ":"JWT"})`, precomputed; a unit test checks it.
const HEADER_B64: &[u8] = b"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";
/// The only `alg` value accepted.
const ALG_HS256: &[u8] = b"HS256";

/// Longest header segment we will decode generically.
const MAX_HEADER_B64_LEN: usize = 256;
const HEADER_BUF_LEN: usize = decoded_capacity(MAX_HEADER_B64_LEN);
const PAYLOAD_BUF_LEN: usize = decoded_capacity(MAX_TOKEN_LEN);
/// base64url length of a 32-byte signature, unpadded.
const SIGNATURE_B64_LEN: usize = 43;
/// `{"sub":"` + 20 digits + `","iat":` + 20 + `,"exp":` + 20 + `}` is 84 bytes at most.
const PAYLOAD_MAX_LEN: usize = 96;

const SEGMENT_SEPARATOR: u8 = b'.';

/// Why a token was rejected. Every variant means "respond 401".
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum JwtError {
    /// Not three base64url segments, too long, or a segment is not valid base64url / JSON.
    Malformed,
    /// The header is not an object whose `alg` is `"HS256"`.
    BadAlgorithm,
    /// The signature does not match.
    BadSignature,
    /// `now >= exp`.
    Expired,
    /// `exp` missing or not a plain integer, or `sub` missing or not a decimal-digit string that fits a `u64`.
    BadClaims,
}

impl fmt::Display for JwtError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            JwtError::Malformed => "malformed token",
            JwtError::BadAlgorithm => "unsupported algorithm",
            JwtError::BadSignature => "bad signature",
            JwtError::Expired => "token expired",
            JwtError::BadClaims => "bad claims",
        })
    }
}

impl std::error::Error for JwtError {}

/// The claims verification needs.
#[derive(Debug, PartialEq, Eq)]
struct Claims {
    sub: u64,
    exp: u64,
}

/// HS256 signer and verifier for one secret.
#[derive(Clone)]
pub struct Jwt {
    mac: HmacSha256,
}

impl Jwt {
    /// Keys the signer; the HMAC pad states are computed once here.
    pub fn new(secret: &[u8]) -> Self {
        Jwt {
            mac: HmacSha256::new(secret),
        }
    }

    /// Appends `header.payload.signature` for the user to `out`.
    pub fn sign(&self, user_id: u64, iat: u64, exp: u64, out: &mut Vec<u8>) {
        let mut payload = [0u8; PAYLOAD_MAX_LEN];
        let payload_len = write_payload(user_id, iat, exp, &mut payload);

        let start = out.len();
        out.extend_from_slice(HEADER_B64);
        out.push(SEGMENT_SEPARATOR);
        base64::encode_url(&payload[..payload_len], out);
        let signature = self.mac.mac(&[&out[start..]]);
        out.push(SEGMENT_SEPARATOR);
        base64::encode_url(&signature, out);
    }

    /// Checks `token` and returns the user id in `sub`.
    pub fn verify(&self, token: &[u8], now: u64) -> Result<u64, JwtError> {
        let parts = split(token)?;
        check_header(parts.header)?;
        self.check_signature(parts.signing_input, parts.signature)?;
        let claims = parse_claims(parts.payload)?;
        if now >= claims.exp {
            return Err(JwtError::Expired);
        }
        Ok(claims.sub)
    }

    fn check_signature(&self, signing_input: &[u8], signature_b64: &[u8]) -> Result<(), JwtError> {
        let mut given = [0u8; DIGEST_LEN];
        if signature_b64.len() != SIGNATURE_B64_LEN
            || base64::decode_url_into(signature_b64, &mut given) != Some(DIGEST_LEN)
        {
            return Err(JwtError::Malformed);
        }
        let expected = self.mac.mac(&[signing_input]);
        if ct::eq(&expected, &given) {
            Ok(())
        } else {
            Err(JwtError::BadSignature)
        }
    }
}

/// Writes the claims JSON into `buf` and returns its length.
fn write_payload(user_id: u64, iat: u64, exp: u64, buf: &mut [u8; PAYLOAD_MAX_LEN]) -> usize {
    let mut rest: &mut [u8] = &mut buf[..];
    // Cannot fail: the longest payload is 84 bytes and the buffer holds 96 (pinned by a test).
    let _ = write!(rest, r#"{{"sub":"{user_id}","iat":{iat},"exp":{exp}}}"#);
    PAYLOAD_MAX_LEN - rest.len()
}

/// The three segments of a token plus the span the signature covers.
struct Parts<'a> {
    header: &'a [u8],
    payload: &'a [u8],
    signature: &'a [u8],
    /// `header.payload`, exactly as received.
    signing_input: &'a [u8],
}

/// Cuts the token into its three segments at the first two dots.
///
/// A third dot needs no search of its own: `.` is not in the base64url alphabet, so a dot left inside a
/// segment makes that segment's decode fail, and the token is rejected as `Malformed` there. Finding the two
/// separators is the cost that matters, so the common layout is located by position instead of by scanning:
/// the header is a known constant and the signature is always 43 characters.
fn split(token: &[u8]) -> Result<Parts<'_>, JwtError> {
    if token.len() > MAX_TOKEN_LEN {
        return Err(JwtError::Malformed);
    }
    let first = if token.starts_with(HEADER_B64)
        && token.get(HEADER_B64.len()) == Some(&SEGMENT_SEPARATOR)
    {
        HEADER_B64.len()
    } else {
        find_separator(token).ok_or(JwtError::Malformed)?
    };
    let signature_dot = token
        .len()
        .checked_sub(SIGNATURE_B64_LEN + 1)
        .filter(|&i| i > first);
    let second = match signature_dot {
        Some(i) if token[i] == SEGMENT_SEPARATOR => i,
        _ => first + 1 + find_separator(&token[first + 1..]).ok_or(JwtError::Malformed)?,
    };
    let parts = Parts {
        header: &token[..first],
        payload: &token[first + 1..second],
        signature: &token[second + 1..],
        signing_input: &token[..second],
    };
    // An empty signature is left to the signature check, so `alg: none` tokens report BadAlgorithm.
    if parts.header.is_empty() || parts.payload.is_empty() {
        return Err(JwtError::Malformed);
    }
    Ok(parts)
}

fn find_separator(bytes: &[u8]) -> Option<usize> {
    bytes.iter().position(|&b| b == SEGMENT_SEPARATOR)
}

fn check_header(segment: &[u8]) -> Result<(), JwtError> {
    if segment == HEADER_B64 {
        return Ok(()); // the layout every token we and the load generator mint has
    }
    check_header_generic(segment)
}

/// Slow path: any header that is a JSON object with `"alg":"HS256"` (other members ignored).
fn check_header_generic(segment: &[u8]) -> Result<(), JwtError> {
    let mut buf = [0u8; HEADER_BUF_LEN];
    let len = if segment.len() > MAX_HEADER_B64_LEN {
        None
    } else {
        base64::decode_url_into(segment, &mut buf)
    };
    let json = &buf[..len.ok_or(JwtError::Malformed)?];

    let mut alg_ok = false;
    let mut seen = false;
    let scanned = scan_object(json, |key, value| {
        if key != b"alg" {
            return Ok(());
        }
        if seen {
            return Err(ScanError::Rejected); // duplicate `alg`: ambiguous
        }
        seen = true;
        alg_ok = value == Value::Str(ALG_HS256);
        Ok(())
    });
    match scanned {
        Ok(()) if alg_ok => Ok(()),
        Ok(()) | Err(ScanError::Rejected) => Err(JwtError::BadAlgorithm),
        Err(ScanError::Syntax) => Err(JwtError::Malformed),
    }
}

fn parse_claims(payload_b64: &[u8]) -> Result<Claims, JwtError> {
    let mut buf = [0u8; PAYLOAD_BUF_LEN];
    let len = base64::decode_url_into(payload_b64, &mut buf).ok_or(JwtError::Malformed)?;
    let json = &buf[..len];
    match claims_exact_layout(json) {
        Some(claims) => Ok(claims),
        None => claims_general(json),
    }
}

const LAYOUT_SUB: &[u8] = br#"{"sub":""#;
const LAYOUT_IAT: &[u8] = br#"","iat":"#;
const LAYOUT_EXP: &[u8] = br#","exp":"#;
const LAYOUT_END: &[u8] = b"}";

/// Fast path: matches `{"sub":"<digits>","iat":<digits>,"exp":<digits>}` byte for byte.
///
/// `None` means "not this layout, or a value the strict reading would reject": the caller then asks the general
/// scanner, which decides. Numbers must be canonical JSON integers (no leading zeros).
fn claims_exact_layout(json: &[u8]) -> Option<Claims> {
    let rest = json.strip_prefix(LAYOUT_SUB)?;
    let (sub_digits, rest) = split_digits(rest);
    let rest = rest.strip_prefix(LAYOUT_IAT)?;
    let (iat_digits, rest) = split_digits(rest);
    let rest = rest.strip_prefix(LAYOUT_EXP)?;
    let (exp_digits, rest) = split_digits(rest);
    if rest != LAYOUT_END || !is_canonical_integer(iat_digits) {
        return None;
    }
    if !is_canonical_integer(exp_digits) {
        return None;
    }
    Some(Claims {
        sub: parse_decimal_u64(sub_digits)?,
        exp: parse_decimal_u64(exp_digits)?,
    })
}

/// Splits the leading run of ASCII digits from the rest.
fn split_digits(bytes: &[u8]) -> (&[u8], &[u8]) {
    let count = bytes.iter().take_while(|b| b.is_ascii_digit()).count();
    bytes.split_at(count)
}

/// A JSON integer without sign: non-empty and no leading zero unless it is exactly `0`.
fn is_canonical_integer(digits: &[u8]) -> bool {
    !digits.is_empty() && (digits.len() == 1 || digits[0] != b'0')
}

/// Slow path: any key order, whitespace, extra members, escapes.
fn claims_general(json: &[u8]) -> Result<Claims, JwtError> {
    let mut sub = None;
    let mut exp = None;
    scan_object(json, |key, value| match (key, value) {
        (b"sub", Value::Str(digits)) if sub.is_none() => {
            sub = Some(parse_decimal_u64(digits).ok_or(ScanError::Rejected)?);
            Ok(())
        }
        (b"exp", Value::Uint(n)) if exp.is_none() => {
            exp = Some(n);
            Ok(())
        }
        // A second or mistyped `sub` / `exp` is ambiguous or invalid.
        (b"sub" | b"exp", _) => Err(ScanError::Rejected),
        _ => Ok(()),
    })
    .map_err(|e| match e {
        ScanError::Syntax => JwtError::Malformed,
        ScanError::Rejected => JwtError::BadClaims,
    })?;
    Ok(Claims {
        sub: sub.ok_or(JwtError::BadClaims)?,
        exp: exp.ok_or(JwtError::BadClaims)?,
    })
}

#[cfg(test)]
mod tests;
