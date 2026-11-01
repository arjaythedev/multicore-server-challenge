package conduit.platform

import java.lang.invoke.MethodHandles
import java.lang.invoke.VarHandle
import java.net.InetSocketAddress
import java.net.SocketTimeoutException
import java.net.StandardSocketOptions
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.SelectionKey
import java.nio.channels.Selector
import java.nio.channels.SocketChannel
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.locks.LockSupport
import java.util.concurrent.locks.ReentrantLock
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

actual fun platformInit(): String =
    "jvm ${System.getProperty("java.vm.name")} ${System.getProperty("java.version")}, " +
        "heap max ${Runtime.getRuntime().maxMemory() shr 20} MB"

actual fun nanoTime(): Long = System.nanoTime()

actual fun currentTimeMillis(): Long = System.currentTimeMillis()

actual fun isOutOfMemory(e: Throwable): Boolean = e is OutOfMemoryError

private val random = SecureRandom()

actual fun secureRandomBytes(dst: ByteArray) = random.nextBytes(dst)

actual fun getenv(name: String): String? = System.getenv(name)

actual fun cpuCount(): Int = Runtime.getRuntime().availableProcessors()

/** Our own threads carry their [Scratch] (and FFM errno capture) in fields: no ThreadLocal lookup on hot paths. */
internal class ConduitThread(name: String, body: Runnable) : Thread(body, name) {
    @JvmField val scratch = Scratch()
    @JvmField var capture: java.lang.foreign.MemorySegment? = null
}

actual fun startThread(name: String, nice: Int, body: () -> Unit) {
    val t = ConduitThread(name) {
        if (nice > 0) Nice.set(nice)
        body()
    }
    t.isDaemon = true
    t.start()
}

actual fun parkForever(): Nothing {
    while (true) LockSupport.park()
}

actual class Monitor actual constructor() {
    private val lock = ReentrantLock()
    private val cond = lock.newCondition()

    actual fun lock() = lock.lock()
    actual fun unlock() = lock.unlock()
    actual fun await() = cond.await()
    actual fun awaitNanos(nanos: Long) {
        cond.awaitNanos(nanos)
    }
    actual fun signal() = cond.signal()
    actual fun signalAll() = cond.signalAll()
}

/**
 * A truly blocking socket channel. (java.net.Socket after a timed connect stays in non-blocking mode for good, so
 * every read that has to wait costs read -> EAGAIN, poll, read: three syscalls per Postgres round trip instead of
 * one.) The channel connects with a timeout through a selector, then switches to blocking mode. I/O goes through
 * one direct buffer per direction (reads: the connection's worker thread; writes: serialized by PgConn).
 */
actual class BlockingSocket private constructor(private val ch: SocketChannel) {
    private val rb: ByteBuffer = ByteBuffer.allocateDirect(IO_CHUNK)
    private val wb: ByteBuffer = ByteBuffer.allocateDirect(IO_CHUNK)

    actual fun read(b: ByteArray, off: Int, len: Int): Int {
        val bb = rb
        bb.clear()
        if (len < IO_CHUNK) bb.limit(len)
        val n = ch.read(bb) // blocks until at least one byte (or EOF: -1)
        if (n > 0) {
            bb.flip()
            bb.get(b, off, n)
        }
        return n
    }

    actual fun writeFully(b: ByteArray, off: Int, len: Int) {
        val bb = wb
        var p = off
        val end = off + len
        while (p < end) {
            val n = minOf(end - p, IO_CHUNK)
            bb.clear()
            bb.put(b, p, n)
            bb.flip()
            while (bb.hasRemaining()) ch.write(bb)
            p += n
        }
    }

    actual fun close() = ch.close()

    actual companion object {
        private const val IO_CHUNK = 64 * 1024

        actual fun connect(host: String, port: Int): BlockingSocket {
            val ch = SocketChannel.open()
            try {
                ch.setOption(StandardSocketOptions.TCP_NODELAY, true)
                ch.setOption(StandardSocketOptions.SO_RCVBUF, 1 shl 20)
                ch.setOption(StandardSocketOptions.SO_SNDBUF, 1 shl 20)
                ch.configureBlocking(false)
                if (!ch.connect(InetSocketAddress(host, port))) {
                    Selector.open().use { sel ->
                        ch.register(sel, SelectionKey.OP_CONNECT)
                        if (sel.select(10_000L) == 0) throw SocketTimeoutException("connect to $host:$port timed out")
                    }
                    if (!ch.finishConnect()) throw SocketTimeoutException("connect to $host:$port timed out")
                }
                ch.configureBlocking(true) // (the selector is closed, so the channel is deregistered)
                return BlockingSocket(ch)
            } catch (e: Throwable) {
                ch.close()
                throw e
            }
        }
    }
}

actual class HmacSha256 actual constructor(key: ByteArray) {
    private val mac: Mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(key, "HmacSHA256")) }

    actual fun mac(data: ByteArray, off: Int, len: Int, out: ByteArray, outOff: Int) {
        mac.update(data, off, len)
        mac.doFinal(out, outOff)
    }
}

actual fun sha256(data: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(data)

private val LONG_LE: VarHandle = MethodHandles.byteArrayViewVarHandle(LongArray::class.java, ByteOrder.LITTLE_ENDIAN)

actual fun loadLongLE(b: ByteArray, p: Int): Long = LONG_LE.get(b, p) as Long // one intrinsic 8-byte load

private val scratch = ThreadLocal.withInitial { Scratch() }

actual fun threadScratch(): Scratch = (Thread.currentThread() as? ConduitThread)?.scratch ?: scratch.get()

/**
 * Raw epoll through FFM (EpollHttp.kt; measured cheaper per request than NIO), unless HTTP_IO=nio, the bind address
 * is not IPv4 or FFM is unusable: then java.nio selector loops (NioHttp.kt).
 */
actual fun startHttpServer(host: String, port: Int, loops: Int, engine: conduit.http.HttpEngine) {
    if (getenv("HTTP_IO") != "nio") {
        val ok = try {
            startEpollServer(host, port, loops, engine)
        } catch (e: LinkageError) { // FFM unusable (Sys failed to initialize): fall back
            println("http: epoll via FFM unavailable ($e); using NIO")
            false
        }
        if (ok) return
    }
    startNioServer(host, port, loops, engine)
}
