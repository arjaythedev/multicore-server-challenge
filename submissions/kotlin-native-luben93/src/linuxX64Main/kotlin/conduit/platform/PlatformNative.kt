package conduit.platform

import conduit.crypto.HmacSha256Impl
import conduit.crypto.Sha256
import kotlinx.cinterop.COpaquePointer
import kotlinx.cinterop.LongVar
import kotlinx.cinterop.StableRef
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.alloc
import kotlinx.cinterop.allocArray
import kotlinx.cinterop.asStableRef
import kotlinx.cinterop.convert
import kotlinx.cinterop.get
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.nativeHeap
import kotlinx.cinterop.pointed
import kotlinx.cinterop.ptr
import kotlinx.cinterop.sizeOf
import kotlinx.cinterop.staticCFunction
import kotlinx.cinterop.toKString
import kotlinx.cinterop.usePinned
import kotlinx.cinterop.value
import platform.posix.AF_INET
import platform.posix.CLOCK_MONOTONIC
import platform.posix.CLOCK_REALTIME
import platform.posix.EINTR
import platform.posix.IPPROTO_TCP
import platform.posix.MSG_NOSIGNAL
import platform.posix.O_RDONLY
import platform.linux.PRIO_PROCESS
import platform.linux.RLIMIT_NOFILE
import platform.posix.SIGPIPE
import platform.posix.SIG_IGN
import platform.posix.SOCK_STREAM
import platform.posix.SOL_SOCKET
import platform.posix.SO_RCVBUF
import platform.posix.SO_SNDBUF
import platform.posix.TCP_NODELAY
import platform.posix.addrinfo
import platform.posix.clock_gettime
import platform.posix.close
import platform.posix.connect
import platform.posix.errno
import platform.posix.freeaddrinfo
import platform.posix.getaddrinfo
import platform.linux.getrlimit
import platform.posix.open
import platform.posix.pthread_cond_init
import platform.posix.pthread_cond_signal
import platform.posix.pthread_cond_broadcast
import platform.posix.pthread_cond_t
import platform.posix.pthread_cond_timedwait
import platform.posix.pthread_cond_wait
import platform.posix.pthread_create
import platform.posix.pthread_detach
import platform.posix.pthread_mutex_init
import platform.posix.pthread_mutex_lock
import platform.posix.pthread_mutex_t
import platform.posix.pthread_mutex_unlock
import platform.posix.pthread_tVar
import platform.posix.read
import platform.posix.recv
import platform.linux.rlimit
import platform.posix.send
import platform.linux.setpriority
import platform.linux.setrlimit
import platform.posix.setsockopt
import platform.posix.signal
import platform.posix.sleep
import platform.posix.socket
import platform.posix.strerror
import platform.posix.syscall
import platform.posix.sysconf
import platform.posix._SC_NPROCESSORS_ONLN
import platform.posix.timespec
import kotlin.concurrent.AtomicInt
import kotlin.native.concurrent.ThreadLocal

private const val SYS_GETTID = 186L
private const val SYS_SCHED_GETAFFINITY = 204L

actual fun platformInit(): String {
    signal(SIGPIPE, SIG_IGN)
    val gc = gcInit()
    val limit = memScoped {
        val rl = alloc<rlimit>()
        getrlimit(RLIMIT_NOFILE, rl.ptr)
        if (rl.rlim_cur < rl.rlim_max) {
            rl.rlim_cur = rl.rlim_max
            setrlimit(RLIMIT_NOFILE, rl.ptr)
            getrlimit(RLIMIT_NOFILE, rl.ptr)
        }
        rl.rlim_cur.toLong()
    }
    return "kotlin/native, RLIMIT_NOFILE $limit, $gc"
}

/**
 * The GC's heap target defaults to 10 MiB, so a server allocating tens of MB/s would collect many times a second
 * (each collection marks the whole live heap: every connection's state). GC_HEAP_MB (default 512) raises the floor
 * of the autotuned target; GC_LOG=1 prints collections per 10 s with the last pause.
 */
@OptIn(kotlin.native.runtime.NativeRuntimeApi::class)
private fun gcInit(): String {
    val mb = getenv("GC_HEAP_MB")?.trim()?.toLongOrNull() ?: 512L
    if (mb > 0) {
        val bytes = mb shl 20
        kotlin.native.runtime.GC.minHeapBytes = bytes
        kotlin.native.runtime.GC.targetHeapBytes = bytes
    }
    if (getenv("GC_LOG") == "1") startThread("gc-log") { gcLog() }
    return "gc heap target ${kotlin.native.runtime.GC.targetHeapBytes shr 20} MiB"
}

@OptIn(kotlin.native.runtime.NativeRuntimeApi::class, ExperimentalStdlibApi::class)
private fun gcLog() {
    var lastEpoch = -1L
    while (true) {
        sleep(10u)
        val i = kotlin.native.runtime.GC.lastGCInfo ?: continue
        val before = i.memoryUsageBefore.values.sumOf { it.totalObjectsSizeBytes } shr 20
        val after = i.memoryUsageAfter.values.sumOf { it.totalObjectsSizeBytes } shr 20
        val pause = (i.firstPauseEndTimeNs - i.firstPauseStartTimeNs) / 1000
        println(
            "gc: epoch ${i.epoch} (+${if (lastEpoch < 0) 0 else i.epoch - lastEpoch}/10s) " +
                "last: ${(i.endTimeNs - i.startTimeNs) / 1000} us total, pause $pause us, " +
                "heap $before -> $after MiB, marked ${i.markedCount}, " +
                "target ${kotlin.native.runtime.GC.targetHeapBytes shr 20} MiB",
        )
        lastEpoch = i.epoch
    }
}

actual fun nanoTime(): Long = memScoped {
    val ts = alloc<timespec>()
    clock_gettime(CLOCK_MONOTONIC, ts.ptr)
    ts.tv_sec * 1_000_000_000L + ts.tv_nsec
}

actual fun currentTimeMillis(): Long = memScoped {
    val ts = alloc<timespec>()
    clock_gettime(CLOCK_REALTIME, ts.ptr)
    ts.tv_sec * 1000L + ts.tv_nsec / 1_000_000
}

private val urandom: Int by lazy { open("/dev/urandom", O_RDONLY).also { check(it >= 0) { "open /dev/urandom" } } }

actual fun secureRandomBytes(dst: ByteArray) {
    if (dst.isEmpty()) return
    dst.usePinned { p ->
        var got = 0
        while (got < dst.size) {
            val r = read(urandom, p.addressOf(got), (dst.size - got).convert())
            if (r > 0) got += r.toInt() else if (errno != EINTR) error("read /dev/urandom: errno $errno")
        }
    }
}

actual fun getenv(name: String): String? = platform.posix.getenv(name)?.toKString()

actual fun cpuCount(): Int {
    // sched_getaffinity, so `taskset` limits are respected like the JVM's availableProcessors()
    val n = memScoped {
        val words = 16 // 1024 CPUs
        val set = allocArray<LongVar>(words)
        val r = syscall(SYS_SCHED_GETAFFINITY, 0, words * 8, set)
        if (r <= 0) 0 else {
            var c = 0
            for (i in 0 until words) c += set[i].countOneBits()
            c
        }
    }
    return if (n > 0) n else sysconf(_SC_NPROCESSORS_ONLN).toInt().coerceAtLeast(1)
}

private class ThreadStart(val nice: Int, val body: () -> Unit)

actual fun startThread(name: String, nice: Int, body: () -> Unit) {
    val ref = StableRef.create(ThreadStart(nice, body))
    memScoped {
        val tid = alloc<pthread_tVar>()
        val rc = pthread_create(
            tid.ptr, null,
            staticCFunction { arg: COpaquePointer? ->
                val r = arg!!.asStableRef<ThreadStart>()
                val start = r.get()
                r.dispose()
                if (start.nice > 0) setpriority(PRIO_PROCESS, syscall(SYS_GETTID).convert(), start.nice)
                try {
                    start.body()
                } catch (t: Throwable) {
                    println("thread died: $t")
                    t.printStackTrace()
                }
                null
            },
            ref.asCPointer(),
        )
        check(rc == 0) { "pthread_create $name: $rc" }
        pthread_detach(tid.value)
    }
}

actual fun parkForever(): Nothing {
    while (true) sleep(3600u)
}

actual class Monitor actual constructor() {
    private val m = nativeHeap.alloc<pthread_mutex_t>().also { pthread_mutex_init(it.ptr, null) }
    private val c = nativeHeap.alloc<pthread_cond_t>().also { pthread_cond_init(it.ptr, null) }

    actual fun lock() {
        pthread_mutex_lock(m.ptr)
    }

    actual fun unlock() {
        pthread_mutex_unlock(m.ptr)
    }

    actual fun await() {
        pthread_cond_wait(c.ptr, m.ptr)
    }

    actual fun awaitNanos(nanos: Long) {
        memScoped {
            val ts = alloc<timespec>()
            clock_gettime(CLOCK_REALTIME, ts.ptr)
            val total = ts.tv_nsec + nanos
            ts.tv_sec += total / 1_000_000_000L
            ts.tv_nsec = total % 1_000_000_000L
            pthread_cond_timedwait(c.ptr, m.ptr, ts.ptr)
        }
    }

    actual fun signal() {
        pthread_cond_signal(c.ptr)
    }

    actual fun signalAll() {
        pthread_cond_broadcast(c.ptr)
    }
}

actual class BlockingSocket private constructor(private val fd: Int) {
    private val closed = AtomicInt(0)

    actual fun read(b: ByteArray, off: Int, len: Int): Int {
        if (len == 0) return 0
        while (true) {
            val r = b.usePinned { p -> recv(fd, p.addressOf(off), len.convert(), 0) }
            if (r > 0) return r.toInt()
            if (r == 0L) return -1
            val e = errno
            if (e != EINTR) throw IllegalStateException("recv: ${strerror(e)?.toKString()}")
        }
    }

    actual fun writeFully(b: ByteArray, off: Int, len: Int) {
        var p = off
        val end = off + len
        while (p < end) {
            val w = b.usePinned { pin -> send(fd, pin.addressOf(p), (end - p).convert(), MSG_NOSIGNAL) }
            if (w > 0) p += w.toInt() else {
                val e = errno
                if (e != EINTR) throw IllegalStateException("send: ${strerror(e)?.toKString()}")
            }
        }
    }

    actual fun close() {
        if (closed.compareAndSet(0, 1)) close(fd)
    }

    actual companion object {
        actual fun connect(host: String, port: Int): BlockingSocket = memScoped {
            val hints = alloc<addrinfo>()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_STREAM
            val res = alloc<kotlinx.cinterop.CPointerVar<addrinfo>>()
            val rc = getaddrinfo(host, port.toString(), hints.ptr, res.ptr)
            check(rc == 0) { "getaddrinfo $host: $rc" }
            val ai = res.value!!.pointed
            val fd = socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol)
            check(fd >= 0) { "socket: errno $errno" }
            val one = alloc<kotlinx.cinterop.IntVar>().apply { value = 1 }
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, one.ptr, sizeOf<kotlinx.cinterop.IntVar>().convert())
            val big = alloc<kotlinx.cinterop.IntVar>().apply { value = 1 shl 20 }
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, big.ptr, sizeOf<kotlinx.cinterop.IntVar>().convert())
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, big.ptr, sizeOf<kotlinx.cinterop.IntVar>().convert())
            val cr = connect(fd, ai.ai_addr, ai.ai_addrlen)
            freeaddrinfo(res.value)
            if (cr != 0) {
                val e = errno
                close(fd)
                error("connect $host:$port: ${strerror(e)?.toKString()}")
            }
            BlockingSocket(fd)
        }
    }
}

actual class HmacSha256 actual constructor(key: ByteArray) {
    private val impl = HmacSha256Impl(key)

    actual fun mac(data: ByteArray, off: Int, len: Int, out: ByteArray, outOff: Int) =
        impl.mac(data, off, len, out, outOff)
}

actual fun sha256(data: ByteArray): ByteArray = Sha256.digest(data)

@ThreadLocal
private object ThreadScratch {
    val scratch = Scratch()
}

actual fun threadScratch(): Scratch = ThreadScratch.scratch


