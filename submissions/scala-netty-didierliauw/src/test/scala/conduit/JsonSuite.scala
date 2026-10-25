package conduit

class JsonSuite extends munit.FunSuite:
  import Json.*

  test("parses objects, arrays, literals and numbers"):
    assertEquals(
      parse(""" { "body" : "x", "n": -1.5e2, "ok": true, "no": false, "nil": null, "a": [1, [], {}] } """),
      Some(
        Obj(
          Map(
            "body" -> Str("x"),
            "n" -> Num(-150),
            "ok" -> Bool(true),
            "no" -> Bool(false),
            "nil" -> Null,
            "a" -> Arr(Vector(Num(1), Arr(Vector()), Obj(Map()))),
          )
        )
      ),
    )

  test("decodes escapes, including surrogate pairs"):
    assertEquals(parse(""""a\"b\\c\/d\b\f\n\r\té😀""""), Some(Str("a\"b\\c/d\b\f\n\r\té😀")))

  test("half a surrogate pair on its own is malformed, and \\u takes ASCII hex digits only"):
    for text <- Seq(""""\ud800"""", """"a\ud800b"""", """"\udc00"""", """"\ude00\ud83d"""", """"\ud83d\u0041"""",
        """"\ud83d\"""", """"\ud83d"""", "\"\\u004\uff21\"", "\"\\u\u0663\u0663\u0664\u0661\"") do
      assertEquals(parse(text), None, s"input: $text")
    assertEquals(parse(""""\ud83d\ude00\u00e9\u0041\uFFFF""""), Some(Str("😀éA\uffff")))

  test("parses UTF-8 bytes, and bytes that aren't UTF-8 are malformed"):
    def utf8(s: String) = s.getBytes(java.nio.charset.StandardCharsets.UTF_8)
    for text <- Seq("""{"body":"plain ASCII"}""", """{"body":"é € 😀"}""", "[]") do
      assertEquals(parseUtf8(utf8(text)), parse(text), text)
    val bad = Seq(Array(0x80), Array(0xc3), Array(0xc0, 0x80), Array(0xe0, 0x80, 0x80), Array(0xed, 0xa0, 0x80),
      Array(0xf0, 0x9f, 0x98), Array(0xf5, 0x80, 0x80, 0x80), Array(0xff))
    for b <- bad.map(_.map(_.toByte)) do
      val doc = utf8("""{"body":"a""") ++ b ++ utf8("""b"}""")
      assertEquals(parseUtf8(doc), None, b.map(x => f"${x & 0xff}%02x").mkString(" "))

  test("passes raw non-ASCII through"):
    assertEquals(parse("\"café ✓\""), Some(Str("café ✓")))

  test("a repeated key keeps its last value"):
    assertEquals(parse("""{"body":"a","body":"b"}"""), Some(Obj(Map("body" -> Str("b")))))

  test("rejects malformed JSON"):
    val bad = Seq(
      "", " ", "{bad json", "{", "}", "[1,]", """{"a":1,}""", """{"a" 1}""", "{'a':1}", "01", "1.", "-", ".5", "1e",
      "+1", "nul", "True", """"\x"""", "\"a\nb\"", "\"abc", """"\u12"""", "{} x", "[] []", "﻿{}",
    )
    for text <- bad do assertEquals(parse(text), None, s"input: $text")

  test("rejects very deep nesting without overflowing the stack"):
    assertEquals(parse("[" * 100_000), None)
    assert(parse("[" * 200 + "]" * 200).isDefined)
