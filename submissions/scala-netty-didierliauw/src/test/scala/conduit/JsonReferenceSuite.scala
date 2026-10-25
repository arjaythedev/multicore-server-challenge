package conduit

import io.netty.buffer.UnpooledByteBufAllocator

import java.nio.charset.StandardCharsets.UTF_8
import scala.util.Random

/** [[Json]] and [[Out]] checked against a reference ([[JsonReference]]: Jackson, plus the three rules it states)
  * on documents generated at random and then damaged a step at a time: both parsers must agree on whether each is
  * valid and on what it holds, and what `Out` writes must parse back to the text it was given. The seed is fixed, so
  * a failure repeats; the clue shows the input with everything outside printable ASCII escaped.
  */
class JsonReferenceSuite extends munit.FunSuite:
  private val random = Random(20261018)

  test("the parser agrees with the reference on generated documents and damaged copies of them"):
    var valid, invalid = 0
    for _ <- 1 to 5000 do
      var text = value(depth = 4)
      for step <- 0 to 8 do
        if step > 0 then text = mutate(text)
        if JsonReference.wholeCharacters(text) then // raw halves of a pair can't come from UTF-8 bytes
          val ours = Json.parse(text)
          assertEquals(ours, JsonReference.parse(text), s"input: ${show(text)}")
          if ours.isDefined then valid += 1 else invalid += 1
    assert(valid > 5000 && invalid > 5000, s"$valid valid, $invalid invalid: the generator should make plenty of both")

  test("the parser agrees with the reference on bytes that may not be UTF-8"):
    val prefix = """{"body":"""".getBytes(UTF_8)
    val suffix = """"}""".getBytes(UTF_8)
    var malformed = 0
    for _ <- 1 to 20000 do
      val bytes = prefix ++ Array.fill(1 + random.nextInt(5))(utf8Piece()).flatten ++ suffix
      val ours = Json.parseUtf8(bytes)
      assertEquals(ours, JsonReference.parseUtf8(bytes), bytes.map(b => f"${b & 0xff}%02x").mkString(" "))
      if ours.isEmpty then malformed += 1
    assert(malformed > 1000 && malformed < 19000, s"$malformed malformed of 20000: the generator should make plenty of both")

  test("what Out writes is JSON that parses back to the text it was given, from the heap and from a Netty buffer"):
    val buf = io.netty.buffer.Unpooled.buffer(4096)
    for _ <- 1 to 20000 do
      val text = randomText()
      val utf8 = text.getBytes(UTF_8)
      assertEquals(JsonReference.parseUtf8(written(_.jsonString(utf8))), Some(Json.Str(text)), show(text))
      buf.clear().writeInt(7).writeBytes(utf8) // somewhere in a reply, as Postgres's text is
      val fromBuffer = written(_.jsonString(buf, 4, utf8.length))
      assertEquals(JsonReference.parseUtf8(fromBuffer), Some(Json.Str(text)), show(text))

  // Generated documents: every kind of value, random whitespace, strings mixing raw and escaped characters (any
  // \u code unit, so lone surrogate halves too).

  private def pick[A](options: A*): A = options(random.nextInt(options.length))

  private def ws(): String = pick("", "", " ", "\n", "\t", "\r\n  ")

  private def value(depth: Int): String = random.nextInt(if depth > 0 then 9 else 6) match
    case 0 => "null"
    case 1 => pick("true", "false")
    case 2 | 3 => number()
    case 4 | 5 => string()
    case 6 | 7 => Seq.fill(random.nextInt(4))(s"${ws()}${string()}${ws()}:${ws()}${value(depth - 1)}${ws()}").mkString("{", ",", "}")
    case _ => Seq.fill(random.nextInt(4))(s"${ws()}${value(depth - 1)}${ws()}").mkString("[", ",", "]")

  private def digits(n: Int): String = Seq.fill(n)(('0' + random.nextInt(10)).toChar).mkString

  private def number(): String =
    val int = if random.nextInt(4) == 0 then "0" else s"${1 + random.nextInt(9)}${digits(random.nextInt(22))}"
    val fraction = if random.nextBoolean() then s".${digits(1 + random.nextInt(5))}" else ""
    val exponent = if random.nextInt(3) == 0 then s"${pick("e", "E")}${pick("", "+", "-")}${digits(1 + random.nextInt(3))}" else ""
    s"${pick("", "-")}$int$fraction$exponent"

  private def string(): String = Seq.fill(random.nextInt(10))(stringPart()).mkString("\"", "", "\"")

  private def stringPart(): String = random.nextInt(14) match
    case 0 => pick("\\\"", "\\\\", "\\/")
    case 1 => pick("\\b", "\\f", "\\n", "\\r", "\\t")
    case 2 => f"\\u${random.nextInt(0x20)}%04x"
    case 3 => f"\\u${random.nextInt(0x10000)}%04X"
    case 4 => pick("\\ud83d\\ude00", "\\uD83D\\uDE00")
    case 5 => pick("😀", "é", "€", "\u2028", "\ufeff")
    case _ => (' ' + random.nextInt(95)).toChar match
        case '"' | '\\' => "x"
        case c => c.toString

  // Damage: delete, insert, replace, cut, or repeat a span, with pieces of JSON's syntax and characters that are
  // nearly it (fullwidth and Arabic-Indic digits, a non-breaking space, NUL).

  private val Pieces = Seq("{", "}", "[", "]", ",", ":", "\"", "\\", "\\u", "\\ud800", "\\udc00", "0", "7", "-", "+",
    ".", "e", " ", "\n", "\u000b", "\u0000", "\u001f", "true", "nul", "😀", "\uff10", "\uff21", "\u0663", "\u00a0")

  private def mutate(text: String): String =
    if text.isEmpty then pick(Pieces*)
    else
      val i = random.nextInt(text.length)
      random.nextInt(5) match
        case 0 => text.substring(0, i) + text.substring(i + 1)
        case 1 => text.substring(0, i) + pick(Pieces*) + text.substring(i)
        case 2 => text.substring(0, i) + pick(Pieces*) + text.substring(i + 1)
        case 3 => text.substring(0, i)
        case _ =>
          val end = (i + 1 + random.nextInt(8)).min(text.length)
          text.substring(0, end) + text.substring(i, end) + text.substring(end)

  // Bytes for a string's content: well-formed sequences, and ill-formed ones of every kind.

  private def utf8Piece(): Array[Byte] = (random.nextInt(16) match
    case 0 => Array(random.nextInt(256))
    case 1 => Array(0x80 + random.nextInt(64)) // a continuation byte alone
    case 2 => Array(0xc0 + random.nextInt(2), 0x80 + random.nextInt(64)) // overlong
    case 3 => Array(0xe0, 0x80 + random.nextInt(32), 0x80) // overlong
    case 4 => Array(0xed, 0xa0 + random.nextInt(32), 0x80 + random.nextInt(64)) // a surrogate
    case 5 => Array(0xf4, 0x90 + random.nextInt(48), 0x80, 0x80) // past U+10FFFF
    case 6 => Array(0xf5 + random.nextInt(11), 0x80, 0x80, 0x80)
    case 7 => Array(0xf0, 0x9f, 0x98) // cut short
    case 8 => Array(0xc3)
    case _ => pick("é", "€", "😀", "a", "\ufeff", "\u07ff", "\uffff", "\u0800").getBytes(UTF_8).map(_ & 0xff)
  ).map(_.toByte)

  /** Text of any characters: control characters, quotes and backslashes, BMP and beyond, no lone surrogates. */
  private def randomText(): String =
    val sb = java.lang.StringBuilder()
    for _ <- 0 until random.nextInt(40) do
      val c = random.nextInt(6) match
        case 0 => random.nextInt(0x20)
        case 1 => pick('"'.toInt, '\\'.toInt, '/'.toInt, 0x7f, 0x2028, 0xfeff, 0xffff)
        case 2 => 0x20 + random.nextInt(0x60)
        case 3 => 0x80 + random.nextInt(0x780)
        case 4 => 0x10000 + random.nextInt(0x100000)
        case _ =>
          val bmp = 0x800 + random.nextInt(0xf800)
          if bmp >= 0xd800 && bmp <= 0xdfff then 0xe000 else bmp
      sb.appendCodePoint(c)
    sb.toString

  /** The body `Out` writes. */
  private def written(write: Out => Unit): Array[Byte] =
    val out = Out()
    out.reset()
    write(out)
    val buf = out.response(UnpooledByteBufAllocator.DEFAULT, Status.Ok, Out.Ending.KeepAlive)
    try
      val all = new Array[Byte](buf.readableBytes)
      buf.readBytes(all)
      val headEnd = all.indices.find(i => all.startsWith(Array[Byte]('\r', '\n', '\r', '\n'), i)).get
      all.drop(headEnd + 4)
    finally buf.release()

  private def show(text: String): String =
    text.flatMap(c => if c >= ' ' && c <= '~' then c.toString else f"\\u${c.toInt}%04x")
