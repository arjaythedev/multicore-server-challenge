package conduit.http

import conduit.util.ByteBuf
import java.util.zip.CRC32
import java.util.zip.Deflater

/** Per-thread compressor (raw deflate, fastest level) and checksum: responses are rendered on many threads. */
private class GzipState {
    val deflater = Deflater(Deflater.BEST_SPEED, true)
    val crc = CRC32()
}

private val state = ThreadLocal.withInitial { GzipState() }

private val HEADER = byteArrayOf(0x1f, 0x8b.toByte(), 8, 0, 0, 0, 0, 0, 0, 3) // deflate, no name/time, OS unix

actual fun gzip(src: ByteArray, off: Int, len: Int, dst: ByteBuf): Boolean {
    val s = state.get()
    val d = s.deflater
    try {
        dst.put(HEADER)
        d.reset()
        d.setInput(src, off, len)
        d.finish()
        while (!d.finished()) {
            dst.ensure(len / 2 + 64)
            val n = d.deflate(dst.buf, dst.len, dst.buf.size - dst.len)
            dst.len += n
            if (dst.len - len > 1024) return false // not shrinking: give up early
        }
        s.crc.reset()
        s.crc.update(src, off, len)
        putIntLE(dst, s.crc.value.toInt())
        putIntLE(dst, len)
        return true
    } catch (_: Exception) {
        return false
    }
}

private fun putIntLE(dst: ByteBuf, v: Int) {
    dst.put(v and 0xFF)
    dst.put((v ushr 8) and 0xFF)
    dst.put((v ushr 16) and 0xFF)
    dst.put((v ushr 24) and 0xFF)
}
