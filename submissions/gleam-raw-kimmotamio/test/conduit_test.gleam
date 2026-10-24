import conduit/bcrypt
import conduit/jsonw
import conduit/jwt
import conduit/pg/proto
import conduit/util
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/string_tree
import gleeunit

pub fn main() {
  gleeunit.main()
}

pub fn rfc3339_test() {
  assert util.rfc3339(0) == "2000-01-01T00:00:00.000Z"
  assert util.rfc3339(-1) == "1999-12-31T23:59:59.999Z"
  // 2024-02-29T12:34:56.789999Z truncates, not rounds.
  assert util.rfc3339(762_525_296_789_999) == "2024-02-29T12:34:56.789Z"
  assert util.rfc3339(951_782_400_000_000) == "2030-02-28T00:00:00.000Z"
}

@external(erlang, "conduit_nif", "rfc3339")
fn nif_rfc3339(micros: Int) -> String

// The C formatter agrees with the Gleam one on ordinary, negative, leap-day and far-future values.
pub fn rfc3339_nif_test() {
  list.each(
    [
      0, -1, 1, 999, 1000, -1000, 762_525_296_789_999, 951_782_400_000_000, -946_684_800_000_000,
      -946_684_800_000_001, 1_000_000_000_000_000, 1_234_567_891_234_567, 4_102_444_800_000_000, 86_399_999_999,
      86_400_000_000, -86_400_000_000, 252_460_800_000_000, 2_000_000_000_000_000,
    ],
    fn(m) { assert nif_rfc3339(m) == util.rfc3339(m) },
  )
  assert string_tree.to_string(jsonw.ts(0)) == "\"2000-01-01T00:00:00.000Z\""
}

// The C array writer agrees with the Gleam one, escapes included.
pub fn json_string_array_test() {
  let cases = [
    [],
    [<<>>],
    [<<"a":utf8>>],
    [<<"a":utf8>>, <<"b":utf8>>],
    [<<"q\"q":utf8>>, <<"back\\slash":utf8>>, <<"nl\n":utf8>>, <<0, 1, 31>>, <<"\u{e9}":utf8>>, <<"tab\t\r\u{8}\u{c}":utf8>>],
    list.repeat(<<"tag-name":utf8>>, 200),
  ]
  list.each(cases, fn(items) {
    assert string_tree.to_string(jsonw.str_array(items)) == string_tree.to_string(jsonw.str_array_gleam(items))
  })
  assert string_tree.to_string(jsonw.str_array([<<"a":utf8>>, <<"b\"":utf8>>])) == "[\"a\",\"b\\\"\"]"
}

pub fn json_string_test() {
  assert string_tree.to_string(jsonw.str(<<"plain":utf8>>)) == "\"plain\""
  assert string_tree.to_string(jsonw.str(<<>>)) == "\"\""
  assert string_tree.to_string(jsonw.str(<<"\"":utf8>>)) == "\"\\\"\""
  assert string_tree.to_string(jsonw.str(<<"tab\tend":utf8>>)) == "\"tab\\tend\""
  assert string_tree.to_string(jsonw.str(<<0, 31, 32, 127, 8, 12, 13>>)) == "\"\\u0000\\u001f \u{7f}\\b\\f\\r\""
  let long = string.repeat("x", 5000) <> "\\" <> string.repeat("y", 5000)
  assert string_tree.to_string(jsonw.str(util.to_bits(long))) == "\"" <> string.repeat("x", 5000) <> "\\\\" <> string.repeat("y", 5000) <> "\""
  assert string_tree.to_string(jsonw.str(<<"a\"b\\c\nd\te":utf8, 1, "f":utf8>>)) == "\"a\\\"b\\\\c\\nd\\te\\u0001f\""
  assert string_tree.to_string(jsonw.str(<<"ünï":utf8>>)) == "\"ünï\""
  assert string_tree.to_string(jsonw.opt_str(None)) == "null"
  assert string_tree.to_string(jsonw.str_array([<<"a":utf8>>, <<"b":utf8>>])) == "[\"a\",\"b\"]"
}

pub fn jwt_round_trip_test() {
  let secret = <<"multicore-server-challenge":utf8>>
  let token = jwt.issue(secret, 150, 1_700_000_000)
  assert jwt.check("Token " <> token, secret, 1_700_000_001) == jwt.User(150, token)
  assert jwt.check("Token " <> token, secret, 1_700_000_000 + 2_592_000) == jwt.Invalid
  assert jwt.check("Token " <> token, <<"other":utf8>>, 1_700_000_001) == jwt.Invalid
  assert jwt.check("Bearer " <> token, secret, 1_700_000_001) == jwt.Invalid
  assert jwt.check("", secret, 1_700_000_001) == jwt.Anonymous
  assert jwt.check("Token not.a.jwt", secret, 1_700_000_001) == jwt.Invalid
  // A tampered signature, a tampered payload, an extra segment.
  let n = string.length(token)
  let flipped = case string.slice(token, n - 1, 1) {
    "A" -> "B"
    _ -> "A"
  }
  assert jwt.check("Token " <> string.slice(token, 0, n - 1) <> flipped, secret, 1_700_000_001) == jwt.Invalid
  assert jwt.check("Token " <> string.replace(token, "eyJzdWIiOiIxNTAi", "eyJzdWIiOiIxNTEi"), secret, 1_700_000_001) == jwt.Invalid
  assert jwt.check("Token " <> token <> ".x", secret, 1_700_000_001) == jwt.Invalid
  assert jwt.check("Token " <> token, secret, 1_700_000_001) == jwt.User(150, token)
  // Another header spelling and a padded signature take the general path and are accepted too.
  let header = bit_array.base64_url_encode(<<"{\"typ\":\"JWT\",\"alg\":\"HS256\"}":utf8>>, False)
  let payload = bit_array.base64_url_encode(<<"{\"sub\":\"7\",\"iat\":1700000000,\"exp\":1700000600,\"nbf\":1700000000}":utf8>>, False)
  let signing = header <> "." <> payload
  let sig = bit_array.base64_url_encode(hmac_sha256(secret, util.to_bits(signing)), True)
  let other = signing <> "." <> sig
  assert jwt.check("Token " <> other, secret, 1_700_000_001) == jwt.User(7, other)
  assert jwt.check("Token " <> other, secret, 1_700_000_600) == jwt.Invalid
  let hs512_header = bit_array.base64_url_encode(<<"{\"typ\":\"JWT\",\"alg\":\"HS512\"}":utf8>>, False)
  let signing2 = hs512_header <> "." <> payload
  let bad = signing2 <> "." <> bit_array.base64_url_encode(hmac_sha256(secret, util.to_bits(signing2)), False)
  assert jwt.check("Token " <> bad, secret, 1_700_000_001) == jwt.Invalid
}

@external(erlang, "conduit_ffi", "hmac_sha256")
fn hmac_sha256(key: BitArray, data: BitArray) -> BitArray

type Ref {
  RefRequest(method: String, target: String, auth: String, body: BitArray, rest: BitArray, close: Bool)
  RefMore
  RefBad
}

@external(erlang, "conduit_ffi", "parse_request_ref")
fn parse_request_ref(buf: BitArray) -> Ref

@external(erlang, "conduit_ffi", "split_segments")
fn split_segments(path: String) -> List(String)

@external(erlang, "conduit_ffi", "split_target")
fn split_target(target: String) -> #(String, String)

// The C request parser agrees with the decode_packet one on every request shape below (well-formed, pipelined,
// partial, LF-only, odd spacing, odd case) and on what is refused; obs-fold continuation lines are the one
// documented difference (the reference joins them, the NIF refuses them).
pub fn parse_request_nif_test() {
  let inputs = [
    "GET /api/tags HTTP/1.1\r\nHost: x\r\n\r\n",
    "GET /api/articles?limit=5&offset=10 HTTP/1.1\r\nHost: x\r\nAuthorization: Token abc.def.ghi\r\n\r\n",
    "GET /api/articles/a-slug/comments HTTP/1.1\r\nauthorization:   Token t   \r\nConnection: Close\r\n\r\n",
    "POST /api/users/login HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"user\":{}}  GET /x HTTP/1.1\r\n\r\n",
    "POST /api/users/login HTTP/1.1\r\nContent-Length: 13\r\n\r\n{\"user\":{}}",
    "POST /api/users/login HTTP/1.1\r\nContent-Length: 13\r\n\r\n{\"user\"",
    "POST /api/x HTTP/1.1\r\nContent-Length: +3\r\n\r\nabc",
    "POST /api/x HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\nabc",
    "POST /api/x HTTP/1.1\r\nContent-Length: x\r\n\r\nabc",
    "POST /api/x HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n",
    "POST /api/x HTTP/1.1\r\nContent-Length: 1048576\r\n\r\n",
    "POST /api/x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
    "GET /x HTTP/1.1\n\n",
    "GET /x HTTP/1.1\nX-A: b\n\r\n",
    "GET  /x  HTTP/1.1 \r\n\r\n",
    "GET /x HTTP/2.0\r\n\r\n",
    "GET /x HTTP/1\r\n\r\n",
    "GET /x\r\n\r\n",
    "GET * HTTP/1.1\r\n\r\n",
    "GET http://h/x HTTP/1.1\r\n\r\n",
    "GET /a\tb HTTP/1.1\r\n\r\n",
    "GET /a%ff HTTP/1.1\r\n\r\n",
    "GET /\u{e9}/ HTTP/1.1\r\n\r\n",
    "GET /api/profiles/%C3%A9?x=1?y=2 HTTP/1.1\r\nX-A:\r\n\r\n",
    "GET /api/articles/ HTTP/1.1\r\n\r\n",
    "\r\nGET /x HTTP/1.1\r\n\r\n",
    "GET /x HTTP/1.1\r\nNo-Colon\r\n\r\n",
    "GET /x HTTP/1.1\r\n: v\r\n\r\n",
    "GET /x HTTP/1.1\r\nX Y: v\r\n\r\n",
    "GET /x HTTP/1.1\r\nHost: x\r\n",
    "GET /x HTTP/1.1\r\nHos",
    "GE",
    "",
    "get /x HTTP/1.1\r\n\r\n",
    "OPTIONS /x HTTP/1.0\r\nConnection: keep-alive\r\n\r\n",
  ]
  list.each(inputs, fn(text) {
    let bits = util.to_bits(text)
    let nif = parse_request_nif(bits)
    let want = case parse_request_ref(bits) {
      RefRequest(method, target, auth, body, rest, close) -> {
        let #(path, query) = split_target(target)
        Request(method, split_segments(path), query, auth, body, rest, close)
      }
      RefMore -> More
      RefBad -> Bad
    }
    assert nif == want
  })
  // Raw bytes that are not UTF-8 in the target are refused by both.
  assert parse_request_nif(<<"GET /a":utf8, 0xff, " HTTP/1.1\r\n\r\n":utf8>>) == Bad
  assert parse_request_nif(<<"GET /a":utf8, 0xc3, 0xa9, " HTTP/1.1\r\n\r\n":utf8>>) == Request("GET", ["", "a\u{e9}"], "", "", <<>>, <<>>, False)
  // A head that never ends is refused once it passes 16 KB, not before.
  assert parse_request_nif(util.to_bits("GET /x HTTP/1.1\r\nX: " <> string.repeat("a", 16_000))) == More
  assert parse_request_nif(util.to_bits("GET /x HTTP/1.1\r\nX: " <> string.repeat("a", 16_400))) == Bad
}

type Parsed {
  Request(method: String, segments: List(String), query: String, auth: String, body: BitArray, rest: BitArray, close: Bool)
  More
  Bad
}

@external(erlang, "conduit_nif", "parse_request")
fn parse_request_nif(buf: BitArray) -> Parsed

@external(erlang, "conduit_nif", "hmac_sha256")
fn nif_hmac_sha256(key: BitArray, data: BitArray) -> BitArray

@external(erlang, "conduit_nif", "jwt_verify")
fn nif_jwt_verify(token: BitArray, secret: BitArray, now: Int) -> jwt.Fast

@external(erlang, "crypto", "strong_rand_bytes")
fn random_bytes(n: Int) -> BitArray

@external(erlang, "rand", "uniform")
fn random_int(n: Int) -> Int

// The C HMAC-SHA256 agrees with OTP's crypto on keys shorter and longer than a block and on every message length
// around the block boundaries.
pub fn hmac_nif_test() {
  list.each(list.repeat(Nil, 300), fn(_) {
    let key = random_bytes(random_int(130) - 1)
    let data = random_bytes(random_int(400) - 1)
    assert nif_hmac_sha256(key, data) == hmac_sha256(key, data)
  })
  list.index_map(list.repeat(Nil, 141), fn(_, n) {
    let key = random_bytes(n)
    let data = random_bytes(n)
    assert nif_hmac_sha256(key, data) == hmac_sha256(key, data)
  })
}

// What the C fast path takes and what it leaves to the general path, and that both agree.
pub fn jwt_fast_path_test() {
  let secret = <<"multicore-server-challenge":utf8>>
  let token = jwt.issue(secret, 150, 1_700_000_000)
  assert nif_jwt_verify(util.to_bits(token), secret, 1_700_000_001) == jwt.Fast(150)
  assert nif_jwt_verify(util.to_bits(token), secret, 1_700_000_000 + 2_592_000) == jwt.Rejected
  assert nif_jwt_verify(util.to_bits(token), <<"other":utf8>>, 1_700_000_001) == jwt.Rejected
  assert nif_jwt_verify(<<"not.a.jwt":utf8>>, secret, 1) == jwt.General
  assert nif_jwt_verify(util.to_bits(token <> ".x"), secret, 1) == jwt.General
  let signed = fn(claims: String) -> String {
    let signing = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9." <> bit_array.base64_url_encode(util.to_bits(claims), False)
    signing <> "." <> bit_array.base64_url_encode(hmac_sha256(secret, util.to_bits(signing)), False)
  }
  // Other claim shapes are the general path's, and it accepts or rejects them the same way.
  let numeric = signed("{\"sub\":\"7\",\"exp\":1700000600}")
  assert nif_jwt_verify(util.to_bits(numeric), secret, 1_700_000_001) == jwt.General
  assert jwt.verify(numeric, secret, 1_700_000_001) == Ok(7)
  let nbf = signed("{\"sub\":\"7\",\"iat\":1700000000,\"exp\":1700000600,\"nbf\":1700000100}")
  assert nif_jwt_verify(util.to_bits(nbf), secret, 1_700_000_001) == jwt.General
  assert jwt.verify(nbf, secret, 1_700_000_001) == Error(Nil)
  assert jwt.verify(nbf, secret, 1_700_000_101) == Ok(7)
  let zero = signed("{\"sub\":\"0\",\"iat\":1700000000,\"exp\":1700000600}")
  assert nif_jwt_verify(util.to_bits(zero), secret, 1_700_000_001) == jwt.General
  assert jwt.verify(zero, secret, 1_700_000_001) == Error(Nil)
  let big = signed("{\"sub\":\"123456789012345678\",\"iat\":1700000000,\"exp\":1700000600}")
  assert nif_jwt_verify(util.to_bits(big), secret, 1_700_000_001) == jwt.Fast(123_456_789_012_345_678)
  let huge = signed("{\"sub\":\"1234567890123456789\",\"iat\":1700000000,\"exp\":1700000600}")
  assert nif_jwt_verify(util.to_bits(huge), secret, 1_700_000_001) == jwt.General
  assert jwt.verify(huge, secret, 1_700_000_001) == Ok(1_234_567_890_123_456_789)
  // A signed payload that is not base64url is rejected by both.
  let signing = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.!!!!"
  let junk = signing <> "." <> bit_array.base64_url_encode(hmac_sha256(secret, util.to_bits(signing)), False)
  assert nif_jwt_verify(util.to_bits(junk), secret, 1) == jwt.Rejected
  assert jwt.verify(junk, secret, 1) == Error(Nil)
  // Random tokens never verify, and the fast path never claims one the general path would reject.
  list.each(list.repeat(Nil, 200), fn(_) {
    let t = bit_array.base64_url_encode(random_bytes(random_int(120)), False)
    let t = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9." <> t <> "." <> bit_array.base64_url_encode(random_bytes(32), False)
    assert nif_jwt_verify(util.to_bits(t), secret, 1) != jwt.Fast(1)
    assert jwt.verify(t, secret, 1) == Error(Nil)
  })
}

pub fn page_test() {
  assert util.page(util.parse_query("")) == Ok(#(20, 0))
  assert util.page(util.parse_query("limit=05&offset=005")) == Ok(#(5, 5))
  assert util.page(util.parse_query("limit=0")) == Error(Nil)
  assert util.page(util.parse_query("limit=101")) == Error(Nil)
  assert util.page(util.parse_query("limit=%2B5")) == Error(Nil)
  assert util.page(util.parse_query("offset=99999999999999999999")) == Error(Nil)
  assert util.page(util.parse_query("offset=100000000")) == Ok(#(20, 100_000_000))
  let q = util.parse_query("tag=&author=bob&tag=x&favorited=a%20b")
  assert q.tag == Some("x")
  assert q.author == Some("bob")
  assert q.favorited == Some("a b")
}

pub fn pct_decode_test() {
  assert util.pct_decode(<<"a%20b%zz+c":utf8>>, True) == <<"a b%zz c":utf8>>
  assert util.pct_decode(<<"a+b":utf8>>, False) == <<"a+b":utf8>>
  assert util.decode_segment("caf%C3%A9") == Ok("café")
  assert util.decode_segment("%00") == Error(Nil)
  assert util.decode_segment("") == Error(Nil)
}

// The C decoders agree with the Gleam ones, including on NULLs, empty values, truncation and empty arrays.
pub fn decode_nif_test() {
  let rows = [
    <<2:size(16), 8:size(32), 42:size(64), -1:size(32)>>,
    <<0:size(16)>>,
    <<3:size(16), 0:size(32), -1:size(32), 5:size(32), "hello":utf8>>,
    <<1:size(16), 3:size(32), "ab":utf8>>,
    <<2:size(16), 1:size(32), "a":utf8>>,
    <<>>,
    <<7>>,
  ]
  list.each(rows, fn(r) { assert proto.data_row(r) == proto.data_row_gleam(r) })
  let big = list.repeat(<<300:size(32), 0:size(2400)>>, 14) |> bit_array.concat
  let row = <<14:size(16), big:bits>>
  assert proto.data_row(row) == proto.data_row_gleam(row)
  assert list.length(proto.data_row(row)) == 14
  let arrays = [
    Some(<<1:size(32), 0:size(32), 25:size(32), 2:size(32), 1:size(32), 1:size(32), "a":utf8, 2:size(32), "bc":utf8>>),
    Some(<<1:size(32), 1:size(32), 25:size(32), 3:size(32), 1:size(32), -1:size(32), 0:size(32), 1:size(32), "x":utf8>>),
    Some(<<0:size(32), 0:size(32), 25:size(32)>>),
    Some(<<1:size(32), 0:size(32), 25:size(32), 2:size(32), 1:size(32), 1:size(32), "a":utf8, 9:size(32), "short":utf8>>),
    Some(<<>>),
    None,
  ]
  list.each(arrays, fn(a) { assert proto.col_text_array(a) == proto.col_text_array_gleam(a) })
}

pub fn proto_test() {
  let row = <<2:size(16), 8:size(32), 42:size(64), -1:size(32)>>
  let message = <<"D":utf8, { bit_array.byte_size(row) + 4 }:size(32), row:bits, "Z":utf8, 5:size(32), "I":utf8>>
  let assert Ok(#(68, payload, rest)) = proto.next_message(message)
  assert proto.data_row(payload) == [Some(<<42:size(64)>>), None]
  let assert Ok(#(90, <<"I":utf8>>, <<>>)) = proto.next_message(rest)
  assert proto.next_message(<<"D":utf8, 100:size(32), 1, 2>>) == Error(Nil)
  let arr = <<1:size(32), 0:size(32), 25:size(32), 2:size(32), 1:size(32), 1:size(32), "a":utf8, 2:size(32), "bc":utf8>>
  assert proto.col_text_array(Some(arr)) == [<<"a":utf8>>, <<"bc":utf8>>]
  assert proto.col_text_array(Some(<<0:size(32), 0:size(32), 25:size(32)>>)) == []
  assert proto.text_array_param(["a\"b", "c\\d"]) == Some(<<"{\"a\\\"b\",\"c\\\\d\"}":utf8>>)
  assert proto.array_literal([Some(<<"1":utf8>>), None]) == Some(<<"{\"1\",NULL}":utf8>>)
}

pub fn bcrypt_test() {
  bcrypt.start(20)
  let assert Ok(hash) = bcrypt.hash(<<"conformance-pass-1":utf8>>)
  assert bit_array.byte_size(hash) == 60
  assert bcrypt.verify(<<"conformance-pass-1":utf8>>, hash)
  assert !bcrypt.verify(<<"wrong":utf8>>, hash)
  // A seeded user's hash ("password123").
  let seeded = <<"$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq":utf8>>
  assert bcrypt.verify(<<"password123":utf8>>, seeded)
  assert !bcrypt.verify(<<"password124":utf8>>, seeded)
  assert !bcrypt.verify(<<"x":utf8>>, <<"not-a-hash":utf8>>)
}
