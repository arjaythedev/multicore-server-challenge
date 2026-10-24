package conduit.http

import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals

/** The 8-bytes-per-step byte search and head-end scan agree with the obvious byte loops. */
class ParseScanTest {
    private fun naiveIndexOf(b: ByteArray, c: Byte, from: Int, end: Int): Int {
        for (i in from until end) if (b[i] == c) return i
        return -1
    }

    private fun naiveHeadEnd(b: ByteArray, from: Int, end: Int): Int {
        var i = from
        while (i < end) {
            if (b[i] == 10.toByte()) {
                val n = i + 1
                if (n >= end) return -1
                if (b[n] == 10.toByte()) return n + 1
                if (b[n] == 13.toByte()) {
                    if (n + 1 >= end) return -1
                    if (b[n + 1] == 10.toByte()) return n + 2
                }
            }
            i++
        }
        return -1
    }

    @Test
    fun indexOfMatchesTheByteLoop() {
        val r = Random(5)
        for (round in 0 until 3000) {
            val n = r.nextInt(0, 40)
            // few distinct values so matches (and bytes >= 0x80 next to them) are common
            val b = ByteArray(n) { byteArrayOf(10, 13, 32, 44, 0x0B, 0x8A.toByte(), 0xFF.toByte(), 'a'.code.toByte())[r.nextInt(8)] }
            val from = if (n == 0) 0 else r.nextInt(0, n + 1)
            val end = r.nextInt(from, n + 1)
            for (c in byteArrayOf(10, 32, 44, 0x8A.toByte())) {
                assertEquals(naiveIndexOf(b, c, from, end), indexOf(b, c, from, end), "c=$c from=$from end=$end ${b.toList()}")
            }
        }
    }

    @Test
    fun headEndMatchesTheByteLoop() {
        val r = Random(6)
        for (round in 0 until 5000) {
            val n = r.nextInt(0, 48)
            val b = ByteArray(n) { byteArrayOf(10, 13, 'a'.code.toByte(), ':'.code.toByte())[r.nextInt(4)] }
            val from = if (n == 0) 0 else r.nextInt(0, n + 1)
            val end = r.nextInt(from, n + 1)
            assertEquals(naiveHeadEnd(b, from, end), headEnd(b, from, end), "from=$from end=$end ${b.toList()}")
        }
    }
}
