package conduit.pg

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class PgAuthTest {
    @Test
    fun md5Vectors() {
        assertEquals("d41d8cd98f00b204e9800998ecf8427e", Md5.hex(Md5.digest(ByteArray(0))))
        assertEquals("900150983cd24fb0d6963f7d28e17f72", Md5.hex(Md5.digest("abc".encodeToByteArray())))
        assertEquals(
            "57edf4a22be3c955ac49da2e2107b67a",
            Md5.hex(Md5.digest("1234567890".repeat(8).encodeToByteArray())), // 80 bytes: two blocks
        )
        // what libpq sends for user "postgres", password "secret", salt 01 02 03 04 (computed with Python's hashlib)
        assertEquals("md5bb41a296aab6baccb36ff243a562abff", Md5.password("postgres", "secret", byteArrayOf(1, 2, 3, 4)))
    }

    @Test
    fun pbkdf2Vector() {
        // RFC 7914 section 11: PBKDF2-HMAC-SHA256, P="passwd", S="salt", c=1 (first 32 bytes)
        assertEquals(
            "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc",
            Md5.hex(Scram.pbkdf2("passwd".encodeToByteArray(), "salt".encodeToByteArray(), 1)),
        )
        // RFC 7677's SaltedPassword is checked through the full exchange below (4096 iterations)
    }

    @Test
    fun scramRfc7677() {
        val s = Scram("pencil", nonce = "rOprNGfwEbeRWgbNEkqO", user = "user")
        assertEquals("n,,n=user,r=rOprNGfwEbeRWgbNEkqO", s.clientFirst)
        val fin = s.clientFinal("r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF\$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096")
        assertEquals(
            "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF\$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=",
            fin,
        )
        s.verifyServerFinal("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=")
        assertFailsWith<IllegalStateException> {
            s.verifyServerFinal("v=AAAATRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=")
        }
    }

    @Test
    fun scramRejectsForeignNonce() {
        val s = Scram("pencil", nonce = "abc")
        assertFailsWith<IllegalStateException> { s.clientFinal("r=xyz123,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096") }
    }
}
