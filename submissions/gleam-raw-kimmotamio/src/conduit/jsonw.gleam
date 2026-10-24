//// JSON output written straight into iodata (a StringTree): no intermediate maps. String escaping, string
//// arrays and timestamp formatting are C helpers in native/conduit_nif.c.

import conduit/util
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string_tree.{type StringTree}

/// A JSON string literal, escaped: `[$", s, $"]` around the original binary when nothing needs escaping.
@external(erlang, "conduit_nif", "json_string")
pub fn str(s: BitArray) -> StringTree

pub fn str_s(s: String) -> StringTree {
  str(util.to_bits(s))
}

pub fn opt_str(s: Option(BitArray)) -> StringTree {
  case s {
    Some(v) -> str(v)
    None -> string_tree.from_string("null")
  }
}

pub fn int(n: Int) -> StringTree {
  string_tree.from_string(int.to_string(n))
}

pub fn bool(b: Bool) -> StringTree {
  case b {
    True -> string_tree.from_string("true")
    False -> string_tree.from_string("false")
  }
}

/// A Postgres binary `timestamptz` (microseconds since 2000-01-01) as a quoted RFC 3339 string, milliseconds.
@external(erlang, "conduit_nif", "json_rfc3339")
pub fn ts(micros: Int) -> StringTree

/// A JSON array of strings as one binary (a NIF): the 200-name tags list is one term, not 600.
@external(erlang, "conduit_nif", "json_string_array")
pub fn str_array(items: List(BitArray)) -> StringTree

/// The same in Gleam, the tests' reference.
pub fn str_array_gleam(items: List(BitArray)) -> StringTree {
  list.map(items, str)
  |> list.intersperse(string_tree.from_string(","))
  |> string_tree.concat
  |> string_tree.prepend("[")
  |> string_tree.append("]")
}

pub fn error(msg: String) -> StringTree {
  string_tree.from_strings(["{\"errors\":{\"body\":[\"", msg, "\"]}}"])
}

