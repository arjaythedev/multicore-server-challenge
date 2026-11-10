//! HS256 JWTs, checked in full on every request (signature, `alg`, `exp`, `nbf`); nothing is cached.

use std::time::{SystemTime, UNIX_EPOCH};

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use hmac::{Hmac, Mac};
use serde::Deserialize;
use sha2::Sha256;
use std::borrow::Cow;

const TOKEN_TTL_SECS: u64 = 30 * 24 * 60 * 60;
/// base64url(`{"alg":"HS256","typ":"JWT"}`)
const HEADER: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";

pub struct Jwt {
    mac: Hmac<Sha256>,
}

impl Jwt {
    pub fn new(secret: &str) -> Self {
        Jwt {
            mac: Hmac::new_from_slice(secret.as_bytes()).expect("HMAC takes any key length"),
        }
    }

    /// A fresh token: claims exactly `{"sub": "<id>", "iat": now, "exp": now + 30 days}`.
    pub fn issue(&self, user_id: i64) -> String {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let payload = format!(
            r#"{{"sub":"{user_id}","iat":{now},"exp":{}}}"#,
            now + TOKEN_TTL_SECS
        );
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

    /// The user id in a valid token, or None (→ 401). A valid token is ASCII: its signature and payload are
    /// base64url, and its header is either the standard one or base64url too.
    pub fn verify<T: AsRef<[u8]> + ?Sized>(&self, token: &T) -> Option<i64> {
        let token = token.as_ref();
        // Exactly two dots: header.payload.signature.
        let last = memchr::memrchr(b'.', token)?;
        let (signed, sig) = (&token[..last], &token[last + 1..]);
        let first = memchr::memchr(b'.', signed)?;
        let (header, payload) = (&signed[..first], &signed[first + 1..]);
        if memchr::memchr(b'.', payload).is_some() {
            return None;
        }
        let mut sig_bytes = [0u8; 32];
        if b64url(sig, &mut sig_bytes)? != 32 {
            return None;
        }
        let mut mac = self.mac.clone();
        mac.update(signed);
        mac.verify_slice(&sig_bytes).ok()?;

        // The standard header has a known HS256 algorithm. Its signature is
        // still verified above on every request; other valid headers use JSON.
        if header != HEADER.as_bytes() {
            let mut header_buf = [0u8; 512];
            let bytes = decode(header, &mut header_buf)?;
            if bytes.trim_ascii_start().first() != Some(&b'{') {
                return None;
            }
            #[derive(Deserialize)]
            struct Header<'a> {
                #[serde(borrow)]
                alg: Cow<'a, str>,
            }
            let decoded: Header<'_> = serde_json::from_slice(&bytes).ok()?;
            if decoded.alg != "HS256" {
                return None;
            }
        }
        // Issued payloads are ~60 bytes; longer ones decode on the heap.
        let mut payload_buf = [0u8; 256];
        let payload_bytes = decode(payload, &mut payload_buf)?;
        if payload_bytes.trim_ascii_start().first() != Some(&b'{') {
            return None;
        }
        #[derive(Deserialize)]
        struct Claims<'a> {
            #[serde(borrow)]
            sub: Cow<'a, str>,
            exp: f64,
            nbf: Option<f64>,
        }
        // Claims exactly as `issue` writes them are read directly; anything else goes through serde_json.
        let claims = match issued_claims(&payload_bytes) {
            Some((sub, exp)) => Claims {
                sub: Cow::Borrowed(sub),
                exp,
                nbf: None,
            },
            None => serde_json::from_slice(&payload_bytes).ok()?,
        };
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .ok()?
            .as_secs_f64();
        if now >= claims.exp || claims.nbf.is_some_and(|nbf| now < nbf) {
            return None;
        }
        let sub = &claims.sub;
        crate::parse_uint(sub).filter(|id| *id > 0)
    }
}

/// `(sub, exp)` from a payload of exactly the form `issue` writes, `{"sub":"<digits>","iat":<n>,"exp":<n>}`, with
/// canonical JSON integers of at most 15 digits (exact as f64, as serde_json reads them); None for anything else.
fn issued_claims(payload: &[u8]) -> Option<(&str, f64)> {
    fn digits(s: &[u8]) -> usize {
        s.iter().take_while(|b| b.is_ascii_digit()).count()
    }
    fn number(s: &[u8]) -> Option<(f64, &[u8])> {
        let n = digits(s);
        if n == 0 || n > 15 || (n > 1 && s[0] == b'0') {
            return None;
        }
        let v = s[..n]
            .iter()
            .fold(0u64, |v, d| v * 10 + u64::from(d - b'0'));
        Some((v as f64, &s[n..]))
    }
    let rest = payload.strip_prefix(br#"{"sub":""#)?;
    let n = digits(rest);
    let (sub, rest) = rest.split_at(n);
    if n == 0 {
        return None;
    }
    let (_, rest) = number(rest.strip_prefix(br#"","iat":"#)?)?;
    let (exp, rest) = number(rest.strip_prefix(br#","exp":"#)?)?;
    if rest != b"}" {
        return None;
    }
    // ASCII digits.
    Some((std::str::from_utf8(sub).ok()?, exp))
}

fn decode<'a>(s: &[u8], stack: &'a mut [u8]) -> Option<Cow<'a, [u8]>> {
    if s.len() / 4 * 3 + 2 <= stack.len() {
        let n = b64url(s, stack)?;
        Some(Cow::Borrowed(&stack[..n]))
    } else {
        let mut heap = vec![0; s.len() / 4 * 3 + 2];
        let n = b64url(s, &mut heap)?;
        heap.truncate(n);
        Some(Cow::Owned(heap))
    }
}

/// base64url symbol values; 0xff for any other byte (including `=`).
const B64URL: [u8; 256] = {
    let mut t = [0xffu8; 256];
    let mut i = 0;
    while i < 64 {
        t[b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"[i] as usize] =
            i as u8;
        i += 1;
    }
    t
};

/// Unpadded base64url into `out`, with exactly the acceptance of base64's `URL_SAFE_NO_PAD.decode_slice`: every
/// byte a symbol (no `=`), a length that is not 1 mod 4, zero trailing bits, and room in `out`. Returns the
/// decoded length.
fn b64url(input: &[u8], out: &mut [u8]) -> Option<usize> {
    let tail = input.len() % 4;
    if tail == 1 {
        return None;
    }
    let quads = input.len() / 4;
    let len = quads * 3 + tail.saturating_sub(1);
    let out = out.get_mut(..len)?;
    let sym = |b: u8| u32::from(B64URL[b as usize]);
    let (body, rest) = input.split_at(quads * 4);
    for (q, o) in body.chunks_exact(4).zip(out.chunks_exact_mut(3)) {
        let (a, b, c, d) = (sym(q[0]), sym(q[1]), sym(q[2]), sym(q[3]));
        if (a | b | c | d) > 63 {
            return None;
        }
        let v = a << 18 | b << 12 | c << 6 | d;
        o.copy_from_slice(&[(v >> 16) as u8, (v >> 8) as u8, v as u8]);
    }
    let o = &mut out[quads * 3..];
    match *rest {
        [] => {}
        [a, b] => {
            let (a, b) = (sym(a), sym(b));
            if (a | b) > 63 || b & 0x0f != 0 {
                return None;
            }
            o[0] = (a << 2 | b >> 4) as u8;
        }
        [a, b, c] => {
            let (a, b, c) = (sym(a), sym(b), sym(c));
            if (a | b | c) > 63 || c & 0x03 != 0 {
                return None;
            }
            let v = a << 10 | b << 4 | c >> 2;
            o.copy_from_slice(&[(v >> 8) as u8, v as u8]);
        }
        _ => unreachable!("length checked above"),
    }
    Some(len)
}

#[cfg(test)]
mod tests {
    use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};

    /// The hand-written decoder accepts and decodes exactly what the base64 crate does.
    #[test]
    fn b64url_matches_base64() {
        let mut seed = 7u64;
        let mut next = move || {
            seed = seed
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            (seed >> 33) as usize
        };
        let alphabet =
            b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=+/.\x00\xff";
        for _ in 0..200_000 {
            let len = next() % 70;
            let input: Vec<u8> = (0..len)
                .map(|_| {
                    if next() % 40 == 0 {
                        alphabet[64 + next() % (alphabet.len() - 64)]
                    } else {
                        alphabet[next() % 64]
                    }
                })
                .collect();
            for cap in [
                len / 4 * 3 + 2,
                32,
                0,
                len * 3 / 4,
                len * 3 / 4 - (len > 3) as usize,
            ] {
                let (mut a, mut b) = (vec![0u8; cap], vec![0u8; cap]);
                let ours = super::b64url(&input, &mut a);
                let theirs = URL_SAFE_NO_PAD.decode_slice(&input, &mut b).ok();
                assert_eq!(
                    ours,
                    theirs,
                    "{:?} cap {cap}",
                    String::from_utf8_lossy(&input)
                );
                if let Some(n) = ours {
                    assert_eq!(a[..n], b[..n]);
                }
            }
        }
        // Valid encodings of random bytes round-trip.
        for len in 0..80 {
            let bytes: Vec<u8> = (0..len).map(|_| next() as u8).collect();
            let s = URL_SAFE_NO_PAD.encode(&bytes);
            let mut out = vec![0; len + 2];
            assert_eq!(super::b64url(s.as_bytes(), &mut out), Some(len));
            assert_eq!(out[..len], bytes[..]);
        }
    }
}
