package conduit.infrastructure.postgres

import conduit.domain.shared.ValidationException
import io.vertx.core.Vertx
import io.vertx.kotlin.coroutines.coAwait
import io.vertx.pgclient.PgBuilder
import io.vertx.pgclient.PgConnectOptions
import io.vertx.pgclient.PgException
import io.vertx.sqlclient.PoolOptions
import io.vertx.sqlclient.Row
import io.vertx.sqlclient.RowSet
import io.vertx.sqlclient.SqlClient
import io.vertx.sqlclient.Tuple
import java.net.URI
import java.net.URLDecoder
import java.util.concurrent.ConcurrentHashMap

/**
 * Connection settings from a libpq-style DATABASE_URL (postgres://user:password@host:port/database).
 *
 * Settings for every connection (sent when it opens):
 * - plan_cache_mode=force_generic_plan: a statement is planned once per connection, not on every execution;
 * - jit=off, max_parallel_workers_per_gather=0: no JIT and no parallel workers for these short queries.
 * Prepared statements are cached per connection. No TLS (the client's default): the database runs on the same machine.
 */
fun connectOptions(databaseUrl: String): PgConnectOptions {
    val uri = URI.create(databaseUrl)
    val credentials = (uri.rawUserInfo ?: "").split(":", limit = 2).map { part -> URLDecoder.decode(part, Charsets.UTF_8) }
    return PgConnectOptions()
        .setHost(uri.host ?: "localhost")
        .setPort(if (uri.port == -1) 5432 else uri.port)
        .setDatabase(uri.rawPath.removePrefix("/"))
        .setUser(credentials.getOrNull(0))
        .setPassword(credentials.getOrNull(1))
        .setCachePreparedStatements(true)
        .addProperty("plan_cache_mode", "force_generic_plan")
        .addProperty("jit", "off")
        .addProperty("max_parallel_workers_per_gather", "0")
}

/**
 * The client for single statements. It doesn't block a thread while Postgres works, and it pipelines: it sends the
 * next statement over a connection without waiting for the previous result, spreading statements over [connections]
 * connections. So a few connections serve all requests, which means fewer Postgres processes competing for the cores.
 * Every write is a single statement (Postgres runs each one atomically), so no request needs a connection to itself.
 */
fun createPipelinedClient(vertx: Vertx, options: PgConnectOptions, connections: Int): SqlClient {
    return PgBuilder.client()
        .with(PoolOptions().setMaxSize(connections))
        .connectingTo(options)
        .using(vertx)
        .build()
}

// Our SQL is written with `?` placeholders (see Queries.kt); the Postgres protocol numbers them ($1, $2, ...).
// Each statement text is converted once and then reused.
private val numberedStatements = ConcurrentHashMap<String, String>()

private fun numberPlaceholders(sql: String): String {
    val numbered = StringBuilder(sql.length + 16)
    var next = 1
    for (character in sql) {
        if (character == '?') {
            numbered.append('$').append(next++)
        } else {
            numbered.append(character)
        }
    }
    return numbered.toString()
}

/** Runs one statement; suspends (doesn't block) until Postgres answers. */
suspend fun SqlClient.execute(sql: String, arguments: Tuple): RowSet<Row> {
    return preparedQuery(numberedStatements.computeIfAbsent(sql, ::numberPlaceholders)).execute(arguments).coAwait()
}

/** A unique violation (SQLSTATE 23505) is the domain's "already taken"; anything else is rethrown. */
suspend fun <T> translateUniqueViolation(block: suspend () -> T): T {
    try {
        return block()
    } catch (exception: PgException) {
        if (exception.sqlState == "23505") throw ValidationException("username or email has already been taken")
        throw exception
    }
}
