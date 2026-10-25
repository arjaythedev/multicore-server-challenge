package conduit

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.StandardCharsets.UTF_8

/** Validation and decoding of what a request carries outside its body: ids, paging, query strings, path segments. */
object Input:
  /** The positive decimal integer in `s` from `from` until `until`, digits only, read in place, or 0 if it isn't one:
    * a `Long`, not an `Option`, so that nothing is allocated. Ids too large for a Long saturate, so they're simply
    * not found.
    */
  def positiveId(s: String, from: Int, until: Int): Long =
    if from >= until then 0
    else
      var value = 0L
      var i = from
      while i < until do
        val c = s.charAt(i)
        if c < '0' || c > '9' then return 0
        value = if value > (Long.MaxValue - 9) / 10 then Long.MaxValue else value * 10 + (c - '0')
        i += 1
      value

  /** [[positiveId]] of the bytes from `from` until `until` (a token's `sub`). */
  def positiveId(bytes: Array[Byte], from: Int, until: Int): Long =
    if from >= until then 0
    else
      var value = 0L
      var i = from
      while i < until do
        val c = bytes(i)
        if c < '0' || c > '9' then return 0
        value = if value > (Long.MaxValue - 9) / 10 then Long.MaxValue else value * 10 + (c - '0')
        i += 1
      value

  /** A query parameter's value: ASCII digits only, no sign or spaces, and fitting in a Long; -1 if it isn't one. */
  def unsigned(s: String): Long =
    if s.isEmpty || s.length > 19 then return -1
    var value = 0L
    var i = 0
    while i < s.length do
      val c = s.charAt(i)
      if c < '0' || c > '9' then return -1
      if value > (Long.MaxValue - (c - '0')) / 10 then return -1
      value = value * 10 + (c - '0')
      i += 1
    value

  /** The query parameters a request may have, each its first value, percent-decoded (`+` is a space): pairs split on
    * `&`; a pair that isn't valid percent-encoding, or has a `;`, is dropped. Absent parameters are null.
    */
  final class Query(query: String):
    var limit: String = null
    var offset: String = null
    var tag: String = null
    var author: String = null
    var favorited: String = null

    if query != null then
      var start = 0
      while start <= query.length do
        var end = query.indexOf('&', start)
        if end < 0 then end = query.length
        if end > start then pair(start, end)
        start = end + 1

    private def pair(start: Int, end: Int): Unit =
      val semicolon = query.indexOf(';', start)
      if semicolon >= 0 && semicolon < end then return
      val found = query.indexOf('=', start)
      val eq = if found < 0 || found > end then end else found
      val key = decode(query, start, eq, plusIsSpace = true)
      if key == null then return
      val value = if eq < end then decode(query, eq + 1, end, plusIsSpace = true) else ""
      if value == null then return
      key match
        case "limit" => if limit == null then limit = value
        case "offset" => if offset == null then offset = value
        case "tag" => if tag == null then tag = value
        case "author" => if author == null then author = value
        case "favorited" => if favorited == null then favorited = value
        case _ => ()

  /** A path segment, percent-decoded as UTF-8 (`+` stays `+`), or null if it isn't valid percent-encoding or UTF-8. */
  def segment(path: String, from: Int, until: Int): String = decode(path, from, until, plusIsSpace = false)

  /** `s[from, until)` percent-decoded into UTF-8 text, or null if it isn't valid: a `%` without two hex digits, or bytes
    * that aren't UTF-8 (Postgres would refuse them).
    */
  def decode(s: String, from: Int, until: Int, plusIsSpace: Boolean): String =
    var i = from
    while i < until && s.charAt(i) != '%' && !(plusIsSpace && s.charAt(i) == '+') && s.charAt(i) < 0x80 do i += 1
    if i == until then return s.substring(from, until)
    val bytes = ByteArrayOutputStream(until - from)
    i = from
    while i < until do
      val c = s.charAt(i)
      if c == '%' then
        if i + 2 >= until then return null
        val hi = Character.digit(s.charAt(i + 1), 16)
        val lo = Character.digit(s.charAt(i + 2), 16)
        if hi < 0 || lo < 0 || s.charAt(i + 1) > 0x7f || s.charAt(i + 2) > 0x7f then return null
        bytes.write(hi << 4 | lo)
        i += 3
      else
        bytes.write(if plusIsSpace && c == '+' then ' ' else c) // the request line is ISO-8859-1: one byte each
        i += 1
    try UTF_8.newDecoder().decode(ByteBuffer.wrap(bytes.toByteArray)).toString
    catch case _: CharacterCodingException => null

  /** The spec's `SLUGIFY(x)`, `trim(both '-' from lower(regexp_replace(x, '[^A-Za-z0-9]+', '-', 'g')))`, computed
    * here instead of in Postgres: every run of characters other than ASCII letters and digits becomes one `-`,
    * letters are lower-cased, and the `-`s at either end are dropped.
    */
  def slugify(title: String): String =
    val sb = java.lang.StringBuilder(title.length)
    var dash = false
    var i = 0
    while i < title.length do
      val c = title.charAt(i)
      if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') then
        if dash && sb.length > 0 then sb.append('-')
        dash = false
        sb.append(c)
      else if c >= 'A' && c <= 'Z' then
        if dash && sb.length > 0 then sb.append('-')
        dash = false
        sb.append((c + 32).toChar)
      else dash = true
      i += 1
    sb.toString
