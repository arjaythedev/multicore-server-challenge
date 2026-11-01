//! Strict RFC 8259 reader producing a [`Value`] tree.
//!
//! Checks: whole input is UTF-8, at most 1 MiB, nesting at most 32, no trailing bytes, no comments, no
//! leading zeros, no raw control characters in strings, valid escapes. `\uXXXX` handles surrogate pairs; a
//! lone surrogate becomes U+FFFD (as Go's decoder does). Strings without escapes borrow from the input.

use std::borrow::Cow;

use super::value::{JsonError, Value};

/// Largest input accepted.
pub const MAX_INPUT_BYTES: usize = 1024 * 1024;
/// Deepest nesting of arrays/objects accepted.
pub const MAX_DEPTH: usize = 32;

const REPLACEMENT: char = '\u{FFFD}';

/// Parse one JSON document.
pub fn parse(input: &[u8]) -> Result<Value<'_>, JsonError> {
    if input.len() > MAX_INPUT_BYTES {
        return Err(JsonError::TooLarge);
    }
    let text = std::str::from_utf8(input).map_err(|_| JsonError::InvalidUtf8)?;
    let mut p = Parser {
        text,
        bytes: input,
        pos: 0,
    };
    p.skip_ws();
    let value = p.value(0)?;
    p.skip_ws();
    if p.pos != p.bytes.len() {
        return Err(p.error());
    }
    Ok(value)
}

struct Parser<'a> {
    /// Same bytes as `bytes`, already validated as UTF-8; slices are taken at ASCII delimiters only.
    text: &'a str,
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Parser<'a> {
    fn error(&self) -> JsonError {
        JsonError::Syntax { offset: self.pos }
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    fn skip_ws(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.pos += 1;
        }
    }

    fn expect(&mut self, byte: u8) -> Result<(), JsonError> {
        if self.peek() == Some(byte) {
            self.pos += 1;
            Ok(())
        } else {
            Err(self.error())
        }
    }

    fn literal(&mut self, word: &[u8], value: Value<'a>) -> Result<Value<'a>, JsonError> {
        if self.bytes[self.pos..].starts_with(word) {
            self.pos += word.len();
            Ok(value)
        } else {
            Err(self.error())
        }
    }

    fn value(&mut self, depth: usize) -> Result<Value<'a>, JsonError> {
        match self.peek() {
            Some(b'{') => self.object(depth + 1),
            Some(b'[') => self.array(depth + 1),
            Some(b'"') => Ok(Value::String(self.string()?)),
            Some(b't') => self.literal(b"true", Value::Bool(true)),
            Some(b'f') => self.literal(b"false", Value::Bool(false)),
            Some(b'n') => self.literal(b"null", Value::Null),
            Some(b'-' | b'0'..=b'9') => self.number(),
            _ => Err(self.error()),
        }
    }

    fn array(&mut self, depth: usize) -> Result<Value<'a>, JsonError> {
        if depth > MAX_DEPTH {
            return Err(JsonError::TooDeep);
        }
        self.pos += 1; // '['
        let mut items = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b']') {
            self.pos += 1;
            return Ok(Value::Array(items));
        }
        loop {
            self.skip_ws();
            items.push(self.value(depth)?);
            self.skip_ws();
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b']') => {
                    self.pos += 1;
                    return Ok(Value::Array(items));
                }
                _ => return Err(self.error()),
            }
        }
    }

    fn object(&mut self, depth: usize) -> Result<Value<'a>, JsonError> {
        if depth > MAX_DEPTH {
            return Err(JsonError::TooDeep);
        }
        self.pos += 1; // '{'
        let mut members = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b'}') {
            self.pos += 1;
            return Ok(Value::Object(members));
        }
        loop {
            self.skip_ws();
            if self.peek() != Some(b'"') {
                return Err(self.error());
            }
            let key = self.string()?;
            self.skip_ws();
            self.expect(b':')?;
            self.skip_ws();
            members.push((key, self.value(depth)?));
            self.skip_ws();
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b'}') => {
                    self.pos += 1;
                    return Ok(Value::Object(members));
                }
                _ => return Err(self.error()),
            }
        }
    }

    /// `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`
    fn number(&mut self) -> Result<Value<'a>, JsonError> {
        let start = self.pos;
        if self.peek() == Some(b'-') {
            self.pos += 1;
        }
        match self.peek() {
            Some(b'0') => self.pos += 1,
            Some(b'1'..=b'9') => self.skip_digits(),
            _ => return Err(self.error()),
        }
        if self.peek() == Some(b'.') {
            self.pos += 1;
            self.require_digits()?;
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.pos += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.pos += 1;
            }
            self.require_digits()?;
        }
        let text = self.text.get(start..self.pos).ok_or_else(|| self.error())?;
        Ok(Value::Number(text))
    }

    fn skip_digits(&mut self) {
        while self.peek().is_some_and(|b| b.is_ascii_digit()) {
            self.pos += 1;
        }
    }

    fn require_digits(&mut self) -> Result<(), JsonError> {
        let before = self.pos;
        self.skip_digits();
        if self.pos == before {
            Err(self.error())
        } else {
            Ok(())
        }
    }

    /// Parse a string starting at the opening quote. Borrowed when it has no escapes.
    fn string(&mut self) -> Result<Cow<'a, str>, JsonError> {
        self.pos += 1; // opening quote
        let start = self.pos;
        // Fast scan: stop at the closing quote, a backslash, or an illegal control character.
        loop {
            match self.peek() {
                Some(b'"') => {
                    let s = self.text.get(start..self.pos).ok_or_else(|| self.error())?;
                    self.pos += 1;
                    return Ok(Cow::Borrowed(s));
                }
                Some(b'\\') => break,
                Some(b) if b >= 0x20 => self.pos += 1,
                _ => return Err(self.error()), // control character or end of input
            }
        }
        let mut owned = String::from(self.text.get(start..self.pos).ok_or_else(|| self.error())?);
        self.string_with_escapes(&mut owned)?;
        Ok(Cow::Owned(owned))
    }

    /// Continue a string at a backslash, appending decoded text to `out`, until the closing quote.
    fn string_with_escapes(&mut self, out: &mut String) -> Result<(), JsonError> {
        loop {
            let run_start = self.pos;
            while self
                .peek()
                .is_some_and(|b| b >= 0x20 && b != b'"' && b != b'\\')
            {
                self.pos += 1;
            }
            out.push_str(
                self.text
                    .get(run_start..self.pos)
                    .ok_or_else(|| self.error())?,
            );
            match self.peek() {
                Some(b'"') => {
                    self.pos += 1;
                    return Ok(());
                }
                Some(b'\\') => {
                    self.pos += 1;
                    self.escape(out)?;
                }
                _ => return Err(self.error()),
            }
        }
    }

    /// Decode the escape after a backslash (the backslash is already consumed).
    fn escape(&mut self, out: &mut String) -> Result<(), JsonError> {
        let Some(c) = self.peek() else {
            return Err(self.error());
        };
        self.pos += 1;
        match c {
            b'"' => out.push('"'),
            b'\\' => out.push('\\'),
            b'/' => out.push('/'),
            b'b' => out.push('\u{8}'),
            b'f' => out.push('\u{c}'),
            b'n' => out.push('\n'),
            b'r' => out.push('\r'),
            b't' => out.push('\t'),
            b'u' => out.push(self.unicode_escape()?),
            _ => {
                self.pos -= 1;
                return Err(self.error());
            }
        }
        Ok(())
    }

    /// After `\u`: four hex digits, plus a following `\uXXXX` when the first is a high surrogate.
    fn unicode_escape(&mut self) -> Result<char, JsonError> {
        let first = self.hex4()?;
        match first {
            0xD800..=0xDBFF => {
                // A high surrogate is only valid when a low surrogate escape follows.
                let save = self.pos;
                if self.bytes[self.pos..].starts_with(b"\\u") {
                    self.pos += 2;
                    let second = self.hex4()?;
                    if (0xDC00..=0xDFFF).contains(&second) {
                        let code = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00);
                        return Ok(char::from_u32(code).unwrap_or(REPLACEMENT));
                    }
                }
                self.pos = save; // leave the next escape to be decoded on its own
                Ok(REPLACEMENT)
            }
            0xDC00..=0xDFFF => Ok(REPLACEMENT),
            _ => Ok(char::from_u32(first).unwrap_or(REPLACEMENT)),
        }
    }

    fn hex4(&mut self) -> Result<u32, JsonError> {
        let digits = self
            .bytes
            .get(self.pos..self.pos + 4)
            .ok_or_else(|| self.error())?;
        let mut n = 0u32;
        for &d in digits {
            let v = match d {
                b'0'..=b'9' => d - b'0',
                b'a'..=b'f' => d - b'a' + 10,
                b'A'..=b'F' => d - b'A' + 10,
                _ => return Err(self.error()),
            };
            n = n << 4 | u32::from(v);
        }
        self.pos += 4;
        Ok(n)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ok(s: &str) -> Value<'_> {
        parse(s.as_bytes()).unwrap_or_else(|e| panic!("{s:?}: {e}"))
    }

    fn rejected(s: &[u8]) -> JsonError {
        parse(s).expect_err(&String::from_utf8_lossy(s))
    }

    #[test]
    fn scalars() {
        assert_eq!(ok("null"), Value::Null);
        assert_eq!(ok(" true "), Value::Bool(true));
        assert_eq!(ok("false"), Value::Bool(false));
        assert_eq!(ok("-12.5e+3"), Value::Number("-12.5e+3"));
        assert_eq!(ok("0"), Value::Number("0"));
        assert_eq!(ok("\"hi\""), Value::String("hi".into()));
    }

    #[test]
    fn conduit_body() {
        let v = ok(r#"{"article":{"title":"T","tagList":["a","b"],"draft":null,"n":3}}"#);
        let article = v.get("article").unwrap();
        assert_eq!(article.get("title").and_then(Value::as_str), Some("T"));
        assert_eq!(
            article
                .get("tagList")
                .and_then(Value::as_array)
                .map(<[_]>::len),
            Some(2)
        );
        assert!(article.get("draft").unwrap().is_null());
        assert_eq!(article.get("n").and_then(Value::as_number), Some("3"));
        assert!(article.get("missing").is_none());
        assert_eq!(article.as_object().map(<[_]>::len), Some(4));
    }

    #[test]
    fn strings_borrow_unless_escaped() {
        let v = ok(r#"["plain","es\ncaped","åäö"]"#);
        let items = v.as_array().unwrap();
        assert!(matches!(&items[0], Value::String(Cow::Borrowed("plain"))));
        assert!(matches!(&items[1], Value::String(Cow::Owned(s)) if s == "es\ncaped"));
        assert!(matches!(&items[2], Value::String(Cow::Borrowed("åäö"))));
    }

    #[test]
    fn all_simple_escapes() {
        assert_eq!(
            ok(r#""\"\\\/\b\f\n\r\t""#).as_str(),
            Some("\"\\/\u{8}\u{c}\n\r\t")
        );
    }

    #[test]
    fn unicode_escapes_and_surrogates() {
        assert_eq!(ok(r#""\u00e5\u00C4""#).as_str(), Some("åÄ"));
        assert_eq!(ok(r#""\ud83d\ude00""#).as_str(), Some("😀"));
        assert_eq!(ok(r#""a\u0000b""#).as_str(), Some("a\0b"));
        // Lone surrogates become U+FFFD; the character after a lone high surrogate survives.
        assert_eq!(ok(r#""\ud83d""#).as_str(), Some("\u{FFFD}"));
        assert_eq!(ok(r#""\ud83dx""#).as_str(), Some("\u{FFFD}x"));
        assert_eq!(ok(r#""\ude00""#).as_str(), Some("\u{FFFD}"));
        assert_eq!(ok(r#""\ud83d\u0041""#).as_str(), Some("\u{FFFD}A"));
        assert_eq!(ok(r#""\ud83d\ud83d\ude00""#).as_str(), Some("\u{FFFD}😀"));
    }

    #[test]
    fn duplicate_keys_keep_the_last() {
        let v = ok(r#"{"a":1,"b":2,"a":3}"#);
        assert_eq!(v.get("a").and_then(Value::as_number), Some("3"));
        assert_eq!(v.as_object().map(<[_]>::len), Some(3));
    }

    #[test]
    fn empty_containers_and_whitespace() {
        assert_eq!(ok(" [ ] "), Value::Array(vec![]));
        assert_eq!(ok("\t{\r\n}\n"), Value::Object(vec![]));
        assert_eq!(ok("[1 , 2]").as_array().map(<[_]>::len), Some(2));
    }

    #[test]
    fn rejects_malformed_documents() {
        let cases: &[&str] = &[
            "",
            " ",
            "nul",
            "tru",
            "True",
            "[",
            "]",
            "{",
            "}",
            "[1,]",
            "[,1]",
            "[1 2]",
            "{\"a\":1,}",
            "{,}",
            "{\"a\"}",
            "{\"a\":}",
            "{a:1}",
            "{'a':1}",
            "{\"a\" 1}",
            "01",
            "-",
            "-01",
            "+1",
            ".5",
            "1.",
            "1.e3",
            "1e",
            "1e+",
            "0x1",
            "NaN",
            "Infinity",
            "\"abc",
            "\"a\nb\"",
            "\"a\tb\"",
            "\"\\x41\"",
            "\"\\u12\"",
            "\"\\u12G4\"",
            "\"\\",
            "[1] x",
            "1 2",
            "{} {}",
            "// c\n1",
            "/* c */ 1",
            "[1]/**/",
            "\u{feff}1",
        ];
        for case in cases {
            assert!(
                matches!(parse(case.as_bytes()), Err(JsonError::Syntax { .. })),
                "{case:?}"
            );
        }
    }

    #[test]
    fn syntax_error_reports_offset() {
        assert_eq!(rejected(b"[1,]"), JsonError::Syntax { offset: 3 });
        assert_eq!(rejected(b"{} x"), JsonError::Syntax { offset: 3 });
    }

    #[test]
    fn invalid_utf8_is_rejected_even_inside_a_string() {
        assert_eq!(rejected(b"\"\xff\""), JsonError::InvalidUtf8);
        assert_eq!(rejected(b"\"\xc3\""), JsonError::InvalidUtf8);
        assert_eq!(rejected(b"\"\xed\xa0\x80\""), JsonError::InvalidUtf8); // encoded surrogate
    }

    #[test]
    fn depth_limit() {
        let nested = |n: usize| format!("{}1{}", "[".repeat(n), "]".repeat(n));
        assert!(parse(nested(MAX_DEPTH).as_bytes()).is_ok());
        assert_eq!(
            rejected(nested(MAX_DEPTH + 1).as_bytes()),
            JsonError::TooDeep
        );
        let objects = format!(
            "{}1{}",
            "{\"a\":".repeat(MAX_DEPTH + 1),
            "}".repeat(MAX_DEPTH + 1)
        );
        assert_eq!(rejected(objects.as_bytes()), JsonError::TooDeep);
        // A very deep input must fail cleanly, not overflow the stack.
        assert_eq!(rejected("[".repeat(100_000).as_bytes()), JsonError::TooDeep);
    }

    #[test]
    fn size_limit() {
        let at_limit = format!("\"{}\"", "a".repeat(MAX_INPUT_BYTES - 2));
        assert!(parse(at_limit.as_bytes()).is_ok());
        let over = format!("\"{}\"", "a".repeat(MAX_INPUT_BYTES - 1));
        assert_eq!(rejected(over.as_bytes()), JsonError::TooLarge);
    }

    #[test]
    fn accessors_on_wrong_types_return_none() {
        let v = ok("1");
        assert!(v.get("a").is_none() && v.as_str().is_none() && v.as_bool().is_none());
        assert!(v.as_array().is_none() && v.as_object().is_none() && !v.is_null());
        assert_eq!(ok("true").as_bool(), Some(true));
    }

    #[test]
    fn round_trip_through_the_writer() {
        use crate::json::JsonWriter;
        let tricky = "line1\nline2 \"q\" \\ \u{1} \u{7f} åäö 😀 /";
        let mut out = Vec::new();
        let mut w = JsonWriter::new(&mut out);
        w.begin_array();
        w.string(tricky);
        w.int(-9_007_199_254_740_993);
        w.bool(false);
        w.null();
        w.end_array();
        let v = parse(&out).unwrap();
        let items = v.as_array().unwrap();
        assert_eq!(items[0].as_str(), Some(tricky));
        assert_eq!(items[1].as_number(), Some("-9007199254740993"));
        assert_eq!(items[2].as_bool(), Some(false));
        assert!(items[3].is_null());
    }
}
