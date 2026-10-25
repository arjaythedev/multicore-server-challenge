package conduit

class InputSuite extends munit.FunSuite:
  test("paging values: digits only, fitting in a Long"):
    assertEquals(Input.unsigned("10"), 10L)
    assertEquals(Input.unsigned("005"), 5L)
    assertEquals(Input.unsigned("9223372036854775807"), Long.MaxValue)
    for bad <- Seq("", "-1", "+5", " 5", "1.5", "abc", "99999999999999999999", "9223372036854775808") do
      assertEquals(Input.unsigned(bad), -1L, bad)

  test("query strings: the first value of each, percent-decoded"):
    val q = Input.Query("limit=05&offset=005&tag=a+b%21&limit=7&author=&x=1")
    assertEquals((q.limit, q.offset, q.tag, q.author, q.favorited), ("05", "005", "a b!", "", null))
    assertEquals(Input.Query("limit=%2B5").limit, "+5")
    assertEquals(Input.Query("limit=%205").limit, " 5")
    assertEquals(Input.Query("limit").limit, "")
    assertEquals(Input.Query("limit=1;offset=2").limit, null) // a pair with a semicolon is dropped
    assertEquals(Input.Query("tag=%zz&tag=ok").tag, "ok") // as is one that isn't valid percent-encoding
    assertEquals(Input.Query("tag=%C3%A9t%C3%A9").tag, "été")
    assertEquals(Input.Query(null).limit, null)

  test("path segments: percent-decoded UTF-8, + kept"):
    assertEquals(Input.segment("a+b%20c", 0, 7), "a+b c")
    assertEquals(Input.segment("%E2%82%AC", 0, 9), "€")
    assertEquals(Input.segment("%FF", 0, 3), null)
    assertEquals(Input.segment("%4", 0, 2), null)

  test("slugs as SLUGIFY makes them"):
    for (title, slug) <- Seq(
        "Conformance: Hello, World! 2026" -> "conformance-hello-world-2026",
        "  Conformance -- Renamed Title!  " -> "conformance-renamed-title",
        "Été à Paris" -> "t-paris",
        "!!!" -> "",
        "a_b" -> "a-b",
        "ABC" -> "abc",
      )
    do assertEquals(Input.slugify(title), slug, title)
