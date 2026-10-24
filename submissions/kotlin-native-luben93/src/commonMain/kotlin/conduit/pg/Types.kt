package conduit.pg

import kotlin.jvm.JvmField
import conduit.util.ByteBuf
import conduit.util.intBE
import conduit.util.longBE

/** Postgres type OIDs used in Parse. */
object Oid {
    const val BOOL = 16
    const val INT8 = 20
    const val INT4 = 23
    const val TEXT = 25
    const val INT4_ARRAY = 1007
    const val TEXT_ARRAY = 1009
    const val INT8_ARRAY = 1016
}

/** An ErrorResponse: [code] is the SQLSTATE (e.g. "23505" unique violation). */
class PgError(val code: String, val message: String) {
    override fun toString() = "$code $message"
}

/**
 * A view of one DataRow, parsed in place in a connection's receive buffer. All results are requested in BINARY
 * format: int4/int8 big-endian, bool one byte, timestamptz int64 microseconds since 2000-01-01 UTC, text raw UTF-8,
 * text[] the binary array format.
 *
 * Validity: a Row (and the [Result] it came from) points into a receive buffer that is reused once the handler that
 * owns it suspends again or completes. Copy anything you need across a suspension point.
 */
class Row {
    @JvmField var buf: ByteArray = EMPTY
    @JvmField var ncols: Int = 0
    @JvmField val off: IntArray = IntArray(MAX_COLS)
    /** Byte length per column; -1 = NULL. */
    @JvmField val len: IntArray = IntArray(MAX_COLS)

    /** Points this view at a DataRow message body (after the 'D' type byte and length): Int16 ncols, then columns. */
    fun parse(b: ByteArray, bodyStart: Int) {
        buf = b
        val n = ((b[bodyStart].toInt() and 0xFF) shl 8) or (b[bodyStart + 1].toInt() and 0xFF)
        ncols = n
        var p = bodyStart + 2
        for (c in 0 until n) {
            val l = b.intBE(p)
            p += 4
            off[c] = p
            len[c] = l
            if (l > 0) p += l
        }
    }

    fun isNull(c: Int): Boolean = len[c] < 0
    fun int4(c: Int): Int = buf.intBE(off[c])
    fun int8(c: Int): Long = buf.longBE(off[c])
    fun bool(c: Int): Boolean = buf[off[c]].toInt() != 0
    /** timestamptz: microseconds since 2000-01-01T00:00:00Z. */
    fun micros(c: Int): Long = buf.longBE(off[c])
    fun str(c: Int): String? = if (len[c] < 0) null else buf.decodeToString(off[c], off[c] + len[c])
    fun bytes(c: Int): ByteArray? = if (len[c] < 0) null else buf.copyOfRange(off[c], off[c] + len[c])

    companion object {
        const val MAX_COLS = 32
        private val EMPTY = ByteArray(0)
    }
}

/**
 * The outcome of one statement execution for one request: its rows (in order), the CommandComplete tag's row count,
 * or an error. Same validity rule as [Row].
 */
class Result {
    @JvmField var error: PgError? = null
    /** Rows affected/returned, from the CommandComplete tag ("INSERT 0 1" -> 1, "DELETE 3" -> 3, "SELECT 5" -> 5). */
    @JvmField var affected: Long = 0
    @JvmField var buf: ByteArray = ByteArray(0)
    /** Start offsets (in [buf]) of each DataRow body. */
    @JvmField var rowStarts: IntArray = IntArray(8)
    @JvmField var rowCount: Int = 0
    private val view = Row()

    val ok: Boolean get() = error == null

    /** Parses row [i] into a shared view (the previous view returned by [row] becomes invalid). */
    fun row(i: Int): Row {
        view.parse(buf, rowStarts[i])
        return view
    }

    fun addRow(b: ByteArray, bodyStart: Int) {
        buf = b
        if (rowCount == rowStarts.size) rowStarts = rowStarts.copyOf(rowCount * 2)
        rowStarts[rowCount++] = bodyStart
    }

    fun clear() {
        error = null; affected = 0; rowCount = 0
    }
}

/**
 * Binary parameter encoder for one statement execution: appends Int32 length + value per parameter, in order.
 * The parameter count must match the statement's declared OIDs.
 */
class Params(initial: Int = 256) {
    @JvmField val out = ByteBuf(initial)
    @JvmField var count = 0

    fun int8(v: Long): Params { out.putIntBE(8); out.putLongBE(v); count++; return this }
    fun int4(v: Int): Params { out.putIntBE(4); out.putIntBE(v); count++; return this }
    fun bool(v: Boolean): Params { out.putIntBE(1); out.put(if (v) 1 else 0); count++; return this }
    fun nul(): Params { out.putIntBE(-1); count++; return this }

    /** text (UTF-8); null -> SQL NULL. */
    fun text(s: String?): Params {
        if (s == null) return nul()
        val lenPos = out.len
        out.putIntBE(0)
        out.putUtf8(s)
        out.setIntBE(lenPos, out.len - lenPos - 4)
        count++
        return this
    }

    /** text[] (1-D, lower bound 1, no NULL elements). */
    fun textArray(items: List<String>): Params {
        val lenPos = out.len
        out.putIntBE(0)
        out.putIntBE(1)            // ndim
        out.putIntBE(0)            // has-null flag
        out.putIntBE(Oid.TEXT)     // element type
        out.putIntBE(items.size)   // dimension size
        out.putIntBE(1)            // lower bound
        for (s in items) {
            val p = out.len
            out.putIntBE(0)
            out.putUtf8(s)
            out.setIntBE(p, out.len - p - 4)
        }
        out.setIntBE(lenPos, out.len - lenPos - 4)
        count++
        return this
    }
}
