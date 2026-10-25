package conduit

import conduit.Registrations.{ScrambledIntMap, scramble}

class RegistrationsSuite extends munit.FunSuite:
  test("scrambling is a bijection: no two descriptors share a key"):
    val keys = (0 until 200_000).map(scramble)
    assertEquals(keys.distinct.size, keys.size)

  test("the scrambled map behaves like a map"):
    val map = ScrambledIntMap[String]()
    for fd <- 0 until 70_000 do assertEquals(map.put(fd, s"c$fd"), null)
    assertEquals(map.size, 70_000)
    assertEquals(map.get(12_345), "c12345")
    assert(map.containsKey(69_999))
    for fd <- 0 until 70_000 by 2 do assertEquals(map.remove(fd), s"c$fd")
    assertEquals(map.size, 35_000)
    assertEquals(map.get(12_344), null)
    assertEquals(map.get(12_345), "c12345")
    assertEquals(map.put(12_345, "again"), "c12345")
    assertEquals(map.values.size, 35_000)
