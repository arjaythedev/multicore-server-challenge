//// Percent-decoding, query-string parsing, page validation and timestamp formatting.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub const max_i64 = 9_223_372_036_854_775_807

@external(erlang, "conduit_ffi", "has_nul")
pub fn has_nul(s: BitArray) -> Bool

@external(erlang, "conduit_ffi", "is_utf8")
pub fn is_utf8(s: BitArray) -> Bool

@external(erlang, "gleam_stdlib", "identity")
pub fn unsafe_to_string(s: BitArray) -> String

@external(erlang, "gleam_stdlib", "identity")
pub fn to_bits(s: String) -> BitArray

/// Non-empty ASCII digits that fit in an i64 (no sign, no whitespace).
pub fn parse_digits(s: String) -> Result(Int, Nil) {
  let bits = to_bits(s)
  case bit_array.byte_size(bits) {
    0 -> Error(Nil)
    n if n > 19 -> Error(Nil)
    _ ->
      case all_digits(bits) {
        False -> Error(Nil)
        True ->
          case int.parse(s) {
            Ok(v) if v <= max_i64 -> Ok(v)
            _ -> Error(Nil)
          }
      }
  }
}

fn all_digits(b: BitArray) -> Bool {
  case b {
    <<>> -> True
    <<c:size(8), rest:bytes>> if c >= 48 && c <= 57 -> all_digits(rest)
    _ -> False
  }
}

/// Percent-decoding that keeps malformed escapes literally; `plus` turns `+` into a space (query strings).
/// Most segments have nothing to decode: one `binary:match` says so without a pass in Gleam.
pub fn pct_decode(s: BitArray, plus: Bool) -> BitArray {
  case needs_decoding(s, plus) {
    False -> s
    True -> do_decode(s, plus, <<>>)
  }
}

@external(erlang, "conduit_ffi", "needs_decoding")
fn needs_decoding(s: BitArray, plus: Bool) -> Bool

fn do_decode(s: BitArray, plus: Bool, acc: BitArray) -> BitArray {
  case s {
    <<>> -> acc
    <<"%":utf8, h:size(8), l:size(8), rest:bytes>> ->
      case hex(h), hex(l) {
        Ok(a), Ok(b) -> do_decode(rest, plus, <<acc:bits, { a * 16 + b }:size(8)>>)
        _, _ -> do_decode(<<h:size(8), l:size(8), rest:bits>>, plus, <<acc:bits, "%":utf8>>)
      }
    <<"+":utf8, rest:bytes>> if plus -> do_decode(rest, plus, <<acc:bits, " ":utf8>>)
    <<c:size(8), rest:bytes>> -> do_decode(rest, plus, <<acc:bits, c:size(8)>>)
    _ -> acc
  }
}

fn hex(c: Int) -> Result(Int, Nil) {
  case c {
    _ if c >= 48 && c <= 57 -> Ok(c - 48)
    _ if c >= 97 && c <= 102 -> Ok(c - 87)
    _ if c >= 65 && c <= 70 -> Ok(c - 55)
    _ -> Error(Nil)
  }
}

/// Percent-decodes one path segment: valid UTF-8, no embedded NUL (Postgres can't store it), non-empty.
pub fn decode_segment(seg: String) -> Result(String, Nil) {
  let decoded = pct_decode(to_bits(seg), False)
  case bit_array.byte_size(decoded) > 0 && is_utf8(decoded) && !has_nul(decoded) {
    True -> Ok(unsafe_to_string(decoded))
    False -> Error(Nil)
  }
}

pub type Query {
  Query(
    limit: Option(String),
    offset: Option(String),
    tag: Option(String),
    author: Option(String),
    favorited: Option(String),
  )
}

/// The query parameters we care about. The first occurrence of each wins; empty filters count as absent.
/// Values with invalid UTF-8 become U+FFFD so they simply match nothing.
pub fn parse_query(q: String) -> Query {
  case q {
    "" -> Query(None, None, None, None, None)
    _ -> list.fold(string.split(q, "&"), Query(None, None, None, None, None), query_pair)
  }
}

fn query_pair(acc: Query, pair: String) -> Query {
  let #(k, v) = case string.split_once(pair, "=") {
    Ok(#(k, v)) -> #(k, v)
    Error(_) -> #(pair, "")
  }
  let key = pct_decode(to_bits(k), True)
  case key {
    <<"limit":utf8>> -> Query(..acc, limit: first(acc.limit, value(v)))
    <<"offset":utf8>> -> Query(..acc, offset: first(acc.offset, value(v)))
    <<"tag":utf8>> if v != "" -> Query(..acc, tag: first(acc.tag, value(v)))
    <<"author":utf8>> if v != "" -> Query(..acc, author: first(acc.author, value(v)))
    <<"favorited":utf8>> if v != "" -> Query(..acc, favorited: first(acc.favorited, value(v)))
    _ -> acc
  }
}

fn first(existing: Option(String), new: String) -> Option(String) {
  case existing {
    Some(_) -> existing
    None -> Some(new)
  }
}

fn value(v: String) -> String {
  let decoded = pct_decode(to_bits(v), True)
  case is_utf8(decoded) {
    True -> unsafe_to_string(decoded)
    False -> "\u{FFFD}"
  }
}

/// `#(limit, offset)` from the parameters (defaults 20 and 0), or an error for a 422.
pub fn page(q: Query) -> Result(#(Int, Int), Nil) {
  case bounded(q.limit, 20, 1, 100), bounded(q.offset, 0, 0, max_i64) {
    Ok(limit), Ok(offset) -> Ok(#(limit, offset))
    _, _ -> Error(Nil)
  }
}

fn bounded(v: Option(String), default: Int, min: Int, max: Int) -> Result(Int, Nil) {
  case v {
    None -> Ok(default)
    Some(s) ->
      case parse_digits(s) {
        Ok(n) if n >= min && n <= max -> Ok(n)
        _ -> Error(Nil)
      }
  }
}

// ---------------------------------------------------------------- timestamps

const pg_epoch_unix = 946_684_800

fn fdiv(a: Int, b: Int) -> Int {
  let q = a / b
  case a % b < 0 {
    True -> q - 1
    False -> q
  }
}

/// RFC 3339 in UTC with exactly 3 fractional digits (truncated), from Postgres microseconds since 2000-01-01.
/// Built with integer arithmetic straight into a binary: no string padding, no formatting calls.
pub fn rfc3339(micros: Int) -> String {
  let secs = fdiv(micros, 1_000_000)
  let ms = fdiv(micros - secs * 1_000_000, 1000)
  let unix = secs + pg_epoch_unix
  let days = fdiv(unix, 86_400)
  let sod = unix - days * 86_400
  let hh = sod / 3600
  let mm = { sod % 3600 } / 60
  let ss = sod % 60
  // Howard Hinnant's civil_from_days.
  let z = days + 719_468
  let era = fdiv(z, 146_097)
  let doe = z - era * 146_097
  let yoe = { doe - doe / 1460 + doe / 36_524 - doe / 146_096 } / 365
  let y = yoe + era * 400
  let doy = doe - { 365 * yoe + yoe / 4 - yoe / 100 }
  let mp = { 5 * doy + 2 } / 153
  let d = doy - { 153 * mp + 2 } / 5 + 1
  let m = case mp < 10 {
    True -> mp + 3
    False -> mp - 9
  }
  let y = case m <= 2 {
    True -> y + 1
    False -> y
  }
  unsafe_to_string(<<
    { 48 + y / 1000 }:size(8),
    { 48 + { y / 100 } % 10 }:size(8),
    { 48 + { y / 10 } % 10 }:size(8),
    { 48 + y % 10 }:size(8),
    "-":utf8,
    { 48 + m / 10 }:size(8),
    { 48 + m % 10 }:size(8),
    "-":utf8,
    { 48 + d / 10 }:size(8),
    { 48 + d % 10 }:size(8),
    "T":utf8,
    { 48 + hh / 10 }:size(8),
    { 48 + hh % 10 }:size(8),
    ":":utf8,
    { 48 + mm / 10 }:size(8),
    { 48 + mm % 10 }:size(8),
    ":":utf8,
    { 48 + ss / 10 }:size(8),
    { 48 + ss % 10 }:size(8),
    ".":utf8,
    { 48 + ms / 100 }:size(8),
    { 48 + { ms / 10 } % 10 }:size(8),
    { 48 + ms % 10 }:size(8),
    "Z":utf8,
  >>)
}
