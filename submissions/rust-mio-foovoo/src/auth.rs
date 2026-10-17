//! `Authorization: Token <jwt>`: HS256 tokens, verified on every request (signature, alg, exp, nbf).

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD as B64};
use ring::hmac;
use std::borrow::Cow;

use serde_json::Value;

/// base64url of `{"alg":"HS256","typ":"JWT"}`: the header we issue and the load generator mints.
const STD_HEADER: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";
const TOKEN_TTL_SECS: i64 = 30 * 24 * 60 * 60;

pub struct Jwt {
    key: hmac::Key,
}

pub enum Auth {
    Anonymous,
    User(i64),
    Invalid,
}

impl Jwt {
    pub fn new(secret: &[u8]) -> Jwt {
        Jwt { key: hmac::Key::new(hmac::HMAC_SHA256, secret) }
    }

    pub fn issue(&self, user_id: i64, now: i64) -> String {
        let claims = format!(r#"{{"sub":"{user_id}","iat":{now},"exp":{}}}"#, now + TOKEN_TTL_SECS);
        let mut token = String::with_capacity(160);
        token.push_str(STD_HEADER);
        token.push('.');
        B64.encode_string(claims.as_bytes(), &mut token);
        let sig = hmac::sign(&self.key, token.as_bytes());
        token.push('.');
        B64.encode_string(sig.as_ref(), &mut token);
        token
    }

    /// A missing or empty header is anonymous; anything else must be a valid `Token <jwt>`.
    pub fn check(&self, header: Option<&[u8]>, now: i64) -> Auth {
        let Some(h) = header.filter(|h| !h.is_empty()) else { return Auth::Anonymous };
        let Some(token) = h.strip_prefix(b"Token ") else { return Auth::Invalid };
        match std::str::from_utf8(token).ok().and_then(|t| self.verify(t, now)) {
            Some(id) => Auth::User(id),
            None => Auth::Invalid,
        }
    }

    pub fn verify(&self, token: &str, now: i64) -> Option<i64> {
        let mut parts = token.splitn(3, '.');
        let (header, payload, sig) = (parts.next()?, parts.next()?, parts.next()?);
        if sig.contains('.') {
            return None;
        }
        if header != STD_HEADER {
            let h: Value = serde_json::from_slice(&B64.decode(header).ok()?).ok()?;
            if h.get("alg")?.as_str()? != "HS256" {
                return None;
            }
        }
        let mut sig_bytes = [0u8; 32];
        if B64.decode_slice(sig, &mut sig_bytes).ok()? != 32 {
            return None;
        }
        let signed_len = header.len() + 1 + payload.len();
        hmac::verify(&self.key, &token.as_bytes()[..signed_len], &sig_bytes).ok()?;

        let mut buf = [0u8; 512];
        let claims = match B64.decode_slice(payload, &mut buf) {
            Ok(n) => flat_claims(&buf[..n]).or_else(|| json_claims(&buf[..n]))?,
            Err(_) => json_claims(&B64.decode(payload).ok()?)?,
        };
        if !(claims.exp? > now) || claims.nbf.is_some_and(|nbf| nbf > now) {
            return None;
        }
        crate::util::parse_digits_i64(&claims.sub?).filter(|id| *id > 0)
    }
}

/// `None` in a field means absent. A present field of the wrong type makes the whole parse fail.
struct Claims<'a> {
    sub: Option<Cow<'a, str>>,
    exp: Option<i64>,
    nbf: Option<i64>,
}

/// General path: any valid JSON object.
fn json_claims(bytes: &[u8]) -> Option<Claims<'static>> {
    let v: Value = serde_json::from_slice(bytes).ok()?;
    let obj = v.as_object()?;
    let int = |k: &str| obj.get(k).map(|v| v.as_i64()).map_or(Some(None), |v| v.map(Some));
    let sub = match obj.get("sub") {
        None => None,
        Some(Value::String(s)) => Some(Cow::Owned(s.clone())),
        Some(_) => return None,
    };
    Some(Claims { sub, exp: int("exp")?, nbf: int("nbf")? })
}

/// Fast path for a flat object of escape-free strings and integers (what every issuer here produces). Anything else
/// returns `None` and goes to `json_claims`, so the two always agree.
fn flat_claims(b: &[u8]) -> Option<Claims<'_>> {
    let mut c = Claims { sub: None, exp: None, nbf: None };
    let ws = |i: &mut usize| {
        while *i < b.len() && matches!(b[*i], b' ' | b'\t' | b'\n' | b'\r') {
            *i += 1;
        }
    };
    let string = |i: &mut usize| -> Option<&str> {
        let start = *i + 1;
        let len = b.get(start..)?.iter().position(|&x| x == b'"' || x == b'\\' || x < 0x20)?;
        if b[start + len] != b'"' {
            return None;
        }
        *i = start + len + 1;
        std::str::from_utf8(&b[start..start + len]).ok()
    };
    let mut i = 0;
    ws(&mut i);
    if b.get(i) != Some(&b'{') {
        return None;
    }
    i += 1;
    ws(&mut i);
    if b.get(i) == Some(&b'}') {
        i += 1;
    } else {
        loop {
            if b.get(i) != Some(&b'"') {
                return None;
            }
            let key = string(&mut i)?;
            ws(&mut i);
            if b.get(i) != Some(&b':') {
                return None;
            }
            i += 1;
            ws(&mut i);
            match b.get(i)? {
                b'"' => {
                    let v = string(&mut i)?;
                    match key {
                        "sub" => c.sub = Some(Cow::Borrowed(v)),
                        "exp" | "nbf" => return None,
                        _ => {}
                    }
                }
                b'-' | b'0'..=b'9' => {
                    let start = i;
                    i += (b[i] == b'-') as usize;
                    while i < b.len() && b[i].is_ascii_digit() {
                        i += 1;
                    }
                    if matches!(b.get(i), Some(b'.' | b'e' | b'E')) {
                        return None;
                    }
                    let n: i64 = std::str::from_utf8(&b[start..i]).ok()?.parse().ok()?;
                    match key {
                        "exp" => c.exp = Some(n),
                        "nbf" => c.nbf = Some(n),
                        "sub" => return None,
                        _ => {}
                    }
                }
                _ => return None,
            }
            ws(&mut i);
            match b.get(i)? {
                b',' => {
                    i += 1;
                    ws(&mut i);
                }
                b'}' => {
                    i += 1;
                    break;
                }
                _ => return None,
            }
        }
    }
    ws(&mut i);
    (i == b.len()).then_some(c)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mint(secret: &[u8], header: &str, claims: &str) -> String {
        let key = hmac::Key::new(hmac::HMAC_SHA256, secret);
        let msg = format!("{}.{}", B64.encode(header), B64.encode(claims));
        let sig = hmac::sign(&key, msg.as_bytes());
        format!("{msg}.{}", B64.encode(sig.as_ref()))
    }

    #[test]
    fn roundtrip_and_rejections() {
        let j = Jwt::new(b"s3cret");
        let now = 1_800_000_000;
        let t = j.issue(42, now);
        assert_eq!(j.verify(&t, now), Some(42));
        assert!(t.starts_with(STD_HEADER));
        assert_eq!(j.verify(&t, now + TOKEN_TTL_SECS), None, "expired at exp");

        let hs = r#"{"alg":"HS256"}"#;
        assert_eq!(j.verify(&mint(b"s3cret", hs, r#"{"sub":"7","exp":1900000000}"#), now), Some(7));
        assert_eq!(j.verify(&mint(b"other", hs, r#"{"sub":"7","exp":1900000000}"#), now), None);
        assert_eq!(j.verify(&mint(b"s3cret", r#"{"alg":"none"}"#, r#"{"sub":"7","exp":1900000000}"#), now), None);
        assert_eq!(j.verify(&mint(b"s3cret", r#"{"alg":"HS512"}"#, r#"{"sub":"7","exp":1900000000}"#), now), None);
        assert_eq!(j.verify(&mint(b"s3cret", hs, r#"{"sub":"7"}"#), now), None, "no exp");
        assert_eq!(j.verify(&mint(b"s3cret", hs, r#"{"sub":7,"exp":1900000000}"#), now), None, "numeric sub");
        assert_eq!(j.verify(&mint(b"s3cret", hs, r#"{"sub":"abc","exp":1900000000}"#), now), None);
        assert_eq!(j.verify(&mint(b"s3cret", hs, r#"{"sub":"7","exp":1}"#), now), None);
        assert_eq!(j.verify(&mint(b"s3cret", hs, r#"{"sub":"7","exp":1900000000,"nbf":1900000000}"#), now), None);
        assert_eq!(j.verify("not.a.jwt", now), None);
        let spaced = r#" { "exp" : 1900000000 , "x":[1], "sub":"9" } "#;
        assert_eq!(j.verify(&mint(b"s3cret", hs, spaced), now), Some(9), "fallback parser");
        assert_eq!(j.verify(&mint(b"s3cret", hs, r#"{"sub":"9","exp":1.9e9}"#), now), None, "float exp");
        assert_eq!(j.verify(&mint(b"s3cret", hs, r#"{"sub":"9","exp":"1900000000"}"#), now), None, "string exp");
        assert_eq!(j.verify(&mint(b"s3cret", hs, r#"{"sub":"9","exp":1900000000,"nbf":"x"}"#), now), None);

        assert!(matches!(j.check(None, now), Auth::Anonymous));
        assert!(matches!(j.check(Some(b""), now), Auth::Anonymous));
        assert!(matches!(j.check(Some(format!("Bearer {t}").as_bytes()), now), Auth::Invalid));
        assert!(matches!(j.check(Some(t.as_bytes()), now), Auth::Invalid));
        assert!(matches!(j.check(Some(format!("Token {t}").as_bytes()), now), Auth::User(42)));
    }
}
