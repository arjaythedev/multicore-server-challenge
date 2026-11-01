package conduit.platform

import conduit.http.HttpConn
import conduit.http.HttpEngine
import conduit.util.logSafe
import java.io.IOException
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.StandardProtocolFamily
import java.net.StandardSocketOptions
import java.nio.ByteBuffer
import java.nio.channels.CancelledKeyException
import java.nio.channels.SelectionKey
import java.nio.channels.Selector
import java.nio.channels.ServerSocketChannel
import java.nio.channels.SocketChannel
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicIntegerFieldUpdater
import java.util.function.Consumer

private const val READ_CHUNK = 64 * 1024
/** Largest slice per write call: bounds the JDK's cached per-thread temporary direct buffers. */
private const val WRITE_CHUNK = 256 * 1024
private const val BACKLOG = 65535
private const val ACCEPT_PAUSE_NS = 100_000_000L
private const val TASKS_PER_TURN = 4096

/**
 * JVM: [loops] NIO selector threads. Each binds its own SO_REUSEPORT listener (the kernel spreads new connections
 * over them); without SO_REUSEPORT loop 0 accepts for everybody and hands sockets out round-robin.
 */
internal fun startNioServer(host: String, port: Int, loops: Int, engine: HttpEngine) {
    val n = maxOf(1, loops)
    val addr = InetSocketAddress(InetAddress.getByName(host), port)
    val reusePort = n > 1 && ServerSocketChannel.open(family(addr)).use {
        it.supportedOptions().contains(StandardSocketOptions.SO_REUSEPORT)
    }
    val all = Array(n) { NioLoop(it, engine) }
    for (loop in all) {
        loop.peers = all
        if (reusePort || loop.index == 0) loop.listen(addr, reusePort)
    }
    for (loop in all) startThread("http-${loop.index}") { loop.run() }
}

private fun family(addr: InetSocketAddress) =
    if (addr.address is Inet4Address) StandardProtocolFamily.INET else StandardProtocolFamily.INET6

internal class NioLoop(@JvmField val index: Int, private val engine: HttpEngine) {
    private val selector: Selector = Selector.open()
    @JvmField var peers: Array<NioLoop> = emptyArray()
    private var server: ServerSocketChannel? = null
    private var serverKey: SelectionKey? = null
    private var shared = false
    private var next = 0
    private var acceptPausedUntil = 0L

    private val tasks = ConcurrentLinkedQueue<() -> Unit>()
    /** True while the loop may be blocked in select(): a poster must wake it (only the first one does). */
    private val sleeping = AtomicBoolean(false)

    private val readBuf: ByteBuffer = ByteBuffer.allocateDirect(READ_CHUNK)
    private val scratch = ByteArray(READ_CHUNK)
    private val onKey = Consumer<SelectionKey> { handle(it) }

    fun listen(addr: InetSocketAddress, reusePort: Boolean) {
        val ch = ServerSocketChannel.open(family(addr))
        ch.setOption(StandardSocketOptions.SO_REUSEADDR, true)
        if (reusePort) ch.setOption(StandardSocketOptions.SO_REUSEPORT, true)
        ch.bind(addr, BACKLOG)
        ch.configureBlocking(false)
        server = ch
        shared = !reusePort && peers.size > 1
        serverKey = ch.register(selector, SelectionKey.OP_ACCEPT, null)
    }

    fun run() {
        while (true) {
            try {
                turn()
            } catch (e: Throwable) {
                logSafe({ "http-$index: loop error" }, e) // never throws: nothing here may end the loop
            }
        }
    }

    private fun turn() {
        var timeout = 0L // 0 = no timeout
        if (acceptPausedUntil != 0L) {
            val left = acceptPausedUntil - System.nanoTime()
            if (left <= 0) {
                acceptPausedUntil = 0
                serverKey?.interestOps(SelectionKey.OP_ACCEPT)
            } else timeout = maxOf(1L, left / 1_000_000)
        }
        sleeping.set(true) // then re-check tasks: a poster that saw sleeping == false relies on this check
        if (tasks.isEmpty()) selector.select(onKey, timeout) else selector.selectNow(onKey)
        sleeping.set(false)
        runTasks()
    }

    private fun handle(key: SelectionKey) {
        // callbacks run inside select() but after epoll_wait returned: posters need not wake us any more
        if (sleeping.get()) sleeping.set(false)
        val c = key.attachment()
        if (c !is JvmConn) {
            accept()
            return
        }
        try {
            val ops = key.readyOps()
            if (ops and SelectionKey.OP_WRITE != 0) {
                key.interestOps(SelectionKey.OP_READ)
                if (c.closing == 0) engine.onWritable(c)
            }
            if (ops and SelectionKey.OP_READ != 0 && c.closing == 0) read(c)
        } catch (_: CancelledKeyException) {
            finishClose(c)
        }
    }

    private fun read(c: JvmConn) {
        val buf = readBuf
        buf.clear()
        val n = try {
            c.ch.read(buf)
        } catch (_: IOException) {
            -1
        }
        if (n > 0) {
            buf.flip()
            buf.get(scratch, 0, n)
            engine.onData(c, scratch, 0, n)
        } else if (n < 0) {
            finishClose(c)
        }
    }

    private fun accept() {
        val srv = server ?: return
        while (true) {
            val ch = try {
                srv.accept() ?: return
            } catch (e: IOException) {
                // EMFILE/ENFILE: the listener stays readable, so stop polling it for a while instead of spinning
                serverKey?.interestOps(0)
                acceptPausedUntil = System.nanoTime() + ACCEPT_PAUSE_NS
                println("http-$index: accept: $e; pausing accepts for 100 ms")
                return
            }
            if (shared) {
                val target = peers[next]
                next = (next + 1) % peers.size
                if (target !== this) {
                    target.post { target.register(ch) }
                    continue
                }
            }
            register(ch)
        }
    }

    private fun register(ch: SocketChannel) {
        val c = try {
            ch.configureBlocking(false)
            ch.setOption(StandardSocketOptions.TCP_NODELAY, true)
            val c = JvmConn(ch, this)
            c.key = ch.register(selector, SelectionKey.OP_READ, c)
            c
        } catch (e: IOException) {
            try {
                ch.close()
            } catch (_: IOException) {
            }
            return
        }
        engine.onOpen(c)
    }

    /** Loop thread: closes the channel (once) and tells the engine. */
    fun finishClose(c: JvmConn) {
        if (c.released) return
        c.released = true
        c.closing = 1
        c.key?.cancel()
        try {
            c.ch.close()
        } catch (_: IOException) {
        }
        engine.onClosed(c)
    }

    fun armWrite(c: JvmConn) {
        val k = c.key ?: return
        if (c.closing == 0 && k.isValid) k.interestOps(SelectionKey.OP_READ or SelectionKey.OP_WRITE)
    }

    /** Any thread: runs [task] on this loop soon. Never inline (the engine relies on that). */
    fun post(task: () -> Unit) {
        tasks.offer(task)
        if (sleeping.get() && sleeping.compareAndSet(true, false)) selector.wakeup()
    }

    private fun runTasks() {
        var n = 0
        while (n++ < TASKS_PER_TURN) {
            val t = tasks.poll() ?: return
            try {
                t()
            } catch (e: Throwable) {
                logSafe({ "http-$index: task failed" }, e)
            }
        }
    }
}

private val CLOSING = AtomicIntegerFieldUpdater.newUpdater(JvmConn::class.java, "closing")

/** A client socket. SocketChannel.write is thread-safe, so responses are written by whichever thread answers. */
internal class JvmConn(@JvmField val ch: SocketChannel, @JvmField val loop: NioLoop) : HttpConn() {
    @JvmField var key: SelectionKey? = null
    /** 1 once close() was called or the loop closed the socket (any thread reads it). */
    @JvmField @Volatile var closing = 0
    /** Loop thread only: the channel is closed and onClosed was delivered. */
    @JvmField var released = false

    override fun tryWrite(b: ByteArray, off: Int, len: Int): Int {
        if (closing != 0) return -1
        var done = 0
        try {
            while (done < len) {
                val n = minOf(len - done, WRITE_CHUNK)
                val w = ch.write(ByteBuffer.wrap(b, off + done, n))
                done += w
                if (w < n) break
            }
        } catch (_: IOException) { // includes ClosedChannelException / AsynchronousCloseException
            return -1
        }
        return done
    }

    override fun requestWritable() {
        if (closing == 0) loop.post { loop.armWrite(this) }
    }

    override fun execute(task: () -> Unit) = loop.post(task)

    override fun close() {
        if (CLOSING.compareAndSet(this, 0, 1)) loop.post { loop.finishClose(this) }
    }
}
