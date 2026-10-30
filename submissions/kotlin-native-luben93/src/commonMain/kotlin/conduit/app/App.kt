package conduit.app

import conduit.auth.Passwords
import conduit.db.Db
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
    fun configure(
        collation: List<String?>?,
        appSortsTags: Boolean = true,
        shareReads: Boolean = false,
        shareMaxBatch: Int = ReadShare.maxBatch,
        viewerFlags: Boolean = false,
        feedMaxBatch: Int = 0,
        feedHeavy: Boolean = false,
        feedFloor: Boolean = false,
    ) {
        TagOrder.appSorts = appSortsTags && collation != null &&
            TagOrder.isByteOrder(collation[0] ?: "", collation[1] ?: "", collation[2] ?: "")
        ReadShare.on = shareReads
        ReadShare.maxBatch = shareMaxBatch
        ReadShare.viewerFlags = viewerFlags
        ReadShare.feedMaxBatch = feedMaxBatch
        ReadShare.feedHeavy = feedHeavy
        ReadShare.feedFloor = feedFloor
    }

    /** Who sorts tag lists (for the startup log line). */
    val tagOrder: String get() = if (TagOrder.appSorts) "app" else "sql"

    /** How batched reads work (for the startup log line), see [ReadShare]. */
    val readMode: String
        get() = if (!ReadShare.on) "per request" else "shared, up to ${ReadShare.maxBatch} per batch" +
            if (ReadShare.viewerFlags) ", flags per viewer" else ""

    const val COLLATION_PROBE = TagOrder.PROBE

    /** Every batched read statement, prepared on every connection at startup. */
    val reads: List<ReadKind> get() = Sql.reads

    /** Every write statement, prepared on every connection at startup. */
    val writes: List<WriteStmt> get() = Sql.writes

    /**
     * The queue this route's handler waits in is full (caps: [conduit.db.DbConfig.readQueueMax] and its siblings, set
     * in Main). Answered inline, before anything is queued: the work already queued is bounded this way.
     */
    private fun busy(route: Int): Boolean = when (route) {
        Route.NOT_FOUND -> false
        Route.REGISTER, Route.LOGIN -> Passwords.saturated
        Route.USER_PUT, Route.FOLLOW, Route.UNFOLLOW, Route.ARTICLE_CREATE, Route.ARTICLE_PUT, Route.ARTICLE_DELETE,
        Route.FAVORITE, Route.UNFAVORITE, Route.COMMENT_CREATE, Route.COMMENT_DELETE -> Db.writesSaturated
        else -> Db.readsSaturated
    }

    /** Handles one request; must answer it exactly once (see [Exchange]). */
    suspend fun handle(ex: Exchange) {
        val m = Router.match(ex.method, ex.path)
        // 503 on a kept-alive connection: closing it would only make the client redial, at the worst moment
        if (busy(m.route)) return ex.sendError(503, "server busy")
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
