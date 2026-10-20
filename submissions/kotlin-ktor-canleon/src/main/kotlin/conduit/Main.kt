package conduit

import io.ktor.server.application.install
import io.ktor.server.auth.Authentication
import io.ktor.server.engine.connector
import io.ktor.server.engine.embeddedServer
import io.ktor.server.netty.Netty
import io.ktor.server.plugins.bodylimit.RequestBodyLimit
import io.ktor.server.plugins.statuspages.StatusPages
import io.ktor.server.routing.routing
import io.vertx.core.Vertx
import io.vertx.core.VertxOptions
import conduit.application.ArticleService
import conduit.application.CommentService
import conduit.application.ProfileService
import conduit.application.TagService
import conduit.application.UserService
import conduit.infrastructure.postgres.connectOptions
import conduit.infrastructure.postgres.createPipelinedClient
import conduit.infrastructure.postgres.PostgresArticleRepository
import conduit.infrastructure.postgres.PostgresCommentRepository
import conduit.infrastructure.postgres.PostgresProfileRepository
import conduit.infrastructure.postgres.PostgresTagRepository
import conduit.infrastructure.postgres.PostgresUserRepository
import conduit.infrastructure.security.BcryptPasswordHasher
import conduit.infrastructure.security.JwtTokens
import conduit.infrastructure.web.articleRoutes
import conduit.infrastructure.web.commentRoutes
import conduit.infrastructure.web.MAX_BODY_BYTES
import conduit.infrastructure.web.errorResponses
import conduit.infrastructure.web.tokenAuth
import conduit.infrastructure.web.profileRoutes
import conduit.infrastructure.web.userRoutes

/** Postgres allows 100 connections (SPEC.md); stay well below. */
private const val MAX_CONNECTIONS = 90

// Composition root: builds infrastructure -> application -> domain and starts the server.
fun main() {
    val environment = System.getenv()
    val cores = Runtime.getRuntime().availableProcessors()
    // Pipelining: one connection serves many requests at once, so two connections per core are enough (16 on the box).
    val requestedConnections = optional(environment, "DB_POOL_SIZE")?.toInt() ?: (2 * cores)
    val connections = requestedConnections.coerceIn(1, MAX_CONNECTIONS)
    // Vert.x runs the database connections on its own event loops (native epoll when available).
    val vertx = Vertx.vertx(VertxOptions().setPreferNativeTransport(true).setEventLoopPoolSize(cores))
    val databaseOptions = connectOptions(environment.getValue("DATABASE_URL"))
    val client = createPipelinedClient(vertx, databaseOptions, connections)
    val jwtTokens = JwtTokens(environment.getValue("JWT_SECRET"))

    val userService = UserService(PostgresUserRepository(client), BcryptPasswordHasher(threads = maxOf(1, cores / 2)), jwtTokens)
    val profileService = ProfileService(PostgresProfileRepository(client))
    val articleService = ArticleService(PostgresArticleRepository(client))
    val commentService = CommentService(PostgresCommentRepository(client))
    val tagService = TagService(PostgresTagRepository(client))

    embeddedServer(
        Netty,
        configure = {
            connector {
                port = optional(environment, "PORT")?.toInt() ?: 3000
                host = optional(environment, "HOST") ?: "127.0.0.1"
            }
            // Nothing blocks a request thread (database calls suspend, bcrypt has its own threads), so Ktor's default
            // thread counts are enough.
        },
    ) {
        install(StatusPages) { errorResponses() }
        install(RequestBodyLimit) { bodyLimit { MAX_BODY_BYTES } }
        install(Authentication) { tokenAuth(jwtTokens.verifier) }
        routing {
            userRoutes(userService)
            profileRoutes(profileService)
            articleRoutes(articleService, tagService)
            commentRoutes(commentService)
        }
    }.start(wait = true)
}

/** An optional setting: unset and empty both mean "use the default" (like `${NAME:-default}` in a shell script). */
private fun optional(environment: Map<String, String>, name: String): String? {
    val value = environment[name]
    return if (value.isNullOrBlank()) null else value
}
