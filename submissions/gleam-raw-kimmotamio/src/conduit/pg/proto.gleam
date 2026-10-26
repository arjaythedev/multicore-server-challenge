//// PostgreSQL wire protocol 3.0: message encoders and decoders for the subset the server uses
//// (startup, SCRAM/md5/cleartext auth, Parse/Bind/Execute/Sync, DataRow in binary format, errors).

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

pub const oid_bool = 16

pub const oid_int8 = 20

pub const oid_int4 = 23

pub const oid_text = 25

pub const oid_text_array = 1009

/// A text-format parameter value (`None` is SQL NULL).
pub type Param =
  Option(BitArray)

/// One decoded DataRow: a column is `None` when NULL, else the binary-format bytes.
pub type Row =
  List(Option(BitArray))

// ---------------------------------------------------------------- encoding

fn with_len(tag: String, payload: BitArray) -> BitArray {
  let len = bit_array.byte_size(payload) + 4
  <<tag:utf8, len:size(32), payload:bits>>
}

fn cstr(s: String) -> BitArray {
  <<s:utf8, 0:size(8)>>
}

pub fn startup(user: String, database: String, options: String) -> BitArray {
  let body =
    bit_array.concat([
      <<196_608:size(32)>>,
      cstr("user"),
      cstr(user),
      cstr("database"),
      cstr(database),
      cstr("client_encoding"),
      cstr("UTF8"),
      cstr("options"),
      cstr(options),
      <<0:size(8)>>,
    ])
  let len = bit_array.byte_size(body) + 4
  <<len:size(32), body:bits>>
}

pub fn password_message(data: BitArray) -> BitArray {
  with_len("p", <<data:bits, 0:size(8)>>)
}

pub fn sasl_initial(mechanism: String, data: BitArray) -> BitArray {
  with_len(
    "p",
    <<cstr(mechanism):bits, bit_array.byte_size(data):size(32), data:bits>>,
  )
}

pub fn sasl_response(data: BitArray) -> BitArray {
  with_len("p", data)
}

pub fn parse(name: String, query: String, param_oids: List(Int)) -> BitArray {
  let oids =
    list.map(param_oids, fn(o) { <<o:size(32)>> }) |> bit_array.concat
  with_len(
    "P",
    <<
      cstr(name):bits,
      cstr(query):bits,
      list.length(param_oids):size(16),
      oids:bits,
    >>,
  )
}

/// Bind the unnamed portal to a named statement: text-format parameters, binary-format results.
pub fn bind(statement: String, params: List(Param)) -> BitArray {
  let values =
    list.map(params, fn(p) {
      case p {
        None -> <<-1:size(32)>>
        Some(v) -> <<bit_array.byte_size(v):size(32), v:bits>>
      }
    })
    |> bit_array.concat
  with_len(
    "B",
    <<
      0:size(8),
      cstr(statement):bits,
      0:size(16),
      list.length(params):size(16),
      values:bits,
      1:size(16),
      1:size(16),
    >>,
  )
}

pub const execute = <<"E":utf8, 9:size(32), 0:size(8), 0:size(32)>>

pub const sync = <<"S":utf8, 4:size(32)>>

pub const terminate = <<"X":utf8, 4:size(32)>>

/// Text-format `int8` parameter.
pub fn int_param(n: Int) -> Param {
  Some(<<int.to_string(n):utf8>>)
}

pub fn text_param(s: String) -> Param {
  Some(<<s:utf8>>)
}

pub fn opt_text_param(s: Option(String)) -> Param {
  case s {
    Some(v) -> Some(<<v:utf8>>)
    None -> None
  }
}

/// Text-format `text[]` literal: `{"a","b"}` with `"` and `\` escaped.
pub fn text_array_param(items: List(String)) -> Param {
  let elems =
    list.map(items, fn(s) { <<"\"":utf8, escape_array_elem(<<s:utf8>>, <<>>):bits, "\"":utf8>> })
    |> list.intersperse(<<",":utf8>>)
    |> bit_array.concat
  Some(<<"{":utf8, elems:bits, "}":utf8>>)
}

/// Text-format array literal from text-format parameter values: every element quoted, NULL for `None`.
pub fn array_literal(items: List(Param)) -> Param {
  let elems =
    list.map(items, fn(p) {
      case p {
        None -> <<"NULL":utf8>>
        Some(s) ->
          case has_quote_or_backslash(s) {
            False -> <<"\"":utf8, s:bits, "\"":utf8>>
            True -> <<"\"":utf8, escape_array_elem(s, <<>>):bits, "\"":utf8>>
          }
      }
    })
    |> list.intersperse(<<",":utf8>>)
    |> bit_array.concat
  Some(<<"{":utf8, elems:bits, "}":utf8>>)
}

@external(erlang, "conduit_ffi", "has_quote_or_backslash")
fn has_quote_or_backslash(s: BitArray) -> Bool

fn escape_array_elem(s: BitArray, acc: BitArray) -> BitArray {
  case s {
    <<>> -> acc
    <<"\"":utf8, rest:bytes>> -> escape_array_elem(rest, <<acc:bits, "\\\"":utf8>>)
    <<"\\":utf8, rest:bytes>> -> escape_array_elem(rest, <<acc:bits, "\\\\":utf8>>)
    <<c:size(8), rest:bytes>> -> escape_array_elem(rest, <<acc:bits, c:size(8)>>)
    _ -> acc
  }
}

// ---------------------------------------------------------------- decoding

/// Splits the next complete backend message off a buffer: `#(tag, payload, rest)`.
pub fn next_message(buf: BitArray) -> Result(#(Int, BitArray, BitArray), Nil) {
  case buf {
    <<tag:size(8), len:size(32), rest:bytes>> -> {
      let n = len - 4
      case rest {
        <<payload:bytes-size(n), rest2:bytes>> -> Ok(#(tag, payload, rest2))
        _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

/// Decodes a DataRow body into its columns (sub-binaries of the socket buffer; a NIF, see native/conduit_nif.c).
@external(erlang, "conduit_nif", "decode_row")
pub fn data_row(payload: BitArray) -> Row

/// The same decoding in Gleam: the reference the tests hold the NIF to.
pub fn data_row_gleam(payload: BitArray) -> Row {
  case payload {
    <<n:size(16), rest:bytes>> -> columns(rest, n, [])
    _ -> []
  }
}

fn columns(buf: BitArray, n: Int, acc: Row) -> Row {
  case n {
    0 -> list.reverse(acc)
    _ ->
      case buf {
        <<-1:signed-size(32), rest:bytes>> -> columns(rest, n - 1, [None, ..acc])
        <<len:size(32), v:bytes-size(len), rest:bytes>> ->
          columns(rest, n - 1, [Some(v), ..acc])
        _ -> list.reverse(acc)
      }
  }
}

/// The SQLSTATE of an ErrorResponse (field code `C`), plus the message (`M`).
pub fn error_fields(payload: BitArray) -> #(String, String) {
  error_loop(payload, "", "")
}

fn error_loop(buf: BitArray, code: String, msg: String) -> #(String, String) {
  case buf {
    <<0:size(8), _:bytes>> | <<>> -> #(code, msg)
    <<t:size(8), rest:bytes>> -> {
      let #(value, rest2) = take_cstr(rest, 0)
      case t {
        67 -> error_loop(rest2, value, msg)
        77 -> error_loop(rest2, code, value)
        _ -> error_loop(rest2, code, msg)
      }
    }
    _ -> #(code, msg)
  }
}

fn take_cstr(buf: BitArray, n: Int) -> #(String, BitArray) {
  case bit_array.slice(buf, n, 1) {
    Ok(<<0:size(8)>>) -> {
      let assert Ok(s) = bit_array.slice(buf, 0, n)
      let assert Ok(rest) = bit_array.slice(buf, n + 1, bit_array.byte_size(buf) - n - 1)
      #(bit_array.to_string(s) |> option_or(""), rest)
    }
    Ok(_) -> take_cstr(buf, n + 1)
    Error(_) -> #(bit_array.to_string(buf) |> option_or(""), <<>>)
  }
}

fn option_or(r: Result(a, b), default: a) -> a {
  case r {
    Ok(v) -> v
    Error(_) -> default
  }
}

// ---------------------------------------------------------------- binary column values

pub fn col_int(c: Option(BitArray)) -> Int {
  case c {
    Some(<<n:signed-size(64)>>) -> n
    Some(<<n:signed-size(32)>>) -> n
    Some(<<n:signed-size(16)>>) -> n
    _ -> 0
  }
}

pub fn col_bool(c: Option(BitArray)) -> Bool {
  case c {
    Some(<<1:size(8)>>) -> True
    _ -> False
  }
}

/// `timestamptz` in binary format: microseconds since 2000-01-01T00:00:00Z.
pub fn col_micros(c: Option(BitArray)) -> Int {
  case c {
    Some(<<n:signed-size(64)>>) -> n
    _ -> 0
  }
}

/// A text column; NULL becomes an empty string (callers that care use `col_opt_text`).
pub fn col_text(c: Option(BitArray)) -> BitArray {
  case c {
    Some(v) -> v
    None -> <<>>
  }
}

pub fn col_opt_text(c: Option(BitArray)) -> Option(BitArray) {
  c
}

/// A one-dimensional `text[]` in binary format (a NIF, see native/conduit_nif.c).
pub fn col_text_array(c: Option(BitArray)) -> List(BitArray) {
  case c {
    Some(bin) -> decode_text_array(bin)
    None -> []
  }
}

@external(erlang, "conduit_nif", "decode_text_array")
fn decode_text_array(bin: BitArray) -> List(BitArray)

/// The same decoding in Gleam: the reference the tests hold the NIF to.
pub fn col_text_array_gleam(c: Option(BitArray)) -> List(BitArray) {
  case c {
    Some(<<0:size(32), _:bytes>>) -> []
    Some(<<1:size(32), _flags:size(32), _oid:size(32), n:size(32), _lb:size(32), rest:bytes>>) ->
      array_elems(rest, n, [])
    _ -> []
  }
}

fn array_elems(buf: BitArray, n: Int, acc: List(BitArray)) -> List(BitArray) {
  case n {
    0 -> list.reverse(acc)
    _ ->
      case buf {
        <<-1:signed-size(32), rest:bytes>> -> array_elems(rest, n - 1, [<<>>, ..acc])
        <<len:size(32), v:bytes-size(len), rest:bytes>> -> array_elems(rest, n - 1, [v, ..acc])
        _ -> list.reverse(acc)
      }
  }
}
