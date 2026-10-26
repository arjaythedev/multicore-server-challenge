## HS256 JWT creation and verification for the RealWorld contract.
##
## Claims are exactly `sub` (decimal user id string), `iat` and `exp` (unix
## seconds).  The header must be HS256.  Verification is intentionally done on
## every request: the challenge forbids a token-verification cache.

{.passL: "-lcrypto".}

import std/[json, base64, strutils, times]

type
  EVP_MD {.importc: "EVP_MD", header: "<openssl/evp.h>", incompleteStruct.} = object

  JwtStatus* = enum
    jsOk, jsInvalid

  JwtInfo* = object
    userId*: int64
    exp*: int64

proc EVP_sha256(): ptr EVP_MD
  {.importc, header: "<openssl/evp.h>".}

proc HMAC(evp: ptr EVP_MD; key: pointer; keyLen: cint;
          data: ptr UncheckedArray[byte]; dataLen: csize_t;
          md: ptr UncheckedArray[byte]; mdLen: ptr cuint): ptr byte
  {.importc, header: "<openssl/hmac.h>".}

proc b64urlEncode*(s: string): string =
  result = base64.encode(s)
  result = result.replace('+', '-').replace('/', '_')
  while result.len > 0 and result[^1] == '=':
    result.setLen(result.len - 1)

proc b64urlDecode*(s: string): string =
  var t = s.replace('-', '+').replace('_', '/')
  case t.len mod 4
  of 0: discard
  of 2: t.add "=="
  of 3: t.add "="
  else: return ""
  try: base64.decode(t)
  except CatchableError: ""

proc hmacSha256(secret, data: string): array[32, byte] =
  var mac: array[32, byte]
  var macLen: cuint
  let p = HMAC(EVP_sha256(), secret.cstring, cint(secret.len),
               cast[ptr UncheckedArray[byte]](data.cstring), csize_t(data.len),
               cast[ptr UncheckedArray[byte]](addr mac[0]), addr macLen)
  if p == nil or macLen != 32'u32:
    raise newException(ValueError, "HMAC-SHA256 failed")
  mac

proc constantTimeEqual(a, b: openArray[byte]): bool =
  if a.len != b.len: return false
  var diff = 0
  for i in 0 ..< a.len:
    diff = diff or (int(a[i]) xor int(b[i]))
  diff == 0

proc encodeJwt*(userId: int64; secret: string): string =
  let now = int64(epochTime())
  let header = """{"alg":"HS256","typ":"JWT"}"""
  let payload = $(%*{
    "sub": $userId,
    "iat": now,
    "exp": now + 30'i64 * 24 * 60 * 60
  })
  let signingInput = b64urlEncode(header) & "." & b64urlEncode(payload)
  let signature = hmacSha256(secret, signingInput)
  var sig = newString(32)
  for i in 0 ..< 32: sig[i] = char(signature[i])
  signingInput & "." & b64urlEncode(sig)

proc verifyJwt*(secret, token: string): tuple[status: JwtStatus, info: JwtInfo] =
  ## Verify signature, HS256 header, exp, and decimal `sub`.
  let parts = token.split('.')
  if parts.len != 3: return (jsInvalid, JwtInfo())

  let headerRaw = b64urlDecode(parts[0])
  let payloadRaw = b64urlDecode(parts[1])
  let sigRaw = b64urlDecode(parts[2])
  if headerRaw.len == 0 or payloadRaw.len == 0 or sigRaw.len != 32:
    return (jsInvalid, JwtInfo())

  var header, payload: JsonNode
  try:
    header = parseJson(headerRaw)
    payload = parseJson(payloadRaw)
  except CatchableError:
    return (jsInvalid, JwtInfo())

  if header.kind != JObject or payload.kind != JObject: return (jsInvalid, JwtInfo())
  if not header.hasKey("alg") or header["alg"].kind != JString or
     header["alg"].getStr != "HS256":
    return (jsInvalid, JwtInfo())

  let signingInput = parts[0] & "." & parts[1]
  let expected = hmacSha256(secret, signingInput)
  var actual: array[32, byte]
  for i in 0 ..< 32: actual[i] = byte(ord(sigRaw[i]))
  if not constantTimeEqual(expected, actual): return (jsInvalid, JwtInfo())

  if not payload.hasKey("sub") or not payload.hasKey("exp"):
    return (jsInvalid, JwtInfo())
  if payload["sub"].kind != JString or payload["exp"].kind notin {JInt, JFloat}:
    return (jsInvalid, JwtInfo())

  var userId: int64
  try:
    userId = int64(parseBiggestInt(payload["sub"].getStr))
  except CatchableError:
    return (jsInvalid, JwtInfo())
  let exp = int64(payload["exp"].getFloat)
  if userId <= 0 or exp <= int64(epochTime()):
    return (jsInvalid, JwtInfo())

  (jsOk, JwtInfo(userId: userId, exp: exp))
