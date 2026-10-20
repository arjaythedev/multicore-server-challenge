//! Request-side helpers: query strings, percent-decoding, and the field types request bodies
//! are validated with.

use std::ops::Deref;

use serde::Deserialize;

use crate::api::AppError;
use crate::db::{Param, ToParam};

/// ASCII digits only (no sign, no spaces) that fit in an i64.
pub fn parse_uint(s: &str) -> Option<i64> {
    if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    s.parse().ok()
}

fn hex(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

/// Percent-decode; `plus` turns '+' into ' ' (query strings).
pub fn pct_decode(s: &str, plus: bool) -> String {
    if !s.bytes().any(|b| b == b'%' || (plus && b == b'+')) {
        return s.to_string();
    }
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'%' if i + 2 < b.len() => {
                match (hex(b[i + 1]), hex(b[i + 2])) {
                    (Some(h), Some(l)) => {
                        out.push(h << 4 | l);
                        i += 3;
                    }
                    _ => {
                        out.push(b'%');
                        i += 1;
                    }
                }
            }
            b'+' if plus => {
                out.push(b' ');
                i += 1;
            }
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// First value of each query parameter.
pub struct Query(Vec<(String, String)>);

impl Query {
    pub fn parse(q: Option<&str>) -> Query {
        let mut v = Vec::new();
        for part in q.unwrap_or("").split('&') {
            if part.is_empty() {
                continue;
            }
            let (k, val) = part.split_once('=').unwrap_or((part, ""));
            v.push((pct_decode(k, true), pct_decode(val, true)));
        }
        Query(v)
    }
    pub fn get(&self, key: &str) -> Option<&str> {
        self.0.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str())
    }
    pub fn filter(&self, key: &str) -> Option<&str> {
        self.get(key).filter(|v| !v.is_empty())
    }
    pub fn page(&self) -> Result<(i64, i64), AppError> {
        let limit = match self.get("limit") {
            None => 20,
            Some(v) => parse_uint(v).filter(|n| (1..=100).contains(n)).ok_or(AppError::Unprocessable)?,
        };
        let offset = match self.get("offset") {
            None => 0,
            Some(v) => parse_uint(v).ok_or(AppError::Unprocessable)?,
        };
        Ok((limit, offset))
    }
}

/// A string field that must not be empty (otherwise the request is 422).
#[derive(Deserialize)]
#[serde(try_from = "String")]
pub struct NonEmpty(String);

impl TryFrom<String> for NonEmpty {
    type Error = &'static str;

    fn try_from(s: String) -> Result<Self, Self::Error> {
        if s.is_empty() {
            Err("must not be empty")
        } else {
            Ok(NonEmpty(s))
        }
    }
}

impl Deref for NonEmpty {
    type Target = str;

    fn deref(&self) -> &str {
        &self.0
    }
}

impl From<NonEmpty> for String {
    fn from(s: NonEmpty) -> String {
        s.0
    }
}

impl ToParam for NonEmpty {
    fn to_param(&self) -> Param {
        self.0.to_param()
    }
}
