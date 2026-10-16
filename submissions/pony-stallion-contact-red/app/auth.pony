use json = "json"
use "encode/base64"
use "time"
use "lib:conduit_password"
use "lib:crypto"
use "lib:dl"
use "lib:pthread"
use "lib:m"

use @conduit_hash[I32](password: Pointer[U8] tag, size: USize,
  output: Pointer[U8] tag)
use @conduit_verify[I32](password: Pointer[U8] tag, size: USize,
  hash: Pointer[U8] tag, hash_size: USize)
use @EVP_sha256[Pointer[None]]()
use @HMAC[Pointer[U8]](md: Pointer[None], key: Pointer[U8] tag,
  key_len: I32, data: Pointer[U8] tag, data_len: USize,
  output: Pointer[U8] tag, output_len: Pointer[U32] tag)
use @CRYPTO_memcmp[I32](a: Pointer[U8] tag, b: Pointer[U8] tag, len: USize)

primitive _Password
  fun hash(password: String): String ? =>
    let out = recover iso Array[U8].init(0, 60) end
    if @conduit_hash(password.cpointer(), password.size(), out.cpointer())
      != 1
    then
      error
    end
    String.from_iso_array(consume out)

  fun verify(password: String, hash': String): Bool =>
    @conduit_verify(password.cpointer(), password.size(), hash'.cpointer(),
      hash'.size()) == 1

primitive _JWT
  fun encode(data: ReadSeq[U8]): String =>
    let out = Base64.encode_url(data where pad = true)
    out.strip("=")
    consume out

  fun sign(secret: String, data: String): Array[U8] val ? =>
    let out = recover iso Array[U8].init(0, 32) end
    let size = recover iso Array[U32].init(0, 1) end
    if @HMAC(@EVP_sha256(), secret.cpointer(), secret.size().i32(),
      data.cpointer(), data.size(), out.cpointer(), size.cpointer()).is_null()
    then
      error
    end
    if size(0)? != 32 then error end
    consume out

  fun issue(secret: String, id: I64): String ? =>
    let now = Time.seconds()
    let claims = json.JSONObject.update("sub", id.string())
      .update("iat", now).update("exp", now + (30 * 24 * 3600))
    let payload: String val = claims.print()
    let data: String val = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
      + encode(payload)
    data + "." + encode(sign(secret, data)?)

  fun verify(secret: String, token: String): I64 ? =>
    let parts: Array[String] val = token.split(".")
    if parts.size() != 3 then error end
    for part in parts.values() do
      if part.size() == 0 then error end
      for c in part.values() do
        if not (((c >= 'a') and (c <= 'z'))
          or ((c >= 'A') and (c <= 'Z'))
          or ((c >= '0') and (c <= '9')) or (c == '-') or (c == '_'))
        then
          error
        end
      end
    end
    let header: String val = Base64.decode_url[String iso](parts(0)?)?
    let h = json.JSONParser.parse(header) as json.JSONObject
    if (h("alg")? as String) != "HS256" then error end
    let data: String val = parts(0)? + "." + parts(1)?
    let actual: Array[U8] val = Base64.decode_url(parts(2)?)?
    let expected = sign(secret, data)?
    if (actual.size() != 32)
      or (@CRYPTO_memcmp(actual.cpointer(), expected.cpointer(), 32) != 0)
    then
      error
    end
    let payload: String val = Base64.decode_url[String iso](parts(1)?)?
    let claims = json.JSONParser.parse(payload) as json.JSONObject
    let exp = match claims("exp")?
      | let n: I64 => n.f64()
      | let n: F64 => n
      else error
      end
    if exp <= Time.seconds().f64() then error end
    let id = _Input.decimal(claims("sub")? as String)?
    if id <= 0 then error end
    id
