package conduit.db

import conduit.pg.PgConn
import conduit.pg.PgException
import conduit.pg.PgIoException
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import kotlin.coroutines.Continuation
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.startCoroutine

/**
 * Integration-test fixture: one database copied from the dev seed (conduit_dev) for the whole test JVM, dropped at
 * exit. Admin work goes through our own client as the superuser (trust on 127.0.0.1 in the lab); the runtimes
 * under test log in as the server role `conduit` (SCRAM), as in CI.
 */
internal object TestPg {
    val host: String = System.getenv("PGHOST")?.takeIf { it.isNotEmpty() && !it.startsWith("/") } ?: "127.0.0.1"
    val port: Int = System.getenv("PGPORT")?.toIntOrNull() ?: 5432
    private val template = System.getenv("DB_TEST_TEMPLATE") ?: "conduit_dev"

    const val OPTIONS =
        "-c plan_cache_mode=force_generic_plan -c jit=off -c max_parallel_workers_per_gather=0 -c enable_memoize=off"

    /** The batched-read prefix every ReadKind statement starts with. */
    const val UNNEST = "SELECT r.i, x.* FROM unnest(\$1::int4[], \$2::int8[], \$3::int4[], \$4::int8[], \$5::text[]) " +
        "AS r(i, v, l, o, k) CROSS JOIN LATERAL "

    /** The shared test database, or null when no Postgres is reachable (the tests then pass vacuously, loudly). */
    val db: String? by lazy { create() }

    fun admin(database: String = "postgres"): PgConn =
        PgConn.connect(host, port, "postgres", System.getenv("PGPASSWORD") ?: "", database, "", "conduit-test")

    fun <T> adminQuery(database: String, sql: String, f: (List<List<String?>>) -> T): T {
        val c = admin(database)
        try {
            return f(c.simpleQuery(sql))
        } finally {
            c.close()
        }
    }

    private fun create(): String? {
        val c = try {
            admin()
        } catch (e: PgIoException) {
            println("SKIPPING database integration tests: no Postgres at $host:$port (${e.message})")
            return null
        }
        val name = "dbtest_" + (1..8).map { "0123456789abcdef".random() }.joinToString("")
        try {
            var attempt = 0
            while (true) {
                try {
                    c.simpleQuery("CREATE DATABASE $name TEMPLATE $template STRATEGY FILE_COPY")
                    break
                } catch (e: PgException) {
                    // 55006: someone else is copying / connected to the template right now
                    if (e.error.code != "55006" || ++attempt > 50) throw e
                    Thread.sleep(200)
                }
            }
        } finally {
            c.close()
        }
        Runtime.getRuntime().addShutdownHook(Thread { drop(name) })
        return name
    }

    private fun drop(name: String) {
        try {
            adminQuery("postgres", "DROP DATABASE IF EXISTS $name WITH (FORCE)") {}
        } catch (e: Throwable) {
            System.err.println("could not drop test database $name: $e")
        }
    }

    fun config(database: String, reads: Int, writes: Int): DbConfig =
        DbConfig.fromUrl("postgres://conduit:conduit@$host:$port/$database", reads, writes, OPTIONS)

    /** Starts [block] as a coroutine on the calling thread; [done] gets its failure (or null). */
    fun launch(block: suspend () -> Unit, done: (Throwable?) -> Unit) {
        block.startCoroutine(Continuation(EmptyCoroutineContext) { done(it.exceptionOrNull()) })
    }

    /** Runs [block] as a coroutine and waits for its value. Results must be inspected inside [block]. */
    fun <T> await(seconds: Long = 30, block: suspend () -> T): T {
        val f = CompletableFuture<T>()
        block.startCoroutine(Continuation(EmptyCoroutineContext) { r ->
            r.fold({ f.complete(it) }, { f.completeExceptionally(it) })
        })
        return f.get(seconds, TimeUnit.SECONDS)
    }
}
