package conduit.auth

import kotlin.coroutines.Continuation
import kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED
import kotlin.coroutines.intrinsics.suspendCoroutineUninterceptedOrReturn
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.jvm.JvmField
import conduit.crypto.Bcrypt
import conduit.json.JsonReader
import conduit.json.JsonValue
import conduit.platform.HmacSha256
import conduit.platform.Monitor
import conduit.platform.Scratch
import conduit.platform.nanoTime
import conduit.platform.secureRandomBytes
import conduit.platform.startThread
import conduit.platform.threadScratch

/** JWT HS256 with the claims the spec requires: {"sub":"<id>","iat":<now>,"exp":<now+30d>}. No caching (rule 7). */
object Jwt {
    /** base64url of {"alg":"HS256","typ":"JWT"}: what we, the loadgen and golang-jwt all send. */
    private const val HEADER = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
    private val HEADER_BYTES = HEADER.encodeToByteArray()
    private const val TTL = 30L * 24 * 3600

    /** Longest token accepted; the token's bytes and its decoded payload share [Scratch.tmp]. */
    private const val MAX_TOKEN = 2048

    /** 32 bytes of HMAC-SHA256 are 43 base64url characters (no padding). */
    private const val SIG_CHARS = 43

    private const val URL64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    private val DECODE = IntArray(128) { -1 }.also { t -> for (i in URL64.indices) t[URL64[i].code] = i }

    private var key: ByteArray? = null

    /** Must be called once at startup with JWT_SECRET. */
    fun init(secret: String) {
        key = secret.encodeToByteArray()
        threadScratch().jwtMac = null // (tests re-init on one thread; other threads' MACs are created after init)
    }

    /** This thread's HMAC keyed with the secret (key setup once per thread, never per token). */
    private fun hmac(s: Scratch): HmacSha256 =
        s.jwtMac ?: HmacSha256(checkNotNull(key) { "Jwt.init not called" }).also { s.jwtMac = it }

    /** A fresh token for [userId], issued at [nowSec] (Unix seconds), expiring 30 days later. */
    fun sign(userId: Long, nowSec: Long): String {
        val payload = "{\"sub\":\"$userId\",\"iat\":$nowSec,\"exp\":${nowSec + TTL}}".encodeToByteArray()
        val sb = StringBuilder(64 + payload.size * 2)
        sb.append(HEADER).append('.')
        encode(payload, payload.size, sb)
        val signed = sb.toString().encodeToByteArray()
        val s = threadScratch()
        hmac(s).mac(signed, 0, signed.size, s.mac, 0)
        sb.append('.')
        encode(s.mac, 32, sb)
        return sb.toString()
    }

    /**
     * Verifies signature (HS256, constant-time compare), header alg == "HS256" (any other alg, including "none",
     * is rejected), `exp` > [nowSec], and `sub` = decimal user id string > 0. Returns the user id, or 0 if invalid.
     *
     * Exactly three base64url segments; the signature must decode to 32 bytes and is checked first, so nothing
     * unauthenticated is parsed. `iat`/`nbf` are not checked (like the reference: clients' clocks may be ahead).
     * Uses this thread's [Scratch.tmp] and [Scratch.mac].
     */
    fun verify(token: String, nowSec: Long): Long {
        val n = token.length
        if (n < 3 + SIG_CHARS || n > MAX_TOKEN) return 0
        val s = threadScratch()
        val t = s.tmp
        var d1 = -1
        var d2 = -1
        for (i in 0 until n) {
            val c = token[i].code
            if (c == '.'.code) {
                if (d1 < 0) d1 = i else if (d2 < 0) d2 = i else return 0
            } else if (c >= 128 || DECODE[c] < 0) {
                return 0
            }
            t[i] = c.toByte()
        }
        if (d1 < 1 || d2 < d1 + 2 || n - d2 - 1 != SIG_CHARS) return 0
        val mac = s.mac
        hmac(s).mac(t, 0, d2, mac, 0)
        if (!signatureMatches(t, d2 + 1, mac)) return 0
        if (!(d1 == HEADER.length && sameBytes(t, 0, HEADER_BYTES)) && !headerIsHs256(t, d1)) return 0
        val plen = decode(t, d1 + 1, d2, t, MAX_TOKEN)
        if (plen < 0) return 0
        return claims(t, MAX_TOKEN, MAX_TOKEN + plen, nowSec)
    }

    /** Decodes 43 chars at t[p] (all valid base64url) and compares them with [mac] without an early exit. */
    private fun signatureMatches(t: ByteArray, p: Int, mac: ByteArray): Boolean {
        var diff = 0
        var i = p
        var o = 0
        while (o < 30) {
            val v = (DECODE[t[i].toInt()] shl 18) or (DECODE[t[i + 1].toInt()] shl 12) or
                (DECODE[t[i + 2].toInt()] shl 6) or DECODE[t[i + 3].toInt()]
            diff = diff or (((v ushr 16) xor mac[o].toInt()) and 0xff) or
                (((v ushr 8) xor mac[o + 1].toInt()) and 0xff) or ((v xor mac[o + 2].toInt()) and 0xff)
            i += 4
            o += 3
        }
        // 3 chars = 18 bits: 2 bytes + 2 unused bits (ignored, as Go's non-strict base64 does)
        val v = (DECODE[t[i].toInt()] shl 12) or (DECODE[t[i + 1].toInt()] shl 6) or DECODE[t[i + 2].toInt()]
        diff = diff or (((v ushr 10) xor mac[30].toInt()) and 0xff) or (((v ushr 2) xor mac[31].toInt()) and 0xff)
        return diff == 0
    }

    private fun sameBytes(t: ByteArray, off: Int, expect: ByteArray): Boolean {
        for (i in expect.indices) if (t[off + i] != expect[i]) return false
        return true
    }

    /** Any other header encoding (key order, whitespace, extra fields): parsed, alg must be "HS256". */
    private fun headerIsHs256(t: ByteArray, end: Int): Boolean {
        val h = ByteArray(end * 3 / 4 + 3)
        val len = decode(t, 0, end, h, 0)
        if (len < 0) return false
        val v = JsonReader.parse(h, 0, len) as? JsonValue.Obj ?: return false
        return (v["alg"] as? JsonValue.Str)?.value == "HS256"
    }

    /**
     * Claims at b[p, end): fast scan of a flat object of ASCII strings, numbers and literals (what every client
     * sends); anything else (escapes, non-ASCII, nesting) goes through [JsonReader] with the same rules.
     * Duplicate keys: the last one wins (as in Go).
     */
    private fun claims(b: ByteArray, start: Int, end: Int, nowSec: Long): Long {
        var sub = 0L // 0 = missing or invalid
        var expOk = false
        var p = ws(b, start, end)
        if (p >= end || b[p] != '{'.code.toByte()) return 0
        p = ws(b, p + 1, end)
        if (p < end && b[p] == '}'.code.toByte()) return 0 // {} has no sub
        while (true) {
            if (p >= end || b[p] != '"'.code.toByte()) return 0
            val k = p + 1
            p = plainString(b, k, end)
            if (p < 0) return slowClaims(b, start, end, nowSec)
            val kLen = p - k
            p = ws(b, p + 1, end)
            if (p >= end || b[p] != ':'.code.toByte()) return 0
            p = ws(b, p + 1, end)
            if (p >= end) return 0
            val isSub = kLen == 3 && b[k] == 's'.code.toByte() && b[k + 1] == 'u'.code.toByte() &&
                b[k + 2] == 'b'.code.toByte()
            val isExp = kLen == 3 && b[k] == 'e'.code.toByte() && b[k + 1] == 'x'.code.toByte() &&
                b[k + 2] == 'p'.code.toByte()
            val c = b[p].toInt()
            when {
                c == '"'.code -> {
                    val v = p + 1
                    p = plainString(b, v, end)
                    if (p < 0) return slowClaims(b, start, end, nowSec)
                    if (isSub) sub = userId(b, v, p)
                    if (isExp) expOk = false
                    p++
                }
                c == '-'.code || (c >= '0'.code && c <= '9'.code) -> {
                    val e = numberEnd(b, p, end)
                    if (e < 0) return 0
                    if (isSub) sub = 0
                    if (isExp) expOk = expAfter(b, p, e, nowSec)
                    p = e
                }
                c == 't'.code || c == 'f'.code || c == 'n'.code -> {
                    val e = literalEnd(b, p, end)
                    if (e < 0) return 0
                    if (isSub) sub = 0
                    if (isExp) expOk = false
                    p = e
                }
                c == '{'.code || c == '['.code -> return slowClaims(b, start, end, nowSec)
                else -> return 0
            }
            p = ws(b, p, end)
            if (p >= end) return 0
            val sep = b[p++]
            if (sep == '}'.code.toByte()) break
            if (sep != ','.code.toByte()) return 0
            p = ws(b, p, end)
        }
        if (ws(b, p, end) != end) return 0
        return if (expOk) sub else 0
    }

    private fun slowClaims(b: ByteArray, start: Int, end: Int, nowSec: Long): Long {
        val o = JsonReader.parse(b, start, end - start) as? JsonValue.Obj ?: return 0
        val exp = o["exp"] as? JsonValue.Num ?: return 0
        val sub = o["sub"] as? JsonValue.Str ?: return 0
        val e = exp.text.encodeToByteArray()
        if (!expAfter(e, 0, e.size, nowSec)) return 0
        val s = sub.value.encodeToByteArray()
        return userId(s, 0, s.size)
    }

    private fun ws(b: ByteArray, from: Int, end: Int): Int {
        var p = from
        while (p < end) {
            val c = b[p].toInt()
            if (c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09) p++ else break
        }
        return p
    }

    /** From after an opening quote: the index of the closing quote, or -1 if not plain printable ASCII. */
    private fun plainString(b: ByteArray, from: Int, end: Int): Int {
        var p = from
        while (p < end) {
            val c = b[p].toInt()
            if (c == '"'.code) return p
            if (c < 0x20 || c == '\\'.code) return -1 // control (invalid) or escape: let JsonReader decide
            p++
        }
        return -1
    }

    /** JSON number syntax from [from]; the index after it, or -1. */
    private fun numberEnd(b: ByteArray, from: Int, end: Int): Int {
        var p = from
        if (b[p] == '-'.code.toByte()) p++
        if (p >= end) return -1
        if (b[p] == '0'.code.toByte()) {
            p++
        } else {
            val d = p
            while (p < end && isDigit(b[p])) p++
            if (p == d) return -1
        }
        if (p < end && b[p] == '.'.code.toByte()) {
            val d = ++p
            while (p < end && isDigit(b[p])) p++
            if (p == d) return -1
        }
        if (p < end && (b[p] == 'e'.code.toByte() || b[p] == 'E'.code.toByte())) {
            p++
            if (p < end && (b[p] == '+'.code.toByte() || b[p] == '-'.code.toByte())) p++
            val d = p
            while (p < end && isDigit(b[p])) p++
            if (p == d) return -1
        }
        return p
    }

    private fun literalEnd(b: ByteArray, from: Int, end: Int): Int {
        val word = when (b[from].toInt()) {
            't'.code -> "true"
            'f'.code -> "false"
            else -> "null"
        }
        if (end - from < word.length) return -1
        for (i in word.indices) if (b[from + i].toInt() != word[i].code) return -1
        return from + word.length
    }

    private fun isDigit(c: Byte) = c >= '0'.code.toByte() && c <= '9'.code.toByte()

    /** The number b[from, end) (valid JSON syntax) is a time after [nowSec]. */
    private fun expAfter(b: ByteArray, from: Int, end: Int, nowSec: Long): Boolean {
        var p = from
        val neg = b[p] == '-'.code.toByte()
        if (neg) p++
        var v = 0L
        var digits = 0
        while (p < end && isDigit(b[p])) {
            if (digits < 18) v = v * 10 + (b[p] - '0'.code.toByte())
            digits++
            p++
        }
        if (p == end) { // an integer, the usual case
            if (digits > 18) return !neg // beyond 10^18 s: far future or far past
            return !neg && v > nowSec
        }
        val d = b.decodeToString(from, end).toDouble() // fraction or exponent: rare
        return d.isFinite() && d > nowSec.toDouble()
    }

    /** 1..18 decimal digits with a value > 0 (leading zeros allowed, as Go's ParseInt does); else 0. */
    private fun userId(b: ByteArray, from: Int, end: Int): Long {
        val n = end - from
        if (n < 1 || n > 18) return 0
        var v = 0L
        for (p in from until end) {
            val c = b[p]
            if (!isDigit(c)) return 0
            v = v * 10 + (c - '0'.code.toByte())
        }
        return v
    }

    /** base64url without padding. */
    private fun encode(d: ByteArray, len: Int, sb: StringBuilder) {
        var i = 0
        while (i + 3 <= len) {
            val v = ((d[i].toInt() and 0xff) shl 16) or ((d[i + 1].toInt() and 0xff) shl 8) or (d[i + 2].toInt() and 0xff)
            sb.append(URL64[v ushr 18]).append(URL64[(v ushr 12) and 63]).append(URL64[(v ushr 6) and 63])
                .append(URL64[v and 63])
            i += 3
        }
        when (len - i) {
            1 -> {
                val v = d[i].toInt() and 0xff
                sb.append(URL64[v ushr 2]).append(URL64[(v and 3) shl 4])
            }
            2 -> {
                val v = ((d[i].toInt() and 0xff) shl 8) or (d[i + 1].toInt() and 0xff)
                sb.append(URL64[v ushr 10]).append(URL64[(v ushr 4) and 63]).append(URL64[(v and 15) shl 2])
            }
        }
    }

    /**
     * Decodes base64url (no padding; every char already checked to be in the alphabet) from src[from, to) into
     * dst[dOff..]. Returns the byte count, or -1 for an impossible length.
     */
    private fun decode(src: ByteArray, from: Int, to: Int, dst: ByteArray, dOff: Int): Int {
        val n = to - from
        if (n % 4 == 1) return -1
        var i = from
        var o = dOff
        while (i + 4 <= to) {
            val v = (DECODE[src[i].toInt()] shl 18) or (DECODE[src[i + 1].toInt()] shl 12) or
                (DECODE[src[i + 2].toInt()] shl 6) or DECODE[src[i + 3].toInt()]
            dst[o] = (v ushr 16).toByte()
            dst[o + 1] = (v ushr 8).toByte()
            dst[o + 2] = v.toByte()
            i += 4
            o += 3
        }
        when (to - i) {
            2 -> {
                val v = (DECODE[src[i].toInt()] shl 6) or DECODE[src[i + 1].toInt()]
                dst[o++] = (v ushr 4).toByte()
            }
            3 -> {
                val v = (DECODE[src[i].toInt()] shl 12) or (DECODE[src[i + 1].toInt()] shl 6) or DECODE[src[i + 2].toInt()]
                dst[o++] = (v ushr 10).toByte()
                dst[o++] = (v ushr 2).toByte()
            }
        }
        return o - dOff
    }
}

/**
 * bcrypt cost 10 (rule 7), run on a small pool of low-priority threads so logins never take CPU from requests.
 * Several queued jobs are computed together with interleaved lanes (bcrypt's S-box lookups are latency-bound,
 * so 2-4 independent hashes in one loop run in about the time of one).
 */
object Passwords {
    /** Cost of every new hash (rule 7). */
    const val COST = 10

    /** One hash or verify. [cost] < 0: the stored hash did not parse (answered false, no hashing). */
    private class Job(
        @JvmField val key: IntArray,
        @JvmField val salt: IntArray,
        @JvmField val cost: Int,
        /** Raw salt for formatting a new hash; null for a verify. */
        @JvmField val saltBytes: ByteArray?,
        /** The stored 23 bytes for a verify; null for a new hash. */
        @JvmField val expected: ByteArray?,
        /** When the batch window for this job closes (nanoTime). */
        @JvmField val due: Long,
    ) {
        @JvmField val out = ByteArray(24)
        @JvmField var onHash: Continuation<String>? = null
        @JvmField var onVerify: Continuation<Boolean>? = null
    }

    private val lock = Monitor()
    private val queue = ArrayList<Job>()
    /** A worker is waiting for its batch to fill; the others take only full batches meanwhile. */
    private var gathering = false
    private var windowNanos = 0L
    private var started = false

    /** Starts [threads] bcrypt workers. [batchWindowMs]: how long a worker waits to collect lanes before starting. */
    fun start(threads: Int, batchWindowMs: Long) {
        lock.lock()
        try {
            if (started) return // (tests may call it more than once)
            started = true
            windowNanos = batchWindowMs * 1_000_000
        } finally {
            lock.unlock()
        }
        for (i in 0 until maxOf(1, threads)) startThread("bcrypt-$i", nice = 10) { worker(warm = i == 0) }
    }

    /** A new "$2b$10$..." hash with a fresh 16-byte random salt. Always suspends; resumes on a bcrypt thread. */
    suspend fun hash(password: String): String {
        val salt = ByteArray(16)
        secureRandomBytes(salt)
        val job = Job(
            Bcrypt.keyWords(password.encodeToByteArray()), Bcrypt.saltWords(salt), COST, salt, null,
            nanoTime() + windowNanos,
        )
        return suspendCoroutineUninterceptedOrReturn { c ->
            job.onHash = c
            enqueue(job)
            COROUTINE_SUSPENDED
        }
    }

    /** Verifies [password] against a stored $2a/$2b/$2y hash. Always suspends; resumes on a bcrypt thread. */
    suspend fun verify(password: String, hash: String): Boolean {
        val s = Bcrypt.parse(hash)
        val now = nanoTime()
        val job = if (s == null) {
            Job(EMPTY_KEY, EMPTY_SALT, -1, null, null, now) // due at once: nothing to batch
        } else {
            Job(Bcrypt.keyWords(password.encodeToByteArray()), s.salt, s.cost, null, s.expected, now + windowNanos)
        }
        return suspendCoroutineUninterceptedOrReturn { c ->
            job.onVerify = c
            enqueue(job)
            COROUTINE_SUSPENDED
        }
    }

    private val EMPTY_KEY = IntArray(18)
    private val EMPTY_SALT = IntArray(4)

    private fun enqueue(job: Job) {
        lock.lock()
        try {
            queue.add(job)
            lock.signalAll() // wakes the gatherer (batch may be full now) and idle workers
        } finally {
            lock.unlock()
        }
    }

    private fun worker(warm: Boolean) {
        if (warm) warmUp()
        val batch = arrayOfNulls<Job>(Bcrypt.MAX_LANES)
        while (true) {
            val n = take(batch)
            try {
                run(batch, n)
            } catch (t: Throwable) {
                println("bcrypt worker: $t")
            }
            batch.fill(null)
        }
    }

    /**
     * Blocks until a batch is ready: up to [Bcrypt.MAX_LANES] jobs of the oldest job's cost, taken once the batch is
     * full or the oldest job is due. One worker gathers at a time; the others take only full batches meanwhile.
     */
    private fun take(batch: Array<Job?>): Int {
        val max = Bcrypt.MAX_LANES
        lock.lock()
        try {
            while (true) {
                if (queue.isEmpty() || (gathering && queue.size < max)) {
                    lock.await()
                    continue
                }
                if (queue.size < max) {
                    gathering = true
                    try {
                        while (queue.isNotEmpty() && queue.size < max) {
                            val wait = queue[0].due - nanoTime()
                            if (wait <= 0) break
                            lock.awaitNanos(wait)
                        }
                    } finally {
                        gathering = false
                    }
                    if (queue.isEmpty()) continue // a full batch was taken by another worker meanwhile
                }
                val cost = queue[0].cost
                var n = 0
                var i = 0
                while (i < queue.size && n < max) {
                    val j = queue[i]
                    if (j.cost == cost) {
                        batch[n++] = j
                        queue.removeAt(i)
                    } else {
                        i++
                    }
                }
                lock.signalAll() // leftovers need a new gatherer
                return n
            }
        } finally {
            lock.unlock()
        }
    }

    /** Computes the batch's lanes, then resumes every caller on this thread. */
    private fun run(batch: Array<Job?>, n: Int) {
        val first = batch[0]!!
        var failure: Throwable? = null
        if (first.cost >= 0) {
            try {
                val keys = Array(n) { batch[it]!!.key }
                val salts = Array(n) { batch[it]!!.salt }
                val outs = Array(n) { batch[it]!!.out }
                Bcrypt.hashLanes(n, keys, salts, first.cost, outs)
            } catch (t: Throwable) {
                failure = t
            }
        }
        for (i in 0 until n) {
            val j = batch[i]!!
            try {
                val h = j.onHash
                val v = j.onVerify
                if (failure != null) {
                    h?.resumeWithException(failure)
                    v?.resumeWithException(failure)
                } else if (h != null) {
                    h.resume(Bcrypt.format(j.cost, j.saltBytes!!, j.out))
                } else if (v != null) {
                    v.resume(j.cost >= 0 && Bcrypt.matches(j.out, j.expected!!))
                }
            } catch (t: Throwable) {
                println("bcrypt: resumed handler threw: $t") // must not kill the worker or skip other lanes
            }
        }
    }

    /**
     * JIT warm-up on the first worker (pointless but cheap on Native, ~0.3 s once): runs every lane count often
     * enough at cost 0 (2 rounds) for a full C2 compile, so the first logins neither run interpreted nor in a
     * half-compiled OSR loop (cold first hashes measured ~80 ms instead of ~49). Checks every lane's result too.
     */
    private fun warmUp() {
        val key = Bcrypt.keyWords("warm-up".encodeToByteArray())
        val salt = Bcrypt.saltWords(ByteArray(16) { it.toByte() })
        val ref = ByteArray(24)
        Bcrypt.hashLanes(1, arrayOf(key), arrayOf(salt), 0, arrayOf(ref))
        for (n in 1..Bcrypt.MAX_LANES) {
            val keys = Array(n) { key }
            val salts = Array(n) { salt }
            val outs = Array(n) { ByteArray(24) }
            repeat(warmUpCalls) { Bcrypt.hashLanes(n, keys, salts, 0, outs) }
            for (o in outs) if (!o.contentEquals(ref)) println("bcrypt: SELF-TEST FAILED for $n lanes")
        }
    }

    /** Calls per lane count: C2 compiles a method normally after ~600 invocations (tests set it lower). */
    internal var warmUpCalls = 700
}
