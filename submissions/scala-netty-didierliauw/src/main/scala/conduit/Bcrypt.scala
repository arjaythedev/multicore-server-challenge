package conduit

import java.math.BigInteger
import java.nio.charset.StandardCharsets.{US_ASCII, UTF_8}
import java.security.{MessageDigest, SecureRandom}
import java.util.Arrays
import scala.annotation.nowarn

/** bcrypt (Provos and Mazières, 1999), as OpenBSD computes it: `$2a$`/`$2b$`/`$2y$` hashes, the password's first 72
  * bytes of UTF-8. Every password the server stores is hashed at cost 10, and every login is checked against its
  * stored hash (rule 7). CPU-bound for ~55 ms, so it runs on threads of its own ([[Passwords]]), never on an event
  * loop.
  */
object Bcrypt:
  val Cost = 10
  /** The most bytes of a password bcrypt uses; a longer one is refused rather than cut. */
  val MaxPasswordBytes = 72
  private val SaltBytes = 16

  /** A new hash of `password` at [[Cost]], with a fresh random salt. */
  def hash(password: Array[Byte], random: SecureRandom): String =
    val salt = new Array[Byte](SaltBytes)
    random.nextBytes(salt)
    hash(password, salt, Cost)

  /** The hash of `password` with `salt` (16 bytes) at `cost`, as `$2a$<cost>$<salt><hash>`. */
  def hash(password: Array[Byte], salt: Array[Byte], cost: Int): String = format(salt, cost, crypt(password, salt, cost))

  /** Whether `password` is the one `stored` is a hash of: false for anything [[parse]] refuses. */
  def check(password: Array[Byte], stored: String): Boolean =
    val s = parse(stored)
    s != null && s.matches(crypt(password, s.salt, s.cost))

  /** A stored hash: its salt and cost, to compute a password's hash with, and the hash to compare it with. */
  final class Stored private[Bcrypt] (val salt: Array[Byte], val cost: Int, hash: String):
    /** Whether [[crypt]]'s bytes are this hash, compared in constant time. */
    def matches(computed: Array[Byte]): Boolean =
      val sb = java.lang.StringBuilder(31)
      encode(computed, 23, sb)
      MessageDigest.isEqual(sb.toString.getBytes(US_ASCII), hash.getBytes(US_ASCII))

  /** A `$2a$`, `$2b$` or `$2y$` hash, or null for anything else (`$2x$` is the broken variant of old crypt_blowfish,
    * which nothing here writes).
    */
  def parse(stored: String): Stored =
    if stored.length != 60 || stored.charAt(0) != '$' || stored.charAt(1) != '2' || stored.charAt(3) != '$' || stored.charAt(6) != '$'
    then return null
    val minor = stored.charAt(2)
    if minor != 'a' && minor != 'b' && minor != 'y' then return null
    val d1 = stored.charAt(4) - '0'
    val d2 = stored.charAt(5) - '0'
    if d1 < 0 || d1 > 9 || d2 < 0 || d2 > 9 then return null
    val cost = d1 * 10 + d2
    if cost < 4 || cost > 31 then return null
    val salt = decode(stored, 7, SaltBytes)
    if salt == null then null else Stored(salt, cost, stored.substring(29))

  /** `$2a$<cost>$<salt><hash>`, from [[crypt]]'s bytes. */
  def format(salt: Array[Byte], cost: Int, computed: Array[Byte]): String =
    require(salt.length == SaltBytes && cost >= 4 && cost <= 31)
    val sb = java.lang.StringBuilder(60)
    sb.append("$2a$").append((cost / 10).toString).append((cost % 10).toString).append('$')
    encode(salt, SaltBytes, sb)
    encode(computed, 23, sb)
    sb.toString

  /** A new random salt. */
  def salt(random: SecureRandom): Array[Byte] =
    val salt = new Array[Byte](SaltBytes)
    random.nextBytes(salt)
    salt

  /** `password` as the key bcrypt reads, cyclically: its UTF-8 bytes and a NUL; only the first 72 bytes count. */
  private[conduit] def key(password: Array[Byte]): Array[Byte] = Arrays.copyOf(password, password.length + 1)

  /** The 24 bytes of "OrpheanBeholderScryDoubt" encrypted 64 times with the expensive key schedule's state. */
  private[conduit] def crypt(password: Array[Byte], salt: Array[Byte], cost: Int): Array[Byte] =
    val key = this.key(password)
    val keyWords = words(key, 18)
    val saltWords = words(salt, 18)
    val st = Arrays.copyOf(Initial, Initial.length)
    // EksBlowfishSetup: the salted key schedule, then 2^cost rounds of the plain one with the key and the salt.
    xorP(st, keyWords)
    var l = 0
    var r = 0
    var s = 0 // the salt's next word
    var i = 0
    while i < StateWords do
      l ^= saltWords(s % 4)
      r ^= saltWords((s + 1) % 4)
      s += 2
      val lr = encipher(st, l, r)
      l = (lr >>> 32).toInt
      r = lr.toInt
      st(i) = l
      st(i + 1) = r
      i += 2
    var rounds = 1L << cost
    while rounds > 0 do
      expand(st, keyWords)
      expand(st, saltWords)
      rounds -= 1
    finish(st)

  /** "OrpheanBeholderScryDoubt" encrypted 64 times with the state EksBlowfishSetup left: the hash's 24 bytes. */
  private def finish(st: Array[Int]): Array[Byte] =
    val c = Array(0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274)
    var j = 0
    while j < 6 do
      var n = 0
      var l = c(j)
      var r = c(j + 1)
      while n < 64 do
        val lr = encipher(st, l, r)
        l = (lr >>> 32).toInt
        r = lr.toInt
        n += 1
      c(j) = l
      c(j + 1) = r
      j += 2
    val out = new Array[Byte](24)
    for k <- 0 until 6 do
      out(4 * k) = (c(k) >>> 24).toByte
      out(4 * k + 1) = (c(k) >>> 16).toByte
      out(4 * k + 2) = (c(k) >>> 8).toByte
      out(4 * k + 3) = c(k).toByte
    out

  /** [[crypt]] of four passwords at once, all at `cost`: their key schedules run in lockstep, round by round, so that
    * one hash's chain of dependent table loads overlaps the others' (on its own, a hash leaves most of a core waiting
    * on them). Each hash is the same work as with [[crypt]]: full bcrypt at `cost` (rule 7); only the scheduling
    * changes.
    */
  private[conduit] def crypt4(passwords: Array[Array[Byte]], salts: Array[Array[Byte]], cost: Int): Array[Array[Byte]] =
    val k = Array.tabulate(4)(i => words(key(passwords(i)), 18))
    val s = Array.tabulate(4)(i => words(salts(i), 18))
    val a = Arrays.copyOf(Initial, StateWords)
    val b = Arrays.copyOf(Initial, StateWords)
    val c = Arrays.copyOf(Initial, StateWords)
    val d = Arrays.copyOf(Initial, StateWords)
    expand4(a, b, c, d, k(0), k(1), k(2), k(3), s(0), s(1), s(2), s(3))
    var rounds = 1L << cost
    while rounds > 0 do
      expand4(a, b, c, d, k(0), k(1), k(2), k(3), null, null, null, null)
      expand4(a, b, c, d, s(0), s(1), s(2), s(3), null, null, null, null)
      rounds -= 1
    Array(a, b, c, d).map(finish)

  /** [[expand]] of four states at once, with their keys; with salts (all four or none), the salted schedule that
    * starts EksBlowfishSetup.
    */
  private def expand4(
      a: Array[Int], b: Array[Int], c: Array[Int], d: Array[Int],
      ka: Array[Int], kb: Array[Int], kc: Array[Int], kd: Array[Int],
      sa: Array[Int], sb: Array[Int], sc: Array[Int], sd: Array[Int],
  ): Unit =
    xorP(a, ka)
    xorP(b, kb)
    xorP(c, kc)
    xorP(d, kd)
    val salted = sa != null
    var la, ra, lb, rb, lc, rc, ld, rd = 0
    var s = 0 // the salts' next word: 0 or 2
    var i = 0
    while i < StateWords do
      if salted then
        la ^= sa(s); ra ^= sa(s + 1)
        lb ^= sb(s); rb ^= sb(s + 1)
        lc ^= sc(s); rc ^= sc(s + 1)
        ld ^= sd(s); rd ^= sd(s + 1)
        s ^= 2
      var xa = la ^ a(0); var ya = ra
      var xb = lb ^ b(0); var yb = rb
      var xc = lc ^ c(0); var yc = rc
      var xd = ld ^ d(0); var yd = rd
      // Blowfish's 16 rounds, unrolled as a C compiler unrolls them: the P-array's words at constant places, no loop
      // (16.2 -> 15.4 ms per hash).
      ya ^= fu(a, xa) ^ a(1); yb ^= fu(b, xb) ^ b(1); yc ^= fu(c, xc) ^ c(1); yd ^= fu(d, xd) ^ d(1)
      xa ^= fu(a, ya) ^ a(2); xb ^= fu(b, yb) ^ b(2); xc ^= fu(c, yc) ^ c(2); xd ^= fu(d, yd) ^ d(2)
      ya ^= fu(a, xa) ^ a(3); yb ^= fu(b, xb) ^ b(3); yc ^= fu(c, xc) ^ c(3); yd ^= fu(d, xd) ^ d(3)
      xa ^= fu(a, ya) ^ a(4); xb ^= fu(b, yb) ^ b(4); xc ^= fu(c, yc) ^ c(4); xd ^= fu(d, yd) ^ d(4)
      ya ^= fu(a, xa) ^ a(5); yb ^= fu(b, xb) ^ b(5); yc ^= fu(c, xc) ^ c(5); yd ^= fu(d, xd) ^ d(5)
      xa ^= fu(a, ya) ^ a(6); xb ^= fu(b, yb) ^ b(6); xc ^= fu(c, yc) ^ c(6); xd ^= fu(d, yd) ^ d(6)
      ya ^= fu(a, xa) ^ a(7); yb ^= fu(b, xb) ^ b(7); yc ^= fu(c, xc) ^ c(7); yd ^= fu(d, xd) ^ d(7)
      xa ^= fu(a, ya) ^ a(8); xb ^= fu(b, yb) ^ b(8); xc ^= fu(c, yc) ^ c(8); xd ^= fu(d, yd) ^ d(8)
      ya ^= fu(a, xa) ^ a(9); yb ^= fu(b, xb) ^ b(9); yc ^= fu(c, xc) ^ c(9); yd ^= fu(d, xd) ^ d(9)
      xa ^= fu(a, ya) ^ a(10); xb ^= fu(b, yb) ^ b(10); xc ^= fu(c, yc) ^ c(10); xd ^= fu(d, yd) ^ d(10)
      ya ^= fu(a, xa) ^ a(11); yb ^= fu(b, xb) ^ b(11); yc ^= fu(c, xc) ^ c(11); yd ^= fu(d, xd) ^ d(11)
      xa ^= fu(a, ya) ^ a(12); xb ^= fu(b, yb) ^ b(12); xc ^= fu(c, yc) ^ c(12); xd ^= fu(d, yd) ^ d(12)
      ya ^= fu(a, xa) ^ a(13); yb ^= fu(b, xb) ^ b(13); yc ^= fu(c, xc) ^ c(13); yd ^= fu(d, xd) ^ d(13)
      xa ^= fu(a, ya) ^ a(14); xb ^= fu(b, yb) ^ b(14); xc ^= fu(c, yc) ^ c(14); xd ^= fu(d, yd) ^ d(14)
      ya ^= fu(a, xa) ^ a(15); yb ^= fu(b, xb) ^ b(15); yc ^= fu(c, xc) ^ c(15); yd ^= fu(d, xd) ^ d(15)
      xa ^= fu(a, ya) ^ a(16); xb ^= fu(b, yb) ^ b(16); xc ^= fu(c, yc) ^ c(16); xd ^= fu(d, yd) ^ d(16)
      la = ya ^ a(17); ra = xa
      lb = yb ^ b(17); rb = xb
      lc = yc ^ c(17); rc = xc
      ld = yd ^ d(17); rd = xd
      a(i) = la; a(i + 1) = ra
      b(i) = lb; b(i + 1) = rb
      c(i) = lc; c(i + 1) = rc
      d(i) = ld; d(i + 1) = rd
      i += 2

  /** Blowfish's key schedule without salt: the P-array XORed with the key's words, then the whole state rewritten by
    * encrypting zeros in a chain.
    */
  private def expand(st: Array[Int], keyWords: Array[Int]): Unit =
    xorP(st, keyWords)
    var l = 0
    var r = 0
    var i = 0
    while i < StateWords do
      val lr = encipher(st, l, r)
      l = (lr >>> 32).toInt
      r = lr.toInt
      st(i) = l
      st(i + 1) = r
      i += 2

  private def xorP(st: Array[Int], keyWords: Array[Int]): Unit =
    var i = 0
    while i < 18 do
      st(i) ^= keyWords(i)
      i += 1

  /** One Blowfish encryption of (l, r): 16 rounds of the Feistel network, as `l << 32 | r`. */
  private def encipher(st: Array[Int], l0: Int, r0: Int): Long =
    var l = l0 ^ st(0)
    var r = r0
    var i = 1
    while i < 17 do
      r ^= f(st, l) ^ st(i)
      l ^= f(st, r) ^ st(i + 1)
      i += 2
    ((r ^ st(17)).toLong << 32) | (l & 0xffffffffL)

  private def f(st: Array[Int], x: Int): Int =
    ((st(S0 + (x >>> 24)) + st(S1 + ((x >>> 16) & 0xff))) ^ st(S2 + ((x >>> 8) & 0xff))) + st(S3 + (x & 0xff))

  /** [[f]] without bounds checks, for [[crypt4]]: each index is a byte of `x` (0 to 255) into its S-box, which is
    * always within the state's 1,042 words. Four lanes of `f` are ~16 loads whose checks the JIT can't remove (the
    * index isn't a loop variable), and the interleaved hashes are bound by instruction count: 18.5 ms of CPU per hash
    * instead of 26.6. Each byte is extracted on its own and scaled in the address (`<< 2`), as a C compiler indexes a
    * table, rather than shifted and masked to a byte offset in one go: 16.2 ms instead of 18.7. A method, not
    * `inline`: [[expand4]] calls it 64 times, and inlined there it makes a method too big for the JIT to compile (93 ms
    * per hash, interpreted); the JIT inlines it itself. `Unsafe`'s memory access is deprecated for removal, and
    * allowed on JDK 25 (`install.sh` pins it) with `--sun-misc-unsafe-memory-access=allow` (`start.sh`); a later JDK
    * would refuse it.
    */
  @nowarn("cat=deprecation")
  private def fu(st: Array[Int], x: Int): Int =
    ((U.getInt(st, S0Offset + ((x >>> 24).toLong << 2)) + U.getInt(st, S1Offset + (((x >>> 16) & 0xff).toLong << 2))) ^
      U.getInt(st, S2Offset + (((x >>> 8) & 0xff).toLong << 2))) + U.getInt(st, S3Offset + ((x & 0xff).toLong << 2))

  private val U: sun.misc.Unsafe =
    val field = classOf[sun.misc.Unsafe].getDeclaredField("theUnsafe")
    field.setAccessible(true)
    field.get(null).asInstanceOf[sun.misc.Unsafe]
  /** The S-boxes' byte offsets in an `Array[Int]`. */
  @nowarn("cat=deprecation")
  private val S0Offset = U.arrayBaseOffset(classOf[Array[Int]]).toLong + 4L * 18
  private val S1Offset = S0Offset + 4L * 256
  private val S2Offset = S1Offset + 4L * 256
  private val S3Offset = S2Offset + 4L * 256

  /** The first `n` 32-bit words of `bytes` read big-endian and cyclically, as bcrypt streams its key and salt. */
  private def words(bytes: Array[Byte], n: Int): Array[Int] =
    val out = new Array[Int](n)
    var off = 0
    for i <- 0 until n do
      var w = 0
      for _ <- 0 until 4 do
        w = (w << 8) | (bytes(off) & 0xff)
        off = (off + 1) % bytes.length
      out(i) = w
    out

  /** Where the four S-boxes start in the state, after the 18 words of the P-array. */
  private val S0 = 18
  private val S1 = S0 + 256
  private val S2 = S1 + 256
  private val S3 = S2 + 256
  private val StateWords = 18 + 4 * 256

  /** Blowfish's initial P-array and S-boxes: the fractional part of pi in hexadecimal, 32 bits at a time
    * (0x243f6a88, 0x85a308d3, ...), computed here rather than written out as a table.
    */
  private[conduit] val Initial: Array[Int] = piWords(StateWords)

  /** The first `n` 32-bit words of pi's fraction, by Machin's formula, pi = 16 atan(1/5) - 4 atan(1/239), in fixed
    * point with 64 guard bits.
    */
  private def piWords(n: Int): Array[Int] =
    val bits = 32 * n + 64
    def atanInverse(x: Int): BigInteger = // atan(1/x) * 2^bits
      val x2 = BigInteger.valueOf(x.toLong * x)
      var power = BigInteger.ONE.shiftLeft(bits).divide(BigInteger.valueOf(x)) // x^-(2k+1) * 2^bits
      var sum = power
      var k = 1
      while power.signum != 0 do
        power = power.divide(x2)
        val term = power.divide(BigInteger.valueOf(2L * k + 1))
        sum = if k % 2 == 1 then sum.subtract(term) else sum.add(term)
        k += 1
      sum
    val pi = atanInverse(5).shiftLeft(4).subtract(atanInverse(239).shiftLeft(2))
    val fraction = pi.subtract(BigInteger.valueOf(3).shiftLeft(bits)).shiftRight(64)
    Array.tabulate(n)(i => fraction.shiftRight(32 * (n - 1 - i)).intValue)

  private val Alphabet = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
  private val Index: Array[Int] =
    val index = Array.fill(128)(-1)
    for i <- Alphabet.indices do index(Alphabet.charAt(i)) = i
    index

  /** bcrypt's base64 (its own alphabet, no padding) of the first `length` bytes of `d`. */
  private def encode(d: Array[Byte], length: Int, sb: java.lang.StringBuilder): Unit =
    var off = 0
    var done = false
    while off < length && !done do
      var c1 = d(off) & 0xff
      off += 1
      sb.append(Alphabet.charAt(c1 >> 2))
      c1 = (c1 & 0x03) << 4
      if off >= length then
        sb.append(Alphabet.charAt(c1))
        done = true
      else
        var c2 = d(off) & 0xff
        off += 1
        sb.append(Alphabet.charAt(c1 | (c2 >> 4)))
        c1 = (c2 & 0x0f) << 2
        if off >= length then
          sb.append(Alphabet.charAt(c1))
          done = true
        else
          c2 = d(off) & 0xff
          off += 1
          sb.append(Alphabet.charAt(c1 | (c2 >> 6)))
          sb.append(Alphabet.charAt(c2 & 0x3f))

  /** `length` bytes decoded from bcrypt's base64 in `s` from `from` on, or null if a character isn't in its alphabet. */
  private def decode(s: String, from: Int, length: Int): Array[Byte] =
    def char64(i: Int): Int =
      val c = s.charAt(i)
      if c < 128 then Index(c) else -1
    val out = new Array[Byte](length)
    var off = from
    var n = 0
    while n < length do
      val c1 = char64(off)
      val c2 = char64(off + 1)
      if c1 < 0 || c2 < 0 then return null
      out(n) = ((c1 << 2) | ((c2 & 0x30) >> 4)).toByte
      n += 1
      if n < length then
        val c3 = char64(off + 2)
        if c3 < 0 then return null
        out(n) = (((c2 & 0x0f) << 4) | ((c3 & 0x3c) >> 2)).toByte
        n += 1
        if n < length then
          val c4 = char64(off + 3)
          if c4 < 0 then return null
          out(n) = (((c3 & 0x03) << 6) | c4).toByte
          n += 1
      off += 4
    out

  /** A password as bcrypt's input: its UTF-8 bytes. */
  def utf8(password: String): Array[Byte] = password.getBytes(UTF_8)
