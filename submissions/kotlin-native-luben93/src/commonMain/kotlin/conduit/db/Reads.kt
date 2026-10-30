package conduit.db

import conduit.http.Exchange
import conduit.http.RequestKey
import conduit.pg.Oid
import conduit.pg.PgConn
import conduit.pg.PgError
import conduit.pg.PgStatement
import conduit.pg.Result
import conduit.pg.beginBind
import conduit.pg.endBindExecute
import conduit.pg.sync
import conduit.platform.Monitor
import conduit.platform.locked
import conduit.platform.nanoTime
import conduit.platform.startThread
import conduit.util.ByteBuf
import conduit.util.Timing
import conduit.util.intBE
import conduit.util.logSafe
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
    /** The HTTP request this read is for (null: none, or the guard is off); dropped unrun once it is abandoned. */
    @JvmField val owner: Exchange?,
) {
    /** Arrival order (global, assigned under the pool lock): the dispatcher serves the oldest waiter first. */
    @JvmField var seq = 0L

    /** When it was queued ([nanoTime]). */
    @JvmField val born = nanoTime()
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

    // statistics of the current DB_STATS_S interval: queue wait per request (queued until sent), round trip per batch
    // (sent until its reply was read)
    @JvmField var iRequests = 0L
    @JvmField var iBatches = 0L
    @JvmField val wait = Timing()
    @JvmField val rtt = Timing()

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

    /** The newest waiter ([DbConfig.lifoMicros]: served first while the queue is congested). */
    fun pollLast(): ReadReq {
        val i = (head + size - 1) and (ring.size - 1)
        val r = ring[i]!!
        ring[i] = null
        size--
        return r
    }

    /**
     * Queued and below its maxInflight; with a gather window ([gather] ns, [now] = [nanoTime]) also full, or its oldest
     * request has waited out the window.
     */
    fun ready(now: Long, gather: Long): Boolean =
        size > 0 && (kind.maxInflight <= 0 || inflight < kind.maxInflight) &&
            (gather <= 0L || size >= maxBatch || now - ring[head]!!.born >= gather)
}

/** One batched execution: up to maxBatch requests of one kind, and their (reused) Results. */
internal class ReadBatch(cap: Int) {
    @JvmField var q: KindQueue? = null
    @JvmField var n = 0

    /** When it was handed to its connection ([nanoTime]), for the round-trip statistics. */
    @JvmField var sentAt = 0L
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
        val rt = nanoTime() - batch.sentAt
        batch.q!!.rtt.add(rt)
        (pool as ReadPool).busyNanos += rt
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
            } catch (e: Throwable) { // one handler failing must not skip the rest of the batch
                logSafe({ "db: read continuation threw" }, e)
            }
        }
    }
}

/**
 * The read connections. A free connection takes the ready kind (non-empty, below its maxInflight) whose oldest
 * request has waited longest, and sends up to maxBatch of its requests as ONE execution of the kind's statement.
 * At low load every request goes out alone at once; under load requests pile up while all connections are busy
 * and leave in big batches, so Postgres work per request drops exactly when it matters.
 *
 * A queued request whose HTTP client is gone ([Exchange.abandoned]) is dropped when its turn comes: it never reaches
 * Postgres, and its handler is never resumed ([DbConfig.skipAbandoned]).
 */
internal class ReadPool(
    @JvmField val runtime: DbRuntime,
    config: DbConfig,
    statements: List<PgStatement>,
    kinds: List<ReadKind>,
    stmtNames: List<ByteArray>,
) : Pool("read", config, statements, config.readConns, config.readQueueMax) {
    @JvmField val queues = Array(kinds.size) { KindQueue(kinds[it], stmtNames[it], kinds[it].maxBatch.coerceIn(1, 1024)) }
    private val cap = queues.maxOfOrNull { it.maxBatch } ?: 1
    @JvmField val workers = Array(config.readConns) { ReadWorker(this, it, cap) }
    private val skipAbandoned = config.skipAbandoned
    private val gatherNanos = config.gatherMicros * 1000L
    private val lifoNanos = config.lifoMicros * 1000L

    private var seq = 0L
    private var queued = 0

    /** Reads queued right now (a racy read, for a load signal: [Db.readsQueued]). */
    val queuedNow: Int get() = queued

    // statistics (guarded by lock)
    @JvmField var batches = 0L
    @JvmField var requests = 0L
    @JvmField var largest = 0

    /** Requests dropped unrun because their client was gone. */
    @JvmField var skipped = 0L

    /** Batches taken newest-first ([DbConfig.lifoMicros]). */
    @JvmField var lifoBatches = 0L

    /** Round-trip time of the current statistics interval, summed over connections (utilization, see [intervalStats]). */
    @JvmField var busyNanos = 0L

    /** Requests per batch, bucketed: 1, 2-3, 4-7, 8-15, 16-31, 32-63, 64+. */
    @JvmField val sizes = LongArray(7)

    fun enqueue(kind: ReadKind, viewer: Long, limit: Int, offset: Long, key: String, cont: Continuation<Result>) {
        val id = kind.id
        val q = if (id >= 0 && id < queues.size) queues[id] else null
        check(q != null && q.kind === kind) { "ReadKind ${kind.name} was not passed to Db.start" }
        val r = ReadReq(viewer, limit, offset, key, cont, if (skipAbandoned) cont.context[RequestKey] else null)
        val c = lock.locked {
            r.seq = ++seq
            q.add(r)
            queued++
            noteQueuedLocked(queued)
            dispatchLocked()
        }
        if (c != null) send(c)
    }

    /**
     * With a gather window, nothing else hands a kind to an idle connection once its window has passed (enqueue and
     * finished round trips only send what is ready then): a clock thread does, every eighth of the window.
     */
    fun startGatherClock() {
        if (gatherNanos <= 0) return
        val tick = maxOf(500_000L, gatherNanos / 8)
        startThread("db-gather") {
            val m = Monitor()
            val assigned = ArrayList<PgConn>(workers.size)
            while (true) {
                sleepNanos(m, tick)
                lock.locked {
                    if (stopping) return@startThread
                    while (true) assigned.add(dispatchLocked() ?: break)
                }
                for (c in assigned) send(c)
                assigned.clear()
            }
        }
    }

    override fun assignLocked(w: Worker): Boolean {
        w as ReadWorker
        val batch = w.spare()
        val now = if (gatherNanos > 0 || lifoNanos > 0) nanoTime() else 0L
        var best: KindQueue? = null
        var n = 0
        while (n == 0 && queued > 0) {
            best = null
            var bestSeq = Long.MAX_VALUE
            var oldestBorn = Long.MAX_VALUE
            for (q in queues) {
                if (q.ready(now, gatherNanos)) {
                    val h = q.ring[q.head]!!
                    if (h.born < oldestBorn) oldestBorn = h.born
                    if (h.seq < bestSeq) {
                        bestSeq = h.seq
                        best = q
                    }
                }
            }
            if (best == null) break
            // Adaptive LIFO: while the oldest ready read has waited past the threshold, serve the kind holding the
            // newest request, newest first. Per kind it would starve the other kinds behind one stale head.
            val lifo = lifoNanos > 0 && now - oldestBorn >= lifoNanos
            if (lifo) {
                var newest = Long.MIN_VALUE
                for (q in queues) {
                    if (q.ready(now, gatherNanos)) {
                        val s = q.ring[(q.head + q.size - 1) and (q.ring.size - 1)]!!.seq
                        if (s > newest) {
                            newest = s
                            best = q
                        }
                    }
                }
                lifoBatches++
            }
            val k = best!!
            batch.ensure(minOf(k.size, k.maxBatch))
            while (n < k.maxBatch && k.size > 0) {
                val r = if (lifo) k.pollLast() else k.poll()
                queued--
                if (!dropAbandoned(r)) batch.reqs[n++] = r
            }
            // n == 0: every waiter of this kind was abandoned. Look again (another kind may have live ones) rather
            // than send an empty batch.
        }
        noteQueuedLocked(queued)
        if (best == null || n == 0) {
            pushIdleLocked(w)
            return false
        }
        batch.n = n
        batch.q = best
        best.inflight++
        w.flight = batch
        w.inFlight = true
        encode(batch, w.conn!!.out)
        batches++
        requests += n
        best.batches++
        best.requests += n
        if (n > largest) largest = n
        sizes[minOf(6, 31 - n.countLeadingZeroBits())]++
        val t = nanoTime()
        for (j in 0 until n) best.wait.add(t - batch.reqs[j]!!.born)
        batch.sentAt = t
        best.iRequests += n
        best.iBatches++
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

    /** Under [lock]: whether [r] is dropped (its client is gone, see [skipAbandoned]) instead of run. */
    private fun dropAbandoned(r: ReadReq): Boolean {
        val o = r.owner ?: return false
        if (!o.abandoned) return false
        o.abandon()
        skipped++
        return true
    }

    override fun drainLocked(): List<Any>? {
        if (queued == 0) return null
        val all = ArrayList<Any>(queued)
        for (q in queues) while (q.size > 0) all.add(q.poll())
        queued = 0
        noteQueuedLocked(0)
        return all
    }

    override fun failDrained(drained: List<Any>, err: PgError) {
        for (r in drained) {
            try {
                val res = Result()
                res.error = err
                (r as ReadReq).cont.resume(res)
            } catch (e: Throwable) {
                logSafe({ "db: read continuation threw" }, e)
            }
        }
    }

    /**
     * The statistics interval just ended ([intervalNanos] long), then the next one starts: how much of it the read
     * connections had a round trip out (near 100%: requests wait for a free connection), and per kind with traffic
     * requests/batches, queue wait per request and round trip per batch (mean/max ms).
     */
    fun intervalStats(intervalNanos: Long): String = lock.locked {
        val util = if (intervalNanos > 0) 100 * busyNanos / (intervalNanos * workers.size) else 0
        busyNanos = 0
        val sb = StringBuilder("reads util $util%, queued $queued")
        for (q in queues) {
            if (q.iBatches == 0L) continue
            sb.append(" | ").append(q.kind.name).append(' ').append(q.iRequests).append('/').append(q.iBatches)
                .append(" wait ").append(q.wait.take()).append(" rt ").append(q.rtt.take())
            q.iRequests = 0
            q.iBatches = 0
        }
        sb.toString()
    }

    fun stats(): String = lock.locked {
        val avg = if (batches == 0L) 0.0 else requests.toDouble() / batches
        "reads: $requests requests in $batches batches (avg ${(avg * 100).toLong() / 100.0}, max $largest; " +
            "sizes 1:${sizes[0]} 2-3:${sizes[1]} 4-7:${sizes[2]} 8-15:${sizes[3]} 16-31:${sizes[4]} " +
            "32-63:${sizes[5]} 64+:${sizes[6]}), queued $queued, skipped $skipped, healthy $healthy/${workers.size}, " +
            "reconnects $reconnects, lifo batches $lifoBatches; per kind (requests/batches):" +
            queues.joinToString("") { " ${it.kind.name} ${it.requests}/${it.batches}" }
    }
}
