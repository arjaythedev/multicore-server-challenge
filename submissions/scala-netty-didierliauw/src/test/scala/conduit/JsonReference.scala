package conduit

import com.fasterxml.jackson.core.JsonToken
import com.fasterxml.jackson.databind.node.JsonNodeType
import com.fasterxml.jackson.databind.{DeserializationFeature, JsonNode, ObjectMapper}

import java.io.IOException
import scala.jdk.CollectionConverters.*

/** What JSON text means, by a reference: Jackson, the most used Java JSON library (a test-only dependency), held to
  * RFC 8259 as strictly as [[Json]] is. Three rules are checked here rather than left to Jackson:
  *
  *   - half a surrogate pair on its own (a `\u` escape, or encoded in UTF-8) is malformed, since it can't be
  *     stored (`Json.escape`); Jackson accepts it, as JSON's grammar does;
  *   - a `\u` escape takes four ASCII hex digits, as the grammar says (HEXDIG): Jackson 2.18 reads only a
  *     character's low 7 bits there, so `\u004Ł` is `J` and `\u00٣1` is `Á` (found by [[JsonReferenceSuite]]);
  *   - bytes must be UTF-8 by RFC 3629's grammar, checked here on its own: no overlong forms, no surrogates.
  */
object JsonReference:
  private val mapper = ObjectMapper().enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS)

  /** The value of `text`, as a [[Json]] tree, or None if it isn't valid. */
  def parse(text: String): Option[Json] =
    if !asciiHexEscapes(text) then return None
    try
      // Every string, overwritten repeated keys included, must be whole characters.
      val tokens = mapper.getFactory.createParser(text)
      try
        var token = tokens.nextToken()
        while token != null do
          val isString = token == JsonToken.FIELD_NAME || token == JsonToken.VALUE_STRING
          if isString && !wholeCharacters(tokens.getText) then return None
          token = tokens.nextToken()
      finally tokens.close()
      Option(mapper.readTree(text)).filterNot(_.isMissingNode).map(convert)
    catch case _: IOException => None

  /** The value of UTF-8 `bytes`, or None if they aren't UTF-8 or valid JSON. */
  def parseUtf8(bytes: Array[Byte]): Option[Json] =
    if !isUtf8(bytes) then None else parse(String(bytes, java.nio.charset.StandardCharsets.UTF_8))

  /** JSON text for `value`, written by Jackson. */
  def write(value: AnyRef): String = mapper.writeValueAsString(value)

  private def convert(node: JsonNode): Json = node.getNodeType match
    case JsonNodeType.OBJECT => Json.Obj(node.properties.asScala.map(e => e.getKey -> convert(e.getValue)).toMap)
    case JsonNodeType.ARRAY => Json.Arr(node.elements.asScala.map(convert).toVector)
    case JsonNodeType.STRING => Json.Str(node.textValue)
    case JsonNodeType.NUMBER => Json.Num(node.doubleValue)
    case JsonNodeType.BOOLEAN => Json.Bool(node.booleanValue)
    case JsonNodeType.NULL => Json.Null
    case other => throw IllegalStateException(s"unexpected node: $other")

  /** Every `\u` is followed by four ASCII hex digits. A backslash and the character after it are taken as a pair,
    * so an escaped backslash followed by `u` isn't an escape; outside strings a backslash is malformed anyway.
    */
  private def asciiHexEscapes(text: String): Boolean =
    def hex(c: Char) = c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F'
    var i = 0
    while i < text.length do
      if text.charAt(i) == '\\' then
        if i + 1 < text.length && text.charAt(i + 1) == 'u' && !(i + 6 <= text.length && (i + 2 until i + 6).forall(k => hex(text.charAt(k))))
        then return false
        i += 2
      else i += 1
    true

  /** No half of a surrogate pair without the other. */
  def wholeCharacters(s: String): Boolean =
    var i = 0
    while i < s.length do
      val c = s.charAt(i)
      if Character.isHighSurrogate(c) then
        if i + 1 >= s.length || !Character.isLowSurrogate(s.charAt(i + 1)) then return false
        i += 2
      else if Character.isLowSurrogate(c) then return false
      else i += 1
    true

  /** UTF-8 by RFC 3629, section 4:
    * {{{
    * UTF8-2 = %xC2-DF tail
    * UTF8-3 = %xE0 %xA0-BF tail / %xE1-EC 2tail / %xED %x80-9F tail / %xEE-EF 2tail
    * UTF8-4 = %xF0 %x90-BF 2tail / %xF1-F3 3tail / %xF4 %x80-8F 2tail
    * }}}
    */
  def isUtf8(bytes: Array[Byte]): Boolean =
    def at(i: Int) = if i < bytes.length then bytes(i) & 0xff else -1
    def tail(i: Int) = at(i) >= 0x80 && at(i) <= 0xbf
    var i = 0
    while i < bytes.length do
      val b = at(i)
      val (length, secondLow, secondHigh) =
        if b < 0x80 then (1, 0, 0)
        else if b >= 0xc2 && b <= 0xdf then (2, 0x80, 0xbf)
        else if b == 0xe0 then (3, 0xa0, 0xbf)
        else if b >= 0xe1 && b <= 0xec || b == 0xee || b == 0xef then (3, 0x80, 0xbf)
        else if b == 0xed then (3, 0x80, 0x9f)
        else if b == 0xf0 then (4, 0x90, 0xbf)
        else if b >= 0xf1 && b <= 0xf3 then (4, 0x80, 0xbf)
        else if b == 0xf4 then (4, 0x80, 0x8f)
        else return false
      if length > 1 && (at(i + 1) < secondLow || at(i + 1) > secondHigh) then return false
      var k = 2
      while k < length do
        if !tail(i + k) then return false
        k += 1
      i += length
    true
