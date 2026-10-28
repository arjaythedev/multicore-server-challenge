//! The parsed JSON tree and its error type.

use std::borrow::Cow;
use std::fmt;

/// A parsed JSON value. Strings without escapes and all numbers borrow from the input.
#[derive(Clone, Debug, PartialEq)]
pub enum Value<'a> {
    Null,
    Bool(bool),
    /// The number exactly as written (already checked against the JSON grammar). Convert with `str::parse`.
    Number(&'a str),
    String(Cow<'a, str>),
    Array(Vec<Value<'a>>),
    /// Members in input order. Duplicate keys are kept; [`Value::get`] returns the last one.
    Object(Vec<(Cow<'a, str>, Value<'a>)>),
}

impl<'a> Value<'a> {
    /// Member of an object by key; with duplicate keys the last one wins (like Go's `encoding/json`).
    /// `None` for a missing key or a non-object.
    pub fn get(&self, key: &str) -> Option<&Value<'a>> {
        match self {
            Value::Object(members) => members.iter().rev().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::String(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Value::Bool(b) => Some(*b),
            _ => None,
        }
    }

    /// The number's text, e.g. `"-1.5e3"`.
    pub fn as_number(&self) -> Option<&str> {
        match self {
            Value::Number(n) => Some(n),
            _ => None,
        }
    }

    pub fn is_null(&self) -> bool {
        matches!(self, Value::Null)
    }

    pub fn as_array(&self) -> Option<&[Value<'a>]> {
        match self {
            Value::Array(items) => Some(items),
            _ => None,
        }
    }

    pub fn as_object(&self) -> Option<&[(Cow<'a, str>, Value<'a>)]> {
        match self {
            Value::Object(members) => Some(members),
            _ => None,
        }
    }
}

/// Why a document was rejected.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum JsonError {
    /// Input longer than [`super::MAX_INPUT_BYTES`].
    TooLarge,
    InvalidUtf8,
    /// Arrays/objects nested deeper than [`super::MAX_DEPTH`].
    TooDeep,
    /// Not valid JSON; `offset` is the byte position where parsing stopped.
    Syntax {
        offset: usize,
    },
}

impl fmt::Display for JsonError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            JsonError::TooLarge => f.write_str("JSON input too large"),
            JsonError::InvalidUtf8 => f.write_str("JSON input is not valid UTF-8"),
            JsonError::TooDeep => f.write_str("JSON nested too deeply"),
            JsonError::Syntax { offset } => write!(f, "invalid JSON at byte {offset}"),
        }
    }
}

impl std::error::Error for JsonError {}
