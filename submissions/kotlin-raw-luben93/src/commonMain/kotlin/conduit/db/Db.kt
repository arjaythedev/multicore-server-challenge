package conduit.db

import conduit.pg.Params
import conduit.pg.Result

/**
 * A batched read statement. Every read endpoint is one ReadKind; requests of the same kind that queue up while the
 * read connections are busy are sent together as ONE execution of [sql].
 *
 * [sql] is the complete batched statement. It always takes the same five array parameters, one element per request:
 *
 *   $1 int4[] i   request index 0..n-1 (the first result column MUST be r.i, used to route rows back)
 *   $2 int8[] v   viewer user id (0 = anonymous)
 *   $3 int4[] l   limit
 *   $4 int8[] o   offset, or an id for by-id kinds
 *   $5 text[] k   key: slug / username / tag / email ("" when unused)
 *
 * and starts like:
 *   SELECT r.i, x.* FROM unnest($1::int4[], $2::int8[], $3::int4[], $4::int8[], $5::text[]) AS r(i, v, l, o, k)
 *   CROSS JOIN LATERAL (<per-request query using r.v, r.l, r.o, r.k>) x
 *
 * Each request's rows come back in the order the per-request query produces them. Subqueries that don't reference
 * a request column must be tied to the request row (e.g. `WHERE r.i >= 0`) so they run once per request, never once
 * per statement (rule 5: nothing is shared between requests).
 */
class ReadKind(
    val name: String,
    val sql: String,
    /** Most requests sent in one execution. */
    val maxBatch: Int = 64,
    /** Most read connections this kind may occupy at once (0 = no limit beyond the pool). */
    val maxInflight: Int = 0,
) {
    /** Assigned by [Db.start]: index into the kind table. */
    var id: Int = -1
}

/** A single-statement write (or a write-adjacent read that must run on a write connection). */
class WriteStmt(
    val name: String,
    val sql: String,
    /** Parse parameter type OIDs, see [conduit.pg.Oid]. */
    val paramOids: IntArray,
) {
    var id: Int = -1
}

class DbConfig(
    val host: String,
    val port: Int,
    val user: String,
    val password: String,
    val database: String,
    val readConns: Int,
    val writeConns: Int,
    /** Startup `options`, e.g. "-c plan_cache_mode=force_generic_plan -c jit=off". */
    val options: String,
) {
    companion object {
        /** Parses postgres://user:pass@host:port/db (percent-decoding user and password). */
        fun fromUrl(url: String, readConns: Int, writeConns: Int, options: String): DbConfig = TODO("db: DbConfig.fromUrl")
    }
}

/**
 * The database: [DbConfig.readConns] read connections and [DbConfig.writeConns] write connections, each with its own
 * thread that does blocking I/O. Handlers call the suspend functions below from any thread; the coroutine is resumed
 * on the connection thread that completed the work (so JSON is built and the response written there).
 *
 * Contract for implementers: [read] and [write] ALWAYS suspend (they never complete inline), and the continuation
 * is resumed exactly once, with a [Result] whose rows stay valid until the resumed code suspends again or returns.
 */
object Db {
    /** Connects every connection, prepares every statement on every connection, starts the threads. Blocks. */
    fun start(config: DbConfig, reads: List<ReadKind>, writes: List<WriteStmt>): Unit = TODO("db: Db.start")

    /**
     * Queues a batched read. [limit], [offset] and [key] fill r.l, r.o and r.k for this request.
     * Errors are reported in [Result.error], never thrown.
     */
    suspend fun read(kind: ReadKind, viewer: Long, limit: Int = 0, offset: Long = 0, key: String = ""): Result =
        TODO("db: Db.read")

    /**
     * Runs one write statement with group commit: concurrent writes share one transaction (BEGIN ... COMMIT) and
     * every caller is resumed only after COMMIT succeeded. [isolated] writes (those likely to fail, e.g. unique
     * violations on register / user update) run in their own implicit transaction, never in a group.
     * Errors are reported in [Result.error], never thrown.
     */
    suspend fun write(stmt: WriteStmt, params: Params, isolated: Boolean = false): Result = TODO("db: Db.write")
}
