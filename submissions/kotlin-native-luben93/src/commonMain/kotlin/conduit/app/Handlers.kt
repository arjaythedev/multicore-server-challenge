package conduit.app

import conduit.auth.Jwt
import conduit.auth.Passwords
import conduit.db.Db
import conduit.http.Exchange
import conduit.json.JsonReader
import conduit.pg.Params
import conduit.pg.Result
import conduit.platform.currentTimeMillis

// Endpoint handlers. Check order follows the reference: auth (401) -> body (422) -> lookup (404) -> ownership (403).
// Rows are rendered before the next suspension (Result/Row validity); anything needed later is copied first.

internal object Auth {
    const val NONE = 0
    const val VALID = 1
    const val INVALID = -1

    /** The token of a "Token <jwt>" header (the only scheme accepted, exact case), or null. */
    fun tokenOf(header: String): String? = if (header.startsWith("Token ")) header.substring(6) else null

    /** Verifies the Authorization header (every request that uses it: no caching) and sets ex.viewer / ex.token. */
    fun check(ex: Exchange): Int {
        ex.viewer = 0
        ex.token = null
        val h = ex.authorization
        if (h.isNullOrEmpty()) return NONE
        val token = tokenOf(h) ?: return INVALID
        val id = Jwt.verify(token, nowSec())
        if (id <= 0) return INVALID
        ex.viewer = id
        ex.token = token
        return VALID
    }
}

internal fun nowSec(): Long = currentTimeMillis() / 1000

private fun unauthorized(ex: Exchange) = ex.sendError(401, "unauthorized")
private fun notFound(ex: Exchange, what: String) = ex.sendError(404, "$what not found")
private fun invalid(ex: Exchange, what: String) = ex.sendError(422, what)

/** Maps a failed statement: 23505 unique violation -> 422, 23503 FK violation (a row vanished) -> 404, else 500. */
private fun failed(ex: Exchange, res: Result) {
    val e = res.error
    when (e?.code) {
        "23505" -> ex.sendError(422, "username or email is already taken")
        "23503" -> ex.sendError(404, "not found")
        else -> {
            println("conduit: database error: $e")
            ex.sendError(500, "internal error")
        }
    }
}

internal object Handlers {
    suspend fun tags(ex: Exchange) {
        val res = Db.read(Sql.TAGS, 0)
        if (!res.ok) return failed(ex, res)
        val j = ex.json
        j.beginObject()
        j.name(N_TAGS)
        if (res.rowCount > 0) j.textArray(res.row(0), 1) else { j.beginArray(); j.endArray() }
        j.endObject()
        ex.send(200)
    }

    suspend fun register(ex: Exchange) {
        val b = Bodies.register(JsonReader.parse(ex.body)) ?: return invalid(ex, "username, email and password are required")
        val hash = Passwords.hash(b.password)
        val res = Db.write(Sql.USER_INSERT, Params().text(b.username).text(b.email).text(hash), isolated = true)
        if (!res.ok) return failed(ex, res)
        if (res.rowCount == 0) return invalid(ex, "username or email is already taken")
        val r = res.row(0)
        val token = Jwt.sign(r.int8(0), nowSec())
        ex.json.user(r.str(1), token, r.str(2), r.str(3), r.str(4))
        ex.send(201)
    }

    suspend fun login(ex: Exchange) {
        val b = Bodies.login(JsonReader.parse(ex.body)) ?: return invalid(ex, "email and password are required")
        // No stored email holds a NUL, and Postgres text can't carry one (it would fail the whole batch).
        if (Bodies.hasNul(b.email)) return ex.sendError(401, "invalid email or password")
        val res = Db.read(Sql.USER_BY_EMAIL, 0, key = b.email)
        if (!res.ok) return failed(ex, res)
        if (res.rowCount == 0) return ex.sendError(401, "invalid email or password")
        val r = res.row(0)
        val id = r.int8(1)
        val email = r.str(2)
        val username = r.str(3)
        val bio = r.str(4)
        val image = r.str(5)
        val hash = r.str(6) ?: ""
        // bcrypt only looks at 72 bytes; a longer password never matches (as Go's bcrypt reports).
        if (Bodies.utf8Length(b.password) > Bodies.MAX_PASSWORD_BYTES || !Passwords.verify(b.password, hash)) {
            return ex.sendError(401, "invalid email or password")
        }
        ex.json.user(email, Jwt.sign(id, nowSec()), username, bio, image)
        ex.send(200)
    }

    suspend fun currentUser(ex: Exchange) {
        val res = Db.read(Sql.USER_BY_ID, ex.viewer)
        if (!res.ok) return failed(ex, res)
        if (res.rowCount == 0) return unauthorized(ex)
        ex.json.user(res.row(0), 1, ex.token)
        ex.send(200)
    }

    suspend fun updateUser(ex: Exchange) {
        val b = Bodies.updateUser(JsonReader.parse(ex.body)) ?: return invalid(ex, "invalid user fields")
        val hash = if (b.password != null) Passwords.hash(b.password) else null
        val p = Params().int8(ex.viewer).text(b.email).text(b.username).text(hash).text(b.bio).text(b.image)
        val res = Db.write(Sql.USER_UPDATE, p, isolated = true)
        if (!res.ok) return failed(ex, res)
        if (res.rowCount == 0) return unauthorized(ex)
        ex.json.user(res.row(0), 0, ex.token)
        ex.send(200)
    }

    suspend fun profile(ex: Exchange, username: String) {
        val res = Db.read(Sql.PROFILE, ex.viewer, key = username)
        if (!res.ok) return failed(ex, res)
        if (res.rowCount == 0) return notFound(ex, "profile")
        val r = res.row(0)
        val j = ex.json
        j.beginObject()
        j.name(N_PROFILE); j.profile(r, 1, r.bool(4))
        j.endObject()
        ex.send(200)
    }

    suspend fun follow(ex: Exchange, username: String, follow: Boolean) {
        val res = Db.write(if (follow) Sql.FOLLOW else Sql.UNFOLLOW, Params().int8(ex.viewer).text(username))
        if (!res.ok) return failed(ex, res)
        if (res.rowCount == 0) return notFound(ex, "profile")
        val j = ex.json
        j.beginObject()
        j.name(N_PROFILE); j.profile(res.row(0), 0, follow)
        j.endObject()
        ex.send(200)
    }

    suspend fun list(ex: Exchange, feed: Boolean) {
        val q = ListQuery.parse(ex.query, filters = !feed) ?: return invalid(ex, "limit must be 1-100 and offset >= 0")
        if (q.key == Url.INVALID) { // no tag or user name can hold these bytes (and they would fail the batch)
            val j = ex.json
            j.beginObject()
            j.name(N_ARTICLES); j.beginArray(); j.endArray()
            j.name(N_ARTICLES_COUNT); j.number(0)
            j.endObject()
            return ex.send(200)
        }
        val kind = when {
            feed -> Sql.FEED
            q.filter == Filter.TAG -> Sql.LIST_TAG
            q.filter == Filter.AUTHOR -> Sql.LIST_AUTHOR
            q.filter == Filter.FAVORITED -> Sql.LIST_FAVORITED
            q.offset >= Sql.DEEP_OFFSET -> Sql.LIST_ALL_DEEP
            else -> Sql.LIST_ALL
        }
        val res = Db.read(kind, ex.viewer, q.limit, q.offset, q.key)
        if (!res.ok) return failed(ex, res)
        val j = ex.json
        j.beginObject()
        j.name(N_ARTICLES)
        j.beginArray()
        var count = 0L
        for (i in 0 until res.rowCount) {
            val r = res.row(i)
            if (i == 0) count = r.int8(Cols.LIST_COUNT)
            if (!r.isNull(Cols.LIST)) j.article(r, Cols.LIST, withBody = false)
        }
        j.endArray()
        j.name(N_ARTICLES_COUNT); j.number(count)
        j.endObject()
        ex.send(200)
    }

    suspend fun article(ex: Exchange, slug: String) {
        val res = Db.read(Sql.ARTICLE_BY_SLUG, ex.viewer, key = slug)
        if (!res.ok) return failed(ex, res)
        if (res.rowCount == 0) return notFound(ex, "article")
        ex.json.articleEnvelope(res.row(0), Cols.ARTICLE)
        ex.send(200)
    }

    /** After a committed write: the article by id, as the viewer sees it now. */
    private suspend fun readBack(ex: Exchange, id: Long) {
        val res = Db.read(Sql.ARTICLE_BY_ID, ex.viewer, offset = id)
        if (!res.ok) return failed(ex, res)
        if (res.rowCount == 0) return notFound(ex, "article") // deleted meanwhile
        ex.json.articleEnvelope(res.row(0), Cols.ARTICLE)
        ex.send(200)
    }

    suspend fun createArticle(ex: Exchange) {
        val b = Bodies.article(JsonReader.parse(ex.body))
            ?: return invalid(ex, "title, description and body are required; tagList must be non-empty strings")
        val p = Params().int8(ex.viewer).text(slugify(b.title) + "-").text(b.title).text(b.description).text(b.body)
            .textArray(b.tags)
        val res = Db.write(Sql.ARTICLE_CREATE, p)
        if (!res.ok) return failed(ex, res)
        if (res.rowCount == 0) return unauthorized(ex)
        ex.json.articleEnvelope(res.row(0), Cols.CREATED)
        ex.send(201)
    }

    suspend fun updateArticle(ex: Exchange, slug: String) {
        val b = Bodies.articleUpdate(JsonReader.parse(ex.body))
            ?: return invalid(ex, "title, description and body must be non-empty strings")
        val viewer = ex.viewer
        val p = Params().int8(viewer).text(slug).text(b.title).text(b.description).text(b.body)
            .text(if (b.title != null) slugify(b.title) + "-" else null)
        val res = Db.write(Sql.ARTICLE_UPDATE, p)
        if (!res.ok) return failed(ex, res)
        if (res.rowCount == 0) return notFound(ex, "article")
        val r = res.row(0)
        if (r.int8(1) != viewer) return ex.sendError(403, "not the author")
        readBack(ex, r.int8(0))
    }

    suspend fun deleteArticle(ex: Exchange, slug: String) {
        val res = Db.write(Sql.ARTICLE_DELETE, Params().int8(ex.viewer).text(slug))
        if (!res.ok) return failed(ex, res)
        if (res.rowCount == 0) return notFound(ex, "article")
        if (res.row(0).int8(0) != ex.viewer) return ex.sendError(403, "not the author")
        ex.sendEmpty(204)
    }

    suspend fun favorite(ex: Exchange, slug: String, favorite: Boolean) {
        val res = Db.write(if (favorite) Sql.FAVORITE else Sql.UNFAVORITE, Params().int8(ex.viewer).text(slug))
        if (!res.ok) return failed(ex, res)
        if (res.rowCount == 0) return notFound(ex, "article")
        readBack(ex, res.row(0).int8(0))
    }

    suspend fun comments(ex: Exchange, slug: String) {
        val res = Db.read(Sql.COMMENTS, ex.viewer, key = slug)
        if (!res.ok) return failed(ex, res)
        if (res.rowCount == 0) return notFound(ex, "article")
        val j = ex.json
        j.beginObject()
        j.name(N_COMMENTS)
        j.beginArray()
        for (i in 0 until res.rowCount) {
            val r = res.row(i)
            if (r.isNull(1)) continue // the article has no comments
            j.beginObject()
            j.name(N_ID); j.number(r.int8(1))
            j.name(N_CREATED_AT); j.timestamp(r.micros(2))
            j.name(N_UPDATED_AT); j.timestamp(r.micros(3))
            j.name(N_BODY); j.text(r, 4)
            j.name(N_AUTHOR); j.profile(r, 5, r.bool(8))
            j.endObject()
        }
        j.endArray()
        j.endObject()
        ex.send(200)
    }

    suspend fun createComment(ex: Exchange, slug: String) {
        val body = Bodies.comment(JsonReader.parse(ex.body)) ?: return invalid(ex, "body is required")
        val res = Db.write(Sql.COMMENT_CREATE, Params().int8(ex.viewer).text(slug).text(body))
        if (!res.ok) return failed(ex, res)
        if (res.rowCount == 0) return notFound(ex, "article")
        val r = res.row(0)
        val j = ex.json
        j.beginObject()
        j.name(N_COMMENT)
        j.beginObject()
        j.name(N_ID); j.number(r.int8(0))
        j.name(N_CREATED_AT); j.timestamp(r.micros(1))
        j.name(N_UPDATED_AT); j.timestamp(r.micros(2))
        j.name(N_BODY); j.string(body)
        j.name(N_AUTHOR); j.profile(r, 3, false)
        j.endObject()
        j.endObject()
        ex.send(201)
    }

    suspend fun deleteComment(ex: Exchange, slug: String, id: Long) {
        if (id < 0) return notFound(ex, "comment")
        val res = Db.write(Sql.COMMENT_DELETE, Params().int8(ex.viewer).text(slug).int8(id))
        if (!res.ok) return failed(ex, res)
        if (res.rowCount == 0) return notFound(ex, "comment")
        if (res.row(0).int8(0) != ex.viewer) return ex.sendError(403, "not the author")
        ex.sendEmpty(204)
    }
}
