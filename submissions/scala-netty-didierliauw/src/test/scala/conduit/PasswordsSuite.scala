package conduit

import java.nio.charset.StandardCharsets.UTF_8
import java.util.concurrent.{ConcurrentHashMap, CountDownLatch, Executor, TimeUnit}

class PasswordsSuite extends munit.FunSuite:
  private val inline: Executor = _.run()
  private val seed = "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq"

  test("checks and new hashes, batched together, each get their own answer"):
    val passwords = Passwords(2, 50)
    val checks = (0 until 9).map(i => if i % 3 == 0 then "wrong" + i else "password123")
    val latch = CountDownLatch(checks.length + 3)
    val checked = ConcurrentHashMap[Int, Boolean]()
    val hashed = ConcurrentHashMap[Int, String]()
    for (p, i) <- checks.zipWithIndex do
      passwords.check(p.getBytes(UTF_8), seed, inline, ok => { checked.put(i, ok); latch.countDown() })
    for i <- 0 until 3 do
      passwords.hash(s"new-$i".getBytes(UTF_8), inline, h => { hashed.put(i, h); latch.countDown() })
    assert(latch.await(30, TimeUnit.SECONDS))
    for i <- checks.indices do assertEquals(checked.get(i), i % 3 != 0, i)
    for i <- 0 until 3 do assert(Bcrypt.check(s"new-$i".getBytes(UTF_8), hashed.get(i)), hashed.get(i))
    assertEquals(hashed.values.stream.distinct.count, 3L)

  test("a hash that isn't bcrypt is refused without a batch"):
    val passwords = Passwords(1, 0)
    val latch = CountDownLatch(1)
    var answer = true
    passwords.check("x".getBytes(UTF_8), "not a hash", inline, ok => { answer = ok; latch.countDown() })
    assert(latch.await(5, TimeUnit.SECONDS))
    assert(!answer)
