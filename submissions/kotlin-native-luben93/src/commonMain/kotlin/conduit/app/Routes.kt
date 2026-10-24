package conduit.app

import kotlin.jvm.JvmField
import conduit.http.Method

/** Route ids (see [Router.match]). */
internal object Route {
    const val NOT_FOUND = 0
    const val TAGS = 1
    const val REGISTER = 2
    const val LOGIN = 3
    const val USER_GET = 4
    const val USER_PUT = 5
    const val PROFILE = 6
    const val FOLLOW = 7
    const val UNFOLLOW = 8
    const val LIST = 9
    const val FEED = 10
    const val ARTICLE_CREATE = 11
    const val ARTICLE_GET = 12
    const val ARTICLE_PUT = 13
    const val ARTICLE_DELETE = 14
    const val FAVORITE = 15
    const val UNFAVORITE = 16
    const val COMMENTS_GET = 17
    const val COMMENT_CREATE = 18
    const val COMMENT_DELETE = 19
}

/**
 * A matched route. [key] is the percent-decoded slug or username (""), [id] the comment id of COMMENT_DELETE, or -1
 * when that segment is not an int64 (404, but only after the auth check, as in the reference).
 */
internal class Routed(@JvmField val route: Int, @JvmField val key: String = "", @JvmField val id: Long = 0)

/**
 * The 19 endpoints under /api/ with at most 4 segments. Like the Go reference (ServeMux with a catch-all), an unknown
 * path or a known path with another method is 404; so are empty segments (a trailing slash) and path keys that don't
 * decode (malformed %XX, NUL, invalid UTF-8: no such row can exist). `GET /api/articles/feed` is the feed; other
 * methods on it address the article with slug "feed".
 */
internal object Router {
    private val NOT_FOUND = Routed(Route.NOT_FOUND)
    private val TAGS = Routed(Route.TAGS)
    private val REGISTER = Routed(Route.REGISTER)
    private val LOGIN = Routed(Route.LOGIN)
    private val USER_GET = Routed(Route.USER_GET)
    private val USER_PUT = Routed(Route.USER_PUT)
    private val LIST = Routed(Route.LIST)
    private val FEED = Routed(Route.FEED)
    private val ARTICLE_CREATE = Routed(Route.ARTICLE_CREATE)

    fun match(method: Method, path: String): Routed {
        if (!path.startsWith("/api/")) return NOT_FOUND
        // Segment boundaries after "/api/": s0..s3 = [b[k], e[k])
        val n = path.length
        var b0 = 5; var e0 = -1; var b1 = -1; var e1 = -1; var b2 = -1; var e2 = -1; var b3 = -1; var e3 = -1
        var count = 0
        var start = 5
        while (true) {
            var end = path.indexOf('/', start)
            if (end < 0) end = n
            if (end == start) return NOT_FOUND // empty segment
            when (count) {
                0 -> { b0 = start; e0 = end }
                1 -> { b1 = start; e1 = end }
                2 -> { b2 = start; e2 = end }
                3 -> { b3 = start; e3 = end }
                else -> return NOT_FOUND
            }
            count++
            if (end == n) break
            start = end + 1
        }
        return when {
            seg(path, b0, e0, "articles") -> when (count) {
                1 -> when (method) {
                    Method.GET -> LIST
                    Method.POST -> ARTICLE_CREATE
                    else -> NOT_FOUND
                }
                2 -> if (method == Method.GET && seg(path, b1, e1, "feed")) FEED else when (method) {
                    Method.GET -> keyed(Route.ARTICLE_GET, path, b1, e1)
                    Method.PUT -> keyed(Route.ARTICLE_PUT, path, b1, e1)
                    Method.DELETE -> keyed(Route.ARTICLE_DELETE, path, b1, e1)
                    else -> NOT_FOUND
                }
                3 -> when {
                    seg(path, b2, e2, "favorite") -> when (method) {
                        Method.POST -> keyed(Route.FAVORITE, path, b1, e1)
                        Method.DELETE -> keyed(Route.UNFAVORITE, path, b1, e1)
                        else -> NOT_FOUND
                    }
                    seg(path, b2, e2, "comments") -> when (method) {
                        Method.GET -> keyed(Route.COMMENTS_GET, path, b1, e1)
                        Method.POST -> keyed(Route.COMMENT_CREATE, path, b1, e1)
                        else -> NOT_FOUND
                    }
                    else -> NOT_FOUND
                }
                else -> if (method == Method.DELETE && seg(path, b2, e2, "comments")) {
                    val slug = Url.decode(path, b1, e1) ?: return NOT_FOUND
                    val id = Url.decode(path, b3, e3) ?: return NOT_FOUND
                    Routed(Route.COMMENT_DELETE, slug, ListQuery.digits(id))
                } else NOT_FOUND
            }
            seg(path, b0, e0, "tags") -> if (count == 1 && method == Method.GET) TAGS else NOT_FOUND
            seg(path, b0, e0, "profiles") -> when (count) {
                2 -> if (method == Method.GET) keyed(Route.PROFILE, path, b1, e1) else NOT_FOUND
                3 -> if (!seg(path, b2, e2, "follow")) NOT_FOUND else when (method) {
                    Method.POST -> keyed(Route.FOLLOW, path, b1, e1)
                    Method.DELETE -> keyed(Route.UNFOLLOW, path, b1, e1)
                    else -> NOT_FOUND
                }
                else -> NOT_FOUND
            }
            seg(path, b0, e0, "user") -> if (count != 1) NOT_FOUND else when (method) {
                Method.GET -> USER_GET
                Method.PUT -> USER_PUT
                else -> NOT_FOUND
            }
            seg(path, b0, e0, "users") -> when {
                count == 1 && method == Method.POST -> REGISTER
                count == 2 && method == Method.POST && seg(path, b1, e1, "login") -> LOGIN
                else -> NOT_FOUND
            }
            else -> NOT_FOUND
        }
    }

    private fun seg(path: String, b: Int, e: Int, lit: String): Boolean =
        e - b == lit.length && path.regionMatches(b, lit, 0, lit.length)

    private fun keyed(route: Int, path: String, b: Int, e: Int): Routed {
        val key = Url.decode(path, b, e) ?: return NOT_FOUND
        return Routed(route, key)
    }
}
