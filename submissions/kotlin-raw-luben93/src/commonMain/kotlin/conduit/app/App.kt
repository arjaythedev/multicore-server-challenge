package conduit.app

import conduit.db.ReadKind
import conduit.db.WriteStmt
import conduit.http.Exchange

/** The Conduit API: routing, auth, validation, SQL and JSON for all 19 endpoints. */
object App {
    /**
     * Startup settings, before [reads] is first used. [collation] is the database's (provider, datcollate,
     * datlocale) from [COLLATION_PROBE]; with a byte-order collation the app sorts tag lists itself, unless
     * [appSortsTags] is false.
     */
    fun configure(collation: List<String?>?, appSortsTags: Boolean = true) {
        TagOrder.appSorts = appSortsTags && collation != null &&
            TagOrder.isByteOrder(collation[0] ?: "", collation[1] ?: "", collation[2] ?: "")
    }

    /** Who sorts tag lists (for the startup log line). */
    val tagOrder: String get() = if (TagOrder.appSorts) "app" else "sql"

    const val COLLATION_PROBE = TagOrder.PROBE

    /** Every batched read statement, prepared on every connection at startup. */
    val reads: List<ReadKind> get() = Sql.reads

    /** Every write statement, prepared on every connection at startup. */
    val writes: List<WriteStmt> get() = Sql.writes

    /** Handles one request; must answer it exactly once (see [Exchange]). */
    suspend fun handle(ex: Exchange) {
        val m = Router.match(ex.method, ex.path)
        when (m.route) {
            // No auth at all: tags ignores the header entirely, register/login don't use it.
            Route.TAGS -> return Handlers.tags(ex)
            Route.REGISTER -> return Handlers.register(ex)
            Route.LOGIN -> return Handlers.login(ex)
            Route.NOT_FOUND -> return ex.sendError(404, "not found")
        }
        val auth = Auth.check(ex, keepToken = m.route == Route.USER_GET || m.route == Route.USER_PUT)
        when (m.route) {
            // Auth optional: no header = anonymous (viewer 0), a present but invalid one = 401.
            Route.PROFILE, Route.LIST, Route.ARTICLE_GET, Route.COMMENTS_GET ->
                if (auth == Auth.INVALID) return ex.sendError(401, "unauthorized")
            // Auth required.
            else -> if (auth != Auth.VALID) return ex.sendError(401, "unauthorized")
        }
        when (m.route) {
            Route.USER_GET -> Handlers.currentUser(ex)
            Route.USER_PUT -> Handlers.updateUser(ex)
            Route.PROFILE -> Handlers.profile(ex, m.key)
            Route.FOLLOW -> Handlers.follow(ex, m.key, follow = true)
            Route.UNFOLLOW -> Handlers.follow(ex, m.key, follow = false)
            Route.LIST -> Handlers.list(ex, feed = false)
            Route.FEED -> Handlers.list(ex, feed = true)
            Route.ARTICLE_CREATE -> Handlers.createArticle(ex)
            Route.ARTICLE_GET -> Handlers.article(ex, m.key)
            Route.ARTICLE_PUT -> Handlers.updateArticle(ex, m.key)
            Route.ARTICLE_DELETE -> Handlers.deleteArticle(ex, m.key)
            Route.FAVORITE -> Handlers.favorite(ex, m.key, favorite = true)
            Route.UNFAVORITE -> Handlers.favorite(ex, m.key, favorite = false)
            Route.COMMENTS_GET -> Handlers.comments(ex, m.key)
            Route.COMMENT_CREATE -> Handlers.createComment(ex, m.key)
            Route.COMMENT_DELETE -> Handlers.deleteComment(ex, m.key, m.id)
            else -> ex.sendError(404, "not found")
        }
    }
}
