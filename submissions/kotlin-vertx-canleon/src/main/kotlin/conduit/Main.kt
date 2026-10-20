package conduit

import io.vertx.core.DeploymentOptions
import io.vertx.core.Vertx
import io.vertx.core.VertxOptions
import conduit.infrastructure.postgres.connectOptions
import conduit.infrastructure.security.BcryptPasswordHasher
import conduit.infrastructure.security.JwtTokens
import java.util.function.Supplier
import kotlin.system.exitProcess

/** Postgres allows 100 connections (SPEC.md); stay well below. */
private const val MAX_CONNECTIONS = 90

// Composition root: builds the shared pieces, then one ServerVerticle per core (each wires its own repositories,
// services and routes).
fun main() {
    val environment = System.getenv()
    val cores = Runtime.getRuntime().availableProcessors()
    // Pipelining: one connection serves many requests at once, so two connections per core are enough (16 on the box).
    // Each server needs at least one, so on a machine with more cores than MAX_CONNECTIONS some event loops get none.
    val requestedConnections = optional(environment, "DB_POOL_SIZE")?.toInt() ?: (2 * cores)
    val totalConnections = requestedConnections.coerceIn(1, MAX_CONNECTIONS)
    val servers = minOf(cores, totalConnections)
    val connectionsPerServer = totalConnections / servers
    val databaseOptions = connectOptions(environment.getValue("DATABASE_URL"))
    val passwordHasher = BcryptPasswordHasher(threads = maxOf(1, cores / 2))
    val jwtTokens = JwtTokens(environment.getValue("JWT_SECRET"))
    val host = optional(environment, "HOST") ?: "127.0.0.1"
    val port = optional(environment, "PORT")?.toInt() ?: 3000

    // one event loop per core, native epoll when available
    val vertx = Vertx.vertx(VertxOptions().setPreferNativeTransport(true).setEventLoopPoolSize(cores))
    val server = Supplier { ServerVerticle(host, port, databaseOptions, connectionsPerServer, passwordHasher, jwtTokens) }
    try {
        vertx.deployVerticle(server, DeploymentOptions().setInstances(servers)).toCompletionStage().toCompletableFuture().get()
    } catch (exception: Exception) {
        System.err.println("could not start: ${exception.cause ?: exception}")
        exitProcess(1)
    }
}

/** An optional setting: unset and empty both mean "use the default" (like `${NAME:-default}` in a shell script). */
private fun optional(environment: Map<String, String>, name: String): String? {
    val value = environment[name]
    return if (value.isNullOrBlank()) null else value
}
