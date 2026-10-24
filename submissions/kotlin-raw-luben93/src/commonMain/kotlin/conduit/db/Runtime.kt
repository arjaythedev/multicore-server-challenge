package conduit.db

import conduit.pg.Oid
import conduit.pg.Params
import conduit.pg.PgConn
import conduit.pg.PgException
import conduit.pg.PgStatement
import conduit.pg.Result
import conduit.pg.beginBind
import conduit.pg.endBindExecute
import conduit.pg.sync
import conduit.platform.Monitor
import conduit.platform.locked
import conduit.platform.nanoTime
import conduit.util.ByteBuf
import kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED
import kotlin.coroutines.intrinsics.suspendCoroutineUninterceptedOrReturn
import kotlin.jvm.JvmField

/**
 * One database runtime: the statement table, the read pool and the write pool. [Db] holds the process-wide one;
 * tests create their own.
 *
 * Statement names: read kind i is "s<i>", write statement j is "s<reads + j>", then BEGIN, COMMIT and ROLLBACK.
 * Every connection prepares all of them, so any connection can run anything.
 */
internal class DbRuntime(@JvmField val config: DbConfig, reads: List<ReadKind>, writes: List<WriteStmt>) {
    private val statements: List<PgStatement>
    @JvmField val beginExec: ByteArray
    @JvmField val commitExec: ByteArray
    @JvmField val rollbackExec: ByteArray
    @JvmField val readPool: ReadPool
    @JvmField val writePool: WritePool
    private val where = "${config.user}@${config.host}:${config.port}/${config.database}"
    private val sleeper = Monitor()

    init {
        require(config.readConns >= 1 && config.writeConns >= 1) { "need at least one read and one write connection" }
        val list = ArrayList<PgStatement>()
        reads.forEachIndexed { i, k ->
            k.id = i
            list.add(PgStatement("s$i", k.sql, READ_OIDS, "read kind '${k.name}'"))
        }
        writes.forEachIndexed { j, w ->
            w.id = j
            list.add(PgStatement("s${reads.size + j}", w.sql, w.paramOids, "write '${w.name}'"))
        }
        val tx = reads.size + writes.size
        list.add(PgStatement("s$tx", "BEGIN", IntArray(0), "BEGIN"))
        list.add(PgStatement("s${tx + 1}", "COMMIT", IntArray(0), "COMMIT"))
        list.add(PgStatement("s${tx + 2}", "ROLLBACK", IntArray(0), "ROLLBACK"))
        statements = list
        beginExec = bindExec("s$tx")
        commitExec = bindExec("s${tx + 1}")
        rollbackExec = bindExec("s${tx + 2}")
        readPool = ReadPool(this, config, list, reads, List(reads.size) { PgConn.cstr("s$it") })
        writePool = WritePool(this, config, list, writes, List(writes.size) { PgConn.cstr("s${reads.size + it}") })
    }

    private fun bindExec(name: String): ByteArray {
        val o = ByteBuf(64)
        val lp = o.beginBind(PgConn.cstr(name), 0)
        o.endBindExecute(lp)
        return o.toByteArray()
    }

    /** Opens every connection (the first one patiently: Postgres may still be starting), then starts the threads. */
    fun start() {
        val total = config.readConns + config.writeConns
        val conns = ArrayList<PgConn>(total)
        try {
            conns.add(connectFirst())
            while (conns.size < total) conns.add(connectMore())
        } catch (e: Throwable) {
            for (c in conns) c.close()
            throw e
        }
        startWorkers(readPool, readPool.workers, conns.subList(0, config.readConns))
        startWorkers(writePool, writePool.workers, conns.subList(config.readConns, total))
    }

    private fun startWorkers(pool: Pool, workers: Array<out Worker>, conns: List<PgConn>) {
        pool.lock.locked {
            for (i in workers.indices) {
                workers[i].conn = conns[i]
                pool.pushIdleLocked(workers[i])
                pool.healthy++
            }
        }
        for (i in workers.indices) workers[i].start(conns[i])
    }

    private fun connectFirst(): PgConn {
        val deadline = nanoTime() + FIRST_CONNECT_NANOS
        var attempts = 0
        while (true) {
            val failure: Throwable
            try {
                val c = PgConn.connect(
                    config.host, config.port, config.user, config.password, config.database, config.options,
                )
                try {
                    c.prepare(statements)
                } catch (e: Throwable) {
                    c.close()
                    throw IllegalStateException("database $where: ${e.message}", e)
                }
                if (attempts > 0) println("db: connected to $where after ${attempts + 1} attempts")
                return c
            } catch (e: PgException) {
                if (!retryable(e.error.code)) throw IllegalStateException("database $where: ${e.message}", e)
                failure = e
            } catch (e: IllegalStateException) {
                throw e
            } catch (e: Throwable) {
                failure = e // connection refused, reset while starting up, ...
            }
            if (attempts++ == 0) println("db: waiting for $where: ${failure.message}")
            if (nanoTime() > deadline) {
                throw IllegalStateException("database $where not reachable after 50 s: ${failure.message}", failure)
            }
            sleepNanos(sleeper, FIRST_RETRY_NANOS)
        }
    }

    private fun connectMore(): PgConn {
        var attempt = 0
        while (true) {
            try {
                return readPool.connect()
            } catch (e: Throwable) {
                if (++attempt >= 3) throw IllegalStateException("database $where: ${e.message}", e)
                sleepNanos(sleeper, FIRST_RETRY_NANOS)
            }
        }
    }

    /** See [Db.read]: always suspends; resumed on the read connection thread that ran the batch. */
    suspend fun read(kind: ReadKind, viewer: Long, limit: Int = 0, offset: Long = 0, key: String = ""): Result =
        suspendCoroutineUninterceptedOrReturn { c ->
            readPool.enqueue(kind, viewer, limit, offset, key, c)
            COROUTINE_SUSPENDED
        }

    /** See [Db.write]: always suspends; resumed on the write connection thread after the commit. */
    suspend fun write(stmt: WriteStmt, params: Params, isolated: Boolean = false): Result =
        suspendCoroutineUninterceptedOrReturn { c ->
            writePool.enqueue(stmt, params, isolated, c)
            COROUTINE_SUSPENDED
        }

    /** Leaves a transaction a reply unexpectedly left open (ReadyForQuery status 'T' or 'E'). Worker thread only. */
    fun rollback(c: PgConn) {
        val o = c.out
        o.reset()
        o.put(rollbackExec)
        o.sync()
        c.send()
        while (c.next() != 'Z'.code) {
            // BindComplete, CommandComplete
        }
    }

    fun stats(): String = readPool.stats() + "; " + writePool.stats()

    /**
     * Tests only: closes every connection and lets the workers exit instead of reconnecting. In-flight requests get
     * 08006. (Relies on a close from another thread waking a blocked read, which holds on the JVM.)
     */
    fun stop() {
        for (pool in listOf<Pool>(readPool, writePool)) pool.lock.locked { pool.stopping = true }
        for (w in readPool.workers) w.conn?.close()
        for (w in writePool.workers) w.conn?.close()
    }

    companion object {
        /** $1 int4[] i, $2 int8[] v, $3 int4[] l, $4 int8[] o, $5 text[] k. */
        private val READ_OIDS = intArrayOf(Oid.INT4_ARRAY, Oid.INT8_ARRAY, Oid.INT4_ARRAY, Oid.INT8_ARRAY, Oid.TEXT_ARRAY)
        private const val FIRST_CONNECT_NANOS = 50_000_000_000L
        private const val FIRST_RETRY_NANOS = 500_000_000L

        /** Worth waiting for: connection trouble, starting up / shutting down, too many clients, no database yet. */
        fun retryable(sqlstate: String): Boolean =
            sqlstate.startsWith("08") || sqlstate.startsWith("57") || sqlstate.startsWith("53") || sqlstate == "3D000"
    }
}

/**
 * Blocks the calling thread for [nanos], waiting on [m], a Monitor nobody signals (the platform layer has no sleep;
 * Monitors are kept, not created per call, because a native Monitor's pthread objects are never freed).
 */
internal fun sleepNanos(m: Monitor, nanos: Long) {
    val deadline = nanoTime() + nanos
    m.lock()
    try {
        while (true) {
            val left = deadline - nanoTime()
            if (left <= 0) break
            m.awaitNanos(left)
        }
    } finally {
        m.unlock()
    }
}
