package conduit

import io.netty.util.concurrent.FastThreadLocal

import java.nio.charset.StandardCharsets.US_ASCII
import java.security.MessageDigest
import java.util

/** HS256 JWTs: issued at login and sign-up, and verified in full on every request that carries one (rule 7: the
  * signature, `alg` and `exp`, with nothing remembered).
  */
final class Jwt(secret: Array[Byte]):
  import Jwt.*

  // An empty key is a valid HMAC key, which anyone can sign with (javax.crypto refuses it).
  require(secret.nonEmpty, "the JWT secret is empty")
  /** HMAC's key pads (RFC 2104): the key, hashed first if longer than SHA-256's block, XORed with 0x36 and 0x5c. */
  private val innerPad = keyPad(0x36)
  private val outerPad = keyPad(0x5c)

  private def keyPad(x: Int): Array[Byte] =
    val key = if secret.length > Block then MessageDigest.getInstance("SHA-256").digest(secret) else secret
    Array.tabulate(Block)(i => ((if i < key.length then key(i) else 0) ^ x).toByte)

  /** The user id (`sub`) of the token in `header` from `from` on (after `Token `), or [[Jwt.Invalid]] if it is
    * refused.
    */
  def verify(header: String, from: Int, nowSeconds: Long): Long =
    val dot1 = header.indexOf('.', from)
    val dot2 = if dot1 < 0 then -1 else header.indexOf('.', dot1 + 1)
    if dot2 < 0 || header.indexOf('.', dot2 + 1) >= 0 then Invalid
    else if !hs256(header, from, dot1) || !signatureValid(header, from, dot2) then Invalid
    else claims(header, dot1 + 1, dot2, nowSeconds)

  /** A token for user `id`, as the spec has it: `{"sub": "<id>", "iat": <now>, "exp": <now + 30 days>}`. */
  def issue(id: Long, nowSeconds: Long): String =
    val payload = s"""{"sub":"$id","iat":$nowSeconds,"exp":${nowSeconds + Lifetime}}""".getBytes(US_ASCII)
    val signingInput = IssuedHeader + "." + util.Base64.getUrlEncoder.withoutPadding.encodeToString(payload)
    val s = scratch.get()
    val input = signingInput.getBytes(US_ASCII)
    hmac(s, input, input.length)
    signingInput + "." + util.Base64.getUrlEncoder.withoutPadding.encodeToString(s.digest)

  /** Whether the header, the token's part from `from` until `until`, is a JSON object whose `alg` is HS256. */
  private[conduit] def hs256(header: String, from: Int, until: Int): Boolean =
    val r = scratch.get().read(header, from, until)
    try
      var hs256 = false
      if r != null && r.objectStart() then
        while r.nextField() do
          if r.textIs(Alg) then hs256 = r.stringField() && r.textIs(Hs256) // the last one counts, as in JSON.parse
          else r.skipField()
        r.finish()
      hs256
    catch case _: Json.Malformed => false

  /** The payload's user id, from the token's part from `from` until `until`, or [[Invalid]]. `exp` is required and
    * `nbf` optional; both must be numbers, and `sub` a positive id in a string. The last of each counts, as in
    * `JSON.parse`.
    */
  private[conduit] def claims(header: String, from: Int, until: Int, now: Long): Long =
    val s = scratch.get()
    val r = s.read(header, from, until)
    try
      if r == null || !r.objectStart() then return Invalid
      var notExpired = false
      var started = true
      var id = 0L
      while r.nextField() do
        // A NaN is a value that isn't a number: every comparison with it is false.
        if r.textIs(Exp) then notExpired = now < r.numberField()
        else if r.textIs(Nbf) then started = now >= r.numberField()
        else if r.textIs(Sub) then id = if r.stringField() then Input.positiveId(r.text, r.textFrom, r.textUntil) else 0
        else r.skipField()
      r.finish()
      if !notExpired || !started || id == 0 then Invalid else id
    catch case _: Json.Malformed => Invalid

  /** HMAC-SHA256 of the token from `from` until its second dot, compared in constant time with the signature after
    * it, in the thread's buffers: `Mac` allocates each result, and the token's parts would be copies.
    */
  private[conduit] def signatureValid(header: String, from: Int, dot2: Int): Boolean =
    val s = scratch.get()
    val length = dot2 - from
    val input = s.bytes(length)
    var i = 0
    while i < length do
      input(i) = header.charAt(from + i).toByte // base64url and a dot, or the token is refused when its parts are decoded
      i += 1
    hmac(s, input, length)
    decodeBase64Url(header, dot2 + 1, header.length, s.signature) == DigestLength && MessageDigest.isEqual(s.digest, s.signature)

  /** HMAC-SHA256 of `input`'s first `length` bytes, into the thread's digest. */
  private def hmac(s: Scratch, input: Array[Byte], length: Int): Unit =
    val sha = s.sha256
    sha.reset()
    sha.update(innerPad)
    sha.update(input, 0, length)
    sha.digest(s.digest, 0, DigestLength)
    sha.update(outerPad)
    sha.update(s.digest)
    sha.digest(s.digest, 0, DigestLength)

object Jwt:
  /** [[Jwt.verify]]'s answer for a token that isn't valid, or expired. */
  val Invalid = -1L
  /** 30 days, in seconds. */
  private val Lifetime = 30L * 24 * 3600
  /** SHA-256's block, in bytes. */
  private val Block = 64
  private val DigestLength = 32
  /** `{"alg":"HS256","typ":"JWT"}`, base64url-encoded. */
  private val IssuedHeader = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"

  private val Alg = "alg".getBytes(US_ASCII)
  private val Hs256 = "HS256".getBytes(US_ASCII)
  private val Exp = "exp".getBytes(US_ASCII)
  private val Nbf = "nbf".getBytes(US_ASCII)
  private val Sub = "sub".getBytes(US_ASCII)

  /** Each thread's buffers, used again for each token. */
  private final class Scratch:
    val sha256 = MessageDigest.getInstance("SHA-256")
    private var buffer = new Array[Byte](512)
    val digest = new Array[Byte](DigestLength)
    val signature = new Array[Byte](DigestLength)
    private val json = Json.Reader()

    /** A buffer of at least `n` bytes. */
    def bytes(n: Int): Array[Byte] =
      if buffer.length < n then buffer = new Array[Byte](n)
      buffer

    /** The reader, reset to read the token's part from `from` until `until`, decoded into the buffer; null if it
      * isn't base64url.
      */
    def read(header: String, from: Int, until: Int): Json.Reader =
      val bytes = this.bytes((until - from) / 4 * 3 + 3)
      val n = decodeBase64Url(header, from, until, bytes)
      if n < 0 then null
      else
        json.reset(bytes, n)
        json

  private val scratch = new FastThreadLocal[Scratch]:
    override protected def initialValue(): Scratch = Scratch()

  /** Each base64url character's 6 bits, or -1. */
  private val Base64Url = Array.tabulate[Int](128): c =>
    if c >= 'A' && c <= 'Z' then c - 'A'
    else if c >= 'a' && c <= 'z' then c - 'a' + 26
    else if c >= '0' && c <= '9' then c - '0' + 52
    else if c == '-' then 62
    else if c == '_' then 63
    else -1

  /** Decodes `s` from `from` until `until` as base64url into `dst`, accepting what `Base64.getUrlDecoder` accepts
    * (padding optional but correct if present, the last character's unused bits ignored): the number of bytes, or -1
    * if it isn't base64url or doesn't fit.
    */
  private[conduit] def decodeBase64Url(s: String, from: Int, until: Int, dst: Array[Byte]): Int =
    var bits = 0
    var shift = 18 // where the next character's 6 bits go in a unit of 4 characters (3 bytes)
    var n = 0
    var i = from
    var padded = false
    while i < until && !padded do
      val c = s.charAt(i)
      i += 1
      val v = if c < 128 then Base64Url(c) else -1
      if v >= 0 then
        bits |= v << shift
        shift -= 6
        if shift < 0 then
          if n + 3 > dst.length then return -1
          dst(n) = (bits >> 16).toByte
          dst(n + 1) = (bits >> 8).toByte
          dst(n + 2) = bits.toByte
          n += 3
          bits = 0
          shift = 18
      else if c == '=' then
        // Ends the data: after two characters of a unit as "==", after three as "=".
        if shift == 18 || shift == 12 then return -1
        if shift == 6 then
          if i == until || s.charAt(i) != '=' then return -1
          i += 1
        padded = true
      else return -1
    if i < until then return -1 // something after the padding
    val last = if shift == 6 then 1 else if shift == 0 then 2 else if shift == 12 then return -1 else 0
    if n + last > dst.length then return -1
    if last > 0 then dst(n) = (bits >> 16).toByte
    if last > 1 then dst(n + 1) = (bits >> 8).toByte
    n + last
