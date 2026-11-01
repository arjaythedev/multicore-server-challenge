package conduit.platform

// The only platform-specific surface. Everything else (HTTP parsing, the Postgres protocol, batching, JSON, JWT,
// bcrypt, handlers) is common Kotlin and compiles unchanged for the JVM and for Kotlin/Native (linuxX64).

/**
 * Called first thing in main. Native: ignores SIGPIPE (a write to a closed socket must not kill the process) and
 * raises the RLIMIT_NOFILE soft limit to the hard limit (tens of thousands of client sockets; the JVM does this
 * itself via -XX:+MaxFDLimit). Returns a one-line description for the startup log.
 */
expect fun platformInit(): String

/** Monotonic clock in nanoseconds. */
expect fun nanoTime(): Long

/** Wall clock, milliseconds since the Unix epoch. */
expect fun currentTimeMillis(): Long

/**
 * Whether [e] is an OutOfMemoryError (which common Kotlin has no type for). Error paths ask before they build any
 * message: with the heap exhausted, every allocation there can throw again.
 */
expect fun isOutOfMemory(e: Throwable): Boolean

/** Fills [dst] with cryptographically secure random bytes (bcrypt salts, SCRAM nonces). */
expect fun secureRandomBytes(dst: ByteArray)

expect fun getenv(name: String): String?

/** A small text file's contents (e.g. /proc counters), or null if it cannot be read. */
expect fun readTextFile(path: String): String?

/** CPUs this process may run on (affinity-aware where the platform allows). */
expect fun cpuCount(): Int

/**
 * Starts a platform (OS) thread running [body]. [nice] > 0 lowers this thread's scheduling priority (Linux nice
 * value, per thread) where the platform allows it; bcrypt workers use it so logins never take CPU from requests.
 */
expect fun startThread(name: String, nice: Int = 0, body: () -> Unit)

/** Blocks the calling thread forever (main thread after startup). */
expect fun parkForever(): Nothing

/** A mutex with one condition, like a Java monitor. Not reentrant. */
expect class Monitor() {
    fun lock()
    fun unlock()
    /** Must hold the lock. Releases it while waiting; spurious wakeups are possible. */
    fun await()
    /** Must hold the lock. Waits at most [nanos]; spurious wakeups are possible. */
    fun awaitNanos(nanos: Long)
    fun signal()
    fun signalAll()
}

inline fun <T> Monitor.locked(block: () -> T): T {
    lock()
    try {
        return block()
    } finally {
        unlock()
    }
}

/** A blocking TCP client socket with TCP_NODELAY (the Postgres connections; one reader thread each). */
expect class BlockingSocket {
    /** Reads up to [len] bytes; blocks until at least one byte arrives. Returns -1 at EOF. Throws on error. */
    fun read(b: ByteArray, off: Int, len: Int): Int

    /** Writes all [len] bytes, blocking as needed. Throws on error. */
    fun writeFully(b: ByteArray, off: Int, len: Int)

    fun close()

    companion object {
        fun connect(host: String, port: Int): BlockingSocket
    }
}

/**
 * HMAC-SHA256 with a fixed key. An instance is NOT thread-safe: use one per thread (see [threadScratch]).
 * JVM: javax.crypto (SHA-NI/AVX2 intrinsics). Native: [conduit.crypto.HmacSha256Impl] (pure Kotlin).
 */
expect class HmacSha256(key: ByteArray) {
    /** Writes the 32-byte MAC of data[off, off+len) to out[outOff, outOff+32). */
    fun mac(data: ByteArray, off: Int, len: Int, out: ByteArray, outOff: Int)
}

/** SHA-256 digest (one-shot; SCRAM only, not on hot paths). */
expect fun sha256(data: ByteArray): ByteArray

/**
 * The 8 bytes b[p, p+8) as a little-endian Long, in one (unaligned) load where the platform has one: lets hot
 * scanners (JSON string escaping) test 8 bytes per step. The caller guarantees p + 8 <= b.size.
 */
expect fun loadLongLE(b: ByteArray, p: Int): Long

/** Per-thread scratch objects (one per OS thread, created lazily). */
class Scratch {
    /** HMAC keyed with JWT_SECRET; set by [conduit.auth.Jwt]. */
    var jwtMac: HmacSha256? = null
    val mac = ByteArray(32)
    val tmp = ByteArray(4096)
}

expect fun threadScratch(): Scratch

/**
 * Starts the HTTP/1.1 listener(s) and [loops] event-loop threads, then returns. Each loop owns the connections it
 * accepted (SO_REUSEPORT listener per loop where available, listen backlog 65535, TCP_NODELAY on every accepted
 * socket, non-blocking I/O). The loops feed bytes to [conduit.http.HttpEngine] and perform writes it requests; all
 * HTTP logic lives in common code. Accept errors (EMFILE/ENFILE) pause accepting for ~100 ms instead of spinning.
 */
expect fun startHttpServer(host: String, port: Int, loops: Int, engine: conduit.http.HttpEngine)
