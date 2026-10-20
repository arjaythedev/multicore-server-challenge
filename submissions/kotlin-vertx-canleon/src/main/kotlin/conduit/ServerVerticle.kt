package conduit

import io.vertx.core.http.HttpServerOptions
import io.vertx.ext.web.Router
import io.vertx.kotlin.coroutines.CoroutineRouterSupport
import io.vertx.kotlin.coroutines.CoroutineVerticle
import io.vertx.kotlin.coroutines.coAwait
import io.vertx.pgclient.PgConnectOptions
import conduit.application.ArticleService
import conduit.application.CommentService
import conduit.application.ProfileService
import conduit.application.TagService
import conduit.application.UserService
import conduit.infrastructure.postgres.createPipelinedClient
import conduit.infrastructure.postgres.PostgresArticleRepository
import conduit.infrastructure.postgres.PostgresCommentRepository
import conduit.infrastructure.postgres.PostgresProfileRepository
import conduit.infrastructure.postgres.PostgresTagRepository
import conduit.infrastructure.postgres.PostgresUserRepository
import conduit.infrastructure.security.BcryptPasswordHasher
import conduit.infrastructure.security.JwtTokens
import conduit.infrastructure.web.TokenAuthentication
import conduit.infrastructure.web.articleRoutes
import conduit.infrastructure.web.commentRoutes
import conduit.infrastructure.web.errorResponses
import conduit.infrastructure.web.profileRoutes
import conduit.infrastructure.web.userRoutes

/**
 * One HTTP server with its own database client, on one event loop. Main deploys one per core; Vert.x spreads the
 * incoming connections over them. A request is read, handled, sent to Postgres and answered on the same thread
 * (only bcrypt runs elsewhere).
 */
class ServerVerticle(
    private val host: String,
    private val port: Int,
    private val databaseOptions: PgConnectOptions,
    private val connections: Int,
    private val passwordHasher: BcryptPasswordHasher,
    private val jwtTokens: JwtTokens,
) : CoroutineVerticle(), CoroutineRouterSupport {

    override suspend fun start() {
        // created here, so its connections belong to this verticle's event loop
        val client = createPipelinedClient(vertx, databaseOptions, connections)
        val userService = UserService(PostgresUserRepository(client), passwordHasher, jwtTokens)
        val profileService = ProfileService(PostgresProfileRepository(client))
        val articleService = ArticleService(PostgresArticleRepository(client))
        val commentService = CommentService(PostgresCommentRepository(client))
        val tagService = TagService(PostgresTagRepository(client))
        val authentication = TokenAuthentication(jwtTokens.verifier)

        val router = Router.router(vertx)
        router.errorResponses()
        userRoutes(router, authentication, userService)
        profileRoutes(router, authentication, profileService)
        articleRoutes(router, authentication, articleService, tagService)
        commentRoutes(router, authentication, commentService)

        vertx.createHttpServer(HttpServerOptions().setHost(host).setPort(port))
            .requestHandler(router)
            .listen()
            .coAwait()
    }
}
