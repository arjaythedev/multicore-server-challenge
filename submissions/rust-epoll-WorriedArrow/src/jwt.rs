//! HS256 JWTs: verified on every request (signature, alg, exp, nbf), never cached.
//!
//! The header and payload are checked with a small validating JSON scanner that reads only the claims we need,
//! straight from a stack buffer: no JSON tree, no allocation. It accepts exactly what a JSON parser would (any key
//! order, whitespace, escapes, other claims of any type; the last of duplicate keys wins) and rejects malformed JSON.

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

// ------------------------------------------------------------------------------------------------------------------
// a validating JSON scanner

/// A short decoded string (keys and the values we look at); longer ones only record that they were longer.
struct Short {
    buf: [u8; 32],
    len: usize,
    long: bool,
}

impl Short {
    fn new() -> Short {
        Short { buf: [0; 32], len: 0, long: false }
    }
    fn push(&mut self, b: &[u8]) {
        if self.len + b.len() > self.buf.len() {
            self.long = true;
        } else {
            self.buf[self.len..self.len + b.len()].copy_from_slice(b);
            self.len += b.len();
        }
    }
    fn get(&self) -> Option<&[u8]> {
        if self.long { None } else { Some(&self.buf[..self.len]) }
    }
}

/// A value we keep from an object: a number, a short string, or anything else.
enum Val {
    Num(f64),
    Str(Option<([u8; 32], usize)>),
    Other,
}

struct Scan<'a> {
    b: &'a [u8],
    i: usize,
}

const MAX_DEPTH: usize = 128;

impl<'a> Scan<'a> {
    fn ws(&mut self) {
        while self.i < self.b.len() && matches!(self.b[self.i], b' ' | b'\t' | b'\n' | b'\r') {
            self.i += 1;
        }
    }

    fn eat(&mut self, c: u8) -> Option<()> {
        self.ws();
        if self.b.get(self.i) == Some(&c) {
            self.i += 1;
            Some(())
        } else {
            None
        }
    }

    fn hex4(&mut self) -> Option<u32> {
        let h = self.b.get(self.i..self.i + 4)?;
        self.i += 4;
        let s = std::str::from_utf8(h).ok()?;
        if !s.bytes().all(|c| c.is_ascii_hexdigit()) {
            return None;
        }
        u32::from_str_radix(s, 16).ok()
    }

    /// A string after its opening quote, decoded into `out`. Rejects control characters, bad escapes, lone
    /// surrogates and invalid UTF-8, as a JSON parser does.
    fn string(&mut self, out: &mut Short) -> Option<()> {
        loop {
            let start = self.i;
            while self.i < self.b.len() && self.b[self.i] != b'"' && self.b[self.i] != b'\\' && self.b[self.i] >= 0x20 {
                self.i += 1;
            }
            let run = &self.b[start..self.i];
            std::str::from_utf8(run).ok()?;
            out.push(run);
            match *self.b.get(self.i)? {
                b'"' => {
                    self.i += 1;
                    return Some(());
                }
                b'\\' => {
                    self.i += 1;
                    let e = *self.b.get(self.i)?;
                    self.i += 1;
                    let c = match e {
                        b'"' => '"',
                        b'\\' => '\\',
                        b'/' => '/',
                        b'b' => '\u{8}',
                        b'f' => '\u{c}',
                        b'n' => '\n',
                        b'r' => '\r',
                        b't' => '\t',
                        b'u' => {
                            let hi = self.hex4()?;
                            let cp = if (0xD800..0xDC00).contains(&hi) {
                                if self.b.get(self.i..self.i + 2) != Some(b"\\u") {
                                    return None;
                                }
                                self.i += 2;
                                let lo = self.hex4()?;
                                if !(0xDC00..0xE000).contains(&lo) {
                                    return None;
                                }
                                0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
                            } else if (0xDC00..0xE000).contains(&hi) {
                                return None;
                            } else {
                                hi
                            };
                            char::from_u32(cp)?
                        }
                        _ => return None,
                    };
                    let mut tmp = [0u8; 4];
                    out.push(c.encode_utf8(&mut tmp).as_bytes());
                }
                _ => return None, // a control character
            }
        }
    }

    /// A number per the JSON grammar, as f64.
    fn number(&mut self) -> Option<f64> {
        let start = self.i;
        let b = self.b;
        if b.get(self.i) == Some(&b'-') {
            self.i += 1;
        }
        match b.get(self.i)? {
            b'0' => self.i += 1,
            b'1'..=b'9' => {
                while self.i < b.len() && b[self.i].is_ascii_digit() {
                    self.i += 1;
                }
            }
            _ => return None,
        }
        if b.get(self.i) == Some(&b'.') {
            self.i += 1;
            if !b.get(self.i)?.is_ascii_digit() {
                return None;
            }
            while self.i < b.len() && b[self.i].is_ascii_digit() {
                self.i += 1;
            }
        }
        if matches!(b.get(self.i), Some(b'e' | b'E')) {
            self.i += 1;
            if matches!(b.get(self.i), Some(b'+' | b'-')) {
                self.i += 1;
            }
            if !b.get(self.i)?.is_ascii_digit() {
                return None;
            }
            while self.i < b.len() && b[self.i].is_ascii_digit() {
                self.i += 1;
            }
        }
        let v: f64 = std::str::from_utf8(&b[start..self.i]).ok()?.parse().ok()?;
        if v.is_finite() { Some(v) } else { None }
    }

    /// Any value; numbers and strings are kept, everything else validated and skipped.
    fn value(&mut self, depth: usize) -> Option<Val> {
        self.ws();
        match *self.b.get(self.i)? {
            b'"' => {
                self.i += 1;
                let mut s = Short::new();
                self.string(&mut s)?;
                Some(Val::Str(s.get().map(|v| {
                    let mut a = [0u8; 32];
                    a[..v.len()].copy_from_slice(v);
                    (a, v.len())
                })))
            }
            b'{' => {
                self.object(depth + 1, |_, _| {})?;
                Some(Val::Other)
            }
            b'[' => {
                if depth + 1 > MAX_DEPTH {
                    return None;
                }
                self.i += 1;
                if self.eat(b']').is_some() {
                    return Some(Val::Other);
                }
                loop {
                    self.value(depth + 1)?;
                    self.ws();
                    match *self.b.get(self.i)? {
                        b',' => self.i += 1,
                        b']' => {
                            self.i += 1;
                            return Some(Val::Other);
                        }
                        _ => return None,
                    }
                }
            }
            b't' | b'f' | b'n' => {
                for lit in [&b"true"[..], b"false", b"null"] {
                    if self.b[self.i..].starts_with(lit) {
                        self.i += lit.len();
                        return Some(Val::Other);
                    }
                }
                None
            }
            _ => self.number().map(Val::Num),
        }
    }

    /// An object at the cursor; calls `f(key, value)` for each member (keys of up to 32 bytes; longer ones can't
    /// be a claim we read).
    fn object(&mut self, depth: usize, mut f: impl FnMut(&[u8], Val)) -> Option<()> {
        if depth > MAX_DEPTH {
            return None;
        }
        self.eat(b'{')?;
        if self.eat(b'}').is_some() {
            return Some(());
        }
        loop {
            self.eat(b'"')?;
            let mut k = Short::new();
            self.string(&mut k)?;
            self.eat(b':')?;
            let v = self.value(depth)?;
            if let Some(k) = k.get() {
                f(k, v);
            }
            self.ws();
            match *self.b.get(self.i)? {
                b',' => self.i += 1,
                b'}' => {
                    self.i += 1;
                    return Some(());
                }
                _ => return None,
            }
        }
    }

    /// A whole document that is one object, nothing after it but whitespace.
    fn document(b: &'a [u8], f: impl FnMut(&[u8], Val)) -> Option<()> {
        let mut s = Scan { b, i: 0 };
        s.object(1, f)?;
        s.ws();
        if s.i == b.len() { Some(()) } else { None }
    }
}

/// Base64url-decodes into a stack buffer, or the heap for unusually large parts.
fn with_decoded<R>(part: &[u8], f: impl FnOnce(&[u8]) -> Option<R>) -> Option<R> {
    let mut buf = [0u8; 512];
    match B64.decode_slice(part, &mut buf) {
        Ok(n) => f(&buf[..n]),
        Err(base64::DecodeSliceError::OutputSliceTooSmall) => f(&B64.decode(part).ok()?),
        Err(_) => None,
    }
}

/// The payload claims verify() checks: (exp, nbf, iat is a number, sub).
type Claims = (Option<Option<f64>>, Option<Option<f64>>, Option<bool>, Option<Option<i64>>);

fn claims(pb: &[u8]) -> Option<Claims> {
    match flat_claims(pb) {
        Some((exp, iat, sub)) => Some((Some(Some(exp)), None, iat.then_some(true), Some(Some(sub)))),
        None => scan_claims(pb),
    }
}

/// The common payload, read without the general scanner: a flat object of "exp" and "iat" (unsigned integers) and
/// "sub" (a string of digits), each at most once, in any order, with no whitespace, escapes or other keys. Anything
/// else returns None and goes through the full scan; whatever this accepts, the scan reads to the same values.
fn flat_claims(b: &[u8]) -> Option<(f64, bool, i64)> {
    let (mut exp, mut iat, mut sub) = (None, false, None);
    let mut i = 1;
    if b.first() != Some(&b'{') || b.last() != Some(&b'}') || b.len() < 3 {
        return None;
    }
    let end = b.len() - 1;
    loop {
        let key = b.get(i..i + 6)?;
        i += 6;
        match key {
            b"\"exp\":" | b"\"iat\":" => {
                let s = i;
                while i < end && b[i].is_ascii_digit() {
                    i += 1;
                }
                let n = i - s;
                if n == 0 || n > 15 || (n > 1 && b[s] == b'0') {
                    return None;
                }
                let v = b[s..i].iter().fold(0u64, |a, &c| a * 10 + (c - b'0') as u64) as f64;
                if key[1] == b'e' {
                    if exp.replace(v).is_some() {
                        return None;
                    }
                } else if std::mem::replace(&mut iat, true) {
                    return None;
                }
            }
            b"\"sub\":" => {
                if b.get(i) != Some(&b'"') {
                    return None;
                }
                i += 1;
                let s = i;
                while i < end && b[i].is_ascii_digit() {
                    i += 1;
                }
                let n = i - s;
                if n == 0 || n > 18 || b.get(i) != Some(&b'"') {
                    return None;
                }
                let v = b[s..i].iter().fold(0i64, |a, &c| a * 10 + (c - b'0') as i64);
                i += 1;
                if sub.replace(v).is_some() {
                    return None;
                }
            }
            _ => return None,
        }
        if i == end {
            break;
        }
        if b[i] != b',' {
            return None;
        }
        i += 1;
    }
    Some((exp?, iat, sub?))
}

fn scan_claims(pb: &[u8]) -> Option<Claims> {
    let mut exp: Option<Option<f64>> = None;
    let mut nbf: Option<Option<f64>> = None;
    let mut iat: Option<bool> = None;
    let mut sub: Option<Option<i64>> = None;
    Scan::document(pb, |k, v| match k {
        b"exp" => exp = Some(if let Val::Num(x) = v { Some(x) } else { None }),
        b"nbf" => nbf = Some(if let Val::Num(x) = v { Some(x) } else { None }),
        b"iat" => iat = Some(matches!(v, Val::Num(_))),
        b"sub" => {
            sub = Some(match v {
                Val::Str(Some((a, n))) if n > 0 && a[..n].iter().all(|c| c.is_ascii_digit()) => {
                    std::str::from_utf8(&a[..n]).ok().and_then(|t| t.parse::<i64>().ok())
                }
                _ => None,
            })
        }
        _ => {}
    })?;
    Some((exp, nbf, iat, sub))
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
            let ok = with_decoded(h, |hb| {
                let mut alg: Option<bool> = None;
                Scan::document(hb, |k, v| {
                    if k == b"alg" {
                        alg = Some(matches!(v, Val::Str(Some((a, n))) if &a[..n] == b"HS256"));
                    }
                })?;
                alg
            })?;
            if !ok {
                return None;
            }
        }
        let (exp, nbf, iat_ok, sub) = with_decoded(p, claims)?;
        let now = now_f64();
        // exp is required, a number, and in the future.
        let exp = exp??;
        if !(now < exp) {
            return None;
        }
        if let Some(nbf) = nbf {
            if now < nbf? {
                return None;
            }
        }
        if iat_ok == Some(false) {
            return None;
        }
        let id = sub??;
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
    fn flat_claims_match_scan() {
        let cases: &[&[u8]] = &[
            br#"{"sub":"42","iat":1700000000,"exp":1800000000}"#,
            br#"{"exp":1800000000,"iat":1700000000,"sub":"42"}"#,
            br#"{"exp":1800000000,"sub":"7"}"#,
            br#"{"sub":"0007","exp":0}"#,
            br#"{"sub":"42","exp":18,"exp":19}"#,
            br#"{"sub":"42","exp":018}"#,
            br#"{"sub":"42","exp":1.5}"#,
            br#"{"sub":"42","exp":1e9}"#,
            br#"{"sub":"","exp":1}"#,
            br#"{"sub":42,"exp":1}"#,
            br#"{"sub":"42","exp":1,"nbf":0}"#,
            br#"{"sub":"42", "exp":1}"#,
            br#"{"sub":"42","exp":1,}"#,
            br#"{"sub":"4\u0032","exp":1}"#,
            br#"{"iat":1,"sub":"1234567890123456789","exp":2}"#,
            br#"{"exp":1234567890123456,"sub":"1"}"#,
            br#"{"exp":2,"sub":"1"}x"#,
            br#"{}"#,
            br#"{"sub":"9"}"#,
        ];
        for c in cases {
            if let Some((exp, iat, sub)) = flat_claims(c) {
                let (e, n, i, s) = scan_claims(c).expect("scan accepts what the fast path does");
                assert_eq!(e, Some(Some(exp)), "{}", String::from_utf8_lossy(c));
                assert_eq!(n, None);
                assert_eq!(i, iat.then_some(true));
                assert_eq!(s, Some(Some(sub)));
            }
        }
        assert!(flat_claims(cases[0]).is_some() && flat_claims(cases[1]).is_some() && flat_claims(cases[2]).is_some());
    }


    fn token(k: &Keys, header: &str, payload: &str) -> Vec<u8> {
        let mut t = String::new();
        B64.encode_string(header.as_bytes(), &mut t);
        t.push('.');
        B64.encode_string(payload.as_bytes(), &mut t);
        let mut mac = k.mac.clone();
        mac.update(t.as_bytes());
        let sig = mac.finalize().into_bytes();
        t.push('.');
        B64.encode_string(sig, &mut t);
        t.into_bytes()
    }

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

    /// The scanner accepts and rejects what serde_json does for the claims we read.
    #[test]
    fn claims_like_serde() {
        let k = Keys::new(b"s");
        let h = r#"{"alg":"HS256","typ":"JWT"}"#;
        let far = now_secs() + 1000;
        let cases: Vec<(String, String)> = vec![
            (h.into(), format!(r#"{{"sub":"7","exp":{far}}}"#)),
            (h.into(), format!(r#"{{ "exp" : {far}.5 , "sub" : "7", "x": [1, {{"a": null}}, "q\"é"], "iat": 1e3 }}"#)),
            (h.into(), format!(r#"{{"exp":{far},"sub":"7"}}"#)),
            (h.into(), format!(r#"{{"exp":1,"exp":{far},"sub":"7"}}"#)),
            (r#"{"typ":"JWT", "alg" : "HS256"}"#.into(), format!(r#"{{"exp":{far},"sub":"7"}}"#)),
            (r#"{"alg":"none"}"#.into(), format!(r#"{{"exp":{far},"sub":"7"}}"#)),
            (h.into(), format!(r#"{{"exp":"{far}","sub":"7"}}"#)),
            (h.into(), r#"{"exp":1,"sub":"7"}"#.into()),
            (h.into(), format!(r#"{{"exp":{far},"sub":7}}"#)),
            (h.into(), format!(r#"{{"exp":{far},"sub":"07x"}}"#)),
            (h.into(), format!(r#"{{"exp":{far},"sub":"0"}}"#)),
            (h.into(), format!(r#"{{"exp":{far},"sub":"7","nbf":{far}}}"#)),
            (h.into(), format!(r#"{{"exp":{far},"sub":"7","iat":"x"}}"#)),
            (h.into(), format!(r#"{{"exp":{far},"sub":"7"}} x"#)),
            (h.into(), format!(r#"{{"exp":{far},"sub":"7",}}"#)),
            (h.into(), format!(r#"{{"exp":{far},"sub":"7","z":"\ud800"}}"#)),
            (h.into(), format!(r#"{{"exp":{far},"sub":"7","z":01}}"#)),
            (h.into(), format!(r#"[{{"exp":{far},"sub":"7"}}]"#)),
        ];
        for (hd, pl) in cases {
            let want = serde_ref(&hd, &pl);
            assert_eq!(k.verify(&token(&k, &hd, &pl)), want, "{hd} {pl}");
        }
    }

    /// What the previous serde_json-based check returned for a header and payload with a valid signature.
    fn serde_ref(h: &str, p: &str) -> Option<i64> {
        use serde_json::Value;
        let hv: Value = serde_json::from_str(h).ok()?;
        if hv.get("alg")?.as_str()? != "HS256" {
            return None;
        }
        let pv: Value = serde_json::from_str(p).ok()?;
        let o = pv.as_object()?;
        let num = |v: &Value| if let Value::Number(n) = v { n.as_f64() } else { None };
        let now = now_f64();
        if !(now < num(o.get("exp")?)?) {
            return None;
        }
        if let Some(n) = o.get("nbf") {
            if now < num(n)? {
                return None;
            }
        }
        if let Some(i) = o.get("iat") {
            num(i)?;
        }
        let sub = o.get("sub")?.as_str()?;
        if sub.is_empty() || !sub.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        let id: i64 = sub.parse().ok()?;
        if id <= 0 { None } else { Some(id) }
    }
}
