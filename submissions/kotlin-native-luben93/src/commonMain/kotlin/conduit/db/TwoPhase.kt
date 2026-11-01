package conduit.db

import conduit.app.N_AUTHOR
import conduit.app.N_BIO
import conduit.app.N_BODY
import conduit.app.N_CREATED_AT
import conduit.app.N_DESCRIPTION
import conduit.app.N_FAVORITED
import conduit.app.N_FAVORITES_COUNT
import conduit.app.N_FOLLOWING
import conduit.app.N_IMAGE
import conduit.app.N_SLUG
import conduit.app.N_TAG_LIST
import conduit.app.N_TITLE
import conduit.app.N_UPDATED_AT
import conduit.app.N_USERNAME
import conduit.json.JsonWriter
import conduit.pg.Oid
import conduit.pg.PgConn
import conduit.pg.PgError
import conduit.pg.Row
import conduit.pg.beginBind
import conduit.pg.endBindExecute
import conduit.pg.sync
import conduit.util.ByteBuf
import conduit.util.intBE
import conduit.util.longBE
import kotlin.jvm.JvmField

// The read path of rust-epoll-theCatWisel (MIT), ported: a batch is split into phase A (ids and counts per kind, their statements run
// unchanged, one pipeline), then ONE decoration round trip (artx: article columns, tag ids, favorites count by primary key; artau: the
// authors; flags: the viewers' favorites and follows), and everything else is app side: the keys of the batch are interned (identical
// slugs, pages and viewers are queried once), tag ids become names, and each distinct article's JSON is formatted once per batch into an
// arena that every request of the batch copies from (engine.rs execute_batch). Nothing outlives the batch.

/** The kinds read this way ([ReadKind.tp]); the ordinal is the request's kind in a [TpState]. */
enum class TpKind { SLUG, ID, COMMENTS, GLOBAL, TAG, AUTHOR, FAVLIST, FEED }

/** Open-addressing set of strings: [intern] returns the key's ordinal (first come, first numbered). */
internal class StrIntern {
    private var keys = arrayOfNulls<String>(16)
    private var table = IntArray(32)
    @JvmField var size = 0

    fun clear() {
        if (size == 0) return
        keys.fill(null, 0, size)
        table.fill(0)
        size = 0
    }

    fun key(i: Int): String = keys[i]!!

    fun intern(s: String): Int {
        if ((size + 1) * 2 > table.size) grow()
        val mask = table.size - 1
        var h = s.hashCode()
        h = h xor (h ushr 15)
        var slot = h and mask
        while (true) {
            val e = table[slot]
            if (e == 0) {
                if (size == keys.size) keys = keys.copyOf(size * 2)
                keys[size] = s
                table[slot] = ++size
                return size - 1
            }
            if (keys[e - 1] == s) return e - 1
            slot = (slot + 1) and mask
        }
    }

    private fun grow() {
        val t = IntArray(table.size * 2)
        val mask = t.size - 1
        for (i in 0 until size) {
            var h = keys[i]!!.hashCode()
            h = h xor (h ushr 15)
            var slot = h and mask
            while (t[slot] != 0) slot = (slot + 1) and mask
            t[slot] = i + 1
        }
        table = t
    }
}

/** Open-addressing set of tuples of [w] longs. */
internal class LongsIntern(private val w: Int) {
    private var vals = LongArray(16 * w)
    private var table = IntArray(32)
    @JvmField var size = 0

    fun clear() {
        if (size == 0) return
        table.fill(0)
        size = 0
    }

    fun v(i: Int, j: Int): Long = vals[i * w + j]

    private fun hash(a: Long, b: Long, c: Long): Int {
        var h = a * -0x61c8864680b583ebL + b * -0x3d4d51c2d82b14b1L + c * 0x2545F4914F6CDD1DL
        h = h xor (h ushr 29)
        return (h ushr 17).toInt()
    }

    fun intern(a: Long, b: Long = 0, c: Long = 0): Int {
        if ((size + 1) * 2 > table.size) grow()
        val mask = table.size - 1
        var slot = hash(a, b, c) and mask
        while (true) {
            val e = table[slot]
            if (e == 0) {
                if ((size + 1) * w > vals.size) vals = vals.copyOf(vals.size * 2)
                val p = size * w
                vals[p] = a
                if (w > 1) vals[p + 1] = b
                if (w > 2) vals[p + 2] = c
                table[slot] = ++size
                return size - 1
            }
            val p = (e - 1) * w
            if (vals[p] == a && (w < 2 || vals[p + 1] == b) && (w < 3 || vals[p + 2] == c)) return e - 1
            slot = (slot + 1) and mask
        }
    }

    private fun grow() {
        val t = IntArray(table.size * 2)
        val mask = t.size - 1
        for (i in 0 until size) {
            val p = i * w
            var slot = hash(vals[p], if (w > 1) vals[p + 1] else 0L, if (w > 2) vals[p + 2] else 0L) and mask
            while (t[slot] != 0) slot = (slot + 1) and mask
            t[slot] = i + 1
        }
        table = t
    }
}

/** Pages of article ordinals: page p is [TpState.pageArts] [off[p], off[p] + len[p]). */
internal class PageSet {
    @JvmField var off = IntArray(16)
    @JvmField var len = IntArray(16)
    @JvmField var fill = IntArray(16)
    @JvmField var n = 0
    fun reset(count: Int) {
        if (off.size < count) {
            off = IntArray(count * 2); len = IntArray(count * 2); fill = IntArray(count * 2)
        } else {
            off.fill(0, 0, count); len.fill(0, 0, count); fill.fill(0, 0, count)
        }
        n = count
    }
}

/**
 * One batch of mixed [TpKind] requests: the interned keys, the phase A statements (encode), the parsed results, the shared
 * decoration (phase B) and the per-batch rendering. Owned by a [ReadBatch]; valid until the batch object is reused.
 */
internal class TpState {
    @JvmField var n = 0
    private var rk = IntArray(0)
    private var rs1 = IntArray(0)
    private var rs2 = IntArray(0)
    private var rv = LongArray(0)

    // interned keys (engine.rs ReadWorker k_*)
    private val kSlug = StrIntern()
    private val kAid = LongsIntern(1)
    private val kCmts = StrIntern()
    private val kGlobal = LongsIntern(2)
    private val kFCnt = arrayOf(StrIntern(), StrIntern(), StrIntern())
    private val kFPage = arrayOf(LongsIntern(3), LongsIntern(3), LongsIntern(3))
    private val kFeedCnt = LongsIntern(1)
    private val kFeedPage = LongsIntern(3)

    // phase A / B results: row start offsets (into [buf]) per statement
    @JvmField var buf: ByteArray = ByteArray(0)
    private var rowsA = IntArray(256)
    private var nRowsA = 0
    private var fromA = IntArray(16)
    private var rowsB = IntArray(256)
    private var nRowsB = 0
    private var fromB = IntArray(8)
    private var stSlug = -1; private var stAid = -1; private var stCmts = -1; private var stGlobal = -1
    private val stFilter = intArrayOf(-1, -1, -1)
    private var stFeed = -1; private var stTags = -1
    private var useWin = false
    private var winMax = 0L
    private var bArtx = -1; private var bArtau = -1; private var bFlags = -1

    @JvmField var error: PgError? = null
    private val row = Row()
    private val row2 = Row()

    // distinct articles and authors (engine.rs distinct_arts / distinct_authors)
    private val artIntern = LongsIntern(1)
    private val auIntern = LongsIntern(1)
    private var artAu = IntArray(64)
    private var artRow = IntArray(64)
    private var artReady = BooleanArray(64)
    private var sHead = IntArray(64); private var sHeadEnd = IntArray(64)
    private var sP0 = IntArray(64); private var sP1 = IntArray(64)
    private var sQ0 = IntArray(64); private var sQ1 = IntArray(64); private var sEnd = IntArray(64)
    private var auRow = IntArray(64)

    private var slugArt = IntArray(16)
    private var idArt = IntArray(16)
    private var pageArts = IntArray(256)
    private var nPageArts = 0
    private var gCounts = LongArray(1)
    private val gPages = PageSet()
    private val winPage = PageSet()
    private val fCounts = arrayOf(LongArray(1), LongArray(1), LongArray(1))
    private val fPages = arrayOf(PageSet(), PageSet(), PageSet())
    private var feedCounts = LongArray(1)
    private val feedPages = PageSet()

    // comments: per slug ordinal, its comment rows (start offsets into [buf]) and their JSON slices in the arena
    private var cmtExists = BooleanArray(16)
    private var cmtFirst = IntArray(16)
    private var cmtLen = IntArray(16)
    private var cmtRows = IntArray(64)
    private var cmtS = IntArray(64)
    private var cmtE = IntArray(64)
    private var cmtAuthor = LongArray(64)
    private var nCmt = 0

    // viewer flags: packed (viewer shl 32 | target), sorted
    private var favPairs = LongArray(64); private var nFavPairs = 0
    private var follPairs = LongArray(64); private var nFollPairs = 0
    private var favHits = LongArray(16); private var nFavHits = 0
    private var follHits = LongArray(16); private var nFollHits = 0
    private var fViewers = LongArray(16); private var fTargets = LongArray(64)
    private var fStarts = IntArray(16); private var fEnds = IntArray(16)
    private var nFV = 0; private var nFT = 0
    private var oViewers = LongArray(16); private var oTargets = LongArray(64)
    private var oStarts = IntArray(16); private var oEnds = IntArray(16)
    private var nOV = 0; private var nOT = 0
    private var depthTmp = LongArray(16)

    // tags: rank by tag id (the position in the statement's name order), names by rank
    private var tagRankById = IntArray(256)
    private var tagOff = IntArray(256)
    private var tagLen = IntArray(256)
    private var nTags = 0
    private var tagTmp = IntArray(16)

    // rendering
    private val arena = ByteBuf(1 shl 16)
    private val aw = JsonWriter(arena)
    private val resp = ByteBuf(1 shl 12)
    private var respS = IntArray(16)
    private var respE = IntArray(16)
    // response cache slots: slug ordinals, global pages, filter pages (3), comment ordinals
    private var cacheSlug = IntArray(0)
    private var cacheGlobal = IntArray(0)

    // ---------------------------------------------------------------------------------------------------------------
    // encode (phase A)

    fun clear() {
        n = 0
        kSlug.clear(); kAid.clear(); kCmts.clear(); kGlobal.clear()
        for (i in 0 until 3) { kFCnt[i].clear(); kFPage[i].clear() }
        kFeedCnt.clear(); kFeedPage.clear()
        artIntern.clear(); auIntern.clear()
        nRowsA = 0; nRowsB = 0; nPageArts = 0; nCmt = 0
        nFavPairs = 0; nFollPairs = 0; nFavHits = 0; nFollHits = 0
        nFV = 0; nFT = 0; nOV = 0; nOT = 0; nTags = 0
        arena.reset(); resp.reset()
        error = null
    }

    private fun ensureReqs(m: Int) {
        if (rk.size >= m) return
        val c = maxOf(m, rk.size * 2)
        rk = IntArray(c); rs1 = IntArray(c); rs2 = IntArray(c); rv = LongArray(c)
    }

    private fun i64Array(o: ByteBuf, count: Int) {
        o.putIntBE(if (count == 0) 12 else 20 + count * 12)
        o.putIntBE(if (count == 0) 0 else 1)
        o.putIntBE(0)
        o.putIntBE(Oid.INT8)
        if (count == 0) return
        o.putIntBE(count)
        o.putIntBE(1)
    }

    private fun putI64(o: ByteBuf, v: Long) { o.putIntBE(8); o.putLongBE(v) }

    private fun i32Header(o: ByteBuf, count: Int) {
        o.putIntBE(if (count == 0) 12 else 20 + count * 8)
        o.putIntBE(if (count == 0) 0 else 1)
        o.putIntBE(0)
        o.putIntBE(Oid.INT4)
        if (count == 0) return
        o.putIntBE(count)
        o.putIntBE(1)
    }

    private fun textHeader(o: ByteBuf, count: Int): Int {
        val p = o.len
        o.putIntBE(0)
        o.putIntBE(if (count == 0) 0 else 1)
        o.putIntBE(0)
        o.putIntBE(Oid.TEXT)
        if (count > 0) { o.putIntBE(count); o.putIntBE(1) }
        return p
    }

    private fun textArray(o: ByteBuf, set: StrIntern) {
        val p = textHeader(o, set.size)
        for (i in 0 until set.size) {
            val q = o.len
            o.putIntBE(0)
            o.putUtf8(set.key(i))
            o.setIntBE(q, o.len - q - 4)
        }
        o.setIntBE(p, o.len - p - 4)
    }

    /** Interns the batch's keys and writes phase A: one Bind/Execute per active statement, then Sync (engine.rs execute_batch). */
    fun encodeA(batch: ReadBatch, o: ByteBuf) {
        val m = batch.n
        clear()
        n = m
        ensureReqs(m)
        for (j in 0 until m) {
            val q = batch.reqs[j]!!
            rv[j] = q.viewer
            val k = q.tpKind
            rk[j] = k
            when (k) {
                TpKind.SLUG.ordinal -> rs1[j] = kSlug.intern(wireKey(q.key))
                TpKind.ID.ordinal -> rs1[j] = kAid.intern(q.offset)
                TpKind.COMMENTS.ordinal -> rs1[j] = kCmts.intern(wireKey(q.key))
                TpKind.GLOBAL.ordinal -> rs1[j] = kGlobal.intern(q.limit.toLong(), q.offset)
                TpKind.TAG.ordinal, TpKind.AUTHOR.ordinal, TpKind.FAVLIST.ordinal -> {
                    val f = k - TpKind.TAG.ordinal
                    val c = kFCnt[f].intern(wireKey(q.key))
                    rs1[j] = c
                    rs2[j] = kFPage[f].intern(c.toLong(), q.limit.toLong(), q.offset)
                }
                else -> { // FEED
                    val c = kFeedCnt.intern(q.viewer)
                    rs1[j] = c
                    rs2[j] = kFeedPage.intern(c.toLong(), q.limit.toLong(), q.offset)
                }
            }
        }
        val touchesArticles = kSlug.size + kAid.size + kGlobal.size + kFPage[0].size + kFPage[1].size + kFPage[2].size + kFeedCnt.size > 0
        var ns = 0
        stSlug = if (kSlug.size > 0) ns++ else -1
        stAid = if (kAid.size > 0) ns++ else -1
        stCmts = if (kCmts.size > 0) ns++ else -1
        stGlobal = if (kGlobal.size > 0) ns++ else -1
        for (i in 0 until 3) stFilter[i] = if (kFPage[i].size > 0) ns++ else -1
        stFeed = if (kFeedCnt.size > 0) ns++ else -1
        stTags = if (touchesArticles) ns++ else -1
        if (fromA.size < ns + 2) fromA = IntArray(ns + 2)

        o.reset()
        if (stSlug >= 0) {
            val lp = o.beginBind(N_ASLUG, 1)
            textArray(o, kSlug)
            o.endBindExecute(lp)
        }
        if (stAid >= 0) {
            val lp = o.beginBind(N_AID, 1)
            i64Array(o, kAid.size)
            for (i in 0 until kAid.size) putI64(o, kAid.v(i, 0))
            o.endBindExecute(lp)
        }
        if (stCmts >= 0) {
            val lp = o.beginBind(N_CMTS, 1)
            textArray(o, kCmts)
            o.endBindExecute(lp)
        }
        if (stGlobal >= 0) {
            useWin = true
            winMax = 0L
            for (i in 0 until kGlobal.size) {
                val end = satAdd(kGlobal.v(i, 0), kGlobal.v(i, 1))
                if (end > 200) { useWin = false; break }
                if (end > winMax) winMax = end
            }
            if (useWin) {
                val lp = o.beginBind(N_GLOBAL_WIN, 1)
                putI64(o, maxOf(winMax, 1L))
                o.endBindExecute(lp)
            } else {
                val lp = o.beginBind(N_GLOBAL, 2)
                i64Array(o, kGlobal.size)
                for (i in 0 until kGlobal.size) putI64(o, kGlobal.v(i, 0))
                i64Array(o, kGlobal.size)
                for (i in 0 until kGlobal.size) putI64(o, kGlobal.v(i, 1))
                o.endBindExecute(lp)
            }
        }
        for (f in 0 until 3) {
            if (stFilter[f] < 0) continue
            val pages = kFPage[f]
            val lp = o.beginBind(FILTER_NAMES[f], 4)
            textArray(o, kFCnt[f])
            i64Array(o, pages.size)
            for (i in 0 until pages.size) putI64(o, pages.v(i, 0) + 1)
            i64Array(o, pages.size)
            for (i in 0 until pages.size) putI64(o, pages.v(i, 1))
            i64Array(o, pages.size)
            for (i in 0 until pages.size) putI64(o, pages.v(i, 2))
            o.endBindExecute(lp)
        }
        if (stFeed >= 0) {
            val lp = o.beginBind(N_FEED, 5)
            val vc = kFeedCnt.size
            i64Array(o, vc)
            for (i in 0 until vc) putI64(o, kFeedCnt.v(i, 0))
            // depth per viewer: the deepest page (limit + offset) any of its requests asks, at least 1
            if (depthTmp.size < vc) depthTmp = LongArray(vc * 2)
            for (i in 0 until vc) depthTmp[i] = 1L
            val pc = kFeedPage.size
            for (i in 0 until pc) {
                val d = maxOf(satAdd(kFeedPage.v(i, 1), kFeedPage.v(i, 2)), 1L)
                val c = kFeedPage.v(i, 0).toInt()
                if (d > depthTmp[c]) depthTmp[c] = d
            }
            i64Array(o, vc)
            for (i in 0 until vc) putI64(o, depthTmp[i])
            i64Array(o, pc)
            for (i in 0 until pc) putI64(o, kFeedPage.v(i, 0) + 1)
            i64Array(o, pc)
            for (i in 0 until pc) putI64(o, kFeedPage.v(i, 1))
            i64Array(o, pc)
            for (i in 0 until pc) putI64(o, kFeedPage.v(i, 2))
            o.endBindExecute(lp)
        }
        if (stTags >= 0) {
            val lp = o.beginBind(N_TAGS, 0)
            o.endBindExecute(lp)
        }
        o.sync()
    }

    private fun satAdd(a: Long, b: Long): Long {
        val s = a + b
        return if (s < a) Long.MAX_VALUE else s
    }

    // ---------------------------------------------------------------------------------------------------------------
    // phase A reply, phase B round trip

    /** Reads one pipeline reply (every statement's rows) into the row tables; the first ErrorResponse is returned. */
    private fun collect(c: PgConn, b: Boolean): PgError? {
        var s = 0
        var cnt = 0
        var err: PgError? = null
        val from = if (b) fromB else fromA
        from[0] = 0
        while (true) {
            when (c.next()) {
                'D'.code -> {
                    if (err == null) {
                        if (b) {
                            if (cnt == rowsB.size) rowsB = rowsB.copyOf(cnt * 2)
                            rowsB[cnt++] = c.mstart
                        } else {
                            if (cnt == rowsA.size) rowsA = rowsA.copyOf(cnt * 2)
                            rowsA[cnt++] = c.mstart
                        }
                    }
                }
                'C'.code -> { s++; if (s < from.size) from[s] = cnt }
                'E'.code -> if (err == null) err = c.error()
                'Z'.code -> {
                    if (b) nRowsB = cnt else nRowsA = cnt
                    lastStatus = c.txStatus()
                    return err
                }
            }
        }
    }

    @JvmField var lastStatus = 'I'.code

    /**
     * Phase A reply (already on the wire), then phase B, then the batch's tables. Returns the error that fails the batch, or null.
     * Row offsets stay valid: nothing compacts the receive buffer inside one reply cycle.
     */
    fun processReply(c: PgConn): PgError? {
        var err = collect(c, false)
        if (err != null) return err
        buf = c.rbuf
        parseA()
        buildFlagRuns()
        // phase B: artx, artau, flags in one pipeline
        val o = c.out
        o.reset()
        var nb = 0
        val na = artIntern.size
        val nu = auIntern.size
        bArtx = if (na > 0) nb++ else -1
        bArtau = if (nu > 0) nb++ else -1
        bFlags = if (nFV > 0 || nOV > 0) nb++ else -1
        if (fromB.size < nb + 2) fromB = IntArray(nb + 2)
        if (nb > 0) {
            if (bArtx >= 0) {
                val lp = o.beginBind(N_ARTX, 1)
                i64Array(o, na)
                for (i in 0 until na) putI64(o, artIntern.v(i, 0))
                o.endBindExecute(lp)
            }
            if (bArtau >= 0) {
                val lp = o.beginBind(N_ARTAU, 1)
                i64Array(o, nu)
                for (i in 0 until nu) putI64(o, auIntern.v(i, 0))
                o.endBindExecute(lp)
            }
            if (bFlags >= 0) {
                val lp = o.beginBind(N_FLAGS, 8)
                i64Array(o, nFV); for (i in 0 until nFV) putI64(o, fViewers[i])
                i64Array(o, nFT); for (i in 0 until nFT) putI64(o, fTargets[i])
                i32Header(o, nFV); for (i in 0 until nFV) { o.putIntBE(4); o.putIntBE(fStarts[i]) }
                i32Header(o, nFV); for (i in 0 until nFV) { o.putIntBE(4); o.putIntBE(fEnds[i]) }
                i64Array(o, nOV); for (i in 0 until nOV) putI64(o, oViewers[i])
                i64Array(o, nOT); for (i in 0 until nOT) putI64(o, oTargets[i])
                i32Header(o, nOV); for (i in 0 until nOV) { o.putIntBE(4); o.putIntBE(oStarts[i]) }
                i32Header(o, nOV); for (i in 0 until nOV) { o.putIntBE(4); o.putIntBE(oEnds[i]) }
                o.endBindExecute(lp)
            }
            o.sync()
            c.send()
            err = collect(c, true)
            if (err != null) return err
            buf = c.rbuf
        } else {
            nRowsB = 0
        }
        buf = c.rbuf
        parseB()
        return null
    }

    // ---------------------------------------------------------------------------------------------------------------
    // phase A results

    private fun growArt(m: Int) {
        if (artAu.size >= m) return
        val c = maxOf(m, artAu.size * 2)
        artAu = artAu.copyOf(c); artRow = artRow.copyOf(c); artReady = artReady.copyOf(c)
        sHead = sHead.copyOf(c); sHeadEnd = sHeadEnd.copyOf(c); sP0 = sP0.copyOf(c); sP1 = sP1.copyOf(c)
        sQ0 = sQ0.copyOf(c); sQ1 = sQ1.copyOf(c); sEnd = sEnd.copyOf(c)
    }

    private fun internArt(id: Long, author: Long, rowStart: Int): Int {
        val before = artIntern.size
        val ord = artIntern.intern(id)
        if (artIntern.size > before) {
            growArt(artIntern.size)
            artAu[ord] = auIntern.intern(author)
            artRow[ord] = rowStart
            artReady[ord] = false
        }
        return ord
    }

    private fun parseA() {
        val b = buf
        val r = row
        // single articles
        if (slugArt.size < kSlug.size) slugArt = IntArray(kSlug.size * 2)
        if (idArt.size < kAid.size) idArt = IntArray(kAid.size * 2)
        slugArt.fill(-1, 0, kSlug.size)
        idArt.fill(-1, 0, kAid.size)
        if (stSlug >= 0) for (i in fromA[stSlug] until fromA[stSlug + 1]) {
            r.parse(b, rowsA[i])
            val k = r.int8(0).toInt()
            if (k in 1..kSlug.size) slugArt[k - 1] = internArt(r.int8(1), r.int8(2), rowsA[i])
        }
        if (stAid >= 0) for (i in fromA[stAid] until fromA[stAid + 1]) {
            r.parse(b, rowsA[i])
            val k = r.int8(0).toInt()
            if (k in 1..kAid.size) idArt[k - 1] = internArt(r.int8(1), r.int8(2), rowsA[i])
        }
        // lists
        if (gCounts.size < 1) gCounts = LongArray(1)
        gCounts[0] = 0
        if (useWin && stGlobal >= 0) {
            unpack(stGlobal, gCounts, 1, winPage)
            val total = kGlobal.size
            gPages.reset(total)
            val wl = if (winPage.n > 0) winPage.len[0] else 0
            val wo = if (winPage.n > 0) winPage.off[0] else 0
            for (p in 0 until total) {
                val lim = kGlobal.v(p, 0)
                val off = kGlobal.v(p, 1)
                val start = minOf(maxOf(off, 0L), wl.toLong()).toInt()
                val end = minOf(satAdd(start.toLong(), maxOf(lim, 0L)), wl.toLong()).toInt()
                gPages.off[p] = wo + start
                gPages.len[p] = end - start
            }
        } else {
            unpack(stGlobal, gCounts, kGlobal.size, gPages)
        }
        for (f in 0 until 3) {
            if (fCounts[f].size < kFCnt[f].size) fCounts[f] = LongArray(kFCnt[f].size * 2)
            fCounts[f].fill(0)
            unpack(stFilter[f], fCounts[f], kFPage[f].size, fPages[f])
        }
        if (feedCounts.size < kFeedCnt.size) feedCounts = LongArray(kFeedCnt.size * 2)
        feedCounts.fill(0)
        unpack(stFeed, feedCounts, kFeedPage.size, feedPages)
        parseComments()
        // pairs for the flags statement
        for (j in 0 until n) {
            val viewer = rv[j]
            if (viewer == 0L) continue
            when (rk[j]) {
                TpKind.SLUG.ordinal, TpKind.ID.ordinal -> {
                    val a = if (rk[j] == TpKind.SLUG.ordinal) slugArt[rs1[j]] else idArt[rs1[j]]
                    if (a >= 0) { addFav(viewer, artIntern.v(a, 0)); addFoll(viewer, auIntern.v(artAu[a], 0)) }
                }
                TpKind.GLOBAL.ordinal -> pagePairs(viewer, gPages, rs1[j], true)
                TpKind.TAG.ordinal, TpKind.AUTHOR.ordinal, TpKind.FAVLIST.ordinal ->
                    pagePairs(viewer, fPages[rk[j] - TpKind.TAG.ordinal], rs2[j], true)
                TpKind.FEED.ordinal -> pagePairs(viewer, feedPages, rs2[j], false)
                else -> { // COMMENTS
                    val k = rs1[j]
                    for (x in cmtFirst[k] until cmtFirst[k] + cmtLen[k]) addFoll(viewer, cmtAuthor[x])
                }
            }
        }
    }

    private fun pagePairs(viewer: Long, ps: PageSet, p: Int, following: Boolean) {
        val o = ps.off[p]
        for (x in o until o + ps.len[p]) {
            val a = pageArts[x]
            addFav(viewer, artIntern.v(a, 0))
            if (following) addFoll(viewer, auIntern.v(artAu[a], 0))
        }
    }

    private fun addFav(viewer: Long, id: Long) {
        if (nFavPairs == favPairs.size) favPairs = favPairs.copyOf(nFavPairs * 2)
        favPairs[nFavPairs++] = (viewer shl 32) or (id and 0xFFFFFFFFL)
    }

    private fun addFoll(viewer: Long, id: Long) {
        if (nFollPairs == follPairs.size) follPairs = follPairs.copyOf(nFollPairs * 2)
        follPairs[nFollPairs++] = (viewer shl 32) or (id and 0xFFFFFFFFL)
    }

    /** engine.rs unpack_list: count rows have k <= 0 (-k is the count's ordinal + 1, 0 the global count), page rows k > 0. */
    private fun unpack(st: Int, counts: LongArray, nPage: Int, ps: PageSet) {
        ps.reset(nPage)
        if (st < 0) return
        val b = buf
        val r = row
        val from = fromA[st]
        val to = fromA[st + 1]
        for (i in from until to) {
            r.parse(b, rowsA[i])
            val k = r.int8(0)
            if (k <= 0L) {
                val idx = if (k == 0L) 0 else (-k - 1).toInt()
                if (idx < counts.size) counts[idx] = r.int8(1)
            } else if (k <= nPage) ps.len[(k - 1).toInt()]++
        }
        var acc = nPageArts
        for (p in 0 until nPage) { ps.off[p] = acc; acc += ps.len[p] }
        if (pageArts.size < acc) pageArts = pageArts.copyOf(maxOf(acc, pageArts.size * 2))
        nPageArts = acc
        for (i in from until to) {
            r.parse(b, rowsA[i])
            val k = r.int8(0)
            if (k > 0L && k <= nPage) {
                val p = (k - 1).toInt()
                pageArts[ps.off[p] + ps.fill[p]++] = internArt(r.int8(1), r.int8(2), rowsA[i])
            }
        }
        for (p in 0 until nPage) {
            if (ps.len[p] > 1) sortDesc(ps.off[p], ps.len[p])
        }
    }

    /** Page entries newest first (the statements already return them so; the leader sorts anyway). */
    private fun sortDesc(off: Int, len: Int) {
        var sorted = true
        for (x in off + 1 until off + len) if (artIntern.v(pageArts[x - 1], 0) < artIntern.v(pageArts[x], 0)) { sorted = false; break }
        if (sorted) return
        for (x in off + 1 until off + len) {
            val a = pageArts[x]
            val id = artIntern.v(a, 0)
            var y = x - 1
            while (y >= off && artIntern.v(pageArts[y], 0) < id) { pageArts[y + 1] = pageArts[y]; y-- }
            pageArts[y + 1] = a
        }
    }

    private fun parseComments() {
        val k = kCmts.size
        if (cmtExists.size < k) { cmtExists = BooleanArray(k * 2); cmtFirst = IntArray(k * 2); cmtLen = IntArray(k * 2) }
        cmtExists.fill(false, 0, k); cmtLen.fill(0, 0, k)
        nCmt = 0
        if (stCmts < 0) return
        val b = buf
        val r = row
        val from = fromA[stCmts]
        val to = fromA[stCmts + 1]
        for (i in from until to) {
            r.parse(b, rowsA[i])
            val o = (r.int8(0) - 1).toInt()
            if (o !in 0 until k) continue
            cmtExists[o] = true
            if (!r.isNull(2) && !r.isNull(7)) cmtLen[o]++
        }
        var acc = 0
        for (o in 0 until k) { cmtFirst[o] = acc; acc += cmtLen[o] }
        if (cmtRows.size < acc) { val c = maxOf(acc, cmtRows.size * 2); cmtRows = IntArray(c); cmtS = IntArray(c); cmtE = IntArray(c); cmtAuthor = LongArray(c) }
        nCmt = acc
        val fillAt = IntArray(k)
        for (i in from until to) {
            r.parse(b, rowsA[i])
            val o = (r.int8(0) - 1).toInt()
            if (o !in 0 until k || r.isNull(2) || r.isNull(7)) continue
            cmtRows[cmtFirst[o] + fillAt[o]++] = rowsA[i]
        }
        // newest first, as the statement's ORDER BY gives them; sort a group only when it is not (engine.rs sorts every group)
        for (o in 0 until k) {
            val f = cmtFirst[o]
            val l = cmtLen[o]
            if (l < 2) continue
            var sorted = true
            for (x in f + 1 until f + l) if (cmtBefore(cmtRows[x - 1], cmtRows[x])) { sorted = false; break }
            if (sorted) continue
            for (x in f + 1 until f + l) {
                val v = cmtRows[x]
                var y = x - 1
                while (y >= f && cmtBefore(cmtRows[y], v)) { cmtRows[y + 1] = cmtRows[y]; y-- }
                cmtRows[y + 1] = v
            }
        }
        for (x in 0 until acc) { r.parse(b, cmtRows[x]); cmtAuthor[x] = r.int8(6) } // the viewers' follows are looked up by author
    }

    /** True when comment row [a] sorts after [b] in (created_at DESC, id DESC) order, i.e. is older or has a smaller id on a tie. */
    private fun cmtBefore(a: Int, b: Int): Boolean {
        row.parse(buf, a); row2.parse(buf, b)
        val ca = row.micros(4); val cb = row2.micros(4)
        if (ca != cb) return ca < cb
        return row.int8(2) < row2.int8(2)
    }

    private fun buildFlagRuns() {
        // favorites
        nFV = 0; nFT = 0
        runs(favPairs, nFavPairs, true)
        nOV = 0; nOT = 0
        runs(follPairs, nFollPairs, false)
    }

    private fun runs(pairs: LongArray, count: Int, fav: Boolean) {
        if (count == 0) return
        pairs.sort(0, count)
        // dedup in place
        var m = 1
        for (i in 1 until count) if (pairs[i] != pairs[m - 1]) pairs[m++] = pairs[i]
        var viewers = if (fav) fViewers else oViewers
        var targets = if (fav) fTargets else oTargets
        var starts = if (fav) fStarts else oStarts
        var ends = if (fav) fEnds else oEnds
        if (targets.size < m) targets = LongArray(maxOf(m, targets.size * 2))
        var nv = 0
        var curV = pairs[0] shr 32
        var runStart = 1
        for (i in 0 until m) {
            val v = pairs[i] shr 32
            if (v != curV) {
                if (nv >= viewers.size) viewers = viewers.copyOf(nv * 2 + 2)
                if (nv >= starts.size) starts = starts.copyOf(nv * 2 + 2)
                if (nv >= ends.size) ends = ends.copyOf(nv * 2 + 2)
                viewers[nv] = curV; starts[nv] = runStart; ends[nv] = i; nv++
                curV = v
                runStart = i + 1
            }
            targets[i] = pairs[i] and 0xFFFFFFFFL
        }
        if (nv >= viewers.size) viewers = viewers.copyOf(nv * 2 + 2)
        if (nv >= starts.size) starts = starts.copyOf(nv * 2 + 2)
        if (nv >= ends.size) ends = ends.copyOf(nv * 2 + 2)
        viewers[nv] = curV; starts[nv] = runStart; ends[nv] = m; nv++
        if (fav) { fViewers = viewers; fTargets = targets; fStarts = starts; fEnds = ends; nFV = nv; nFT = m }
        else { oViewers = viewers; oTargets = targets; oStarts = starts; oEnds = ends; nOV = nv; nOT = m }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // phase B results: the arena

    private fun parseB() {
        val b = buf
        val r = row
        // tags: ranks in the statement's order (the database's collation)
        nTags = 0
        if (stTags >= 0) {
            val from = fromA[stTags]
            val to = fromA[stTags + 1]
            val cnt = to - from
            if (tagOff.size < cnt) { tagOff = IntArray(cnt * 2); tagLen = IntArray(cnt * 2) }
            for (i in from until to) {
                r.parse(b, rowsA[i])
                val id = if (r.len[0] == 4) r.int4(0).toLong() else r.int8(0)
                val rank = nTags++
                tagOff[rank] = r.off[1]
                tagLen[rank] = r.len[1]
                if (id in 0 until (1L shl 20)) {
                    if (tagRankById.size <= id) { val old = tagRankById.size; tagRankById = tagRankById.copyOf(maxOf(id.toInt() + 1, old * 2)); tagRankById.fill(-1, old, tagRankById.size) }
                    tagRankById[id.toInt()] = rank
                }
            }
        }
        val na = artIntern.size
        auRow.let { if (it.size < auIntern.size) auRow = IntArray(auIntern.size * 2) }
        auRow.fill(-1, 0, auIntern.size)
        if (bArtau >= 0) for (i in fromB[bArtau] until fromB[bArtau + 1]) {
            r.parse(b, rowsB[i])
            val k = r.int8(0).toInt()
            if (k in 1..auIntern.size) auRow[k - 1] = rowsB[i]
        }
        if (bArtx >= 0) for (i in fromB[bArtx] until fromB[bArtx + 1]) {
            r.parse(b, rowsB[i])
            val k = r.int8(0).toInt()
            if (k !in 1..na) continue
            val ord = k - 1
            val ar = auRow[artAu[ord]]
            if (ar < 0) continue
            row2.parse(b, ar)
            buildArticle(ord, r, row2)
        }
        if (bFlags >= 0) {
            nFavHits = 0; nFollHits = 0
            for (i in fromB[bFlags] until fromB[bFlags + 1]) {
                r.parse(b, rowsB[i])
                val packed = (r.int8(1) shl 32) or (r.int8(2) and 0xFFFFFFFFL)
                if (r.int8(0) == 0L) {
                    if (nFavHits == favHits.size) favHits = favHits.copyOf(nFavHits * 2)
                    favHits[nFavHits++] = packed
                } else {
                    if (nFollHits == follHits.size) follHits = follHits.copyOf(nFollHits * 2)
                    follHits[nFollHits++] = packed
                }
            }
            favHits.sort(0, nFavHits)
            follHits.sort(0, nFollHits)
        }
        // comment slices
        var arenaCmt = 0
        for (o in 0 until kCmts.size) for (x in cmtFirst[o] until cmtFirst[o] + cmtLen[o]) {
            r.parse(b, cmtRows[x])
            val w = aw
            w.reset()
            val s = arena.len
            w.beginObject()
            w.name(N_ID); w.number(r.int8(2))
            w.name(N_CREATED_AT); w.timestamp(r.micros(4))
            w.name(N_UPDATED_AT); w.timestamp(r.micros(5))
            w.name(N_BODY); w.text(r, 3)
            w.name(N_AUTHOR); w.beginObject()
            w.name(N_USERNAME); w.text(r, 7)
            w.name(N_BIO); w.text(r, 8)
            w.name(N_IMAGE); w.text(r, 9)
            w.name(N_FOLLOWING)
            cmtS[x] = s
            cmtE[x] = arena.len
            arenaCmt++
        }
        // response caches (unflagged responses are formatted once per batch and copied)
        val slots = kSlug.size + kCmts.size + kGlobal.size + kFPage[0].size + kFPage[1].size + kFPage[2].size
        if (respS.size < slots) { respS = IntArray(slots * 2); respE = IntArray(slots * 2) }
        respS.fill(-1, 0, slots)
    }

    private fun buildArticle(ord: Int, x: Row, au: Row) {
        val w = aw
        w.reset()
        sHead[ord] = arena.len
        w.beginObject()
        w.name(N_SLUG); w.text(x, 1)
        w.name(N_TITLE); w.text(x, 2)
        w.name(N_DESCRIPTION); w.text(x, 3)
        sHeadEnd[ord] = arena.len
        w.name(N_TAG_LIST)
        w.beginArray()
        writeTags(w, x)
        w.endArray()
        w.name(N_CREATED_AT); w.timestamp(x.micros(4))
        w.name(N_UPDATED_AT); w.timestamp(x.micros(5))
        w.name(N_FAVORITED)
        sP0[ord] = arena.len
        w.bool(false)
        sP1[ord] = arena.len
        w.name(N_FAVORITES_COUNT); w.number(x.int8(7))
        w.name(N_AUTHOR)
        w.beginObject()
        w.name(N_USERNAME); w.text(au, 1)
        w.name(N_BIO); w.text(au, 2)
        w.name(N_IMAGE); w.text(au, 3)
        w.name(N_FOLLOWING)
        sQ0[ord] = arena.len
        w.bool(false)
        sQ1[ord] = arena.len
        w.endObject()
        w.endObject()
        sEnd[ord] = arena.len
        artReady[ord] = true
    }

    /** The article's tag names, ordered by name: tag ids (an int4[] column 6) sorted by their rank in the tags statement's order. */
    private fun writeTags(w: JsonWriter, x: Row) {
        if (x.len[6] <= 12) return // an empty array has no dimension
        val b = buf
        var p = x.off[6]
        val ndim = b.intBE(p)
        if (ndim == 0) return
        val count = b.intBE(p + 12)
        p += 20
        if (tagTmp.size < count) tagTmp = IntArray(count * 2)
        var m = 0
        for (i in 0 until count) {
            val l = b.intBE(p)
            val id = if (l == 4) b.intBE(p + 4) else b.longBE(p + 4).toInt()
            p += 4 + l
            val rank = if (id >= 0 && id < tagRankById.size) tagRankById[id] else -1
            if (rank < 0) continue
            var y = m - 1
            while (y >= 0 && tagTmp[y] > rank) { tagTmp[y + 1] = tagTmp[y]; y-- }
            tagTmp[y + 1] = rank
            m++
        }
        for (i in 0 until m) w.string(b, tagOff[tagTmp[i]], tagLen[tagTmp[i]])
    }

    // ---------------------------------------------------------------------------------------------------------------
    // rendering (engine.rs RenderCtx and the per-slot reply code)

    private fun isFav(viewer: Long, id: Long): Boolean = nFavHits > 0 && search(favHits, nFavHits, (viewer shl 32) or (id and 0xFFFFFFFFL))
    private fun isFoll(viewer: Long, id: Long): Boolean = nFollHits > 0 && search(follHits, nFollHits, (viewer shl 32) or (id and 0xFFFFFFFFL))

    private fun search(a: LongArray, n: Int, key: Long): Boolean {
        var lo = 0
        var hi = n - 1
        while (lo <= hi) {
            val mid = (lo + hi) ushr 1
            val v = a[mid]
            if (v < key) lo = mid + 1 else if (v > key) hi = mid - 1 else return true
        }
        return false
    }

    private fun unflagged(viewer: Long, a: Int): Boolean =
        viewer == 0L || (!isFav(viewer, artIntern.v(a, 0)) && !isFoll(viewer, auIntern.v(artAu[a], 0)))

    /** One article's value (no envelope); [withBody] adds the body from phase A's row. False: the article could not be decorated. */
    private fun putArticle(j: JsonWriter, a: Int, withBody: Boolean, fav: Boolean, foll: Boolean): Boolean {
        if (!artReady[a]) return false
        val ar = arena.buf
        j.beginRaw()
        if (withBody) {
            j.rawPart(ar, sHead[a], sHeadEnd[a] - sHead[a])
            j.rawPart(BODY_KEY, 0, BODY_KEY.size)
            row.parse(buf, artRow[a])
            j.rawQuoted(buf, row.off[3], row.len[3])
            j.rawPart(ar, sHeadEnd[a], sP0[a] - sHeadEnd[a])
        } else {
            j.rawPart(ar, sHead[a], sP0[a] - sHead[a])
        }
        j.rawPart(if (fav) TRUE else FALSE, 0, if (fav) 4 else 5)
        j.rawPart(ar, sP1[a], sQ0[a] - sP1[a])
        j.rawPart(if (foll) TRUE else FALSE, 0, if (foll) 4 else 5)
        j.rawPart(ar, sQ1[a], sEnd[a] - sQ1[a])
        return true
    }

    private fun cachedReply(j: JsonWriter, slot: Int): Boolean {
        val s = respS[slot]
        if (s < 0) return false
        j.beginRaw()
        j.rawPart(resp.buf, s, respE[slot] - s)
        return true
    }

    private fun rememberReply(j: JsonWriter, slot: Int, from: Int) {
        respS[slot] = resp.len
        resp.put(j.out.buf, from, j.out.len - from)
        respE[slot] = resp.len
    }

    /** {"articles":[...],"articlesCount":N} for list/feed request [req]. */
    fun writeList(j: JsonWriter, req: Int): Boolean {
        val viewer = rv[req]
        val kind = rk[req]
        val ps: PageSet
        val p: Int
        val count: Long
        var slot = -1
        val isFeed = kind == TpKind.FEED.ordinal
        when (kind) {
            TpKind.GLOBAL.ordinal -> { ps = gPages; p = rs1[req]; count = gCounts[0]; slot = kSlug.size + kCmts.size + p }
            TpKind.FEED.ordinal -> { ps = feedPages; p = rs2[req]; count = feedCounts[rs1[req]] }
            else -> {
                val f = kind - TpKind.TAG.ordinal
                ps = fPages[f]; p = rs2[req]; count = fCounts[f][rs1[req]]
                var base = kSlug.size + kCmts.size + kGlobal.size
                for (i in 0 until f) base += kFPage[i].size
                slot = base + p
            }
        }
        val o = ps.off[p]
        val l = ps.len[p]
        var plain = !isFeed && viewer == 0L
        if (!isFeed && viewer != 0L) {
            plain = true
            for (x in o until o + l) if (!unflagged(viewer, pageArts[x])) { plain = false; break }
        }
        if (plain && slot >= 0 && cachedReply(j, slot)) return true
        val from = j.out.len
        j.beginObject()
        j.name(N_ARTICLES)
        j.beginArray()
        for (x in o until o + l) {
            val a = pageArts[x]
            val fav = !plain && viewer != 0L && isFav(viewer, artIntern.v(a, 0))
            val foll = isFeed || (!plain && viewer != 0L && isFoll(viewer, auIntern.v(artAu[a], 0)))
            putArticle(j, a, false, fav, foll)
        }
        j.endArray()
        j.name(N_ARTICLES_COUNT); j.number(count)
        j.endObject()
        if (plain && slot >= 0) rememberReply(j, slot, from)
        return true
    }

    /** {"article": ...} for a SLUG or ID request; false = 404. */
    fun writeArticle(j: JsonWriter, req: Int): Boolean {
        val viewer = rv[req]
        val slug = rk[req] == TpKind.SLUG.ordinal
        val a = if (slug) slugArt[rs1[req]] else idArt[rs1[req]]
        if (a < 0 || !artReady[a]) return false
        val fav = viewer != 0L && isFav(viewer, artIntern.v(a, 0))
        val foll = viewer != 0L && isFoll(viewer, auIntern.v(artAu[a], 0))
        val plain = slug && !fav && !foll
        if (plain && cachedReply(j, rs1[req])) return true
        val from = j.out.len
        j.beginObject()
        j.name(N_ARTICLE)
        putArticle(j, a, true, fav, foll)
        j.endObject()
        if (plain) rememberReply(j, rs1[req], from)
        return true
    }

    /** {"comments":[...]} for a COMMENTS request; false = 404 (no such article). */
    fun writeComments(j: JsonWriter, req: Int): Boolean {
        val k = rs1[req]
        if (!cmtExists[k]) return false
        val viewer = rv[req]
        val f = cmtFirst[k]
        val l = cmtLen[k]
        var plain = viewer == 0L
        if (!plain) {
            plain = true
            for (x in f until f + l) if (isFoll(viewer, cmtAuthor[x])) { plain = false; break }
        }
        val slot = kSlug.size + k
        if (plain && cachedReply(j, slot)) return true
        val from = j.out.len
        val ar = arena.buf
        j.beginObject()
        j.name(N_COMMENTS)
        j.beginArray()
        for (x in f until f + l) {
            j.beginRaw()
            j.rawPart(ar, cmtS[x], cmtE[x] - cmtS[x])
            val foll = !plain && isFoll(viewer, cmtAuthor[x])
            j.rawPart(if (foll) TRUE_END else FALSE_END, 0, if (foll) 6 else 7)
        }
        j.endArray()
        j.endObject()
        if (plain) rememberReply(j, slot, from)
        return true
    }

    companion object {
        private val N_ARTICLES = conduit.app.N_ARTICLES
        private val N_ARTICLES_COUNT = conduit.app.N_ARTICLES_COUNT
        private val N_ARTICLE = conduit.app.N_ARTICLE
        private val N_COMMENTS = conduit.app.N_COMMENTS
        private val N_ID = conduit.app.N_ID
        private val TRUE = "true".encodeToByteArray()
        private val FALSE = "false".encodeToByteArray()
        private val TRUE_END = "true}}".encodeToByteArray()
        private val FALSE_END = "false}}".encodeToByteArray()
        private val BODY_KEY = ",\"body\":".encodeToByteArray()
        private val N_ASLUG = PgConn.cstr("tp_aslug")
        private val N_AID = PgConn.cstr("tp_aid")
        private val N_CMTS = PgConn.cstr("tp_cmts")
        private val N_GLOBAL = PgConn.cstr("tp_global")
        private val N_GLOBAL_WIN = PgConn.cstr("tp_global_win")
        private val FILTER_NAMES = arrayOf(PgConn.cstr("tp_tag"), PgConn.cstr("tp_author"), PgConn.cstr("tp_favlist"))
        private val N_FEED = PgConn.cstr("tp_feed")
        private val N_TAGS = PgConn.cstr("tp_tags")
        private val N_ARTX = PgConn.cstr("tp_artx")
        private val N_ARTAU = PgConn.cstr("tp_artau")
        private val N_FLAGS = PgConn.cstr("tp_flags")
    }
}
