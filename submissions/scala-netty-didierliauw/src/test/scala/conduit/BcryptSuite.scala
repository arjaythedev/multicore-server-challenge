package conduit

import org.springframework.security.crypto.bcrypt.BCrypt as Reference

import java.nio.charset.StandardCharsets.UTF_8
import java.security.SecureRandom

class BcryptSuite extends munit.FunSuite:
  private def utf8(s: String) = s.getBytes(UTF_8)

  test("Blowfish's constants are pi's hexadecimal digits"):
    val p = Bcrypt.Initial
    assertEquals(p.take(4).toSeq, Seq(0x243f6a88, 0x85a308d3, 0x13198a2e, 0x03707344))
    assertEquals(p(17), 0x8979fb1b) // the P-array's last word
    assertEquals(p(18), 0xd1310ba6) // the first S-box's first
    assertEquals(p(18 + 1023), 0x3ac372e6) // the last S-box's last

  test("checks the seed's hash of password123"):
    val seed = "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq"
    assert(Bcrypt.check(utf8("password123"), seed))
    assert(!Bcrypt.check(utf8("password124"), seed))
    assert(!Bcrypt.check(utf8(""), seed))

  test("hashes as $2a$ at cost 10 with a fresh salt, and checks its own hashes"):
    val random = SecureRandom()
    val a = Bcrypt.hash(utf8("conformance-pass-1"), random)
    val b = Bcrypt.hash(utf8("conformance-pass-1"), random)
    assert(a.startsWith("$2a$10$") && a.length == 60, a)
    assertNotEquals(a, b)
    assert(Bcrypt.check(utf8("conformance-pass-1"), a))
    assert(!Bcrypt.check(utf8("conformance-pass-2"), a))
    assert(Reference.checkpw("conformance-pass-1", a))

  test("agrees with Spring Security's BCrypt on random passwords and salts"):
    val random = scala.util.Random(20261023)
    val alphabet = "abcXYZ019 !$-_éü中😀"
    for i <- 0 until 40 do
      val length = random.nextInt(30)
      val password = String(Array.fill(length)(alphabet.charAt(random.nextInt(alphabet.length))))
      val bytes = utf8(password)
      if bytes.length <= Bcrypt.MaxPasswordBytes then
        val salt = new Array[Byte](16)
        random.nextBytes(salt)
        val ours = Bcrypt.hash(bytes, salt, 4 + i % 3)
        val theirs = Reference.hashpw(password, ours.substring(0, 29))
        assertEquals(ours, theirs, password)
        assert(Bcrypt.check(bytes, theirs))

  test("uses the first 72 bytes, and accepts $2b$ and $2y$ hashes"):
    val salt = Array.tabulate[Byte](16)(_.toByte)
    val long = "x" * 72
    assertEquals(Bcrypt.hash(utf8(long), salt, 4), Reference.hashpw(long, Bcrypt.hash(utf8(long), salt, 4).substring(0, 29)))
    assert(Bcrypt.check(utf8(long + "more"), Bcrypt.hash(utf8(long), salt, 4)))
    val a = Bcrypt.hash(utf8("pw"), salt, 4)
    assert(Bcrypt.check(utf8("pw"), "$2b$" + a.drop(4)))
    assert(Bcrypt.check(utf8("pw"), "$2y$" + a.drop(4)))
    assert(!Bcrypt.check(utf8("pw"), "$2x$" + a.drop(4)))

  test("four hashes interleaved are the four hashes"):
    val random = scala.util.Random(4)
    val passwords = Array.fill(4)(utf8(random.alphanumeric.take(random.nextInt(20)).mkString))
    val salts = Array.fill(4)(Array.fill[Byte](16)(random.nextInt(256).toByte))
    val together = Bcrypt.crypt4(passwords, salts, 5)
    for i <- 0 until 4 do assertEquals(together(i).toSeq, Bcrypt.crypt(passwords(i), salts(i), 5).toSeq, i)

  test("refuses what isn't a bcrypt hash"):
    for bad <- Seq("", "plain", "$2a$10$short", "$2a$1x$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq",
        "$2a$10$ZSfEoPvlcsj2Xfvs*eK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq", "$2a$03$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq") do
      assert(!Bcrypt.check(utf8("password123"), bad), bad)
