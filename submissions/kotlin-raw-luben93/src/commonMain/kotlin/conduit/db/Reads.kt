package conduit.db

import conduit.http.Exchange
import conduit.http.RequestKey
import conduit.pg.Oid
import conduit.pg.PgConn
import conduit.pg.PgError
import conduit.pg.PgStatement
import conduit.pg.ArticleRows
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
import kotlin.concurrent.Volatile
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

    /** [Sharing.GROUPS] kinds: per request, the index of the first request of its group (itself for that one). */
    @JvmField var rep = IntArray(cap)

    /** [Sharing.ARTICLES] kinds: the batch's distinct article rows. */
    @JvmField val arts = ArticleRows()

    /** Room for [n] requests (broadcast kinds may take more than the usual cap). Under the pool lock. */
    fun ensure(n: Int) {
        if (n <= reqs.size) return
        val old = results
        reqs = reqs.copyOf(n)
        results = Array(n) { if (it < old.size) old[it] else Result() }
        rep = rep.copyOf(n)
    }
}

/**
 * [key] as Postgres will see it: what ByteBuf.putUtf8 writes, so two requests have the same wire key exactly when their
 * texts are equal. A key with a NUL matches nothing (Postgres text cannot hold it): the key "".
 */
internal fun wireKey(key: String): String {
    var i = 0
    var lone = false
    while (i < key.length) {
        val c = key[i]
        if (c == '\u0000') return ""
        if (c in '\uD800'..'\uDFFF') {
            if (c <= '\uDBFF' && i + 1 < key.length && key[i + 1] in '\uDC00'..'\uDFFF') i++ else lone = true
        }
        i++
    }
    if (!lone) return key
    val sb = StringBuilder(key.length)
    i = 0
    while (i < key.length) {
        val c = key[i]
        if (c in '\uD800'..'\uDBFF' && i + 1 < key.length && key[i + 1] in '\uDC00'..'\uDFFF') {
            sb.append(c).append(key[i + 1])
            i += 2
            continue
        }
        sb.append(if (c in '\uD800'..'\uDFFF') '\uFFFD' else c) // a lone surrogate is written as U+FFFD
        i++
    }
    return sb.toString()
}

/** Groups the requests of a [Sharing.GROUPS] batch by (key, limit, offset). Under the pool lock; keeps its tables between batches. */
internal class Grouper {
    private var table = IntArray(64) // request index + 1, open addressing
    private var keys = arrayOfNulls<String>(16)

    /** rep[j] = index of the first request of the batch whose wire key, limit and offset equal request j's. */
    fun group(reqs: Array<ReadReq?>, n: Int, rep: IntArray) {
        var size = 64
        while (size < n * 2) size = size shl 1
        if (table.size == size) table.fill(0) else table = IntArray(size)
        if (keys.size < n) keys = arrayOfNulls(n)
        val mask = size - 1
        for (j in 0 until n) {
            val q = reqs[j]!!
            val k = wireKey(q.key)
            keys[j] = k
            var h = (k.hashCode() * 31 + q.limit) * 31 + q.offset.hashCode()
            h = h xor (h ushr 15)
            var slot = h and mask
            while (true) {
                val e = table[slot]
                if (e == 0) {
                    table[slot] = j + 1
                    rep[j] = j
                    break
                }
                val g = e - 1
                val gq = reqs[g]!!
                if (gq.limit == q.limit && gq.offset == q.offset && keys[g] == k) {
                    rep[j] = g
                    break
                }
                slot = (slot + 1) and mask
            }
        }
        keys.fill(null, 0, n) // the strings stay reachable otherwise
    }
}

internal class ReadWorker(pool: ReadPool, index: Int, cap: Int) : Worker(pool, index) {
    // Batch objects: the oldest one in flight, with pipelining one more written behind it, and the one being resumed.
    // The third object only exists once the pool pipelines.
    private val cap = cap
    private val a = ReadBatch(cap)
    private val b = ReadBatch(cap)
    private var c: ReadBatch? = null
    @JvmField var flight: ReadBatch? = null

    /** Written to the connection behind [flight] (pipelining), not yet read. */
    @JvmField var queued: ReadBatch? = null
    @JvmField var done: ReadBatch? = null

    /** The pipelined batch of a connection that died, to fail after [done]. */
    private var failed: ReadBatch? = null

    /** A batch object that is neither outstanding nor being resumed. Under the pool lock. */
    fun spare(): ReadBatch {
        if (a !== flight && a !== queued && a !== done) return a
        if (b !== flight && b !== queued && b !== done) return b
        return c ?: ReadBatch(cap).also { c = it }
    }

    override fun processReply(c: PgConn) {
        val batch = flight!!
        val n = batch.n
        val res = batch.results
        val broadcast = batch.q!!.kind.broadcast
        val grouped = batch.q!!.kind.sharing == Sharing.GROUPS
        val articled = batch.q!!.kind.sharing == Sharing.ARTICLES
        val arts = batch.arts
        if (articled) arts.clear()
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
                    if (i in 0 until n) {
                        res[i].addRow(buf, p)
                    } else if (grouped && i < 0 && -1 - i < n && c.mlen >= 30) {
                        res[-1 - i].addFlag(buf, p) // (-1 - request, flag int8, ...): this request's own flag
                    } else if (articled) {
                        if (i == Int.MIN_VALUE) arts.add(p) // a distinct article of the batch
                        else if (i < 0 && -1 - i < n && c.mlen >= 30) res[-1 - i].addFlag(buf, p) // (-1 - request, article id, ...)
                    }
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
        if (grouped && err == null) {
            // the statement tagged each group's rows with its first request: every request of the group gets views of them
            val rep = batch.rep
            for (j in 0 until n) {
                val g = rep[j]
                if (g == j) continue
                val first = res[g]
                for (k in 0 until first.rowCount) res[j].addRow(buf, first.rowStarts[k])
            }
        }
        if (articled && err == null) arts.build(buf)
        for (j in 0 until n) {
            val r = res[j]
            if (articled && err == null) r.articles = arts
            if (err != null) {
                r.error = err
                r.rowCount = 0
                r.flagCount = 0
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
        flight = queued
        queued = null
        inFlight = flight != null
    }

    override fun resumeCompleted() {
        val batch = done!!
        resume(batch)
    }

    override fun abandonLocked(): Boolean {
        val batch = flight ?: return false
        batch.q!!.inflight--
        done = batch
        val second = queued
        if (second != null) {
            second.q!!.inflight--
            failed = second
        }
        flight = null
        queued = null
        inFlight = false
        return true
    }

    override fun resumeAbandoned(err: PgError) {
        fail(done!!, err)
        val second = failed
        if (second != null) {
            failed = null
            fail(second, err)
        }
    }

    private fun fail(batch: ReadBatch, err: PgError) {
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
    private val depth = config.pipelineDepth.coerceIn(1, 2)
    /** The gather window; [config]'s is the floor, the [GatherTuner] (when on) moves it between 1 s ticks. */
    private val cfg = config
    @Volatile private var gatherNanos = config.gatherMicros * 1000L
    private val lifoNanos = config.lifoMicros * 1000L

    private var seq = 0L
    private var queued = 0
    private val grouper = Grouper()

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
        val floorNanos = gatherNanos
        val tick = maxOf(500_000L, floorNanos / 8)
        val tuner = cfg.gatherMaxMicros.let { max ->
            if (max > cfg.gatherMicros) {
                GatherTuner(
                    cfg.gatherMicros / 1000, max / 1000, cfg.gatherStepMicros / 1000, cfg.gatherHighPct, cfg.gatherLowPct,
                )
            } else null
        }
        startThread("db-gather") {
            val m = Monitor()
            val assigned = ArrayList<PgConn>(workers.size)
            var nextTune = nanoTime() + 1_000_000_000L
            while (true) {
                sleepNanos(m, tick)
                if (tuner != null) {
                    val now = nanoTime()
                    if (now >= nextTune) {
                        nextTune = now + 1_000_000_000L
                        val cur = (gatherNanos / 1_000_000L).toInt()
                        val ms = tuner.next(cur)
                        if (ms != cur) {
                            gatherNanos = ms * 1_000_000L
                            if (ms == tuner.maxMs || ms == tuner.floorMs) println("db: read gather window $ms ms (box busy, auto)")
                        }
                    }
                }
                lock.locked {
                    if (stopping) return@startThread
                    while (true) assigned.add(dispatchLocked() ?: break)
                }
                for (c in assigned) send(c)
                assigned.clear()
            }
        }
    }

    override fun assignLocked(w: Worker): Boolean = assign(w as ReadWorker, depth)

    /** One round trip only: this thread writes it, and the worker's own thread must find the send buffer free. */
    override fun assignDispatchedLocked(w: Worker): Boolean = assign(w as ReadWorker, 1)

    /**
     * Under [lock]: fills [w]'s connection up to [limit] outstanding round trips from the queues, encoding them into its
     * send buffer back to back (one write). The first is any ready kind's batch; one behind a running one must be FULL, so
     * pipelining never trades batch size (what the sharing lives on) for latency. Returns whether anything was
     * encoded; parks [w] on the idle stack when it has nothing outstanding and nothing to send.
     */
    private fun assign(w: ReadWorker, limit: Int): Boolean {
        var sent = false
        while (true) {
            val outstanding = if (w.flight == null) 0 else if (w.queued == null) 1 else 2
            if (outstanding >= limit) break
            val batch = w.spare()
            if (!form(batch, outstanding > 0)) break
            val o = w.conn!!.out
            if (!sent) {
                o.reset()
                sent = true
            }
            encode(batch, o)
            if (w.flight == null) w.flight = batch else w.queued = batch
        }
        if (!sent) {
            if (w.flight == null) pushIdleLocked(w)
            return false
        }
        w.inFlight = true
        return true
    }

    /**
     * Under [lock]: moves the next batch's requests from the queues into [batch] (only from a full queue when [full]).
     * False when no such batch exists.
     */
    private fun form(batch: ReadBatch, full: Boolean): Boolean {
        val now = if (gatherNanos > 0 || lifoNanos > 0) nanoTime() else 0L
        var best: KindQueue? = null
        var n = 0
        while (n == 0 && queued > 0) {
            best = null
            var bestSeq = Long.MAX_VALUE
            var oldestBorn = Long.MAX_VALUE
            for (q in queues) {
                if (q.ready(now, gatherNanos) && (!full || q.size >= q.maxBatch)) {
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
                    if (q.ready(now, gatherNanos) && (!full || q.size >= q.maxBatch)) {
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
        if (best == null || n == 0) return false
        batch.n = n
        batch.q = best
        best.inflight++
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
        if (batch.q!!.kind.broadcast) {
            o.endBindExecute(o.beginBind(batch.q!!.stmtName, 0))
            o.sync()
            return
        }
        val n = batch.n
        val reqs = batch.reqs
        if (batch.q!!.kind.sharing == Sharing.GROUPS) grouper.group(reqs, n, batch.rep)
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
        val sb = StringBuilder("reads util $util%, gather ${gatherNanos / 1_000_000L} ms, queued $queued")
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
