//! Scanner for a flat JSON object, used by the JWT slow path.
//!
//! Handles any key order, JSON whitespace, string escapes (`\n`, `\uXXXX` for the basic plane, ...), extra
//! members, and the three value kinds a claim set has: strings, numbers, and the literals `true` / `false` /
//! `null`. Deliberately **not** handled: nested objects or arrays (the whole object is rejected), `\u` surrogate
//! pairs (rejected), UTF-8 validation of strings (the claims we read are ASCII, and non-ASCII bytes just never
//! match), and any limit on the member count (the caller bounds the input size). Own code on purpose: the JWT
//! check must not depend on the general JSON module.

/// Longest unescaped string we build. A string with escapes that decodes to more cannot be a key we look for
/// (`sub`, `exp`, `alg`) nor a value we read (`HS256`, at most 20 digits), so it is reported as `TooLong`
/// instead of allocating. Strings without escapes are never copied and have no length limit here.
const SCRATCH_LEN: usize = 32;

/// A member value, reduced to what the JWT checks need.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Value<'a> {
    /// A string after unescaping (borrowed from the input when it had no escapes).
    Str(&'a [u8]),
    /// A string with escapes whose decoded form is longer than `SCRATCH_LEN`; it can match nothing we read.
    TooLong,
    /// A number written as a plain non-negative integer that fits a `u64`.
    Uint(u64),
    /// Any other valid number (negative, fraction, exponent, or too big) or a literal.
    Other,
}

/// Why scanning stopped.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum ScanError {
    /// Not valid JSON for this subset.
    Syntax,
    /// The visitor rejected a member.
    Rejected,
}

/// Parses `input` as one flat JSON object and calls `visit(key, value)` for each member in order.
/// A key with escapes that decodes to more than `SCRATCH_LEN` bytes is passed as the empty slice.
pub(super) fn scan_object(
    input: &[u8],
    mut visit: impl FnMut(&[u8], Value<'_>) -> Result<(), ScanError>,
) -> Result<(), ScanError> {
    let mut cur = Cursor { input, pos: 0 };
    let mut key_scratch = [0u8; SCRATCH_LEN];
    let mut value_scratch = [0u8; SCRATCH_LEN];

    cur.skip_ws();
    cur.expect(b'{')?;
    cur.skip_ws();
    if cur.eat(b'}') {
        return cur.finish();
    }
    loop {
        cur.skip_ws();
        cur.expect(b'"')?;
        let key = cur.string(&mut key_scratch)?.unwrap_or(&[]);
        cur.skip_ws();
        cur.expect(b':')?;
        cur.skip_ws();
        let value = cur.value(&mut value_scratch)?;
        visit(key, value)?;
        cur.skip_ws();
        match cur.next() {
            Some(b',') => continue,
            Some(b'}') => return cur.finish(),
            _ => return Err(ScanError::Syntax),
        }
    }
}

/// Parses ASCII decimal digits into a `u64`; `None` if empty, not all digits, or overflowing.
pub(super) fn parse_decimal_u64(digits: &[u8]) -> Option<u64> {
    if digits.is_empty() {
        return None;
    }
    let mut value = 0u64;
    for &b in digits {
        if !b.is_ascii_digit() {
            return None;
        }
        value = value.checked_mul(10)?.checked_add(u64::from(b - b'0'))?;
    }
    Some(value)
}

struct Cursor<'a> {
    input: &'a [u8],
    pos: usize,
}

impl<'a> Cursor<'a> {
    fn peek(&self) -> Option<u8> {
        self.input.get(self.pos).copied()
    }

    fn next(&mut self) -> Option<u8> {
        let b = self.peek()?;
        self.pos += 1;
        Some(b)
    }

    fn eat(&mut self, byte: u8) -> bool {
        let hit = self.peek() == Some(byte);
        self.pos += usize::from(hit);
        hit
    }

    fn expect(&mut self, byte: u8) -> Result<(), ScanError> {
        if self.eat(byte) {
            Ok(())
        } else {
            Err(ScanError::Syntax)
        }
    }

    fn skip_ws(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.pos += 1;
        }
    }

    /// After the closing brace only whitespace may follow.
    fn finish(&mut self) -> Result<(), ScanError> {
        self.skip_ws();
        if self.pos == self.input.len() {
            Ok(())
        } else {
            Err(ScanError::Syntax)
        }
    }

    fn value<'s>(&mut self, scratch: &'s mut [u8; SCRATCH_LEN]) -> Result<Value<'s>, ScanError>
    where
        'a: 's,
    {
        match self.peek() {
            Some(b'"') => {
                self.pos += 1;
                Ok(match self.string(scratch)? {
                    Some(s) => Value::Str(s),
                    None => Value::TooLong,
                })
            }
            Some(b'-' | b'0'..=b'9') => self.number(),
            Some(b't') => self.literal(b"true"),
            Some(b'f') => self.literal(b"false"),
            Some(b'n') => self.literal(b"null"),
            _ => Err(ScanError::Syntax), // includes '{' and '[': nested values are not supported
        }
    }

    fn literal<'s>(&mut self, word: &[u8]) -> Result<Value<'s>, ScanError> {
        if self.input[self.pos..].starts_with(word) {
            self.pos += word.len();
            Ok(Value::Other)
        } else {
            Err(ScanError::Syntax)
        }
    }

    fn digits(&mut self) -> usize {
        let start = self.pos;
        while self.peek().is_some_and(|b| b.is_ascii_digit()) {
            self.pos += 1;
        }
        self.pos - start
    }

    /// JSON number grammar: `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`.
    fn number<'s>(&mut self) -> Result<Value<'s>, ScanError> {
        let negative = self.eat(b'-');
        let int_start = self.pos;
        match self.peek() {
            Some(b'0') => self.pos += 1,
            Some(b'1'..=b'9') => {
                self.digits();
            }
            _ => return Err(ScanError::Syntax),
        }
        let int_digits = &self.input[int_start..self.pos];
        let mut plain = !negative;
        if self.eat(b'.') {
            plain = false;
            if self.digits() == 0 {
                return Err(ScanError::Syntax);
            }
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.pos += 1;
            plain = false;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.pos += 1;
            }
            if self.digits() == 0 {
                return Err(ScanError::Syntax);
            }
        }
        Ok(
            match plain.then(|| parse_decimal_u64(int_digits)).flatten() {
                Some(n) => Value::Uint(n),
                None => Value::Other,
            },
        )
    }

    /// Reads a string body (the opening quote is already consumed). Returns the unescaped bytes, borrowed from
    /// the input when there is no escape and from `scratch` otherwise; `None` if the result would not fit.
    fn string<'s>(
        &mut self,
        scratch: &'s mut [u8; SCRATCH_LEN],
    ) -> Result<Option<&'s [u8]>, ScanError>
    where
        'a: 's,
    {
        let start = self.pos;
        loop {
            match self.next() {
                Some(b'"') => return Ok(Some(&self.input[start..self.pos - 1])),
                Some(b'\\') => break,
                Some(0..=0x1F) | None => return Err(ScanError::Syntax),
                Some(_) => {}
            }
        }
        // Slow path: the string has an escape. Copy what we have, then decode the rest into the scratch buffer.
        let mut sink = Sink {
            buf: scratch,
            len: 0,
            overflow: false,
        };
        sink.push_all(&self.input[start..self.pos - 1]);
        self.escape(&mut sink)?;
        loop {
            match self.next() {
                Some(b'"') => return Ok(sink.finish()),
                Some(b'\\') => self.escape(&mut sink)?,
                Some(b @ 0x20..) => sink.push_all(&[b]),
                _ => return Err(ScanError::Syntax),
            }
        }
    }

    /// Decodes one escape sequence (the backslash is already consumed).
    fn escape(&mut self, sink: &mut Sink<'_>) -> Result<(), ScanError> {
        let decoded = match self.next() {
            Some(b'"') => b'"',
            Some(b'\\') => b'\\',
            Some(b'/') => b'/',
            Some(b'b') => 0x08,
            Some(b'f') => 0x0C,
            Some(b'n') => b'\n',
            Some(b'r') => b'\r',
            Some(b't') => b'\t',
            Some(b'u') => {
                let ch = char::from_u32(self.hex4()?).ok_or(ScanError::Syntax)?; // rejects surrogates
                sink.push_all(ch.encode_utf8(&mut [0; 4]).as_bytes());
                return Ok(());
            }
            _ => return Err(ScanError::Syntax),
        };
        sink.push_all(&[decoded]);
        Ok(())
    }

    fn hex4(&mut self) -> Result<u32, ScanError> {
        let mut value = 0u32;
        for _ in 0..4 {
            let digit = self
                .next()
                .and_then(|b| (b as char).to_digit(16))
                .ok_or(ScanError::Syntax)?;
            value = value << 4 | digit;
        }
        Ok(value)
    }
}

/// Bounded output buffer: remembers an overflow instead of failing mid-string, so the scanner can still skip to
/// the closing quote and validate the rest of the object.
struct Sink<'s> {
    buf: &'s mut [u8; SCRATCH_LEN],
    len: usize,
    overflow: bool,
}

impl<'s> Sink<'s> {
    fn push_all(&mut self, bytes: &[u8]) {
        match self.buf.get_mut(self.len..self.len + bytes.len()) {
            Some(dst) => {
                dst.copy_from_slice(bytes);
                self.len += bytes.len();
            }
            None => self.overflow = true,
        }
    }

    fn finish(self) -> Option<&'s [u8]> {
        let Sink { buf, len, overflow } = self;
        if overflow { None } else { Some(&buf[..len]) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Collects members as (key, rendered value) for easy assertions.
    fn members(input: &str) -> Result<Vec<(String, String)>, ScanError> {
        let mut out = Vec::new();
        scan_object(input.as_bytes(), |k, v| {
            out.push((String::from_utf8_lossy(k).into_owned(), format!("{v:?}")));
            Ok(())
        })?;
        Ok(out)
    }

    #[test]
    fn reads_members_in_any_order_with_whitespace() {
        let got = members(" {\n \"b\" : 12 ,\t\"a\":\"x\" , \"c\":true,\"d\":null,\"e\":-3 } \n")
            .unwrap();
        let rendered: Vec<_> = got.iter().map(|(k, v)| format!("{k}={v}")).collect();
        assert_eq!(
            rendered,
            [
                "b=Uint(12)",
                "a=Str([120])",
                "c=Other",
                "d=Other",
                "e=Other"
            ]
        );
    }

    #[test]
    fn empty_object_and_trailing_garbage() {
        assert_eq!(members("{}").unwrap().len(), 0);
        assert_eq!(members("{} x"), Err(ScanError::Syntax));
        assert_eq!(members(""), Err(ScanError::Syntax));
        assert_eq!(members("[]"), Err(ScanError::Syntax));
    }

    #[test]
    fn numbers_follow_json_grammar() {
        let kinds = |text: &str| members(&format!("{{\"n\":{text}}}")).map(|m| m[0].1.clone());
        assert_eq!(kinds("0").unwrap(), "Uint(0)");
        assert_eq!(kinds("1702592000").unwrap(), "Uint(1702592000)");
        assert_eq!(
            kinds("18446744073709551615").unwrap(),
            "Uint(18446744073709551615)"
        );
        assert_eq!(kinds("18446744073709551616").unwrap(), "Other");
        for other in ["1.5", "1.7e9", "1E3", "-1", "0.0"] {
            assert_eq!(kinds(other).unwrap(), "Other", "{other}");
        }
        for bad in ["01", "1.", "-", "1e", "+1", ".5", "1e+"] {
            assert_eq!(kinds(bad), Err(ScanError::Syntax), "{bad}");
        }
    }

    #[test]
    fn strings_unescape() {
        let got = members(r#"{"s\u0075b":"4\u0032","q":"a\"b\\c\/d\n"}"#).unwrap();
        assert_eq!(got[0], ("sub".into(), "Str([52, 50])".into()));
        assert_eq!(got[1].1, "Str([97, 34, 98, 92, 99, 47, 100, 10])");
    }

    #[test]
    fn long_strings_are_kept_without_escapes_and_flagged_with_them() {
        let plain = format!("{{\"k\":\"{}\"}}", "x".repeat(100));
        assert!(members(&plain).unwrap()[0].1.starts_with("Str("));
        let escaped = format!("{{\"k\":\"\\n{}\"}}", "x".repeat(100));
        assert_eq!(members(&escaped).unwrap()[0].1, "TooLong");
    }

    #[test]
    fn rejects_bad_strings_and_nesting() {
        for bad in [
            r#"{"a":"x"#,
            r#"{"a":"\q"}"#,
            r#"{"a":"\u12"}"#,
            r#"{"a":"\ud800"}"#,
            "{\"a\":\"line\nbreak\"}",
            r#"{"a":{}}"#,
            r#"{"a":[1]}"#,
            r#"{"a":1,}"#,
            r#"{"a" 1}"#,
            r#"{a:1}"#,
            r#"{"a":tru}"#,
        ] {
            assert_eq!(members(bad), Err(ScanError::Syntax), "{bad}");
        }
    }

    #[test]
    fn visitor_can_reject() {
        let result = scan_object(br#"{"a":1}"#, |_, _| Err(ScanError::Rejected));
        assert_eq!(result, Err(ScanError::Rejected));
    }

    #[test]
    fn parse_decimal_u64_cases() {
        assert_eq!(parse_decimal_u64(b"0042"), Some(42));
        assert_eq!(parse_decimal_u64(b"18446744073709551615"), Some(u64::MAX));
        assert_eq!(parse_decimal_u64(b"18446744073709551616"), None);
        assert_eq!(parse_decimal_u64(b""), None);
        assert_eq!(parse_decimal_u64(b"4a"), None);
    }
}
