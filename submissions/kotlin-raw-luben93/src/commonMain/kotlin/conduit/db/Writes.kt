package conduit.db

import conduit.pg.Oid
import conduit.pg.Params
import conduit.pg.PgConn
import conduit.pg.PgError
import conduit.pg.PgStatement
import conduit.pg.Result
import conduit.pg.beginBind
import conduit.pg.endBindExecute
import conduit.pg.sync
import conduit.platform.locked
import conduit.platform.nanoTime
import conduit.util.ByteBuf
import conduit.util.Timing
import conduit.util.intBE
import conduit.util.logSafe
import conduit.util.shortBE
import kotlin.coroutines.Continuation
import kotlin.coroutines.resume
import kotlin.jvm.JvmField

/** One queued write. [params] stays untouched until the caller resumes (a failed group re-sends it alone). */
internal class WriteJob(
    @JvmField val stmt: WriteStmt,
    @JvmField val params: Params,
    @JvmField val isolated: Boolean,
    @JvmField val cont: Continuation<Result>,
) {
    @JvmField val res = Result()

    /** Its outcome is final: the ReadyForQuery ending its own transaction was seen. */
    @JvmField var settled = false

    /** When it was queued ([nanoTime]), for the statistics. */
    @JvmField val born = nanoTime()
}

/** FIFO ring of write jobs (power-of-two capacity). Guarded by the pool lock. */
internal class JobQueue {
    @JvmField var ring = arrayOfNulls<WriteJob>(16)
    @JvmField var head = 0
    @JvmField var size = 0

    fun add(j: WriteJob) {
        if (size == ring.size) {
            val bigger = arrayOfNulls<WriteJob>(size * 2)
            for (i in 0 until size) bigger[i] = ring[(head + i) and (size - 1)]
            ring = bigger
            head = 0
        }
        ring[(head + size) and (ring.size - 1)] = j
        size++
    }

    fun poll(): WriteJob {
        val j = ring[head]!!
        ring[head] = null
        head = (head + 1) and (ring.size - 1)
        size--
        return j
    }
}

/**
 * One round trip on a write connection: jobs[0, nIso) are isolated writes, each in its own implicit transaction
 * (own Sync); jobs[nIso, n) are the group: one job alone (autocommit), or BEGIN, every job, COMMIT and one Sync.
 * The group goes last, so its failed transaction can never swallow an isolated write.
 */
internal class WriteTrip(cap: Int) {
    @JvmField val jobs = arrayOfNulls<WriteJob>(cap)
    @JvmField var nIso = 0
    @JvmField var n = 0

    /** When it was handed to its connection ([nanoTime]), for the statistics. */
    @JvmField var sentAt = 0L

    /**
     * The group as statements ([WritePool.plan]): unit u is jobs[unitStart[u], +unitCount[u]): one job, or (count >= 2) jobs
     * of one statement sent as ONE batched execution. Jobs of a batched unit are contiguous in [jobs].
     */
    @JvmField val unitStart = IntArray(WritePool.MAX_GROUP)
    @JvmField val unitCount = IntArray(WritePool.MAX_GROUP)
    @JvmField var nUnits = 0
    @JvmField val tmp = arrayOfNulls<WriteJob>(WritePool.MAX_GROUP)
    @JvmField val taken = BooleanArray(WritePool.MAX_GROUP)
}

internal class WriteWorker(pool: WritePool, index: Int) : Worker(pool, index) {
    private val a = WriteTrip(WritePool.MAX_TRIP)
    private val b = WriteTrip(WritePool.MAX_TRIP)
    @JvmField var flight: WriteTrip? = null
    @JvmField var done: WriteTrip? = null
    private val wpool = pool

    fun spare(): WriteTrip = if (done === a) b else a

    override fun processReply(c: PgConn) {
        val t = flight!!
        for (j in 0 until t.n) {
            val job = t.jobs[j]!!
            job.res.clear()
            job.settled = false
        }
        var status = 'I'.code
        for (j in 0 until t.nIso) status = readSingle(c, t.jobs[j]!!)
        val g = t.n - t.nIso
        if (g == 1) status = readSingle(c, t.jobs[t.nIso]!!)
        else if (g > 1) status = readGroup(c, t)
        if (status != 'I'.code) wpool.runtime.rollback(c)
        val buf = c.rbuf // it may have grown (same offsets) since the first rows were added
        for (j in 0 until t.n) t.jobs[j]!!.res.buf = buf
    }

    /** One statement in its own implicit transaction: rows, count or error, then ReadyForQuery. */
    private fun readSingle(c: PgConn, job: WriteJob): Int {
        val r = job.res
        while (true) {
            when (c.next()) {
                'D'.code -> if (r.error == null) r.addRow(c.rbuf, c.mstart)
                'C'.code -> r.affected = c.tagCount()
                'E'.code -> if (r.error == null) {
                    r.error = c.error()
                    r.rowCount = 0
                }
                'Z'.code -> {
                    job.settled = true
                    return c.txStatus()
                }
            }
        }
    }

    /**
     * Explicit group: BEGIN, jobs, COMMIT, Sync; statement s: 0 = BEGIN, 1..g = jobs, g+1 = COMMIT. Implicit group (the
     * jobs and one Sync, Postgres commits at the Sync): s: 0 until g = jobs, and an error after all g
     * CommandCompletes is the commit's.
     */
    private fun readGroup(c: PgConn, t: WriteTrip): Int {
        val first = t.nIso
        val units = t.nUnits
        val base = if (wpool.implicitTx) 0 else 1
        var s = 0
        var err: PgError? = null
        var errAt = -1
        while (true) {
            val m = c.next()
            if (m == 'D'.code) {
                val u = s - base
                if (err == null && u >= 0 && u < units) route(c, t, u)
            } else if (m == 'C'.code) {
                val u = s - base
                if (u >= 0 && u < units) {
                    val at = t.unitStart[u]
                    val n = t.unitCount[u]
                    if (n == 1) t.jobs[at]!!.res.affected = c.tagCount()
                    else for (j in at until at + n) t.jobs[j]!!.res.let { it.affected = it.rowCount.toLong() }
                }
                s++
            } else if (m == 'E'.code) {
                if (err == null) {
                    err = c.error()
                    errAt = s
                }
            } else if (m == 'Z'.code) {
                break
            }
        }
        val status = c.txStatus()
        if (err == null) {
            for (j in first until t.n) t.jobs[j]!!.settled = true
            return status
        }
        if (errAt == units + base) {
            // COMMIT itself failed: the outcome is not ours to guess, so nothing is retried
            for (j in first until t.n) {
                val job = t.jobs[j]!!
                job.res.clear()
                job.res.error = err
                job.settled = true
            }
            wpool.lock.locked { wpool.commitFailures++ }
            return status
        }
        // A statement failed and aborted the transaction: roll back, then run every job alone (one round trip, a
        // Sync after each), so one unique violation or deadlock cannot fail the others.
        wpool.lock.locked { wpool.reruns++ }
        val o = c.out
        o.reset()
        if (!wpool.implicitTx) { // an implicit transaction was rolled back by the Sync already
            o.put(wpool.runtime.rollbackExec)
            o.sync()
        }
        for (j in first until t.n) {
            wpool.encodeJob(o, t.jobs[j]!!)
            o.sync()
        }
        c.send()
        if (!wpool.implicitTx) {
            while (c.next() != 'Z'.code) {
                // ROLLBACK's BindComplete / CommandComplete
            }
        }
        var st = 'I'.code
        for (j in first until t.n) {
            val job = t.jobs[j]!!
            job.res.clear()
            st = readSingle(c, job)
        }
        return st
    }

    /**
     * The DataRow just read belongs to unit [u]: a single job's row as it is, a batched unit's row to the job named by its
     * column 0 (i), with column 0 cut off in place (the Int16 column count is rewritten over the end of i's value), so
     * the job sees exactly the row its own statement would have returned.
     */
    private fun route(c: PgConn, t: WriteTrip, u: Int) {
        val at = t.unitStart[u]
        val n = t.unitCount[u]
        if (n == 1) {
            t.jobs[at]!!.res.addRow(c.rbuf, c.mstart)
            return
        }
        val b = c.rbuf
        val p = c.mstart
        val i = b.intBE(p + 6)
        if (i < 0 || i >= n) return
        val cols = b.shortBE(p) - 1
        b[p + 8] = (cols ushr 8).toByte()
        b[p + 9] = cols.toByte()
        t.jobs[at + i]!!.res.addRow(b, p + 8)
    }

    override fun completeLocked() {
        val rt = nanoTime() - flight!!.sentAt
        wpool.rtt.add(rt)
        wpool.busyNanos += rt
        done = flight
        flight = null
        inFlight = false
    }

    override fun resumeCompleted() = resume(done!!)

    override fun abandonLocked(): Boolean {
        val t = flight ?: return false
        done = t
        flight = null
        inFlight = false
        return true
    }

    override fun resumeAbandoned(err: PgError) {
        val t = done!!
        for (j in 0 until t.n) {
            val job = t.jobs[j]!!
            if (!job.settled) {
                job.res.clear()
                job.res.error = err
            }
        }
        resume(t)
    }

    private fun resume(t: WriteTrip) {
        for (j in 0 until t.n) {
            val job = t.jobs[j]!!
            t.jobs[j] = null
            try {
                job.cont.resume(job.res)
            } catch (e: Throwable) { // one handler failing must not skip the rest of the trip
                logSafe({ "db: write continuation threw" }, e)
            }
        }
    }
}

/**
 * The write connections, with group commit: a free connection takes every queued group-able write (up to
 * [MAX_GROUP]) and commits them as one transaction in one round trip; callers resume only after COMMIT's
 * ReadyForQuery. Isolated writes (likely to fail, e.g. unique violations on register) ride along in their own
 * implicit transactions.
 */
internal class WritePool(
    @JvmField val runtime: DbRuntime,
    config: DbConfig,
    statements: List<PgStatement>,
    private val stmts: List<WriteStmt>,
    private val stmtNames: List<ByteArray>,
    /** Per statement: the name of its prepared batch form, null where it has none (or batching is off). */
    private val batchNames: List<ByteArray?>,
) : Pool("write", config, statements, config.writeConns, config.writeQueueMax) {
    @JvmField val workers = Array(config.writeConns) { WriteWorker(this, it) }
    @JvmField val implicitTx = config.implicitTx
    private val batching = config.batchWrites && batchNames.any { it != null }
    private val isoQ = JobQueue()
    private val groupQ = JobQueue()

    // statistics (guarded by lock)
    @JvmField var trips = 0L
    @JvmField var jobs = 0L
    @JvmField var groups = 0L

    // statistics of the current DB_STATS_S interval, as for reads (see ReadPool.intervalStats)
    @JvmField var iJobs = 0L
    @JvmField var iTrips = 0L
    @JvmField var busyNanos = 0L
    @JvmField val wait = Timing()
    @JvmField val rtt = Timing()
    @JvmField var groupedJobs = 0L
    @JvmField var largestGroup = 0
    @JvmField var reruns = 0L
    @JvmField var commitFailures = 0L

    fun enqueue(stmt: WriteStmt, params: Params, isolated: Boolean, cont: Continuation<Result>) {
        val id = stmt.id
        check(id >= 0 && id < stmts.size && stmts[id] === stmt) { "WriteStmt ${stmt.name} was not passed to Db.start" }
        val job = WriteJob(stmt, params, isolated, cont)
        val c = lock.locked {
            if (isolated) isoQ.add(job) else groupQ.add(job)
            noteQueuedLocked(isoQ.size + groupQ.size)
            dispatchLocked()
        }
        if (c != null) send(c)
    }

    override fun assignLocked(w: Worker): Boolean {
        w as WriteWorker
        if (isoQ.size == 0 && groupQ.size == 0) {
            pushIdleLocked(w)
            return false
        }
        val t = w.spare()
        var k = 0
        while (isoQ.size > 0 && k < MAX_ISOLATED) t.jobs[k++] = isoQ.poll()
        t.nIso = k
        while (groupQ.size > 0 && k - t.nIso < MAX_GROUP) t.jobs[k++] = groupQ.poll()
        t.n = k
        noteQueuedLocked(isoQ.size + groupQ.size)
        val now = nanoTime()
        for (j in 0 until k) wait.add(now - t.jobs[j]!!.born)
        t.sentAt = now
        iJobs += k
        iTrips++
        w.flight = t
        w.inFlight = true
        encode(t, w.conn!!.out)
        trips++
        jobs += k
        val g = k - t.nIso
        if (g > 1) {
            groups++
            groupedJobs += g
            if (g > largestGroup) largestGroup = g
        }
        return true
    }

    private fun encode(t: WriteTrip, o: ByteBuf) {
        o.reset()
        for (j in 0 until t.nIso) {
            encodeJob(o, t.jobs[j]!!)
            o.sync()
        }
        val g = t.n - t.nIso
        if (g == 1) {
            encodeJob(o, t.jobs[t.nIso]!!)
            o.sync()
        } else if (g > 1) {
            plan(t)
            if (!implicitTx) o.put(runtime.beginExec)
            for (u in 0 until t.nUnits) {
                val at = t.unitStart[u]
                val n = t.unitCount[u]
                if (n == 1) encodeJob(o, t.jobs[at]!!) else encodeBatch(o, t, at, n)
            }
            if (!implicitTx) o.put(runtime.commitExec)
            o.sync()
        }
    }

    /**
     * Under the pool lock: splits the group into statements. Without batching every job is one. With it, the jobs of a
     * statement that has a batch form are pulled together (at the position of its first job, the others keep their order)
     * and sent as one execution. Jobs of different requests in one group are concurrent, so any order is a valid one.
     */
    private fun plan(t: WriteTrip) {
        val first = t.nIso
        val g = t.n - first
        var nu = 0
        if (!batching) {
            for (j in 0 until g) {
                t.unitStart[nu] = first + j
                t.unitCount[nu] = 1
                nu++
            }
            t.nUnits = nu
            return
        }
        for (j in 0 until g) {
            t.tmp[j] = t.jobs[first + j]
            t.taken[j] = false
        }
        var pos = first
        for (j in 0 until g) {
            if (t.taken[j]) continue
            val job = t.tmp[j]!!
            t.unitStart[nu] = pos
            var c = 0
            t.jobs[pos + c++] = job
            if (batchNames[job.stmt.id] != null && nonNull(job.params)) {
                for (k in j + 1 until g) {
                    val other = t.tmp[k]!!
                    if (!t.taken[k] && other.stmt === job.stmt && nonNull(other.params)) {
                        t.taken[k] = true
                        t.jobs[pos + c++] = other
                    }
                }
            }
            t.unitCount[nu] = c
            pos += c
            nu++
        }
        for (j in 0 until g) t.tmp[j] = null
        t.nUnits = nu
    }

    /** No parameter is NULL (a batch form's arrays hold no NULLs). */
    private fun nonNull(p: Params): Boolean {
        val b = p.out.buf
        var off = 0
        for (k in 0 until p.count) {
            val len = b.intBE(off)
            if (len < 0) return false
            off += 4 + len
        }
        return true
    }

    private val offs = IntArray(MAX_GROUP * MAX_BATCH_PARAMS)

    /** One execution of the batch form for jobs[at, at + n) of one statement: $1 = 0..n-1, then each parameter as an array. */
    private fun encodeBatch(o: ByteBuf, t: WriteTrip, at: Int, n: Int) {
        val stmt = t.jobs[at]!!.stmt
        val np = stmt.paramOids.size
        require(np <= MAX_BATCH_PARAMS) { "batched write '${stmt.name}' has too many parameters" }
        for (x in 0 until n) {
            val p = t.jobs[at + x]!!.params
            var off = 0
            for (k in 0 until np) {
                offs[x * np + k] = off
                off += 4 + p.out.buf.intBE(off)
            }
        }
        val lp = o.beginBind(batchNames[stmt.id]!!, 1 + np)
        putArrayHeader(o, Oid.INT4, n, n * 8)
        for (x in 0 until n) {
            o.putIntBE(4)
            o.putIntBE(x)
        }
        for (k in 0 until np) {
            var data = 0
            for (x in 0 until n) data += 4 + t.jobs[at + x]!!.params.out.buf.intBE(offs[x * np + k])
            putArrayHeader(o, stmt.paramOids[k], n, data)
            for (x in 0 until n) {
                val buf = t.jobs[at + x]!!.params.out.buf
                val off = offs[x * np + k]
                o.put(buf, off, 4 + buf.intBE(off))
            }
        }
        o.endBindExecute(lp)
    }

    /** Bind (binary parameters as encoded by the caller) + Execute. */
    fun encodeJob(o: ByteBuf, job: WriteJob) {
        val p = job.params
        val lp = o.beginBind(stmtNames[job.stmt.id], p.count)
        o.put(p.out.buf, 0, p.out.len)
        o.endBindExecute(lp)
    }

    override fun drainLocked(): List<Any>? {
        if (isoQ.size == 0 && groupQ.size == 0) return null
        val all = ArrayList<Any>(isoQ.size + groupQ.size)
        while (isoQ.size > 0) all.add(isoQ.poll())
        while (groupQ.size > 0) all.add(groupQ.poll())
        noteQueuedLocked(0)
        return all
    }

    override fun failDrained(drained: List<Any>, err: PgError) {
        for (x in drained) {
            val job = x as WriteJob
            job.res.error = err
            try {
                job.cont.resume(job.res)
            } catch (e: Throwable) {
                logSafe({ "db: write continuation threw" }, e)
            }
        }
    }

    /** The statistics interval just ended: utilization, jobs/round trips, queue wait per job, round trip (mean/max ms). */
    fun intervalStats(intervalNanos: Long): String = lock.locked {
        val util = if (intervalNanos > 0) 100 * busyNanos / (intervalNanos * workers.size) else 0
        val s = "writes util $util%, queued ${isoQ.size + groupQ.size} | $iJobs/$iTrips wait ${wait.take()} " +
            "rt ${rtt.take()}"
        busyNanos = 0
        iJobs = 0
        iTrips = 0
        s
    }

    fun stats(): String = lock.locked {
        "writes: $jobs jobs in $trips round trips, $groups groups ($groupedJobs jobs, max $largestGroup), " +
            "$reruns reruns, $commitFailures commit failures, queued ${isoQ.size + groupQ.size}, " +
            "healthy $healthy/${workers.size}, reconnects $reconnects"
    }

    companion object {
        const val MAX_GROUP = 64
        const val MAX_ISOLATED = 16
        const val MAX_TRIP = MAX_GROUP + MAX_ISOLATED
        private const val MAX_BATCH_PARAMS = 8
    }
}

/** Binary 1-D array parameter header (no NULLs, lower bound 1), preceded by the parameter's Int32 length. */
internal fun putArrayHeader(o: ByteBuf, elemOid: Int, n: Int, dataLen: Int) {
    o.putIntBE(20 + dataLen)
    o.putIntBE(1)
    o.putIntBE(0)
    o.putIntBE(elemOid)
    o.putIntBE(n)
    o.putIntBE(1)
}
