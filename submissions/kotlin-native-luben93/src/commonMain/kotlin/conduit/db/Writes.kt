package conduit.db

import conduit.pg.Params
import conduit.pg.PgConn
import conduit.pg.PgError
import conduit.pg.PgStatement
import conduit.pg.Result
import conduit.pg.beginBind
import conduit.pg.endBindExecute
import conduit.pg.sync
import conduit.platform.locked
import conduit.util.ByteBuf
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

    /** BEGIN, jobs, COMMIT, Sync. Statement s: 0 = BEGIN, 1..g = jobs, g+1 = COMMIT. */
    private fun readGroup(c: PgConn, t: WriteTrip): Int {
        val first = t.nIso
        val g = t.n - first
        var s = 0
        var err: PgError? = null
        var errAt = -1
        while (true) {
            val m = c.next()
            if (m == 'D'.code) {
                if (err == null && s in 1..g) t.jobs[first + s - 1]!!.res.addRow(c.rbuf, c.mstart)
            } else if (m == 'C'.code) {
                if (s in 1..g) t.jobs[first + s - 1]!!.res.affected = c.tagCount()
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
        if (errAt == g + 1) {
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
        o.put(wpool.runtime.rollbackExec)
        o.sync()
        for (j in first until t.n) {
            wpool.encodeJob(o, t.jobs[j]!!)
            o.sync()
        }
        c.send()
        while (c.next() != 'Z'.code) {
            // ROLLBACK's BindComplete / CommandComplete
        }
        var st = 'I'.code
        for (j in first until t.n) {
            val job = t.jobs[j]!!
            job.res.clear()
            st = readSingle(c, job)
        }
        return st
    }

    override fun completeLocked() {
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
            } catch (e: Throwable) {
                println("db: write continuation threw: $e")
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
) : Pool("write", config, statements, config.writeConns) {
    @JvmField val workers = Array(config.writeConns) { WriteWorker(this, it) }
    private val isoQ = JobQueue()
    private val groupQ = JobQueue()

    // statistics (guarded by lock)
    @JvmField var trips = 0L
    @JvmField var jobs = 0L
    @JvmField var groups = 0L
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
            o.put(runtime.beginExec)
            for (j in t.nIso until t.n) encodeJob(o, t.jobs[j]!!)
            o.put(runtime.commitExec)
            o.sync()
        }
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
        return all
    }

    override fun failDrained(drained: List<Any>, err: PgError) {
        for (x in drained) {
            val job = x as WriteJob
            job.res.error = err
            try {
                job.cont.resume(job.res)
            } catch (e: Throwable) {
                println("db: write continuation threw: $e")
            }
        }
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
    }
}
