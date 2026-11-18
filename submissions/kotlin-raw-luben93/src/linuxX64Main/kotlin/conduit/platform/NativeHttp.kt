package conduit.platform

import conduit.http.HttpConn
import conduit.http.HttpEngine
import conduit.util.logSafe
import kotlinx.cinterop.IntVar
import kotlinx.cinterop.Pinned
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.alloc
import kotlinx.cinterop.allocArray
import kotlinx.cinterop.convert
import kotlinx.cinterop.get
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.nativeHeap
import kotlinx.cinterop.pin
import kotlinx.cinterop.pointed
import kotlinx.cinterop.ptr
import kotlinx.cinterop.sizeOf
import kotlinx.cinterop.usePinned
import kotlinx.cinterop.value
import platform.linux.EFD_NONBLOCK
import platform.linux.EPOLLERR
import platform.linux.EPOLLHUP
import platform.linux.EPOLLIN
import platform.linux.EPOLLOUT
import platform.linux.EPOLL_CTL_ADD
import platform.linux.EPOLL_CTL_DEL
import platform.linux.EPOLL_CTL_MOD
import platform.linux.epoll_create1
import platform.linux.epoll_ctl
import platform.linux.epoll_event
import platform.linux.epoll_wait
import platform.linux.eventfd
import platform.posix.AF_INET
import platform.posix.AI_PASSIVE
import platform.posix.EAGAIN
import platform.posix.EINTR
import platform.posix.EMFILE
import platform.posix.ENFILE
import platform.posix.ENOBUFS
import platform.posix.ENOMEM
import platform.posix.F_GETFL
import platform.posix.F_SETFL
import platform.posix.IPPROTO_TCP
import platform.posix.MSG_NOSIGNAL
import platform.posix.O_NONBLOCK
import platform.posix.SHUT_RDWR
import platform.posix.SOCK_STREAM
import platform.posix.SOL_SOCKET
import platform.posix.SO_REUSEADDR
import platform.posix.TCP_NODELAY
import platform.posix.accept
import platform.posix.addrinfo
import platform.posix.bind
import platform.posix.close
import platform.posix.errno
import platform.posix.fcntl
import platform.posix.freeaddrinfo
import platform.posix.getaddrinfo
import platform.posix.listen
import platform.posix.recv
import platform.posix.send
import platform.posix.setsockopt
import platform.posix.shutdown
import platform.posix.usleep
import platform.posix.socket
import platform.posix.strerror
import kotlinx.cinterop.toKString
import kotlin.concurrent.AtomicInt
import kotlin.concurrent.AtomicReference

private const val SO_REUSEPORT = 15     // asm-generic/socket.h
private const val MSG_DONTWAIT = 0x40
private const val EVENTS = 512
private const val READ_CHUNK = 64 * 1024
/** A loop that just caught an OutOfMemoryError waits this long (us) before its next turn, so that the GC gets to run. */
private const val OOM_PAUSE_US = 10_000u

actual fun startHttpServer(host: String, port: Int, loops: Int, engine: HttpEngine) {
    val n = maxOf(1, loops)
    val reusePort = n > 1
    val shared = if (reusePort) -1 else listenSocket(host, port, reusePort = false)
    for (i in 0 until n) {
        val lfd = if (reusePort) listenSocket(host, port, reusePort = true) else shared
        val loop = EpollLoop(i, lfd, engine)
        startThread("http-$i") { loop.run() }
    }
}

private fun listenSocket(host: String, port: Int, reusePort: Boolean): Int = memScoped {
    val hints = alloc<addrinfo>()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_STREAM
    hints.ai_flags = AI_PASSIVE
    val res = alloc<kotlinx.cinterop.CPointerVar<addrinfo>>()
    val bindHost = if (host == "0.0.0.0" || host.isEmpty()) null else host
    val rc = getaddrinfo(bindHost, port.toString(), hints.ptr, res.ptr)
    check(rc == 0) { "getaddrinfo $host:$port: $rc" }
    val ai = res.value!!.pointed
    val fd = socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol)
    check(fd >= 0) { "socket: ${errText()}" }
    val one = alloc<IntVar>().apply { value = 1 }
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, one.ptr, sizeOf<IntVar>().convert())
    if (reusePort) {
        check(setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, one.ptr, sizeOf<IntVar>().convert()) == 0) {
            "SO_REUSEPORT: ${errText()}"
        }
    }
    check(bind(fd, ai.ai_addr, ai.ai_addrlen) == 0) { "bind $host:$port: ${errText()}" }
    freeaddrinfo(res.value)
    check(listen(fd, 65535) == 0) { "listen: ${errText()}" }
    setNonBlocking(fd)
    fd
}

private fun setNonBlocking(fd: Int) {
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) or O_NONBLOCK)
}

private fun errText(e: Int = errno): String = strerror(e)?.toKString() ?: "errno $e"

/**
 * One event-loop thread: its own epoll set, its own SO_REUSEPORT listener, an eventfd for cross-thread wakeups.
 * Level-triggered: one recv per readiness event, so a busy connection can't starve the others.
 */
private class EpollLoop(val index: Int, val listenFd: Int, val engine: HttpEngine) {
    val epfd = epoll_create1(0).also { check(it >= 0) { "epoll_create1: ${errText()}" } }
    private val wakeFd = eventfd(0, EFD_NONBLOCK.toInt()).also { check(it >= 0) { "eventfd: ${errText()}" } }
    private val events = nativeHeap.allocArray<epoll_event>(EVENTS)
    private val scratch = ByteArray(READ_CHUNK)
    private val pinned: Pinned<ByteArray> = scratch.pin()
    private val wakeBuf = ByteArray(8).pin()
    private val wakeOne = ByteArray(8).also { it[0] = 1 }.pin() // eventfd counter += 1 (little-endian u64)

    /** Connections by fd (fds are small integers; the table grows on demand). */
    private var conns = arrayOfNulls<NativeConn>(1024)

    /** Tasks posted from other threads, as an immutable stack swapped atomically (MPSC). */
    private val tasks = AtomicReference<TaskNode?>(null)
    /** 1 while the loop may be blocked in epoll_wait (a poster must write the eventfd). */
    private val sleeping = AtomicInt(0)
    private var acceptPausedUntil = 0L

    init {
        ctl(EPOLL_CTL_ADD, listenFd, EPOLLIN.toUInt())
        ctl(EPOLL_CTL_ADD, wakeFd, EPOLLIN.toUInt())
    }

    fun ctl(op: Int, fd: Int, ev: UInt): Int = memScoped {
        val e = alloc<epoll_event>()
        e.events = ev
        e.data.fd = fd
        epoll_ctl(epfd, op, fd, e.ptr)
    }

    fun run() {
        while (true) {
            try {
                turn()
            } catch (e: Throwable) {
                // nothing in a catch may throw: this thread owns every socket of its listener
                logSafe({ "http-$index: loop error" }, e)
                if (isOutOfMemory(e)) usleep(OOM_PAUSE_US) // let the GC make progress
            }
        }
    }

    /** One epoll_wait and everything it returned, then the posted tasks. */
    private fun turn() {
        var timeout = -1
        if (acceptPausedUntil != 0L) {
            val left = (acceptPausedUntil - nanoTime()) / 1_000_000
            if (left <= 0) {
                acceptPausedUntil = 0
                ctl(EPOLL_CTL_MOD, listenFd, EPOLLIN.toUInt())
            } else timeout = left.toInt() + 1
        }
        sleeping.value = 1 // then re-check tasks: a poster that saw sleeping == 0 relies on this check
        val n = epoll_wait(epfd, events, EVENTS, if (tasks.value != null) 0 else timeout)
        sleeping.value = 0
        for (i in 0 until n) {
            val ev = events[i]
            val fd = ev.data.fd
            val flags = ev.events
            when (fd) {
                listenFd -> acceptAll()
                // read(), not recv(): an eventfd is not a socket (recv fails with ENOTSOCK, the counter
                // stays set and every epoll_wait returns at once: the loop would spin)
                wakeFd -> platform.posix.read(wakeFd, wakeBuf.addressOf(0), 8u)
                else -> {
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
        }
        runTasks()
    }

    private fun handle(c: NativeConn, flags: UInt) {
        if (flags and EPOLLOUT.toUInt() != 0u) {
            ctl(EPOLL_CTL_MOD, c.fd, EPOLLIN.toUInt())
            if (!c.isClosing()) engine.onWritable(c)
        }
        if (flags and (EPOLLIN.toUInt() or EPOLLHUP.toUInt() or EPOLLERR.toUInt()) != 0u) {
            if (c.isClosing()) {
                // the finishClose that close() posted may be lost (out of memory), and a shut-down socket is readable
                // for good: finish here (idempotent) rather than fire on every epoll_wait
                finishClose(c)
                return
            }
            val r = recv(c.fd, pinned.addressOf(0), READ_CHUNK.convert(), 0)
            when {
                r > 0 -> engine.onData(c, scratch, 0, r.toInt())
                r == 0L -> finishClose(c)
                else -> {
                    val e = errno
                    if (e != EAGAIN && e != EINTR) finishClose(c)
                }
            }
        }
    }

    private fun acceptAll() {
        while (true) {
            val fd = accept(listenFd, null, null)
            if (fd < 0) {
                val e = errno
                if (e == EMFILE || e == ENFILE || e == ENOBUFS || e == ENOMEM) {
                    // out of descriptors: stop accepting for 100 ms instead of spinning on a readable listener
                    ctl(EPOLL_CTL_MOD, listenFd, 0u)
                    acceptPausedUntil = nanoTime() + 100_000_000L
                    println("http-$index: accept: ${errText(e)}; pausing accepts for 100 ms")
                }
                return // EAGAIN (drained), EINTR, ECONNABORTED: back to epoll
            }
            setNonBlocking(fd)
            memScoped {
                val one = alloc<IntVar>().apply { value = 1 }
                setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, one.ptr, sizeOf<IntVar>().convert())
            }
            val c: NativeConn
            try {
                if (fd >= conns.size) conns = conns.copyOf(maxOf(fd + 1, conns.size * 2))
                c = NativeConn(fd, this)
                conns[fd] = c
                ctl(EPOLL_CTL_ADD, fd, EPOLLIN.toUInt())
            } catch (e: Throwable) { // out of memory: nobody else knows this fd, so it is closed here, not leaked
                close(fd)
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

    /** On the loop thread: unregister, close the fd once no other thread is writing to it, tell the engine. */
    fun finishClose(c: NativeConn) {
        if (c.released) return
        c.markClosing()
        if (!c.tryRelease()) { // another thread is inside send(): retry after it leaves
            post { finishClose(c) }
            return
        }
        ctl(EPOLL_CTL_DEL, c.fd, 0u)
        if (c.fd < conns.size && conns[c.fd] === c) conns[c.fd] = null
        close(c.fd)
        engine.onClosed(c)
    }

    fun post(task: () -> Unit) {
        while (true) {
            val head = tasks.value
            if (tasks.compareAndSet(head, TaskNode(task, head))) break
        }
        if (sleeping.value == 1) platform.posix.write(wakeFd, wakeOne.addressOf(0), 8u)
    }

    private fun runTasks() {
        while (true) {
            var node = tasks.getAndSet(null) ?: return
            // the stack is newest-first: reverse to run tasks in posting order
            var rev: TaskNode? = null
            var cur: TaskNode? = node
            while (cur != null) {
                val next = cur.next
                rev = TaskNode(cur.task, rev)
                cur = next
            }
            node = rev!!
            var t: TaskNode? = node
            while (t != null) {
                try {
                    t.task()
                } catch (e: Throwable) {
                    logSafe({ "http-$index: task failed" }, e)
                }
                t = t.next
            }
        }
    }

    fun armWrite(c: NativeConn) {
        // epoll_ctl is thread-safe; the EPOLLOUT event is then delivered to this loop's thread
        ctl(EPOLL_CTL_MOD, c.fd, (EPOLLIN or EPOLLOUT).toUInt())
    }
}

private class TaskNode(val task: () -> Unit, val next: TaskNode?)

/**
 * A client socket. [io] packs a "closing" bit with the number of threads currently inside send(): the fd is only
 * closed (and its number freed for reuse by a new connection) when no writer is using it, so a late response from
 * a Postgres thread can never land on another client's socket.
 */
private class NativeConn(val fd: Int, val loop: EpollLoop) : HttpConn() {
    private val io = AtomicInt(0)
    var released = false // loop thread only

    fun isClosing() = io.value and CLOSING != 0

    fun markClosing() {
        while (true) {
            val v = io.value
            if (v and CLOSING != 0 || io.compareAndSet(v, v or CLOSING)) return
        }
    }

    /** True once no writer is active (the caller then owns the close). */
    fun tryRelease(): Boolean {
        if (io.value != CLOSING) return false
        released = true
        return true
    }

    override fun tryWrite(b: ByteArray, off: Int, len: Int): Int {
        while (true) {
            val v = io.value
            if (v and CLOSING != 0) return -1
            if (io.compareAndSet(v, v + 1)) break
        }
        try {
            if (len == 0) return 0
            val w = b.usePinned { p -> send(fd, p.addressOf(off), len.convert(), MSG_NOSIGNAL or MSG_DONTWAIT) }
            if (w >= 0) return w.toInt()
            val e = errno
            return if (e == EAGAIN || e == EINTR) 0 else -1
        } finally {
            io.decrementAndGet()
        }
    }

    override fun requestWritable() {
        if (!isClosing()) loop.armWrite(this)
    }

    override fun execute(task: () -> Unit) = loop.post(task)

    override fun close() {
        // shutdown() touches the fd, so it runs under the same writer count as send(): the loop cannot close the fd
        // (and accept() hand its number to another client) while we are inside. If the loop already started closing,
        // there is nothing left to do.
        while (true) {
            val v = io.value
            if (v and CLOSING != 0) return
            if (io.compareAndSet(v, v + 1)) break
        }
        try {
            shutdown(fd, SHUT_RDWR) // wakes the loop (EPOLLHUP) and stops further I/O; the loop closes the fd
        } finally {
            io.decrementAndGet()
        }
        markClosing()
        loop.post { loop.finishClose(this) }
    }

    companion object {
        const val CLOSING = 1 shl 30
    }
}
