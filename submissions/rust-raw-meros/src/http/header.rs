//! Small helpers for header names and values. No allocation, ASCII only.

/// Strip leading and trailing spaces and tabs (RFC 9110 optional whitespace).
#[inline]
pub fn trim_ows(mut v: &[u8]) -> &[u8] {
    while let [b' ' | b'\t', rest @ ..] = v {
        v = rest;
    }
    while let [rest @ .., b' ' | b'\t'] = v {
        v = rest;
    }
    v
}

/// RFC 9110 `tchar`: the bytes allowed in a header name or a method.
#[inline]
pub fn is_token_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&b)
}

/// What a `Connection` header asks for. `close` wins over `keep-alive` when both are listed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ConnectionToken {
    Close,
    KeepAlive,
    Neither,
}

/// Look through the comma separated tokens of a `Connection` value.
pub fn connection_token(value: &[u8]) -> ConnectionToken {
    let mut found = ConnectionToken::Neither;
    for token in value.split(|&b| b == b',') {
        let token = trim_ows(token);
        if token.eq_ignore_ascii_case(b"close") {
            return ConnectionToken::Close;
        }
        if token.eq_ignore_ascii_case(b"keep-alive") {
            found = ConnectionToken::KeepAlive;
        }
    }
    found
}

/// `application/json`, optionally followed by `;` parameters (`; charset=utf-8`). Case-insensitive.
pub fn is_json_content_type(value: &[u8]) -> bool {
    const JSON: &[u8] = b"application/json";
    value.len() >= JSON.len()
        && value[..JSON.len()].eq_ignore_ascii_case(JSON)
        && matches!(value.get(JSON.len()), None | Some(b';' | b' ' | b'\t'))
}

/// Result of reading a `Content-Length` value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Length {
    Value(usize),
    /// Empty, or contains something other than ASCII digits.
    Malformed,
}

/// Parse a `Content-Length` value. Saturates instead of overflowing: a huge number is "too large", not "bad".
pub fn parse_content_length(value: &[u8]) -> Length {
    if value.is_empty() {
        return Length::Malformed;
    }
    let mut n: usize = 0;
    for &b in value {
        if !b.is_ascii_digit() {
            return Length::Malformed;
        }
        n = n.saturating_mul(10).saturating_add(usize::from(b - b'0'));
    }
    Length::Value(n)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trims_blanks() {
        assert_eq!(trim_ows(b" \t x y \t"), b"x y");
        assert_eq!(trim_ows(b""), b"");
        assert_eq!(trim_ows(b"   "), b"");
    }

    #[test]
    fn connection_tokens() {
        assert_eq!(connection_token(b"close"), ConnectionToken::Close);
        assert_eq!(connection_token(b"Keep-Alive"), ConnectionToken::KeepAlive);
        assert_eq!(
            connection_token(b"keep-alive, Close"),
            ConnectionToken::Close
        );
        assert_eq!(connection_token(b"upgrade"), ConnectionToken::Neither);
        assert_eq!(connection_token(b"closed"), ConnectionToken::Neither);
    }

    #[test]
    fn content_types() {
        assert!(is_json_content_type(b"application/json"));
        assert!(is_json_content_type(b"Application/JSON; charset=utf-8"));
        assert!(!is_json_content_type(b"application/jsonp"));
        assert!(!is_json_content_type(b"text/plain"));
        assert!(!is_json_content_type(b""));
    }

    #[test]
    fn content_length_values() {
        assert_eq!(parse_content_length(b"0"), Length::Value(0));
        assert_eq!(parse_content_length(b"123"), Length::Value(123));
        assert_eq!(parse_content_length(b""), Length::Malformed);
        assert_eq!(parse_content_length(b"-1"), Length::Malformed);
        assert_eq!(parse_content_length(b"1 2"), Length::Malformed);
        assert_eq!(
            parse_content_length(b"99999999999999999999999999"),
            Length::Value(usize::MAX)
        );
    }
}
