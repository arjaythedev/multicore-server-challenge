package conduit.db

import conduit.pg.PgConn
import conduit.pg.PgError
import conduit.pg.PgStatement
import conduit.platform.Monitor
import conduit.platform.locked
import conduit.platform.startThread
import kotlin.jvm.JvmField

/**
 * What the read and write pools share: one [Monitor] guarding the queues and every worker's state, a stack of idle
 * workers, and the connection-driven dispatch rule. There are no timers: work is handed to a connection when it is
 * queued and a connection is idle, or when a connection finishes its previous round trip.
 *
 * An idle worker's thread sits in a blocking read on its socket (so it also notices a dead connection at once). The
 * thread that hands it work (any thread that queued a request, or the worker itself after a reply) encodes the
 * round trip into the connection's send buffer under [lock] and writes it after unlocking; no thread wake-up is
 * needed on the way to Postgres.
 */
internal abstract class Pool(
    @JvmField val name: String,
    private val config: DbConfig,
    private val statements: List<PgStatement>,
    size: Int,
) {
    @JvmField val lock = Monitor()
    private val idle = arrayOfNulls<Worker>(size)
    private var idleCount = 0

    /** Workers with a live connection (guarded by [lock]). */
    @JvmField var healthy = 0
    @JvmField var reconnects = 0L

    /** Set by [DbRuntime.stop] (tests): workers exit instead of reconnecting. */
    @JvmField var stopping = false

    /** Opens and prepares one connection (any thread; blocks). */
    fun connect(): PgConn {
        val c = PgConn.connect(
            config.host, config.port, config.user, config.password, config.database, config.options,
        )
        try {
            c.prepare(statements)
        } catch (e: Throwable) {
            c.close()
            throw e
        }
        return c
    }

    fun pushIdleLocked(w: Worker) {
        if (w.idle) return
        w.idle = true
        idle[idleCount++] = w
    }

    fun removeIdleLocked(w: Worker) {
        if (!w.idle) return
        w.idle = false
        for (i in 0 until idleCount) {
            if (idle[i] === w) {
                idle[i] = idle[--idleCount]
                idle[idleCount] = null
                return
            }
        }
    }

    /**
     * Under [lock], after queueing: gives queued work to the most recently idled worker (LIFO keeps few Postgres
     * backends hot). Returns the connection the caller must [send] on after unlocking, or null.
     */
    fun dispatchLocked(): PgConn? {
        if (idleCount == 0) return null
        val w = idle[--idleCount]!!
        idle[idleCount] = null
        w.idle = false
        return if (assignLocked(w)) w.conn else null
    }

    /**
     * Under [lock]: moves the next round trip's worth of queued requests to [w] (encoding it into w.conn.out, setting
     * w.inFlight) and returns true, or parks [w] on the idle stack and returns false.
     */
    abstract fun assignLocked(w: Worker): Boolean

    /** Under [lock], when no connection is left: removes every queued request so it can be failed. */
    abstract fun drainLocked(): List<Any>?

    /** Resumes requests taken by [drainLocked] with [err]. No lock held. */
    abstract fun failDrained(drained: List<Any>, err: PgError)

    /** Writes the encoded round trip. A failure is left to the worker's reader, which sees the dead socket. */
    fun send(c: PgConn) {
        try {
            c.send()
        } catch (_: Throwable) {
        }
    }
}

/**
 * One connection and its thread. The thread blocks reading replies; between replies it completes the finished round
 * trip, sends the next one if requests are queued (so Postgres works while we resume the finished requests), and
 * only then resumes the finished requests' continuations, on this thread. Their Results point into the receive
 * buffer, which is not touched again until they have run.
 *
 * Subclasses hold the round-trip objects; all state changes happen under [Pool.lock].
 */
internal abstract class Worker(@JvmField val pool: Pool, @JvmField val index: Int) {
    /** Current connection; null while reconnecting. */
    @JvmField var conn: PgConn? = null
    @JvmField var idle = false

    /** A round trip has been assigned and its reply not yet fully processed. */
    @JvmField var inFlight = false

    private val sleeper = Monitor()

    /** Reads the in-flight round trip's reply up to its (last) ReadyForQuery; may do extra round trips. */
    abstract fun processReply(c: PgConn)

    /** Under lock: the in-flight round trip is complete (inFlight = false); it becomes the one to resume. */
    abstract fun completeLocked()

    /** No lock: resumes every request of the completed round trip. */
    abstract fun resumeCompleted()

    /** Under lock: the connection died; the in-flight round trip (if any) becomes the one to fail. */
    abstract fun abandonLocked(): Boolean

    /** No lock: resumes the abandoned round trip's requests; those not yet settled get [err]. */
    abstract fun resumeAbandoned(err: PgError)

    fun start(first: PgConn) {
        conn = first
        startThread("pg-${pool.name}-$index") { run(first) }
    }

    private fun run(first: PgConn) {
        var c = first
        while (true) {
            try {
                serve(c)
            } catch (e: Throwable) {
                c.close()
                lost(e)
                c = reconnect() ?: return
            }
        }
    }

    private fun serve(c: PgConn) {
        val lock = pool.lock
        while (true) {
            c.beginReply()
            c.next() // blocks until a reply (or an asynchronous message, or EOF) arrives
            c.pushBack()
            // the sender set inFlight under the lock before writing, so it is visible here, and so is out/its batch
            if (!lock.locked { inFlight }) {
                asyncMessage(c)
                continue
            }
            processReply(c)
            val more = lock.locked {
                completeLocked()
                pool.assignLocked(this)
            }
            if (more) pool.send(c)
            resumeCompleted()
        }
    }

    /** NoticeResponse, ParameterStatus or a FATAL ErrorResponse (shutdown, terminate) while idle. */
    private fun asyncMessage(c: PgConn) {
        if (c.next() == 'E'.code) println("db: ${pool.name}-$index: server error while idle: ${c.error()}")
    }

    private fun lost(e: Throwable) {
        val err = PgError(CONNECTION_FAILURE, "database connection lost: ${e.message ?: e}")
        var had = false
        val drained = pool.lock.locked {
            conn = null
            pool.removeIdleLocked(this)
            pool.healthy--
            had = abandonLocked()
            if (pool.healthy == 0) pool.drainLocked() else null
        }
        println("db: ${pool.name}-$index: ${err.message}; reconnecting")
        if (had) resumeAbandoned(err)
        if (drained != null) pool.failDrained(drained, err)
    }

    /** Retries every second until connected and prepared again, then takes queued work. Null once stopping. */
    private fun reconnect(): PgConn? {
        var attempt = 0
        while (true) {
            if (attempt > 0) sleepNanos(sleeper, RECONNECT_NANOS)
            if (pool.lock.locked { pool.stopping }) return null
            try {
                val c = pool.connect()
                val more = pool.lock.locked {
                    conn = c
                    pool.healthy++
                    pool.reconnects++
                    pool.assignLocked(this)
                }
                if (more) pool.send(c)
                println("db: ${pool.name}-$index: reconnected after ${attempt + 1} attempt(s)")
                return c
            } catch (e: Throwable) {
                if (attempt % 30 == 0) println("db: ${pool.name}-$index: reconnect failed: ${e.message ?: e}")
                attempt++
                val drained = pool.lock.locked { if (pool.healthy == 0) pool.drainLocked() else null }
                // nothing can serve queued requests: fail them now rather than let them hang
                if (drained != null) {
                    pool.failDrained(drained, PgError(CONNECTION_FAILURE, "database unavailable: ${e.message ?: e}"))
                }
            }
        }
    }

    companion object {
        /** SQLSTATE connection_failure, given to requests whose connection died. */
        const val CONNECTION_FAILURE = "08006"
        private const val RECONNECT_NANOS = 1_000_000_000L
    }
}
