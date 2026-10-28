package conduit.platform

import conduit.http.HttpConn
import conduit.http.HttpEngine
import conduit.util.logSafe
import java.lang.foreign.Arena
import java.lang.foreign.FunctionDescriptor
import java.lang.foreign.Linker
import java.lang.foreign.MemoryLayout
import java.lang.foreign.MemorySegment
import java.lang.foreign.ValueLayout
import java.lang.foreign.ValueLayout.ADDRESS
import java.lang.foreign.ValueLayout.JAVA_INT
import java.lang.foreign.ValueLayout.JAVA_LONG
import java.lang.invoke.MethodHandle
import java.lang.invoke.VarHandle
import java.net.Inet4Address
import java.net.InetAddress
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicIntegerFieldUpdater
import java.util.concurrent.locks.LockSupport

/**
 * Linux syscalls through the FFM API (x86_64 glibc), for the epoll HTTP loop. The per-request calls (recv, send,
 * accept4, epoll_ctl) are "critical" downcalls: no Java-to-native thread-state transition, and heap byte arrays are
 * passed to the kernel directly (no copy through a temporary direct buffer as NIO does). Only epoll_wait, which
 * blocks, is a normal downcall.
 */
internal object Sys {
    const val EINTR = 4
    const val EAGAIN = 11
    const val ENOMEM = 12
    const val ENFILE = 23
    const val EMFILE = 24
    const val ENOBUFS = 105

    const val AF_INET = 2
    const val SOCK_STREAM = 1
    const val SOCK_NONBLOCK = 0x800
    const val SOCK_CLOEXEC = 0x80000
    const val SOL_SOCKET = 1
    const val SO_REUSEADDR = 2
    const val SO_REUSEPORT = 15
    const val IPPROTO_TCP = 6
    const val TCP_NODELAY = 1
    const val MSG_DONTWAIT = 0x40
    const val MSG_NOSIGNAL = 0x4000
    const val SHUT_RDWR = 2

    const val EPOLLIN = 0x1
    const val EPOLLOUT = 0x4
    const val EPOLLERR = 0x8
    const val EPOLLHUP = 0x10
    const val EPOLL_CTL_ADD = 1
    const val EPOLL_CTL_DEL = 2
    const val EPOLL_CTL_MOD = 3
    /** struct epoll_event is packed on x86_64: u32 events, u64 data. */
    const val EVENT_SIZE = 12L

    private val linker = Linker.nativeLinker()
    private val libc = linker.defaultLookup()
    private val ERRNO_OPT = Linker.Option.captureCallState("errno")
    private val CRITICAL = Linker.Option.critical(true)

    /** The errno capture segment layout (one segment per calling thread). */
    @JvmField val CAPTURE: MemoryLayout = Linker.Option.captureStateLayout()
    private val ERRNO: VarHandle = CAPTURE.varHandle(MemoryLayout.PathElement.groupElement("errno"))

    private fun fn(name: String, d: FunctionDescriptor, vararg o: Linker.Option): MethodHandle =
        linker.downcallHandle(libc.find(name).orElseThrow(), d, *o)

    // (capture, fd, buf, len, flags) -> ssize_t
    @JvmField val RECV = fn("recv", FunctionDescriptor.of(JAVA_LONG, JAVA_INT, ADDRESS, JAVA_LONG, JAVA_INT), ERRNO_OPT, CRITICAL)
    @JvmField val SEND = fn("send", FunctionDescriptor.of(JAVA_LONG, JAVA_INT, ADDRESS, JAVA_LONG, JAVA_INT), ERRNO_OPT, CRITICAL)
    // (capture, fd, addr, addrlen, flags) -> int
    @JvmField val ACCEPT4 = fn("accept4", FunctionDescriptor.of(JAVA_INT, JAVA_INT, ADDRESS, ADDRESS, JAVA_INT), ERRNO_OPT, CRITICAL)
    // (epfd, op, fd, event) -> int
    @JvmField val EPOLL_CTL = fn("epoll_ctl", FunctionDescriptor.of(JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, ADDRESS), CRITICAL)
    // (epfd, events, max, timeout) -> int; blocks: a normal downcall
    @JvmField val EPOLL_WAIT = fn("epoll_wait", FunctionDescriptor.of(JAVA_INT, JAVA_INT, ADDRESS, JAVA_INT, JAVA_INT))
    @JvmField val CLOSE = fn("close", FunctionDescriptor.of(JAVA_INT, JAVA_INT), CRITICAL)
    @JvmField val SHUTDOWN = fn("shutdown", FunctionDescriptor.of(JAVA_INT, JAVA_INT, JAVA_INT), CRITICAL)
    // (fd, buf, len) -> ssize_t: eventfd counter writes and reads
    @JvmField val WRITE = fn("write", FunctionDescriptor.of(JAVA_LONG, JAVA_INT, ADDRESS, JAVA_LONG), CRITICAL)
    @JvmField val READ = fn("read", FunctionDescriptor.of(JAVA_LONG, JAVA_INT, ADDRESS, JAVA_LONG), CRITICAL)
    // (fd, level, name, value, len) -> int
    @JvmField val SETSOCKOPT = fn("setsockopt", FunctionDescriptor.of(JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, ADDRESS, JAVA_INT), CRITICAL)

    // startup only
    private val SOCKET = fn("socket", FunctionDescriptor.of(JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT), ERRNO_OPT)
    private val BIND = fn("bind", FunctionDescriptor.of(JAVA_INT, JAVA_INT, ADDRESS, JAVA_INT), ERRNO_OPT)
    private val LISTEN = fn("listen", FunctionDescriptor.of(JAVA_INT, JAVA_INT, JAVA_INT), ERRNO_OPT)
    private val EPOLL_CREATE1 = fn("epoll_create1", FunctionDescriptor.of(JAVA_INT, JAVA_INT), ERRNO_OPT)
    private val EVENTFD = fn("eventfd", FunctionDescriptor.of(JAVA_INT, JAVA_INT, JAVA_INT), ERRNO_OPT)
    private val STRERROR = fn("strerror", FunctionDescriptor.of(ADDRESS, JAVA_INT))

    /** An int 1 for setsockopt (read-only, shared). */
    @JvmField val ONE: MemorySegment = Arena.global().allocate(JAVA_INT).also { it.set(JAVA_INT, 0L, 1) }
    /** An eventfd increment of 1 (u64, read-only, shared). */
    @JvmField val ONE64: MemorySegment = Arena.global().allocate(JAVA_LONG).also { it.set(JAVA_LONG, 0L, 1L) }

    private val captures = ThreadLocal.withInitial { Arena.global().allocate(CAPTURE) }

    /** This thread's errno capture segment (writers on Postgres threads; loops keep their own). */
    fun capture(): MemorySegment {
        val t = Thread.currentThread()
        if (t is ConduitThread) return t.capture ?: Arena.global().allocate(CAPTURE).also { t.capture = it }
        return captures.get()
    }

    fun errno(capture: MemorySegment): Int = ERRNO.get(capture, 0L) as Int

    fun strerror(e: Int): String = try {
        (STRERROR.invokeExact(e) as MemorySegment).reinterpret(256).getString(0)
    } catch (_: Throwable) {
        "errno $e"
    }

    /** True when the FFM linker and these symbols are usable (native access enabled, Linux x86_64). */
    val available: Boolean by lazy {
        try {
            System.getProperty("os.name") == "Linux" && System.getProperty("os.arch") == "amd64" &&
                (CLOSE.invokeExact(-1) as Int) == -1
        } catch (_: Throwable) {
            false
        }
    }

    private inline fun ok(rc: Int, cap: MemorySegment, what: () -> String): Int {
        if (rc < 0) throw IllegalStateException("${what()}: ${strerror(errno(cap))}")
        return rc
    }

    /** A non-blocking IPv4 listener (SO_REUSEADDR, optionally SO_REUSEPORT) with backlog 65535. */
    fun listen(addr: Inet4Address, port: Int, reusePort: Boolean): Int {
        val cap = capture()
        Arena.ofConfined().use { a ->
            val fd = ok(SOCKET.invokeExact(cap, AF_INET, SOCK_STREAM or SOCK_NONBLOCK or SOCK_CLOEXEC, 0) as Int, cap) { "socket" }
            SETSOCKOPT.invokeExact(fd, SOL_SOCKET, SO_REUSEADDR, ONE, 4) as Int
            if (reusePort) {
                ok(SETSOCKOPT.invokeExact(fd, SOL_SOCKET, SO_REUSEPORT, ONE, 4) as Int, cap) { "SO_REUSEPORT" }
            }
            val sa = a.allocate(16)
            sa.set(ValueLayout.JAVA_SHORT, 0L, AF_INET.toShort())
            sa.set(ValueLayout.JAVA_BYTE, 2L, (port shr 8).toByte())
            sa.set(ValueLayout.JAVA_BYTE, 3L, port.toByte())
            val ip = addr.address
            for (i in 0 until 4) sa.set(ValueLayout.JAVA_BYTE, 4L + i, ip[i])
            ok(BIND.invokeExact(cap, fd, sa, 16) as Int, cap) { "bind ${addr.hostAddress}:$port" }
            ok(LISTEN.invokeExact(cap, fd, 65535) as Int, cap) { "listen" }
            return fd
        }
    }

    fun epollCreate(): Int {
        val cap = capture()
        return ok(EPOLL_CREATE1.invokeExact(cap, 0x80000) as Int, cap) { "epoll_create1" }
    }

    fun eventFd(): Int {
        val cap = capture()
        return ok(EVENTFD.invokeExact(cap, 0, 0x800 or 0x80000) as Int, cap) { "eventfd" } // EFD_NONBLOCK|CLOEXEC
    }
}

/**
 * The HTTP loops on raw epoll via FFM (HTTP_IO=epoll): a port of the Kotlin/Native loop. One listener per loop
 * (SO_REUSEPORT), level-triggered, one recv per readiness event. Returns false (the caller falls back to NIO) when
 * the address is not IPv4 or FFM is unusable.
 */
internal fun startEpollServer(host: String, port: Int, loops: Int, engine: HttpEngine): Boolean {
    val addr = InetAddress.getByName(host) as? Inet4Address ?: return false
    if (!Sys.available) return false
    val n = maxOf(1, loops)
    val shared = if (n > 1) -1 else Sys.listen(addr, port, reusePort = false)
    for (i in 0 until n) {
        val lfd = if (n > 1) Sys.listen(addr, port, reusePort = true) else shared
        val loop = EpollLoop(i, lfd, engine)
        startThread("http-$i") { loop.run() }
    }
    return true
}

private const val EVENTS = 512
private const val EP_READ_CHUNK = 64 * 1024
private const val EP_TASKS_PER_TURN = 4096
/** A loop that just caught an OutOfMemoryError waits this long before its next turn, so that the GC gets to run. */
private const val OOM_PAUSE_NANOS = 10_000_000L

internal class EpollLoop(private val index: Int, private val listenFd: Int, private val engine: HttpEngine) {
    /**
     * The global arena: these segments live as long as the loop (forever), and a downcall taking a global segment
     * does not acquire/release a shared session (an atomic op per call: ~1% of the app CPU samples with ofShared).
     */
    private val arena = Arena.global()
    private val epfd = Sys.epollCreate()
    private val wakeFd = Sys.eventFd()
    private val events: MemorySegment = arena.allocate(Sys.EVENT_SIZE * EVENTS)
    /** epoll_ctl argument (loop thread only). */
    private val ev: MemorySegment = arena.allocate(Sys.EVENT_SIZE)
    /** errno capture (loop thread only). */
    private val cap: MemorySegment = arena.allocate(Sys.CAPTURE)
    private val drain: MemorySegment = arena.allocate(8)
    private val scratch = ByteArray(EP_READ_CHUNK)
    private val scratchSeg: MemorySegment = MemorySegment.ofArray(scratch)

    /** Connections by fd (fds are small integers; the table grows on demand). Loop thread only. */
    private var conns = arrayOfNulls<EpollConn>(1024)

    private val tasks = ConcurrentLinkedQueue<() -> Unit>()
    /** True while the loop may be blocked in epoll_wait: a poster must write the eventfd (only the first one does). */
    private val sleeping = AtomicBoolean(false)
    private var acceptPausedUntil = 0L

    init {
        ctl(Sys.EPOLL_CTL_ADD, listenFd, Sys.EPOLLIN)
        ctl(Sys.EPOLL_CTL_ADD, wakeFd, Sys.EPOLLIN)
    }

    /** Loop thread only (uses [ev]). */
    private fun ctl(op: Int, fd: Int, events: Int): Int {
        ev.set(JAVA_INT_U, 0L, events)
        ev.set(JAVA_INT_U, 4L, fd)
        ev.set(JAVA_INT_U, 8L, 0)
        return Sys.EPOLL_CTL.invokeExact(epfd, op, fd, ev) as Int
    }

    fun run() {
        while (true) {
            try {
                turn()
            } catch (e: Throwable) {
                // nothing in a catch may throw: this thread owns every socket of its listener
                logSafe({ "http-$index: loop error" }, e)
                if (e is OutOfMemoryError) LockSupport.parkNanos(OOM_PAUSE_NANOS) // let the GC make progress
            }
        }
    }

    private fun turn() {
        var timeout = -1
        if (acceptPausedUntil != 0L) {
            val left = (acceptPausedUntil - System.nanoTime()) / 1_000_000
            if (left <= 0) {
                acceptPausedUntil = 0
                ctl(Sys.EPOLL_CTL_MOD, listenFd, Sys.EPOLLIN)
            } else timeout = left.toInt() + 1
        }
        sleeping.set(true) // then re-check tasks: a poster that saw sleeping == false relies on this check
        val n = Sys.EPOLL_WAIT.invokeExact(epfd, events, EVENTS, if (tasks.isEmpty()) timeout else 0) as Int
        sleeping.set(false)
        for (i in 0 until n) {
            val base = i * Sys.EVENT_SIZE
            val flags = events.get(JAVA_INT_U, base)
            val fd = events.get(JAVA_INT_U, base + 4)
            if (fd == listenFd) {
                accept()
            } else if (fd == wakeFd) {
                Sys.READ.invokeExact(wakeFd, drain, 8L) as Long // resets the counter
            } else {
                val c = if (fd < conns.size) conns[fd] else null
                if (c != null) {
                    try {
                        handle(c, flags)
                    } catch (e: Throwable) { // never let one connection kill the loop and all its sockets
                        try {
                            c.close() // before logging (which allocates): the fd must not stay open and registered
                        } catch (_: Throwable) {
                        }
                        logSafe({ "http-$index: connection error" }, e)
                    }
                }
            }
        }
        runTasks()
    }

    private fun handle(c: EpollConn, flags: Int) {
        if (flags and Sys.EPOLLOUT != 0) {
            ctl(Sys.EPOLL_CTL_MOD, c.fd, Sys.EPOLLIN)
            if (!c.isClosing()) engine.onWritable(c)
        }
        if (flags and (Sys.EPOLLIN or Sys.EPOLLHUP or Sys.EPOLLERR) != 0) {
            if (c.isClosing()) {
                // the finishClose that close() posted may be lost (out of memory), and a shut-down socket is readable
                // for good: finish here (idempotent) rather than fire on every epoll_wait
                finishClose(c)
                return
            }
            val r = Sys.RECV.invokeExact(cap, c.fd, scratchSeg, EP_READ_CHUNK.toLong(), 0) as Long
            if (r > 0) {
                engine.onData(c, scratch, 0, r.toInt())
            } else if (r == 0L) {
                finishClose(c)
            } else {
                val e = Sys.errno(cap)
                if (e != Sys.EAGAIN && e != Sys.EINTR) finishClose(c)
            }
        }
    }

    private fun accept() {
        while (true) {
            val fd = Sys.ACCEPT4.invokeExact(cap, listenFd, MemorySegment.NULL, MemorySegment.NULL,
                Sys.SOCK_NONBLOCK or Sys.SOCK_CLOEXEC) as Int
            if (fd < 0) {
                val e = Sys.errno(cap)
                if (e == Sys.EMFILE || e == Sys.ENFILE || e == Sys.ENOBUFS || e == Sys.ENOMEM) {
                    // out of descriptors: stop accepting for 100 ms instead of spinning on a readable listener
                    ctl(Sys.EPOLL_CTL_MOD, listenFd, 0)
                    acceptPausedUntil = System.nanoTime() + 100_000_000L
                    println("http-$index: accept: ${Sys.strerror(e)}; pausing accepts for 100 ms")
                }
                return // EAGAIN (drained), EINTR, ECONNABORTED: back to epoll
            }
            Sys.SETSOCKOPT.invokeExact(fd, Sys.IPPROTO_TCP, Sys.TCP_NODELAY, Sys.ONE, 4) as Int
            val c: EpollConn
            try {
                if (fd >= conns.size) conns = conns.copyOf(maxOf(fd + 1, conns.size * 2))
                c = EpollConn(fd, this)
                conns[fd] = c
                ctl(Sys.EPOLL_CTL_ADD, fd, Sys.EPOLLIN)
            } catch (e: Throwable) { // out of memory: nobody else knows this fd, so it is closed here, not leaked
                Sys.CLOSE.invokeExact(fd) as Int
                throw e
            }
            try {
                engine.onOpen(c)
            } catch (e: Throwable) {
                try {
                    c.close() // before logging, as in turn()
                } catch (_: Throwable) {
                }
                logSafe({ "http-$index: onOpen error" }, e)
            }
        }
    }

    /** Loop thread: unregisters and closes the fd once no other thread is inside send(), then tells the engine. */
    fun finishClose(c: EpollConn) {
        if (c.released) return
        c.markClosing()
        if (!c.tryRelease()) { // another thread is inside send(): retry after it leaves
            post { finishClose(c) }
            return
        }
        ctl(Sys.EPOLL_CTL_DEL, c.fd, 0)
        if (c.fd < conns.size && conns[c.fd] === c) conns[c.fd] = null
        Sys.CLOSE.invokeExact(c.fd) as Int
        engine.onClosed(c)
    }

    fun armWrite(c: EpollConn) {
        if (!c.isClosing()) ctl(Sys.EPOLL_CTL_MOD, c.fd, Sys.EPOLLIN or Sys.EPOLLOUT)
    }

    /** Any thread: runs [task] on this loop soon. Never inline (the engine relies on that). */
    fun post(task: () -> Unit) {
        tasks.offer(task)
        if (sleeping.get() && sleeping.compareAndSet(true, false)) Sys.WRITE.invokeExact(wakeFd, Sys.ONE64, 8L) as Long
    }

    private fun runTasks() {
        var n = 0
        while (n++ < EP_TASKS_PER_TURN) {
            val t = tasks.poll() ?: return
            try {
                t()
            } catch (e: Throwable) {
                logSafe({ "http-$index: task failed" }, e)
            }
        }
    }
}

/** Native-order int at any offset (epoll_event is packed). */
private val JAVA_INT_U: ValueLayout.OfInt = JAVA_INT.withByteAlignment(1)

private val IO = AtomicIntegerFieldUpdater.newUpdater(EpollConn::class.java, "io")

/**
 * A client socket. [io] packs a "closing" bit with the number of threads currently inside send(): the fd is closed
 * (and its number freed for reuse by a new connection) only when no writer is using it, so a late response from a
 * Postgres thread can never land on another client's socket.
 */
internal class EpollConn(@JvmField val fd: Int, @JvmField val loop: EpollLoop) : HttpConn() {
    @JvmField @Volatile var io = 0
    /** Loop thread only: the fd is closed and onClosed was delivered. */
    @JvmField var released = false

    fun isClosing() = io and CLOSING != 0

    fun markClosing() {
        while (true) {
            val v = io
            if (v and CLOSING != 0 || IO.compareAndSet(this, v, v or CLOSING)) return
        }
    }

    /** True once no writer is active (the caller then owns the close). */
    fun tryRelease(): Boolean {
        if (io != CLOSING) return false
        released = true
        return true
    }

    override fun tryWrite(b: ByteArray, off: Int, len: Int): Int {
        while (true) {
            val v = io
            if (v and CLOSING != 0) return -1
            if (IO.compareAndSet(this, v, v + 1)) break
        }
        try {
            if (len == 0) return 0
            val cap = Sys.capture()
            val seg = MemorySegment.ofArray(b).asSlice(off.toLong(), len.toLong())
            val w = Sys.SEND.invokeExact(cap, fd, seg, len.toLong(), Sys.MSG_NOSIGNAL or Sys.MSG_DONTWAIT) as Long
            if (w >= 0) return w.toInt()
            val e = Sys.errno(cap)
            return if (e == Sys.EAGAIN || e == Sys.EINTR) 0 else -1
        } finally {
            IO.decrementAndGet(this)
        }
    }

    override fun requestWritable() {
        if (!isClosing()) loop.post { loop.armWrite(this) }
    }

    override fun execute(task: () -> Unit) = loop.post(task)

    override fun close() {
        // set CLOSING and hold a writer reference while calling shutdown: the loop must not close the fd (whose
        // number could then be reused) in between
        while (true) {
            val v = io
            if (v and CLOSING != 0) return
            if (IO.compareAndSet(this, v, (v or CLOSING) + 1)) break
        }
        try {
            Sys.SHUTDOWN.invokeExact(fd, Sys.SHUT_RDWR) as Int // stops further I/O and wakes the loop (EPOLLHUP)
        } finally {
            IO.decrementAndGet(this)
        }
        loop.post { loop.finishClose(this) }
    }

    private companion object {
        const val CLOSING = 1 shl 30
    }
}
