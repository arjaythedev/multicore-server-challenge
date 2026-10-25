package conduit

class LogSuite extends munit.FunSuite:
  test("an event is one line of JSON: time, level, msg, then its fields"):
    val fields = Seq("path" -> "/a\"b\\c\n\u0001é", "requests" -> 3, "ms" -> 12L, "ok" -> false, "maxMs" -> 1.5, "nan" -> Double.NaN)
    val line = Log.line("warn", "request failed", fields)
    assert(!line.exists(_ < ' '), line)
    assert(line.startsWith("""{"time":""""), line)
    Json.parse(line) match
      case Some(Json.Obj(f)) =>
        assert(f("time").toString.matches("""Str\(\d{4}-\d\d-\d\dT[\d:.]+Z\)"""), f("time").toString)
        assertEquals(f("level"), Json.Str("warn"))
        assertEquals(f("msg"), Json.Str("request failed"))
        assertEquals(f("path"), Json.Str("/a\"b\\c\n\u0001é"))
        assertEquals((f("requests"), f("ms"), f("ok"), f("maxMs")), (Json.Num(3), Json.Num(12), Json.Bool(false), Json.Num(1.5)))
        assertEquals(f("nan"), Json.Str("NaN")) // not a JSON number
      case other => fail(s"not a JSON object: $other")
