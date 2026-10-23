//// JSON output written straight into iodata (a StringTree): no intermediate maps, and a string takes a
//// `binary:match` fast path when nothing in it needs escaping.

import conduit/util
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string_tree.{type StringTree}

/// A JSON string literal, escaped (an iodata-building Erlang helper: the hot path of every response).
@external(erlang, "conduit_ffi", "json_string")
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

pub fn ts(micros: Int) -> StringTree {
  string_tree.from_strings(["\"", util.rfc3339(micros), "\""])
}

pub fn str_array(items: List(BitArray)) -> StringTree {
  list.map(items, str)
  |> list.intersperse(string_tree.from_string(","))
  |> string_tree.concat
  |> string_tree.prepend("[")
  |> string_tree.append("]")
}

pub fn error(msg: String) -> StringTree {
  string_tree.from_strings(["{\"errors\":{\"body\":[\"", msg, "\"]}}"])
}

