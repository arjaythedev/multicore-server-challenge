package conduit.platform

import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
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

private val random = SecureRandom()

actual fun secureRandomBytes(dst: ByteArray) = random.nextBytes(dst)

actual fun getenv(name: String): String? = System.getenv(name)

actual fun cpuCount(): Int = Runtime.getRuntime().availableProcessors()

actual fun startThread(name: String, nice: Int, body: () -> Unit) {
    val t = Thread({
        if (nice > 0) Nice.set(nice)
        body()
    }, name)
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

actual class BlockingSocket private constructor(private val s: Socket) {
    private val input: InputStream = s.getInputStream()
    private val output: OutputStream = s.getOutputStream()

    actual fun read(b: ByteArray, off: Int, len: Int): Int = input.read(b, off, len)

    actual fun writeFully(b: ByteArray, off: Int, len: Int) = output.write(b, off, len)

    actual fun close() = s.close()

    actual companion object {
        actual fun connect(host: String, port: Int): BlockingSocket {
            val s = Socket()
            s.tcpNoDelay = true
            s.receiveBufferSize = 1 shl 20
            s.sendBufferSize = 1 shl 20
            s.connect(InetSocketAddress(host, port), 10_000)
            return BlockingSocket(s)
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

private val scratch = ThreadLocal.withInitial { Scratch() }

actual fun threadScratch(): Scratch = scratch.get()

actual fun startHttpServer(host: String, port: Int, loops: Int, engine: conduit.http.HttpEngine) =
    startNioServer(host, port, loops, engine) // NioHttp.kt
