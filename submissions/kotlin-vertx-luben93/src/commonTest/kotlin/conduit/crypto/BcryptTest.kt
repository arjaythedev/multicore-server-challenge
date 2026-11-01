package conduit.crypto

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The seed's hash of "password123" (bench/seed/seed.go): every seeded user has it. */
private const val SEED = "\$2a\$10\$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq"

private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(2 * it, 2 * it + 2).toInt(16).toByte() }
private fun bytes(s: String) = s.encodeToByteArray()

/**
 * OpenBSD/Openwall vectors (re-checked with the unmodified Openwall core, see research/bcrypt.md 2.9). Each is
 * (password bytes, full expected hash); the salt is the hash's own.
 */
private val VECTORS: List<Pair<ByteArray, String>> = listOf(
    bytes("U*U") to "\$2a\$05\$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW",
    bytes("U*U*") to "\$2a\$05\$CCCCCCCCCCCCCCCCCCCCC.VGOzA784oUp/Z0DY336zx7pLYAy0lwK",
    bytes("U*U*U") to "\$2a\$05\$XXXXXXXXXXXXXXXXXXXXXOAcXxm9kjPGEMsLznoKqmqw7tc8WCx4a",
    bytes("") to "\$2a\$05\$CCCCCCCCCCCCCCCCCCCCC.7uG0VCzI2bS7j6ymqJi9CdcdxiRTWNy",
    bytes("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789") to
        "\$2a\$05\$abcdefghijklmnopqrstuu5s2v8.iXieOjg/.AySBTTZIIVFJeBui",
    bytes("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789chars after 72 are ignored") to
        "\$2a\$05\$abcdefghijklmnopqrstuu5s2v8.iXieOjg/.AySBTTZIIVFJeBui",
    hex("a3") to "\$2b\$05\$/OK.fbVrR/bpIqNJ5ianF.Sa7shbm4.OzKpvFnX1pQLmQW96oUlCq",
    hex("a3") to "\$2a\$05\$/OK.fbVrR/bpIqNJ5ianF.Sa7shbm4.OzKpvFnX1pQLmQW96oUlCq",
    hex("a3") to "\$2y\$05\$/OK.fbVrR/bpIqNJ5ianF.Sa7shbm4.OzKpvFnX1pQLmQW96oUlCq",
    bytes("password123") to "\$2b\$04\$abcdefghijklmnopqrstuuK7Sjs7rFYArh/ytIZsOeM/z4RV2Fw2i",
    bytes("p".repeat(72)) to "\$2b\$04\$abcdefghijklmnopqrstuuNt.0ah97gHY3F7JC1Z6EXmQc0bQBhIO",
    bytes("p".repeat(73)) to "\$2b\$04\$abcdefghijklmnopqrstuuNt.0ah97gHY3F7JC1Z6EXmQc0bQBhIO",
    bytes("p".repeat(71)) to "\$2b\$04\$abcdefghijklmnopqrstuuTYDowBoYf34KLYBHbWu7CBwc/8jbH1q",
    bytes("één 🙂") to "\$2b\$04\$......................8s6VUJLJ1DDlV7xNO7sZksS.U52MSbu",
    bytes("batch self test") to "\$2a\$04\$abcdefghijklmnopqrstuuM5.Jm4ZjoirouZjlg2TjPbXhQEN/8Bm",
    // random passwords (lengths 0..80, any byte but NUL) and salts from the Openwall core, $2a/$2b/$2y in turn
    hex("") to "\$2a\$04\$nKK3n9cMaPThguAma1nRKuewozV2YMjGVWlf7ZFzqeVxIS7omZJVO",
    hex("a4") to "\$2b\$04\$s/N8rfuucR.tQ1tjV/9z/e.KU4.H15L/whNH4lqsmKkTSKIfGNnA2",
    hex("5a3f") to "\$2y\$04\$WPZy5pmxeTXYosL3VjvB8eCjUmWp8He7cAFgZXO19HqtQ8XVsUmbS",
    hex("746575") to "\$2a\$04\$wuPc7yuWDOWJN2kH/2mIe.bQvONNYHJl6IX0Fq93FbJYTWymF.3yW",
    hex("3dc3d2e91bfff0") to "\$2b\$04\$B4X2phFAuD4A.3RYEDZROeBm2vUIF3OnSbXfmk4c1W3QnkRzJjpqC",
    hex("592054b20e431d17") to "\$2y\$04\$1Yz0I4asifgA600VlZnzmuQ.dVp6coXmlet7d3sd3O8XVQyk6Ql3e",
    hex("4563476f463d28366a257357393861") to "\$2a\$04\$VlqILju4bRHc83TDjTmZo.H/kwtgE6xoRmTusNXTN2ZV6v3ASc72m",
    hex("4b2d58e807847f82748b5c6fcb91369c") to "\$2b\$04\$0m5SqihPUCLIkLA3k.9BueJqCToGarzrefdMjF4BzN1Q8xS64AUbC",
    hex("21a81f06ef37c91dc448b3cb5e8ecf270db1efb1043ba2813883806b3efcb4") to
        "\$2y\$04\$u7SM3Y9Sy7IoxB5TW8FI..wb0gUrZ4wseZoMZRsdFHqFHkj.nrTjO",
    hex("53753a486458402339235952592568326c44797744552539296874424c4b3778") to
        "\$2a\$04\$ns3pIjf5YRSIgQCdnJWIQuf9bdAziBBCgLYuCmyAHkNRhOWti/KS2",
    hex("82ce5c81e258478762241fdc5c7169bf91b0656c5dc00eca8c609d671e844497cc046ef6c8387ade63aee5de55dfa32fdd34e45fe765ff") to
        "\$2b\$04\$3mPVc9wb.f7jb8DGBnLQMuh0umVeW5ld9o0tCh9Wm5IpV66PB8jAW",
    hex("5a46220f88083daa85a697bbb21eecc0c6c99bf503cea707e5c94f4e6643922ca6cf084ff7f7b027caeda311378262a7b751a1ac5f66c4ade5c85906ccf868aa34e454d1444794") to
        "\$2y\$04\$BswuV2j3kO1cfNjIPzZgJeQiOZ.ut11raTUbY1uzLE1uuPL5fvo3u",
    hex("30512772263f677569693255714174275b34673f3c75324857257e48497a7b77514a252d646a2044585643384e485848465b6965603e5d3444676f68704b603b2f765a3f24704721") to
        "\$2a\$04\$251LP6GDL9ZfUzCBkyQugeVyQI2rqzIZFEBQ5WVVy1DBu.VFRRzH6",
    hex("baf2b86afd7bcfee878d801f8be538be9c7f10477c76244ff03f98b25caa66e408fbd20203ff726aaa3aa4344186b7a07767c966e999becc1c8a03622c219b08f2160bbc345b395fa7") to
        "\$2b\$04\$GE3ASPajCy./9GzFkCkq7OBhlBgB/FQOty5Ii4tlfYFqVsK6jTHB6",
    hex("a41317c0b6ecd538ec7eafc8d727ce49749c3bbbbb7cbfd0c697c4a9201536378036046e5db4d2d66ca515c068f730cf94f1f6942679d2168feccbef324ef05d8d8e6b3af934fe56448e799f92c207a8") to
        "\$2y\$04\$8Rp2CD/Q7ToUu2ikA0ruE.Z5rklHKix5XRftmIBYR8xdJx7M9ZG3G",
    hex("697b355c31") to "\$2a\$04\$6sekFvhYjlYIA6rebASk9uJjo68SEyRJLP25YhGV8ik3iRcIKZVc.",
)

/** The 16 salt bytes of a hash, decoded the long way (independent of the code under test's [Bcrypt.parse]). */
private fun saltOf(hash: String): ByteArray {
    val a = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    var bits = 0L
    var n = 0
    val out = ArrayList<Byte>()
    for (c in hash.substring(7, 29)) {
        bits = (bits shl 6) or a.indexOf(c).toLong()
        n += 6
        if (n >= 8) {
            n -= 8
            out.add((bits ushr n).toByte())
        }
    }
    return out.take(16).toByteArray()
}

class BcryptTest {
    @Test
    fun seedHash() {
        assertTrue(Bcrypt.verify(bytes("password123"), SEED))
        assertTrue(Bcrypt.verify(bytes("password123"), SEED.replaceRange(2, 3, "b")))
        assertTrue(Bcrypt.verify(bytes("password123"), SEED.replaceRange(2, 3, "y")))
        assertFalse(Bcrypt.verify(bytes("password124"), SEED))
        assertFalse(Bcrypt.verify(bytes("password12"), SEED))
        assertFalse(Bcrypt.verify(bytes(""), SEED))
        // password124 under the seed's salt (Openwall)
        assertTrue(Bcrypt.verify(bytes("password124"), "\$2a\$10\$ZSfEoPvlcsj2XfvsSeK25ezBXBo3NUjyvsoY3AVPF8m6f80nPmTAC"))
    }

    @Test
    fun knownVectors() {
        for ((pw, h) in VECTORS) {
            assertTrue(Bcrypt.verify(pw, h), h)
            if (pw.isNotEmpty() && pw.size <= 72) assertFalse(Bcrypt.verify(pw.copyOf(pw.size - 1), h), "prefix of $h")
            val cost = h.substring(4, 6).toInt()
            assertEquals("\$2b\$" + h.substring(4), Bcrypt.hash(pw, saltOf(h), cost), h) // we always write $2b$
        }
    }

    @Test
    fun cost10Format() {
        assertEquals(
            "\$2b\$10\$abcdefghijklmnopqrstuu0SYq8twpcthS10uxQ26rv0s3Obj8Ufu",
            Bcrypt.hash(bytes("password123"), saltOf("\$2b\$10\$abcdefghijklmnopqrstuu"), 10),
        )
        // non-canonical last salt char ('v' carries unused bits): same salt bytes, canonical output
        assertTrue(Bcrypt.verify(bytes("password123"), "\$2b\$10\$abcdefghijklmnopqrstuv0SYq8twpcthS10uxQ26rv0s3Obj8Ufu"))
        assertEquals(60, Bcrypt.hash(bytes("x"), ByteArray(16), 10).length)
    }

    @Test
    fun keySchedule() {
        // password + NUL, cycled: "ab" -> 61 62 00 61 | 62 00 61 62 | ...
        val k = Bcrypt.keyWords(bytes("ab"))
        assertEquals(0x61620061, k[0])
        assertEquals(0x62006162, k[1])
        assertEquals(0x00616200, k[2])
        // empty password: all NUL
        assertTrue(Bcrypt.keyWords(ByteArray(0)).all { it == 0 })
        // 72+ bytes: no NUL, cut at 72
        assertTrue(Bcrypt.keyWords(bytes("q".repeat(72))).all { it == 0x71717171 })
        assertTrue(Bcrypt.keyWords(bytes("q".repeat(100))).contentEquals(Bcrypt.keyWords(bytes("q".repeat(72)))))
        // 71 bytes: the NUL is the last byte
        assertEquals(0x71717100, Bcrypt.keyWords(bytes("q".repeat(71)))[17])
        // embedded NUL is an ordinary byte
        assertFalse(Bcrypt.keyWords(bytes("a\u0000b")).contentEquals(Bcrypt.keyWords(bytes("a"))))
    }

    @Test
    fun parseRejectsMalformed() {
        assertNotNull(Bcrypt.parse(SEED))
        val bad = listOf(
            "", SEED.dropLast(1), SEED + "x", SEED.replaceRange(2, 3, "x"), SEED.replaceRange(2, 3, "c"),
            SEED.replaceRange(0, 1, "#"), SEED.replaceRange(1, 2, "3"), SEED.replaceRange(3, 4, "-"),
            SEED.replaceRange(6, 7, "-"), SEED.replaceRange(4, 6, "03"), SEED.replaceRange(4, 6, "32"),
            SEED.replaceRange(4, 6, "1a"), SEED.replaceRange(4, 6, " 9"), SEED.replaceRange(10, 11, "!"),
            SEED.replaceRange(40, 41, "+"), SEED.replaceRange(40, 41, "é"), "\$2b\$10\$" + "a".repeat(52) + "=",
        )
        for (h in bad) assertNull(Bcrypt.parse(h), h)
        for (h in bad) assertFalse(Bcrypt.verify(bytes("password123"), h), h)
        assertEquals(31, Bcrypt.parse(SEED.replaceRange(4, 6, "31"))!!.cost)
        assertEquals(4, Bcrypt.parse(SEED.replaceRange(4, 6, "04"))!!.cost)
    }

    @Test
    fun lanesMatchSingle() {
        // every lane count, lanes holding different passwords and salts (cost 4 vectors), in several groupings
        val v = VECTORS.filter { it.second.substring(4, 6) == "04" }
        for (n in 1..Bcrypt.MAX_LANES) {
            for (start in 0..v.size - n) {
                val group = v.subList(start, start + n)
                val keys = Array(n) { Bcrypt.keyWords(group[it].first) }
                val salts = Array(n) { Bcrypt.parse(group[it].second)!!.salt }
                val outs = Array(n) { ByteArray(24) }
                Bcrypt.hashLanes(n, keys, salts, 4, outs)
                for (i in 0 until n) {
                    assertTrue(Bcrypt.matches(outs[i], Bcrypt.parse(group[i].second)!!.expected), "n=$n lane $i ${group[i].second}")
                }
            }
        }
    }

    @Test
    fun lanesAtCost10() {
        val pws = listOf("password123", "password124", "hunter2", "é🙂")
        val salts = List(4) { i -> ByteArray(16) { (it * 7 + i).toByte() } }
        val single = List(4) { Bcrypt.hash(bytes(pws[it]), salts[it], 10) }
        for (n in 2..4) {
            val outs = Array(n) { ByteArray(24) }
            Bcrypt.hashLanes(n, Array(n) { Bcrypt.keyWords(bytes(pws[it])) }, Array(n) { Bcrypt.saltWords(salts[it]) }, 10, outs)
            for (i in 0 until n) assertEquals(single[i], Bcrypt.format(10, salts[i], outs[i]), "n=$n lane $i")
        }
        // the seed hash in lane 4 of a batch
        val seed = Bcrypt.parse(SEED)!!
        val outs = Array(4) { ByteArray(24) }
        Bcrypt.hashLanes(4, Array(4) { Bcrypt.keyWords(bytes(if (it == 3) "password123" else "nope")) }, Array(4) { seed.salt }, 10, outs)
        assertTrue(Bcrypt.matches(outs[3], seed.expected))
        assertFalse(Bcrypt.matches(outs[0], seed.expected))
    }

    @Test
    fun constantTimeCompare() {
        val a = ByteArray(24) { it.toByte() }
        assertTrue(Bcrypt.matches(a, a.copyOf(23)))
        for (i in 0 until 23) assertFalse(Bcrypt.matches(a, a.copyOf(23).also { it[i] = (it[i] + 1).toByte() }), "byte $i")
        assertTrue(Bcrypt.matches(a.copyOf().also { it[23] = 99 }, a.copyOf(23)), "bcrypt encodes only 23 of the 24 bytes")
    }
}
