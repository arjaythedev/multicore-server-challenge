//! Streaming JSON writer over a `Vec<u8>`. Compact output, commas inserted automatically.

use super::{escape, itoa, time};

/// Deepest nesting the comma bitset can track (one bit per level of a `u64`).
const MAX_NESTING: u32 = 63;

/// Appends JSON to a caller-owned buffer. Call order is the caller's responsibility (a `key` before every
/// value inside an object, balanced `begin`/`end`); misuse produces invalid JSON, not undefined behaviour,
/// and trips `debug_assert`s in tests.
///
/// Comma state is one bit per nesting level in `has_item` (bit `d` set: the container at depth `d` already has
/// an element), so there is no allocation and no per-level stack.
pub struct JsonWriter<'a> {
    out: &'a mut Vec<u8>,
    depth: u32,
    has_item: u64,
    /// A key was just written, so the next value follows a `:` and needs no comma.
    after_key: bool,
}

impl<'a> JsonWriter<'a> {
    pub fn new(out: &'a mut Vec<u8>) -> Self {
        JsonWriter {
            out,
            depth: 0,
            has_item: 0,
            after_key: false,
        }
    }

    pub fn begin_object(&mut self) {
        self.open(b'{');
    }

    pub fn end_object(&mut self) {
        self.close(b'}');
    }

    pub fn begin_array(&mut self) {
        self.open(b'[');
    }

    pub fn end_array(&mut self) {
        self.close(b']');
    }

    /// Write `"key":`. `key` is a trusted literal and is not escaped.
    pub fn key(&mut self, key: &'static str) {
        debug_assert!(
            key.bytes().all(|b| b >= 0x20 && b != b'"' && b != b'\\'),
            "key needs escaping: {key:?}"
        );
        debug_assert!(!self.after_key, "two keys in a row");
        self.separator();
        self.out.reserve(key.len() + 3);
        self.out.push(b'"');
        self.out.extend_from_slice(key.as_bytes());
        self.out.extend_from_slice(b"\":");
        self.after_key = true;
    }

    pub fn string(&mut self, s: &str) {
        self.string_bytes(s.as_bytes());
    }

    /// A string whose bytes are already known to be valid UTF-8 (text columns from Postgres).
    pub fn string_bytes(&mut self, s: &[u8]) {
        self.value_start();
        self.out.push(b'"');
        escape::write_escaped(self.out, s);
        self.out.push(b'"');
    }

    pub fn int(&mut self, n: i64) {
        self.value_start();
        itoa::write_i64(self.out, n);
    }

    pub fn bool(&mut self, b: bool) {
        self.value_start();
        self.out
            .extend_from_slice(if b { b"true" } else { b"false" });
    }

    pub fn null(&mut self) {
        self.value_start();
        self.out.extend_from_slice(b"null");
    }

    /// Insert pre-rendered JSON (one complete value) as is.
    pub fn raw(&mut self, json: &[u8]) {
        self.value_start();
        self.out.extend_from_slice(json);
    }

    /// A Postgres `timestamp` (microseconds since 2000-01-01) as `"YYYY-MM-DDTHH:MM:SS.mmmZ"`, truncated to
    /// milliseconds. See [`time::write_timestamp_micros`] for the supported range.
    pub fn timestamp_micros(&mut self, micros_since_2000: i64) {
        self.value_start();
        self.out.push(b'"');
        time::write_timestamp_micros(self.out, micros_since_2000);
        self.out.push(b'"');
    }

    fn open(&mut self, bracket: u8) {
        self.value_start();
        self.out.push(bracket);
        debug_assert!(
            self.depth < MAX_NESTING,
            "nesting too deep for the comma bitset"
        );
        self.depth += 1;
        self.has_item &= !(1u64 << (self.depth & MAX_NESTING)); // new container starts empty
    }

    fn close(&mut self, bracket: u8) {
        debug_assert!(self.depth > 0, "unbalanced end");
        self.depth = self.depth.saturating_sub(1);
        self.out.push(bracket);
    }

    /// Everything that precedes a value: nothing after a key, otherwise the comma for the container.
    fn value_start(&mut self) {
        if self.after_key {
            self.after_key = false;
        } else {
            self.separator();
        }
    }

    /// Write a comma if the current container already has an element, and mark it as non-empty.
    fn separator(&mut self) {
        let bit = 1u64 << (self.depth & MAX_NESTING);
        if self.has_item & bit != 0 {
            self.out.push(b',');
        }
        self.has_item |= bit;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn build(f: impl FnOnce(&mut JsonWriter)) -> String {
        let mut out = Vec::new();
        f(&mut JsonWriter::new(&mut out));
        String::from_utf8(out).unwrap()
    }

    #[test]
    fn nested_document_with_commas() {
        let json = build(|w| {
            w.begin_object();
            w.key("a");
            w.int(1);
            w.key("b");
            w.begin_array();
            w.int(-2);
            w.begin_object();
            w.end_object();
            w.begin_array();
            w.end_array();
            w.string("x");
            w.end_array();
            w.key("c");
            w.begin_object();
            w.key("d");
            w.null();
            w.key("e");
            w.bool(true);
            w.key("f");
            w.bool(false);
            w.end_object();
            w.end_object();
        });
        assert_eq!(
            json,
            r#"{"a":1,"b":[-2,{},[],"x"],"c":{"d":null,"e":true,"f":false}}"#
        );
    }

    #[test]
    fn empty_containers_do_not_leak_comma_state() {
        let json = build(|w| {
            w.begin_array();
            w.begin_array();
            w.int(1);
            w.end_array();
            w.begin_array();
            w.int(2);
            w.end_array();
            w.end_array();
        });
        assert_eq!(json, "[[1],[2]]");
    }

    #[test]
    fn raw_and_timestamp_values() {
        let json = build(|w| {
            w.begin_object();
            w.key("r");
            w.raw(br#"{"pre":[1,2]}"#);
            w.key("t");
            w.timestamp_micros(0);
            w.key("s");
            w.string_bytes("åäö\n".as_bytes());
            w.end_object();
        });
        assert_eq!(
            json,
            r#"{"r":{"pre":[1,2]},"t":"2000-01-01T00:00:00.000Z","s":"åäö\n"}"#
        );
    }

    #[test]
    fn deepest_supported_nesting() {
        let json = build(|w| {
            for _ in 0..62 {
                w.begin_array();
            }
            w.int(1);
            w.int(2);
            for _ in 0..62 {
                w.end_array();
            }
        });
        assert_eq!(json, format!("{}1,2{}", "[".repeat(62), "]".repeat(62)));
    }

    #[test]
    fn output_parses_back() {
        let json = build(|w| {
            w.begin_object();
            w.key("msg");
            w.string("quote \" backslash \\ tab \t nul \0 ö");
            w.key("n");
            w.int(i64::MIN);
            w.end_object();
        });
        let v = crate::json::parse(json.as_bytes()).unwrap();
        assert_eq!(
            v.get("msg").and_then(|m| m.as_str()),
            Some("quote \" backslash \\ tab \t nul \0 ö")
        );
    }
}
