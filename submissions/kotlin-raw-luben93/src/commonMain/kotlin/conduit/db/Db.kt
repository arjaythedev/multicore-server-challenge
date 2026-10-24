package conduit.db

import conduit.pg.Params
import conduit.pg.Result
import conduit.platform.Monitor
import conduit.util.ByteBuf
import kotlin.concurrent.Volatile

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
    /**
     * A request-independent statement (no parameters, no r.i column; rows start at column 0): every request queued
     * when a connection frees is answered by ONE execution, whose rows are delivered to each of them. Nothing outlives
     * the batch, and every recipient was already waiting when the statement started, so each still reads Postgres
     * while being served (GET /api/tags; the #1 entry does the same).
     */
    val broadcast: Boolean = false,
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
        /**
         * Parses postgres://user:pass@host:port/db (also postgresql://; percent-decoding user, password and database;
         * default port 5432, user "postgres", database = user; a ?query is ignored, IPv6 hosts go in brackets).
         */
        fun fromUrl(url: String, readConns: Int, writeConns: Int, options: String): DbConfig {
            val rest = when {
                url.startsWith("postgres://") -> url.substring("postgres://".length)
                url.startsWith("postgresql://") -> url.substring("postgresql://".length)
                else -> throw IllegalArgumentException("database URL must start with postgres:// or postgresql://")
            }.substringBefore('?').substringBefore('#')
            val slash = rest.indexOf('/')
            val authority = if (slash < 0) rest else rest.substring(0, slash)
            val path = if (slash < 0) "" else rest.substring(slash + 1)
            val at = authority.lastIndexOf('@')
            val userInfo = if (at < 0) "" else authority.substring(0, at)
            val hostPort = if (at < 0) authority else authority.substring(at + 1)
            val colon = userInfo.indexOf(':')
            val user = percentDecode(if (colon < 0) userInfo else userInfo.substring(0, colon)).ifEmpty { "postgres" }
            val password = if (colon < 0) "" else percentDecode(userInfo.substring(colon + 1))
            val host: String
            val portText: String
            if (hostPort.startsWith('[')) {
                val close = hostPort.indexOf(']')
                require(close > 0) { "bad IPv6 host in database URL" }
                host = hostPort.substring(1, close)
                portText = hostPort.substring(close + 1).removePrefix(":")
            } else {
                val c = hostPort.lastIndexOf(':')
                host = if (c < 0) hostPort else hostPort.substring(0, c)
                portText = if (c < 0) "" else hostPort.substring(c + 1)
            }
            val port = if (portText.isEmpty()) 5432 else {
                portText.toIntOrNull()?.takeIf { it in 1..65535 }
                    ?: throw IllegalArgumentException("bad port '$portText' in database URL")
            }
            val database = percentDecode(path.trimEnd('/')).ifEmpty { user }
            return DbConfig(host.ifEmpty { "localhost" }, port, user, password, database, readConns, writeConns, options)
        }

        /** %XX sequences as UTF-8 bytes; anything else (including a malformed %) is kept as is. */
        private fun percentDecode(s: String): String {
            if (s.indexOf('%') < 0) return s
            val out = ByteBuf(s.length)
            var i = 0
            while (i < s.length) {
                if (s[i] == '%' && i + 2 < s.length) {
                    val hi = s[i + 1].digitToIntOrNull(16)
                    val lo = s[i + 2].digitToIntOrNull(16)
                    if (hi != null && lo != null) {
                        out.put((hi shl 4) or lo)
                        i += 3
                        continue
                    }
                }
                var j = s.indexOf('%', i + 1)
                if (j < 0) j = s.length
                out.putUtf8(s.substring(i, j))
                i = j
            }
            return out.buf.decodeToString(0, out.len)
        }
    }
}

/**
 * The database: [DbConfig.readConns] read connections and [DbConfig.writeConns] write connections, each with its own
 * thread that does blocking I/O. Handlers call the suspend functions below from any thread; the coroutine is resumed
 * on the connection thread that completed the work (so JSON is built and the response written there).
 *
 * Contract for implementers: [read] and [write] ALWAYS suspend (they never complete inline), and the continuation
 * is resumed exactly once, with a [Result] whose rows stay valid until the resumed code suspends again or returns.
 *
 * Dispatch (see Worker.kt): a request queued while some connection is idle is encoded and written to that
 * connection by the queueing thread itself (a small blocking write into an idle socket's buffer, never a wait on
 * Postgres); otherwise it waits in its kind's queue until a connection finishes a round trip and takes the batch.
 */
object Db {
    @Volatile
    private var runtime: DbRuntime? = null

    /**
     * Connects every connection, prepares every statement on every connection, starts the threads. Blocks. The first
     * connection is retried for up to 50 s (Postgres may still be starting); bad credentials or SQL fail at once.
     */
    fun start(config: DbConfig, reads: List<ReadKind>, writes: List<WriteStmt>) {
        check(runtime == null) { "Db.start called twice" }
        val rt = DbRuntime(config, reads, writes)
        rt.start()
        runtime = rt
    }

    /**
     * Queues a batched read. [limit], [offset] and [key] fill r.l, r.o and r.k for this request.
     * The rows are this request's rows only, as the statement returns them: column 0 is r.i, the kind's own columns
     * start at 1. A [key] containing NUL (which Postgres text cannot hold) is sent as "" so it matches nothing
     * instead of failing the whole batch.
     * Errors are reported in [Result.error], never thrown; an error fails every request of its batch, and a broken
     * connection reports SQLSTATE 08006. (Only a [kind] that was not passed to [start] throws: a programming error.)
     */
    suspend fun read(kind: ReadKind, viewer: Long, limit: Int = 0, offset: Long = 0, key: String = ""): Result =
        rt().read(kind, viewer, limit, offset, key)

    /**
     * Runs one write statement with group commit: concurrent writes share one transaction (BEGIN ... COMMIT) and
     * every caller is resumed only after COMMIT succeeded. [isolated] writes (those likely to fail, e.g. unique
     * violations on register / user update) run in their own implicit transaction, never in a group.
     * Rows (RETURNING) start at column 0; [Result.affected] is the command tag's count.
     * Errors are reported in [Result.error], never thrown: if any statement of a group fails, the group is rolled
     * back and every job re-runs alone (each its own commit), so each caller gets its own statement's outcome, at
     * the price of one commit per job: writes that are expected to fail belong in [isolated].
     * If COMMIT itself fails, every job of the group gets that error (an uncertain commit is never retried).
     * [params] must not be touched until this returns.
     */
    suspend fun write(stmt: WriteStmt, params: Params, isolated: Boolean = false): Result =
        rt().write(stmt, params, isolated)

    /**
     * Runs one simple query on a short-lived connection and returns its rows as text (startup probes, before
     * [start]); waits for Postgres the way [start] does.
     */
    fun query(config: DbConfig, sql: String): List<List<String?>> {
        val c = connectPatiently(config, emptyList(), Monitor())
        try {
            return c.simpleQuery(sql)
        } finally {
            c.close()
        }
    }

    /** One line of batching / group-commit / connection statistics, for logs. */
    fun stats(): String = runtime?.stats() ?: "db: not started"

    private fun rt(): DbRuntime = runtime ?: throw IllegalStateException("Db.start was not called")
}
