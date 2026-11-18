package conduit.http

// HTTP/1.1 request parsing (RFC 9112), in place over the input bytes. Only the headers the server acts on are
// looked at: Content-Length, Transfer-Encoding, Connection, Expect and Authorization; Host and the rest are skipped.

import conduit.platform.loadLongLE

internal const val MAX_HEAD = 64 * 1024
internal const val MAX_BODY = 1 shl 20

private const val CR: Byte = 13
private const val LF: Byte = 10
private const val SP: Byte = 32
private const val HT: Byte = 9
private const val COLON: Byte = 58
private const val QMARK: Byte = 63
private const val SLASH: Byte = 47

/** Connection handling chosen by the request (see [Ex.connMode]). */
internal const val KEEP = 0       // HTTP/1.1 default
internal const val CLOSE = 1      // Connection: close, or HTTP/1.0 without keep-alive
internal const val KEEP_10 = 2    // HTTP/1.0 with Connection: keep-alive (the response must say so)

// scanChunked results (anything >= 0 is the index just past the chunked body)
internal const val NEED = -1
internal const val BAD = -2
internal const val TOO_BIG = -3

private val CONTENT_LENGTH = "content-length".encodeToByteArray()
private val AUTHORIZATION = "authorization".encodeToByteArray()
private val CONNECTION = "connection".encodeToByteArray()
private val TRANSFER_ENCODING = "transfer-encoding".encodeToByteArray()
private val EXPECT = "expect".encodeToByteArray()
private val ACCEPT_ENCODING = "accept-encoding".encodeToByteArray()
private val GZIP_TOKEN = "gzip".encodeToByteArray()
private val CHUNKED = "chunked".encodeToByteArray()
private val CONTINUE = "100-continue".encodeToByteArray()
private val CLOSE_TOKEN = "close".encodeToByteArray()
private val KEEP_ALIVE = "keep-alive".encodeToByteArray()

private const val ONES = 0x0101010101010101L
private const val HIGHS = -0x7f7f7f7f7f7f7f80L // 0x8080808080808080

/** First index of [c] in b[from, end), or -1. Tests 8 bytes per step (SWAR zero-byte test on x xor c...c). */
internal fun indexOf(b: ByteArray, c: Byte, from: Int, end: Int): Int {
    var i = from
    val pattern = (c.toLong() and 0xFF) * ONES
    while (i + 8 <= end) {
        val x = loadLongLE(b, i) xor pattern
        // the lowest flagged byte is exact (a borrow only flags bytes above a real match); little-endian: lowest
        // byte = lowest address
        val m = (x - ONES) and x.inv() and HIGHS
        if (m != 0L) return i + (m.countTrailingZeroBits() ushr 3)
        i += 8
    }
    while (i < end) {
        if (b[i] == c) return i
        i++
    }
    return -1
}

/**
 * Index just past the empty line that ends a head, looking at LFs from [from] on; -1 if not complete yet.
 * Accepts CRLF and bare LF line ends. A caller resuming a search passes the old end minus 3.
 */
internal fun headEnd(b: ByteArray, from: Int, end: Int): Int {
    var i = from
    while (true) {
        i = indexOf(b, LF, i, end)
        if (i < 0) return -1
        val n = i + 1
        if (n >= end) return -1
        val c = b[n]
        if (c == LF) return n + 1
        if (c == CR) {
            if (n + 1 >= end) return -1
            if (b[n + 1] == LF) return n + 2
        }
        i = n
    }
}

/** [b] at [p] equals the lowercase ASCII [lower], ignoring case. Only for letters and '-'. */
private fun eqLower(b: ByteArray, p: Int, lower: ByteArray): Boolean {
    for (i in lower.indices) if ((b[p + i].toInt() or 0x20) != lower[i].toInt()) return false
    return true
}

private fun eqToken(b: ByteArray, s: Int, e: Int, lower: ByteArray): Boolean =
    e - s == lower.size && eqLower(b, s, lower)

private fun isWs(c: Byte) = c == SP || c == HT

/**
 * An Accept-Encoding value b[s, e) lists gzip without q=0 ("gzip", "gzip, deflate", "br;q=1, gzip;q=0.5"). Other
 * codings and "*" are ignored: we only ever send gzip, and only to clients that name it.
 */
private fun acceptsGzip(b: ByteArray, s0: Int, e: Int): Boolean {
    var s = s0
    while (s < e) {
        var t = indexOf(b, ','.code.toByte(), s, e)
        if (t < 0) t = e
        var ts = s
        while (ts < t && isWs(b[ts])) ts++
        var semi = indexOf(b, ';'.code.toByte(), ts, t)
        if (semi < 0) semi = t
        var te = semi
        while (te > ts && isWs(b[te - 1])) te--
        if (eqToken(b, ts, te, GZIP_TOKEN)) return !qZero(b, semi, t)
        s = t + 1
    }
    return false
}

/** Parameters b[s, e) (";q=0", "; q=0.000") give q = 0. */
private fun qZero(b: ByteArray, s: Int, e: Int): Boolean {
    val q = indexOf(b, '='.code.toByte(), s, e)
    if (q < 0) return false
    var i = q + 1
    while (i < e && isWs(b[i])) i++
    if (i >= e || b[i] != '0'.code.toByte()) return false
    i++
    if (i < e && b[i] == '.'.code.toByte()) {
        i++
        while (i < e && b[i] == '0'.code.toByte()) i++
    }
    while (i < e && isWs(b[i])) i++
    return i == e
}

/**
 * Parses the head b[start, he) (he from [headEnd]) into [ex]: method, path, query, Authorization, body framing,
 * connection mode, Expect. Returns 0, or the error status to answer (400, 413, 417, 501) before closing.
 */
internal fun parseHead(ex: Ex, b: ByteArray, start: Int, he: Int): Int {
    // request-line = method SP request-target SP HTTP-version
    val nl = indexOf(b, LF, start, he)
    var le = nl
    if (le > start && b[le - 1] == CR) le--
    val sp1 = indexOf(b, SP, start, le)
    if (sp1 <= start) return 400
    val m = method(b, start, sp1) ?: return 400
    ex.method = m
    val ts = sp1 + 1
    val sp2 = indexOf(b, SP, ts, le)
    if (sp2 <= ts || le - sp2 != 9) return 400
    val v = sp2 + 1
    if (b[v] != 'H'.code.toByte() || b[v + 1] != 'T'.code.toByte() || b[v + 2] != 'T'.code.toByte() ||
        b[v + 3] != 'P'.code.toByte() || b[v + 4] != SLASH || b[v + 5] != '1'.code.toByte() ||
        b[v + 6] != '.'.code.toByte() || b[v + 7] !in '0'.code.toByte()..'9'.code.toByte()
    ) return 400
    val http10 = b[v + 7] == '0'.code.toByte()
    if (!target(ex, b, ts, sp2)) return 400

    var contentLength = -1L
    var chunked = false
    var close = false
    var keepAlive = false
    var p = nl + 1
    while (p < he) {
        val lineEnd = indexOf(b, LF, p, he)
        var e = lineEnd
        if (e > p && b[e - 1] == CR) e--
        if (e == p) break // the empty line
        if (isWs(b[p])) return 400 // obsolete line folding
        var q = p
        while (q < e && b[q] != COLON) {
            if (b[q] <= SP) return 400 // whitespace, CTL or non-ASCII in a field name
            q++
        }
        if (q == e || q == p) return 400
        var vs = q + 1
        while (vs < e && isWs(b[vs])) vs++
        var ve = e
        while (ve > vs && isWs(b[ve - 1])) ve--
        when (q - p) {
            14 -> if (eqLower(b, p, CONTENT_LENGTH)) {
                val n = digits(b, vs, ve)
                if (n < 0 || (contentLength >= 0 && contentLength != n)) return 400
                contentLength = n
            }
            13 -> if (eqLower(b, p, AUTHORIZATION) && ex.authBuf == null) { // the first one counts
                ex.authBuf = b // zero-copy; [EngineCore] copies it if the request waits for its body
                ex.authOff = vs
                ex.authLen = ve - vs
            }
            10 -> if (eqLower(b, p, CONNECTION)) {
                var s = vs
                while (s < ve) {
                    var t = indexOf(b, ','.code.toByte(), s, ve)
                    if (t < 0) t = ve
                    var ts2 = s
                    var te = t
                    while (ts2 < te && isWs(b[ts2])) ts2++
                    while (te > ts2 && isWs(b[te - 1])) te--
                    if (eqToken(b, ts2, te, CLOSE_TOKEN)) close = true
                    else if (eqToken(b, ts2, te, KEEP_ALIVE)) keepAlive = true
                    s = t + 1
                }
            }
            17 -> if (eqLower(b, p, TRANSFER_ENCODING)) {
                if (chunked) return 400 // "chunked" applied twice
                if (!eqToken(b, vs, ve, CHUNKED)) return 501
                chunked = true
            }
            6 -> if (eqLower(b, p, EXPECT)) {
                if (!eqToken(b, vs, ve, CONTINUE)) return 417
                ex.expect = true
            }
            15 -> if (eqLower(b, p, ACCEPT_ENCODING)) ex.acceptGzip = acceptsGzip(b, vs, ve)
        }
        p = lineEnd + 1
    }
    if (chunked && (contentLength >= 0 || http10)) return 400 // request smuggling shapes
    if (contentLength > MAX_BODY) return 413
    ex.chunked = chunked
    ex.bodyLen = if (contentLength > 0) contentLength.toInt() else 0
    if (!chunked && ex.bodyLen == 0) ex.expect = false // nothing to wait for
    ex.connMode = when {
        close -> CLOSE
        http10 -> if (keepAlive) KEEP_10 else CLOSE
        else -> KEEP
    }
    return 0
}

private fun method(b: ByteArray, s: Int, e: Int): Method? {
    val c0 = b[s].toInt()
    when (e - s) {
        3 -> if (b[s + 2] == 'T'.code.toByte()) {
            if (c0 == 'G'.code && b[s + 1] == 'E'.code.toByte()) return Method.GET
            if (c0 == 'P'.code && b[s + 1] == 'U'.code.toByte()) return Method.PUT
        }
        4 -> if (c0 == 'P'.code && b[s + 1] == 'O'.code.toByte() && b[s + 2] == 'S'.code.toByte() &&
            b[s + 3] == 'T'.code.toByte()
        ) return Method.POST
        6 -> if (c0 == 'D'.code && b[s + 1] == 'E'.code.toByte() && b[s + 2] == 'L'.code.toByte() &&
            b[s + 3] == 'E'.code.toByte() && b[s + 4] == 'T'.code.toByte() && b[s + 5] == 'E'.code.toByte()
        ) return Method.DELETE
    }
    for (i in s until e) if (b[i] <= SP || b[i] == 127.toByte()) return null
    return Method.OTHER
}

/** Splits the request-target b[s, e) into path and raw query (origin-form; absolute-form and "*" tolerated). */
private fun target(ex: Ex, b: ByteArray, s0: Int, e: Int): Boolean {
    var s = s0
    if (b[s] != SLASH) {
        if (e - s == 1 && b[s] == '*'.code.toByte()) {
            ex.path = "*"
            return true
        }
        // absolute-form: scheme "://" authority [ path-abempty ] [ "?" query ]
        var i = s
        while (i + 2 < e && !(b[i] == COLON && b[i + 1] == SLASH && b[i + 2] == SLASH)) i++
        if (i + 2 >= e || i == s) return false
        i += 3
        while (i < e && b[i] != SLASH && b[i] != QMARK) i++
        if (i == e || b[i] == QMARK) {
            ex.path = "/"
            if (i < e) ex.query = b.decodeToString(i + 1, e)
            return true
        }
        s = i
    }
    var q = -1
    for (i in s until e) {
        val c = b[i]
        if (c < SP || c == 127.toByte()) return false // CTLs (SP itself cannot occur here)
        if (c == QMARK && q < 0) q = i
    }
    if (q < 0) {
        ex.path = b.decodeToString(s, e)
    } else {
        ex.path = b.decodeToString(s, q)
        ex.query = b.decodeToString(q + 1, e)
    }
    return true
}

/** Strict decimal (digits only, at least one); saturates above [MAX_BODY]. -1 if malformed. */
private fun digits(b: ByteArray, s: Int, e: Int): Long {
    if (s == e) return -1
    var v = 0L
    for (i in s until e) {
        val d = b[i] - '0'.code.toByte()
        if (d < 0 || d > 9) return -1
        if (v <= MAX_BODY) v = v * 10 + d
    }
    return v
}

private fun hex(c: Byte): Int {
    val x = c.toInt()
    return when (x) {
        in '0'.code..'9'.code -> x - '0'.code
        in 'a'.code..'f'.code -> x - 'a'.code + 10
        in 'A'.code..'F'.code -> x - 'A'.code + 10
        else -> -1
    }
}

private const val MAX_CHUNK_LINE = 4096

/**
 * Validates a chunked body starting at [base] in b[.., end), resuming at cs.scan (relative to base) with
 * cs.chunkTotal bytes decoded so far; progress is saved after every complete chunk, so bytes trickling in are not
 * rescanned. Returns the index just past the body (last chunk + trailers), or [NEED], [BAD], [TOO_BIG].
 */
internal fun scanChunked(cs: ConnState, b: ByteArray, base: Int, end: Int): Int {
    var p = base + cs.scan
    var total = cs.chunkTotal
    while (true) {
        // chunk-size [ chunk-ext ] CRLF
        var q = p
        var size = 0
        while (q < end) {
            val h = hex(b[q])
            if (h < 0) break
            size = size * 16 + h
            if (size > MAX_BODY) return TOO_BIG
            q++
        }
        if (q == end) return NEED
        if (q == p) return BAD
        while (q < end && b[q] != LF) {
            if (q - p > MAX_CHUNK_LINE) return BAD
            q++
        }
        if (q == end) return NEED
        q++
        if (size == 0) {
            // trailer section (ignored): field lines up to an empty line
            val ts = q
            while (true) {
                val nl = indexOf(b, LF, q, end)
                if (nl < 0) return if (end - ts > MAX_HEAD) BAD else NEED
                val empty = nl == q || (nl == q + 1 && b[q] == CR)
                q = nl + 1
                if (empty) return q
                if (q - ts > MAX_HEAD) return BAD
            }
        }
        val after = q + size
        if (after >= end) return NEED
        p = when (b[after]) {
            CR -> {
                if (after + 1 >= end) return NEED
                if (b[after + 1] != LF) return BAD
                after + 2
            }
            LF -> after + 1
            else -> return BAD
        }
        total += size
        if (total > MAX_BODY) return TOO_BIG
        cs.scan = p - base
        cs.chunkTotal = total
    }
}

/** Decodes a chunked body that [scanChunked] accepted (starting at [base], [total] data bytes). */
internal fun decodeChunked(b: ByteArray, base: Int, total: Int): ByteArray {
    val out = ByteArray(total)
    var w = 0
    var p = base
    while (true) {
        var size = 0
        while (true) {
            val h = hex(b[p])
            if (h < 0) break
            size = size * 16 + h
            p++
        }
        while (b[p] != LF) p++
        p++
        if (size == 0) return out
        b.copyInto(out, w, p, p + size)
        w += size
        p += size
        p += if (b[p] == CR) 2 else 1
    }
}
