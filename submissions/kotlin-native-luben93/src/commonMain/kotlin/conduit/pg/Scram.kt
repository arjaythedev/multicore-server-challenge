package conduit.pg

import conduit.platform.HmacSha256
import conduit.platform.secureRandomBytes
import conduit.platform.sha256
import kotlin.io.encoding.Base64

/**
 * SCRAM-SHA-256 client (RFC 5802 / RFC 7677) as Postgres speaks it: no channel binding ("n,,", c=biws) and no
 * SASLprep. Postgres ignores the SCRAM user name (it uses the startup packet's), so [user] is empty except in tests
 * against the RFC vectors.
 */
internal class Scram(private val password: String, nonce: String? = null, user: String = "") {
    val clientNonce: String = nonce ?: ByteArray(18).also { secureRandomBytes(it) }.let { Base64.encode(it) }
    private val clientFirstBare = "n=$user,r=$clientNonce"

    /** The SASLInitialResponse payload. */
    val clientFirst: String = "n,,$clientFirstBare"

    private var serverSignature: ByteArray? = null

    /** The SASLResponse payload (client-final-message) for the server's SASLContinue payload. */
    fun clientFinal(serverFirst: String): String {
        var r: String? = null
        var s: String? = null
        var i = 0
        for (part in serverFirst.split(',')) {
            when {
                part.startsWith("r=") -> r = part.substring(2)
                part.startsWith("s=") -> s = part.substring(2)
                part.startsWith("i=") -> i = part.substring(2).toIntOrNull() ?: 0
            }
        }
        check(r != null && r.startsWith(clientNonce) && r.length > clientNonce.length) { "SCRAM: bad server nonce" }
        check(s != null && i > 0) { "SCRAM: bad server-first-message" }
        check(password.isNotEmpty()) { "SCRAM: empty password" }
        val salted = pbkdf2(password.encodeToByteArray(), Base64.decode(s), i)
        val clientKey = hmac(salted, "Client Key".encodeToByteArray())
        val storedKey = sha256(clientKey)
        val withoutProof = "c=biws,r=$r"
        val authMessage = "$clientFirstBare,$serverFirst,$withoutProof".encodeToByteArray()
        val clientSignature = hmac(storedKey, authMessage)
        val proof = ByteArray(32) { (clientKey[it].toInt() xor clientSignature[it].toInt()).toByte() }
        serverSignature = hmac(hmac(salted, "Server Key".encodeToByteArray()), authMessage)
        return "$withoutProof,p=${Base64.encode(proof)}"
    }

    /** Checks the SASLFinal payload ("v=<server signature>"): proves the server knew the password too. */
    fun verifyServerFinal(serverFinal: String) {
        check(!serverFinal.startsWith("e=")) { "SCRAM: server error ${serverFinal.substring(2)}" }
        check(serverFinal.startsWith("v=")) { "SCRAM: bad server-final-message" }
        val expected = checkNotNull(serverSignature) { "SCRAM: server-final before server-first" }
        val got = Base64.decode(serverFinal.substring(2).substringBefore(','))
        var diff = got.size xor expected.size
        for (k in 0 until minOf(got.size, expected.size)) diff = diff or (got[k].toInt() xor expected[k].toInt())
        check(diff == 0) { "SCRAM: server signature mismatch" }
    }

    companion object {
        fun hmac(key: ByteArray, data: ByteArray): ByteArray {
            val out = ByteArray(32)
            HmacSha256(key).mac(data, 0, data.size, out, 0)
            return out
        }

        /** PBKDF2-HMAC-SHA256 with a 32-byte output (one block), the SCRAM `Hi` function. */
        fun pbkdf2(password: ByteArray, salt: ByteArray, iterations: Int): ByteArray {
            val mac = HmacSha256(password)
            val first = salt + byteArrayOf(0, 0, 0, 1)
            var u = ByteArray(32)
            var next = ByteArray(32)
            mac.mac(first, 0, first.size, u, 0)
            val t = u.copyOf()
            for (n in 1 until iterations) {
                mac.mac(u, 0, 32, next, 0)
                val swap = u
                u = next
                next = swap
                for (j in 0 until 32) t[j] = (t[j].toInt() xor u[j].toInt()).toByte()
            }
            return t
        }
    }
}
