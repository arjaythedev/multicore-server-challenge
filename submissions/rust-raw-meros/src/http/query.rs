//! Query-string helpers: parameter lookup, percent-decoding, strict integer parsing.
//!
//! Everything returns borrowed data when nothing needs decoding, which is the usual case (`limit=10`).

use std::borrow::Cow;

/// Value of the first parameter called `name`, decoded as `application/x-www-form-urlencoded`
/// (`%XX` escapes, `+` is a space). A parameter without `=` has an empty value.
/// Keys are compared after decoding too, so `fav%6Frited=x` finds `favorited`.
pub fn query_param<'a>(query: &'a [u8], name: &str) -> Option<Cow<'a, [u8]>> {
    query
        .split(|&b| b == b'&')
        .filter(|pair| !pair.is_empty())
        .find_map(|pair| {
            let (key, value) = match pair.iter().position(|&b| b == b'=') {
                Some(eq) => (&pair[..eq], &pair[eq + 1..]),
                None => (pair, &pair[pair.len()..]),
            };
            (form_decode(key).as_ref() == name.as_bytes()).then(|| form_decode(value))
        })
}

/// Decode `%XX` escapes. Invalid escapes (`%`, `%4`, `%zz`) are kept literally. `+` is left alone, which is
/// right for path segments; use [`form_decode`] for query components.
pub fn percent_decode(input: &[u8]) -> Cow<'_, [u8]> {
    decode(input, false)
}

/// Like [`percent_decode`] but `+` becomes a space (query-string rules).
pub fn form_decode(input: &[u8]) -> Cow<'_, [u8]> {
    decode(input, true)
}

fn decode(input: &[u8], plus_is_space: bool) -> Cow<'_, [u8]> {
    let needs_work = |b: &u8| *b == b'%' || (plus_is_space && *b == b'+');
    let Some(first) = input.iter().position(needs_work) else {
        return Cow::Borrowed(input);
    };
    let mut out = Vec::with_capacity(input.len());
    out.extend_from_slice(&input[..first]);
    let mut i = first;
    while i < input.len() {
        match input[i] {
            b'%' => match (
                input.get(i + 1).copied().and_then(hex_value),
                input.get(i + 2).copied().and_then(hex_value),
            ) {
                (Some(hi), Some(lo)) => {
                    out.push(hi << 4 | lo);
                    i += 3;
                }
                _ => {
                    out.push(b'%');
                    i += 1;
                }
            },
            b'+' if plus_is_space => {
                out.push(b' ');
                i += 1;
            }
            other => {
                out.push(other);
                i += 1;
            }
        }
    }
    Cow::Owned(out)
}

fn hex_value(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

/// Most digits accepted by [`parse_int`]; 18 nines still fit an `i64`.
const MAX_INT_DIGITS: usize = 18;

/// Strict decimal integer: optional leading `-`, then 1 to 18 ASCII digits. No spaces, no `+`, no empty string.
pub fn parse_int(input: &[u8]) -> Option<i64> {
    let (negative, digits) = match input.split_first() {
        Some((b'-', rest)) => (true, rest),
        _ => (false, input),
    };
    if digits.is_empty() || digits.len() > MAX_INT_DIGITS {
        return None;
    }
    let mut n: i64 = 0;
    for &b in digits {
        if !b.is_ascii_digit() {
            return None;
        }
        n = n * 10 + i64::from(b - b'0');
    }
    Some(if negative { -n } else { n })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn param(q: &str, name: &str) -> Option<Vec<u8>> {
        query_param(q.as_bytes(), name).map(Cow::into_owned)
    }

    #[test]
    fn finds_first_occurrence() {
        assert_eq!(
            param("limit=10&offset=0&limit=99", "limit"),
            Some(b"10".to_vec())
        );
        assert_eq!(param("limit=10&offset=0", "offset"), Some(b"0".to_vec()));
        assert_eq!(param("limit=10", "tag"), None);
        assert_eq!(param("", "tag"), None);
    }

    #[test]
    fn empty_and_valueless_params() {
        assert_eq!(param("tag=&x=1", "tag"), Some(Vec::new()));
        assert_eq!(param("flag&x=1", "flag"), Some(Vec::new()));
        assert_eq!(param("&&x=1&&", "x"), Some(b"1".to_vec()));
        assert_eq!(param("a=b=c", "a"), Some(b"b=c".to_vec()));
    }

    #[test]
    fn decodes_values_and_keys() {
        assert_eq!(param("tag=a%20b+c", "tag"), Some(b"a b c".to_vec()));
        assert_eq!(param("fav%6Frited=x", "favorited"), Some(b"x".to_vec()));
        assert_eq!(
            param("author=J%C3%B6rn", "author"),
            Some("Jörn".as_bytes().to_vec())
        );
    }

    #[test]
    fn borrows_when_clean() {
        assert!(matches!(
            query_param(b"limit=10", "limit"),
            Some(Cow::Borrowed(_))
        ));
        assert!(matches!(percent_decode(b"plain"), Cow::Borrowed(_)));
    }

    #[test]
    fn percent_decode_cases() {
        assert_eq!(percent_decode(b"a%2Fb").as_ref(), b"a/b");
        assert_eq!(percent_decode(b"a+b").as_ref(), b"a+b");
        assert_eq!(percent_decode(b"100%").as_ref(), b"100%");
        assert_eq!(percent_decode(b"%4").as_ref(), b"%4");
        assert_eq!(percent_decode(b"%zz%41").as_ref(), b"%zzA");
        assert_eq!(percent_decode(b"%%41").as_ref(), b"%A");
        assert_eq!(percent_decode(b"").as_ref(), b"");
    }

    #[test]
    fn parse_int_accepts_and_rejects() {
        assert_eq!(parse_int(b"0"), Some(0));
        assert_eq!(parse_int(b"42"), Some(42));
        assert_eq!(parse_int(b"-7"), Some(-7));
        assert_eq!(parse_int(b"007"), Some(7));
        assert_eq!(
            parse_int(b"999999999999999999"),
            Some(999_999_999_999_999_999)
        );
        assert_eq!(
            parse_int(b"-999999999999999999"),
            Some(-999_999_999_999_999_999)
        );
        for bad in [
            &b""[..],
            b"-",
            b"+1",
            b" 1",
            b"1 ",
            b"1.5",
            b"0x10",
            b"1e3",
            b"--1",
            b"9999999999999999999",
        ] {
            assert_eq!(parse_int(bad), None, "{}", String::from_utf8_lossy(bad));
        }
    }
}
