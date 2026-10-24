//// `Authorization: Token <jwt>`: HS256 tokens, verified on every request (signature, alg, exp, nbf).
//// Nothing about a verified token is remembered.

import conduit/util
import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string

// base64url of {"alg":"HS256","typ":"JWT"}: the header issued here and minted by the load generator.
const std_header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"

const ttl = 2_592_000

@external(erlang, "conduit_ffi", "hmac_sha256")
fn hmac(key: BitArray, data: BitArray) -> BitArray

@external(erlang, "conduit_ffi", "hash_equals")
fn hash_equals(a: BitArray, b: BitArray) -> Bool

@external(erlang, "conduit_ffi", "base64url_encode")
fn b64_encode(data: BitArray) -> BitArray

@external(erlang, "conduit_ffi", "base64url_decode")
fn b64_decode(data: BitArray) -> Result(BitArray, Nil)

/// What the C fast path (native/conduit_nif.c) made of a token.
pub type Fast {
  Fast(id: Int)
  /// Bad signature, undecodable payload or expired.
  Rejected
  /// Not the one shape the fast path covers: the general path decides.
  General
}

@external(erlang, "conduit_nif", "jwt_verify")
fn fast_verify(token: BitArray, secret: BitArray, now: Int) -> Fast

pub type Auth {
  Anonymous
  User(id: Int, token: String)
  Invalid
}

pub fn issue(secret: BitArray, user_id: Int, now: Int) -> String {
  let claims =
    "{\"sub\":\"" <> int.to_string(user_id) <> "\",\"iat\":" <> int.to_string(now) <> ",\"exp\":" <> int.to_string(now + ttl) <> "}"
  let signing = std_header <> "." <> util.unsafe_to_string(b64_encode(util.to_bits(claims)))
  signing <> "." <> util.unsafe_to_string(b64_encode(hmac(secret, util.to_bits(signing))))
}

/// A missing or empty header is anonymous; anything else must be a valid `Token <jwt>`.
pub fn check(header: String, secret: BitArray, now: Int) -> Auth {
  case header {
    "" -> Anonymous
    "Token " <> token ->
      case verify(token, secret, now) {
        Ok(id) -> User(id, token)
        Error(_) -> Invalid
      }
    _ -> Invalid
  }
}

/// The C fast path takes the one shape every issuer here produces (the standard header, a flat
/// `{"sub":"<id>","iat":<n>,"exp":<n>}` payload, a 43-character unpadded signature): HMAC-SHA256 over the signed
/// part, the expected signature encoded and compared in constant time, and only then the payload decoded and
/// read. Any other shape goes through the general path, which accepts the same tokens more slowly.
pub fn verify(token: String, secret: BitArray, now: Int) -> Result(Int, Nil) {
  case fast_verify(util.to_bits(token), secret, now) {
    Fast(id) -> Ok(id)
    Rejected -> Error(Nil)
    General -> verify_general(token, secret, now)
  }
}

fn verify_general(token: String, secret: BitArray, now: Int) -> Result(Int, Nil) {
  case string.split(token, ".") {
    [header, payload, sig] ->
      case header_ok(header), b64_decode(util.to_bits(sig)) {
        True, Ok(sig_bytes) -> {
          let signed = util.to_bits(header <> "." <> payload)
          case bit_array.byte_size(sig_bytes) == 32 && hash_equals(hmac(secret, signed), sig_bytes) {
            False -> Error(Nil)
            True ->
              case b64_decode(util.to_bits(payload)) {
                Error(_) -> Error(Nil)
                Ok(claims) -> check_claims(claims, now)
              }
          }
        }
        _, _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn check_claims(claims: BitArray, now: Int) -> Result(Int, Nil) {
  case parse_claims(claims) {
    Ok(#(sub, exp, nbf)) ->
      case exp > now && nbf_ok(nbf, now) {
        True -> Ok(sub)
        False -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
}

fn nbf_ok(nbf: Option(Int), now: Int) -> Bool {
  case nbf {
    None -> True
    Some(n) -> n <= now
  }
}

fn header_ok(header: String) -> Bool {
  case header == std_header {
    True -> True
    False ->
      case b64_decode(util.to_bits(header)) {
        Error(_) -> False
        Ok(bytes) -> {
          let decoder = {
            use alg <- decode.field("alg", decode.string)
            decode.success(alg)
          }
          case json.parse_bits(bytes, decoder) {
            Ok("HS256") -> True
            _ -> False
          }
        }
      }
  }
}

/// Fast path for the flat shape every issuer here produces; anything else goes to the general parser.
fn parse_claims(claims: BitArray) -> Result(#(Int, Int, Option(Int)), Nil) {
  case claims {
    <<"{\"sub\":\"":utf8, rest:bytes>> ->
      case digits(rest, 0, 0) {
        Ok(#(sub, <<"\",\"iat\":":utf8, rest:bytes>>)) ->
          case digits(rest, 0, 0) {
            Ok(#(_iat, <<",\"exp\":":utf8, rest:bytes>>)) ->
              case digits(rest, 0, 0) {
                Ok(#(exp, <<"}":utf8>>)) if sub > 0 -> Ok(#(sub, exp, None))
                _ -> general_claims(claims)
              }
            _ -> general_claims(claims)
          }
        _ -> general_claims(claims)
      }
    _ -> general_claims(claims)
  }
}

fn digits(b: BitArray, acc: Int, n: Int) -> Result(#(Int, BitArray), Nil) {
  case b {
    <<c:size(8), rest:bytes>> if c >= 48 && c <= 57 && n < 18 -> digits(rest, acc * 10 + c - 48, n + 1)
    _ if n > 0 -> Ok(#(acc, b))
    _ -> Error(Nil)
  }
}

fn general_claims(claims: BitArray) -> Result(#(Int, Int, Option(Int)), Nil) {
  let decoder = {
    use sub <- decode.field("sub", decode.string)
    use exp <- decode.field("exp", decode.int)
    use nbf <- decode.optional_field("nbf", None, decode.optional(decode.int))
    decode.success(#(sub, exp, nbf))
  }
  case json.parse_bits(claims, decoder) {
    Ok(#(sub, exp, nbf)) ->
      case util.parse_digits(sub) {
        Ok(id) if id > 0 -> Ok(#(id, exp, nbf))
        _ -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
}
