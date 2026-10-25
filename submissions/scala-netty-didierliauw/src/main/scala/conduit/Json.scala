package conduit

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.StandardCharsets.{ISO_8859_1, UTF_8}
import java.util

/** A parsed JSON value. Only request bodies are parsed into one, and they are tiny, so a tree is fine; a token's
  * header and payload are read in place ([[Json.Reader]]).
  */
enum Json:
  case Null
  case Bool(value: Boolean)
  case Num(value: Double)
  case Str(value: String)
  case Arr(items: Vector[Json])
  case Obj(fields: Map[String, Json]) // a repeated key keeps its last value, as in JSON.parse

object Json:
  private val MaxDepth = 256

  /** Parses JSON from bytes, which must be UTF-8 (RFC 8259), or returns None. Bytes that aren't UTF-8 are malformed
    * rather than replaced: `new String(bytes, UTF_8)` would turn them into U+FFFD without a word. ASCII, the common
    * case, decodes without the checking decoder.
    */
  def parseUtf8(bytes: Array[Byte]): Option[Json] =
    val text =
      if isAscii(bytes) then String(bytes, ISO_8859_1) // the same characters, decoded byte for byte
      else
        try UTF_8.newDecoder().decode(ByteBuffer.wrap(bytes)).toString // reports malformed input
        catch case _: CharacterCodingException => return None
    parse(text)

  private def isAscii(bytes: Array[Byte]): Boolean =
    var i = 0
    while i < bytes.length && bytes(i) >= 0 do i += 1
    i == bytes.length

  /** Parses strict JSON (RFC 8259), or returns None if `text` isn't valid JSON. */
  def parse(text: String): Option[Json] =
    try
      val p = Parser(text)
      p.skipWhitespace()
      val value = p.value(0)
      p.skipWhitespace()
      if p.pos != text.length then p.fail()
      Some(value)
    catch case _: Malformed => None

  private[conduit] final class Malformed extends Exception(null, null, false, false)

  /** Reads the fields of a JSON object in place from UTF-8 bytes, as strictly as [[parseUtf8]] parses them (the same
    * grammar, depth limit and UTF-8 rules), without a tree: no objects, but for a number it can't read exactly
    * itself. A string's content, unescaped and as UTF-8, is [[text]] from [[textFrom]] until [[textUntil]]: the input
    * itself unless it has escapes or other than ASCII. Malformed input throws [[Malformed]]. Reused: [[reset]] for
    * each input.
    *
    * {{{
    * r.reset(bytes, length)
    * if r.objectStart() then
    *   while r.nextField() do // the key is in text
    *     if r.textIs(Key) then x = r.numberField() else r.skipField()
    *   r.finish()
    * }}}
    */
  final class Reader:
    private var in: Array[Byte] = null
    private var pos = 0
    private var end = 0
    /** No field of the object read yet. */
    private var first = false
    /** Strings with escapes or other than ASCII, unescaped. */
    private var copy = new Array[Byte](64)
    var text: Array[Byte] = null
    var textFrom = 0
    var textUntil = 0

    def reset(bytes: Array[Byte], length: Int): Unit =
      in = bytes
      pos = 0
      end = length

    /** Starts reading the input's object: false if the input is another value, or none. */
    def objectStart(): Boolean =
      skipWhitespace()
      if peek != '{' then false
      else
        pos += 1
        first = true
        true

    /** Reads the next field's key into [[text]], and true, or the object's end, and false. The field's value is read
      * or skipped before the next call.
      */
    def nextField(): Boolean =
      skipWhitespace()
      if first then
        first = false
        if peek == '}' then
          pos += 1
          return false
      else if peek == ',' then
        pos += 1
        skipWhitespace()
      else
        expect('}')
        return false
      if peek != '"' then fail()
      string()
      skipWhitespace()
      expect(':')
      skipWhitespace()
      true

    /** Whether the last string read is `ascii`'s characters. */
    def textIs(ascii: Array[Byte]): Boolean = util.Arrays.equals(text, textFrom, textUntil, ascii, 0, ascii.length)

    /** Reads the field's value into [[text]] if it is a string, and true, or skips it, and false. */
    def stringField(): Boolean =
      if peek == '"' then
        string()
        true
      else
        skip(1)
        false

    /** The field's value if it is a number, or skips it and returns NaN (no JSON number is NaN, and every comparison
      * with it is false).
      */
    def numberField(): Double =
      if peek == '-' || isDigit(peek) then number(read = true)
      else
        skip(1)
        Double.NaN

    /** Skips the field's value, which must be valid all the same. */
    def skipField(): Unit = skip(1)

    /** After the object's end: nothing but whitespace may follow. */
    def finish(): Unit =
      skipWhitespace()
      if pos != end then fail()

    private def fail(): Nothing = throw Malformed()

    /** The next byte as a character (one above ASCII never matches), or NUL at the end. */
    private def peek: Char = if pos < end then in(pos).toChar else '\u0000'

    private def isDigit(c: Char) = c >= '0' && c <= '9'

    private def skipWhitespace(): Unit =
      while pos < end && (in(pos) == ' ' || in(pos) == '\t' || in(pos) == '\n' || in(pos) == '\r') do pos += 1

    private def expect(c: Char): Unit =
      if peek != c then fail()
      pos += 1

    /** Skips a value, as [[Parser.value]] parses it; `depth` as there. */
    private def skip(depth: Int): Unit =
      if depth > MaxDepth then fail()
      peek match
        case '{' =>
          pos += 1
          skipWhitespace()
          if peek == '}' then pos += 1
          else
            var more = true
            while more do
              skipWhitespace()
              if peek != '"' then fail()
              string()
              skipWhitespace()
              expect(':')
              skipWhitespace()
              skip(depth + 1)
              skipWhitespace()
              if peek == ',' then pos += 1
              else
                expect('}')
                more = false
        case '[' =>
          pos += 1
          skipWhitespace()
          if peek == ']' then pos += 1
          else
            var more = true
            while more do
              skipWhitespace()
              skip(depth + 1)
              skipWhitespace()
              if peek == ',' then pos += 1
              else
                expect(']')
                more = false
        case '"' => string()
        case 't' => literal(True)
        case 'f' => literal(False)
        case 'n' => literal(NullLiteral)
        case c if c == '-' || isDigit(c) => number(read = false)
        case _ => fail()

    private def literal(word: Array[Byte]): Unit =
      if end - pos < word.length || !util.Arrays.equals(in, pos, pos + word.length, word, 0, word.length) then fail()
      pos += word.length

    /** A number, as [[Parser.number]] reads it, and its value if `read`: exact for integers of up to 18 digits, which
      * a `Long` holds and a `Double` rounds as `Double.parseDouble` would; anything else through `parseDouble`.
      */
    private def number(read: Boolean): Double =
      val start = pos
      val negative = peek == '-'
      if negative then pos += 1
      var value = 0L
      var digits = 0
      if peek == '0' then
        pos += 1
        digits = 1
      else
        if !isDigit(peek) then fail()
        while isDigit(peek) do
          value = value * 10 + (in(pos) - '0')
          digits += 1
          pos += 1
      var integer = true
      if peek == '.' then
        pos += 1
        someDigits()
        integer = false
      if peek == 'e' || peek == 'E' then
        pos += 1
        if peek == '+' || peek == '-' then pos += 1
        someDigits()
        integer = false
      if !read then 0
      else if integer && digits <= 18 then (if negative then -value else value).toDouble
      else java.lang.Double.parseDouble(String(in, start, pos - start, ISO_8859_1))

    private def someDigits(): Unit =
      if !isDigit(peek) then fail()
      while isDigit(peek) do pos += 1

    /** A string from its opening quote, into [[text]]. */
    private def string(): Unit =
      pos += 1
      val start = pos
      while pos < end && in(pos) >= ' ' && in(pos) != '"' && in(pos) != '\\' do pos += 1 // ASCII bytes are positive
      if pos < end && in(pos) == '"' then
        text = in
        textFrom = start
        textUntil = pos
        pos += 1
      else
        // Unescaped into the copy, which needs no more room than the input: no escape is shorter than what it stands for.
        if copy.length < end - start then copy = new Array[Byte](end - start)
        var n = pos - start
        System.arraycopy(in, start, copy, 0, n)
        var done = false
        while !done do
          if pos >= end then fail()
          val b = in(pos)
          if b == '"' then
            pos += 1
            done = true
          else if b == '\\' then
            pos += 1
            n = escape(n)
          else if b >= 0 then
            if b < ' ' then fail()
            copy(n) = b
            n += 1
            pos += 1
          else
            val length = utf8Length()
            System.arraycopy(in, pos, copy, n, length)
            n += length
            pos += length
        text = copy
        textFrom = 0
        textUntil = n

    /** The length of the UTF-8 sequence at `pos`, which starts with a byte above ASCII, if it is well-formed (RFC
      * 3629: no overlong forms, no surrogates, nothing past U+10FFFF), as `UTF_8`'s decoder checks it.
      */
    private def utf8Length(): Int =
      val lead = in(pos) & 0xff
      if lead < 0xc2 || lead > 0xf4 then fail()
      val length = if lead < 0xe0 then 2 else if lead < 0xf0 then 3 else 4
      if end - pos < length then fail()
      val second = in(pos + 1) & 0xff
      val low = if lead == 0xe0 then 0xa0 else if lead == 0xf0 then 0x90 else 0x80
      val high = if lead == 0xed then 0x9f else if lead == 0xf4 then 0x8f else 0xbf
      if second < low || second > high then fail()
      var i = 2
      while i < length do
        if (in(pos + i) & 0xc0) != 0x80 then fail()
        i += 1
      length

    /** The escape after a backslash, as [[Parser.escape]] reads it, written to the copy at `n` as UTF-8: the copy's
      * length after it.
      */
    private def escape(n: Int): Int =
      if pos >= end then fail()
      val c = in(pos).toChar
      pos += 1
      c match
        case '"' | '\\' | '/' => put(n, c)
        case 'b' => put(n, '\b')
        case 'f' => put(n, '\f')
        case 'n' => put(n, '\n')
        case 'r' => put(n, '\r')
        case 't' => put(n, '\t')
        case 'u' =>
          val code = hex4()
          if Character.isHighSurrogate(code) then
            if end - pos < 2 || in(pos) != '\\' || in(pos + 1) != 'u' then fail()
            pos += 2
            val low = hex4()
            if !Character.isLowSurrogate(low) then fail()
            utf8(n, Character.toCodePoint(code, low))
          else if Character.isLowSurrogate(code) then fail()
          else utf8(n, code)
        case _ => fail()

    private def put(n: Int, c: Char): Int =
      copy(n) = c.toByte
      n + 1

    /** Writes the code point to the copy at `n` as UTF-8, and returns the copy's length after it. */
    private def utf8(n: Int, code: Int): Int =
      if code < 0x80 then put(n, code.toChar)
      else if code < 0x800 then
        copy(n) = (0xc0 | code >> 6).toByte
        copy(n + 1) = (0x80 | code & 0x3f).toByte
        n + 2
      else if code < 0x10000 then
        copy(n) = (0xe0 | code >> 12).toByte
        copy(n + 1) = (0x80 | code >> 6 & 0x3f).toByte
        copy(n + 2) = (0x80 | code & 0x3f).toByte
        n + 3
      else
        copy(n) = (0xf0 | code >> 18).toByte
        copy(n + 1) = (0x80 | code >> 12 & 0x3f).toByte
        copy(n + 2) = (0x80 | code >> 6 & 0x3f).toByte
        copy(n + 3) = (0x80 | code & 0x3f).toByte
        n + 4

    /** Four hex digits, ASCII only, as [[Parser.hex4]] reads them. */
    private def hex4(): Char =
      if end - pos < 4 then fail()
      var code = 0
      var i = 0
      while i < 4 do
        val c = in(pos + i)
        val digit =
          if c >= '0' && c <= '9' then c - '0'
          else if c >= 'a' && c <= 'f' then c - 'a' + 10
          else if c >= 'A' && c <= 'F' then c - 'A' + 10
          else fail()
        code = code * 16 + digit
        i += 1
      pos += 4
      code.toChar

  private val True = "true".getBytes(ISO_8859_1)
  private val False = "false".getBytes(ISO_8859_1)
  private val NullLiteral = "null".getBytes(ISO_8859_1)

  private final class Parser(s: String):
    var pos = 0

    def fail(): Nothing = throw Malformed()

    def skipWhitespace(): Unit =
      while pos < s.length && isWhitespace(s.charAt(pos)) do pos += 1

    def value(depth: Int): Json =
      if depth > MaxDepth then fail()
      peek match
        case '{' => obj(depth)
        case '[' => arr(depth)
        case '"' => Str(string())
        case 't' => literal("true", Bool(true))
        case 'f' => literal("false", Bool(false))
        case 'n' => literal("null", Null)
        case c if c == '-' || isDigit(c) => number()
        case _ => fail()

    private def peek: Char = if pos < s.length then s.charAt(pos) else '\u0000'

    private def isDigit(c: Char) = c >= '0' && c <= '9'

    private def isWhitespace(c: Char) = c == ' ' || c == '\t' || c == '\n' || c == '\r'

    /** Plain string content: not a quote, a backslash or a control character. */
    private def isPlain(c: Char) = c != '"' && c != '\\' && c >= ' '

    private def expect(c: Char): Unit =
      if peek != c then fail()
      pos += 1

    private def obj(depth: Int): Json =
      pos += 1
      val fields = Map.newBuilder[String, Json]
      skipWhitespace()
      if peek == '}' then pos += 1
      else
        var more = true
        while more do
          skipWhitespace()
          if peek != '"' then fail()
          val key = string()
          skipWhitespace()
          expect(':')
          skipWhitespace()
          fields += key -> value(depth + 1)
          skipWhitespace()
          if peek == ',' then pos += 1
          else
            expect('}')
            more = false
      Obj(fields.result())

    private def arr(depth: Int): Json =
      pos += 1
      val items = Vector.newBuilder[Json]
      skipWhitespace()
      if peek == ']' then pos += 1
      else
        var more = true
        while more do
          skipWhitespace()
          items += value(depth + 1)
          skipWhitespace()
          if peek == ',' then pos += 1
          else
            expect(']')
            more = false
      Arr(items.result())

    private def literal(word: String, result: Json): Json =
      if !s.startsWith(word, pos) then fail()
      pos += word.length
      result

    private def number(): Json =
      val start = pos
      if peek == '-' then pos += 1
      if peek == '0' then pos += 1
      else digits()
      if peek == '.' then
        pos += 1
        digits()
      if peek == 'e' || peek == 'E' then
        pos += 1
        if peek == '+' || peek == '-' then pos += 1
        digits()
      Num(java.lang.Double.parseDouble(s.substring(start, pos)))

    private def digits(): Unit =
      if !isDigit(peek) then fail()
      while isDigit(peek) do pos += 1

    /** A string literal starting at the opening quote. */
    def string(): String =
      pos += 1
      val start = pos
      while pos < s.length && isPlain(s.charAt(pos)) do pos += 1
      if peek == '"' then
        pos += 1
        s.substring(start, pos - 1)
      else
        val sb = java.lang.StringBuilder(pos - start + 16)
        sb.append(s, start, pos)
        var done = false
        while !done do
          if pos >= s.length then fail()
          val c = s.charAt(pos)
          pos += 1
          if c == '"' then done = true
          else if c == '\\' then escape(sb)
          else if c < ' ' then fail()
          else sb.append(c)
        sb.toString

    /** Appends the escape after a backslash. A character outside the BMP arrives as two `\u` escapes, the halves of
      * a surrogate pair. Half a pair on its own is malformed here, though JSON's grammar allows it: it isn't a
      * character, UTF-8 can't encode it, and storing it would change the text (Java writes `?`).
      */
    private def escape(sb: java.lang.StringBuilder): Unit =
      if pos >= s.length then fail()
      val c = s.charAt(pos)
      pos += 1
      c match
        case '"' | '\\' | '/' => sb.append(c)
        case 'b' => sb.append('\b')
        case 'f' => sb.append('\f')
        case 'n' => sb.append('\n')
        case 'r' => sb.append('\r')
        case 't' => sb.append('\t')
        case 'u' =>
          val code = hex4()
          if Character.isHighSurrogate(code) then
            if !s.startsWith("\\u", pos) then fail()
            pos += 2
            val low = hex4()
            if !Character.isLowSurrogate(low) then fail()
            sb.append(code).append(low)
          else if Character.isLowSurrogate(code) then fail()
          else sb.append(code)
        case _ => fail()

    /** Four hex digits, ASCII only (`Character.digit` also takes other scripts' digits and fullwidth letters). */
    private def hex4(): Char =
      if pos + 4 > s.length then fail()
      var code = 0
      for i <- pos until pos + 4 do
        val c = s.charAt(i)
        val digit =
          if c >= '0' && c <= '9' then c - '0'
          else if c >= 'a' && c <= 'f' then c - 'a' + 10
          else if c >= 'A' && c <= 'F' then c - 'A' + 10
          else fail()
        code = code * 16 + digit
      pos += 4
      code.toChar
