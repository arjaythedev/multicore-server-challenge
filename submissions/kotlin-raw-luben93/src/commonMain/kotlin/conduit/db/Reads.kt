package conduit.db

import conduit.pg.Oid
import conduit.pg.PgConn
import conduit.pg.PgError
import conduit.pg.PgStatement
import conduit.pg.Result
import conduit.pg.beginBind
import conduit.pg.endBindExecute
import conduit.pg.sync
import conduit.platform.locked
import conduit.util.ByteBuf
import conduit.util.intBE
import kotlin.coroutines.Continuation
import kotlin.coroutines.resume
import kotlin.jvm.JvmField

/** One queued read: the request's row of the five arrays plus its continuation. */
internal class ReadReq(
    @JvmField val viewer: Long,
    @JvmField val limit: Int,
    @JvmField val offset: Long,
    @JvmField val key: String,
    @JvmField val cont: Continuation<Result>,
) {
    /** Arrival order (global, assigned under the pool lock): the dispatcher serves the oldest waiter first. */
    @JvmField var seq = 0L
}

/** FIFO of one [ReadKind]'s waiting requests (ring buffer, power-of-two capacity). Guarded by the pool lock. */
internal class KindQueue(@JvmField val kind: ReadKind, @JvmField val stmtName: ByteArray, @JvmField val maxBatch: Int) {
    @JvmField var ring = arrayOfNulls<ReadReq>(16)
    @JvmField var head = 0
    @JvmField var size = 0

    /** Batches of this kind on a connection right now. */
    @JvmField var inflight = 0

    // statistics
    @JvmField var requests = 0L
    @JvmField var batches = 0L

    fun add(r: ReadReq) {
        if (size == ring.size) {
            val bigger = arrayOfNulls<ReadReq>(size * 2)
            for (i in 0 until size) bigger[i] = ring[(head + i) and (size - 1)]
            ring = bigger
            head = 0
        }
        ring[(head + size) and (ring.size - 1)] = r
        size++
    }

    fun poll(): ReadReq {
        val r = ring[head]!!
        ring[head] = null
        head = (head + 1) and (ring.size - 1)
        size--
        return r
    }

    fun ready(): Boolean = size > 0 && (kind.maxInflight <= 0 || inflight < kind.maxInflight)
}

/** One batched execution: up to maxBatch requests of one kind, and their (reused) Results. */
internal class ReadBatch(cap: Int) {
    @JvmField var q: KindQueue? = null
    @JvmField var n = 0
    @JvmField var reqs = arrayOfNulls<ReadReq>(cap)
    @JvmField var results = Array(cap) { Result() }

    /** Room for [n] requests (broadcast kinds may take more than the usual cap). Under the pool lock. */
    fun ensure(n: Int) {
        if (n <= reqs.size) return
        val old = results
        reqs = reqs.copyOf(n)
        results = Array(n) { if (it < old.size) old[it] else Result() }
    }
}

internal class ReadWorker(pool: ReadPool, index: Int, cap: Int) : Worker(pool, index) {
    // Two batch objects: one being resumed while the next is in flight. The next is always the one that is not [done].
    private val a = ReadBatch(cap)
    private val b = ReadBatch(cap)
    @JvmField var flight: ReadBatch? = null
    @JvmField var done: ReadBatch? = null

    fun spare(): ReadBatch = if (done === a) b else a

    override fun processReply(c: PgConn) {
        val batch = flight!!
        val n = batch.n
        val res = batch.results
        val broadcast = batch.q!!.kind.broadcast
        for (j in 0 until n) res[j].clear()
        var err: PgError? = null
        var status = 'I'.code
        while (true) {
            val t = c.next()
            if (t == 'D'.code) {
                if (err != null) continue
                if (broadcast) {
                    res[0].addRow(c.rbuf, c.mstart)
                    continue
                }
                // DataRow: Int16 ncols, then column 0 = r.i as Int32 length 4 + Int32 value
                val buf = c.rbuf
                val p = c.mstart
                if (c.mlen >= 10 && buf.intBE(p + 2) == 4) {
                    val i = buf.intBE(p + 6)
                    if (i in 0 until n) res[i].addRow(buf, p)
                }
            } else if (t == 'Z'.code) {
                status = c.txStatus()
                break
            } else if (t == 'E'.code) {
                if (err == null) err = c.error()
            }
            // BindComplete, CommandComplete, NoticeResponse, ParameterStatus: nothing to do
        }
        val buf = c.rbuf // it may have grown (same offsets) since the first rows were added
        if (broadcast && err == null) {
            // every request of the batch gets the one execution's rows (views into the same receive buffer)
            val first = res[0]
            for (j in 1 until n) for (k in 0 until first.rowCount) res[j].addRow(buf, first.rowStarts[k])
        }
        for (j in 0 until n) {
            val r = res[j]
            if (err != null) {
                r.error = err
                r.rowCount = 0
            } else {
                r.buf = buf
                r.affected = r.rowCount.toLong()
            }
        }
        if (status != 'I'.code) (pool as ReadPool).runtime.rollback(c)
    }

    override fun completeLocked() {
        val batch = flight!!
        batch.q!!.inflight--
        done = batch
        flight = null
        inFlight = false
    }

    override fun resumeCompleted() {
        val batch = done!!
        resume(batch)
    }

    override fun abandonLocked(): Boolean {
        val batch = flight ?: return false
        batch.q!!.inflight--
        done = batch
        flight = null
        inFlight = false
        return true
    }

    override fun resumeAbandoned(err: PgError) {
        val batch = done!!
        for (j in 0 until batch.n) {
            val r = batch.results[j]
            r.clear()
            r.error = err
        }
        resume(batch)
    }

    private fun resume(batch: ReadBatch) {
        for (j in 0 until batch.n) {
            val req = batch.reqs[j]!!
            batch.reqs[j] = null
            try {
                req.cont.resume(batch.results[j])
            } catch (e: Throwable) {
                println("db: read continuation threw: $e")
            }
        }
    }
}

/**
 * The read connections. A free connection takes the ready kind (non-empty, below its maxInflight) whose oldest
 * request has waited longest, and sends up to maxBatch of its requests as ONE execution of the kind's statement.
 * At low load every request goes out alone at once; under load requests pile up while all connections are busy
 * and leave in big batches, so Postgres work per request drops exactly when it matters.
 */
internal class ReadPool(
    @JvmField val runtime: DbRuntime,
    config: DbConfig,
    statements: List<PgStatement>,
    kinds: List<ReadKind>,
    stmtNames: List<ByteArray>,
) : Pool("read", config, statements, config.readConns) {
    @JvmField val queues = Array(kinds.size) { KindQueue(kinds[it], stmtNames[it], kinds[it].maxBatch.coerceIn(1, 1024)) }
    private val cap = queues.maxOfOrNull { it.maxBatch } ?: 1
    @JvmField val workers = Array(config.readConns) { ReadWorker(this, it, cap) }

    private var seq = 0L
    private var queued = 0

    // statistics (guarded by lock)
    @JvmField var batches = 0L
    @JvmField var requests = 0L
    @JvmField var largest = 0

    /** Requests per batch, bucketed: 1, 2-3, 4-7, 8-15, 16-31, 32-63, 64+. */
    @JvmField val sizes = LongArray(7)

    fun enqueue(kind: ReadKind, viewer: Long, limit: Int, offset: Long, key: String, cont: Continuation<Result>) {
        val id = kind.id
        val q = if (id >= 0 && id < queues.size) queues[id] else null
        check(q != null && q.kind === kind) { "ReadKind ${kind.name} was not passed to Db.start" }
        val r = ReadReq(viewer, limit, offset, key, cont)
        val c = lock.locked {
            r.seq = ++seq
            q.add(r)
            queued++
            dispatchLocked()
        }
        if (c != null) send(c)
    }

    override fun assignLocked(w: Worker): Boolean {
        w as ReadWorker
        var best: KindQueue? = null
        if (queued > 0) {
            var bestSeq = Long.MAX_VALUE
            for (q in queues) {
                if (q.ready()) {
                    val s = q.ring[q.head]!!.seq
                    if (s < bestSeq) {
                        bestSeq = s
                        best = q
                    }
                }
            }
        }
        if (best == null) {
            pushIdleLocked(w)
            return false
        }
        val batch = w.spare()
        val n = minOf(best.size, best.maxBatch)
        batch.ensure(n)
        for (j in 0 until n) batch.reqs[j] = best.poll()
        batch.n = n
        batch.q = best
        best.inflight++
        queued -= n
        w.flight = batch
        w.inFlight = true
        encode(batch, w.conn!!.out)
        batches++
        requests += n
        best.batches++
        best.requests += n
        if (n > largest) largest = n
        sizes[minOf(6, 31 - n.countLeadingZeroBits())]++
        return true
    }

    /**
     * Bind(s<id>, $1 int4[] i, $2 int8[] v, $3 int4[] l, $4 int8[] o, $5 text[] k) + Execute + Sync; a broadcast
     * kind binds no parameters.
     */
    private fun encode(batch: ReadBatch, o: ByteBuf) {
        o.reset()
        if (batch.q!!.kind.broadcast) {
            o.endBindExecute(o.beginBind(batch.q!!.stmtName, 0))
            o.sync()
            return
        }
        val n = batch.n
        val reqs = batch.reqs
        val lp = o.beginBind(batch.q!!.stmtName, 5)
        arrayHeader(o, Oid.INT4, n, n * 8)
        for (j in 0 until n) {
            o.putIntBE(4)
            o.putIntBE(j)
        }
        arrayHeader(o, Oid.INT8, n, n * 12)
        for (j in 0 until n) {
            o.putIntBE(8)
            o.putLongBE(reqs[j]!!.viewer)
        }
        arrayHeader(o, Oid.INT4, n, n * 8)
        for (j in 0 until n) {
            o.putIntBE(4)
            o.putIntBE(reqs[j]!!.limit)
        }
        arrayHeader(o, Oid.INT8, n, n * 12)
        for (j in 0 until n) {
            o.putIntBE(8)
            o.putLongBE(reqs[j]!!.offset)
        }
        val start = o.len
        arrayHeader(o, Oid.TEXT, n, 0)
        for (j in 0 until n) {
            var key = reqs[j]!!.key
            // Postgres text cannot hold NUL, and one invalid element would fail the whole batch: such a key can
            // match nothing anyway, so send one that matches nothing.
            if (key.indexOf('\u0000') >= 0) key = ""
            val p = o.len
            o.putIntBE(0)
            o.putUtf8(key)
            o.setIntBE(p, o.len - p - 4)
        }
        o.setIntBE(start, o.len - start - 4)
        o.endBindExecute(lp)
        o.sync()
    }

    /** Binary 1-D array header (no NULLs, lower bound 1), preceded by the parameter's Int32 length. */
    private fun arrayHeader(o: ByteBuf, elemOid: Int, n: Int, dataLen: Int) {
        o.putIntBE(20 + dataLen)
        o.putIntBE(1)
        o.putIntBE(0)
        o.putIntBE(elemOid)
        o.putIntBE(n)
        o.putIntBE(1)
    }

    override fun drainLocked(): List<Any>? {
        if (queued == 0) return null
        val all = ArrayList<Any>(queued)
        for (q in queues) while (q.size > 0) all.add(q.poll())
        queued = 0
        return all
    }

    override fun failDrained(drained: List<Any>, err: PgError) {
        for (r in drained) {
            val res = Result()
            res.error = err
            try {
                (r as ReadReq).cont.resume(res)
            } catch (e: Throwable) {
                println("db: read continuation threw: $e")
            }
        }
    }

    fun stats(): String = lock.locked {
        val avg = if (batches == 0L) 0.0 else requests.toDouble() / batches
        "reads: $requests requests in $batches batches (avg ${(avg * 100).toLong() / 100.0}, max $largest; " +
            "sizes 1:${sizes[0]} 2-3:${sizes[1]} 4-7:${sizes[2]} 8-15:${sizes[3]} 16-31:${sizes[4]} " +
            "32-63:${sizes[5]} 64+:${sizes[6]}), queued $queued, healthy $healthy/${workers.size}, " +
            "reconnects $reconnects; per kind (requests/batches):" +
            queues.joinToString("") { " ${it.kind.name} ${it.requests}/${it.batches}" }
    }
}
