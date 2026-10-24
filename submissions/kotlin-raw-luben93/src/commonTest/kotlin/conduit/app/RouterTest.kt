package conduit.app

import conduit.http.Method
import kotlin.test.Test
import kotlin.test.assertEquals

class RouterTest {
    private fun route(m: Method, p: String) = Router.match(m, p).route

    private fun check(m: Method, p: String, want: Int, key: String = "", id: Long = 0) {
        val r = Router.match(m, p)
        assertEquals(want, r.route, "$m $p")
        assertEquals(key, r.key, "key of $m $p")
        assertEquals(id, r.id, "id of $m $p")
    }

    @Test
    fun allEndpoints() {
        check(Method.POST, "/api/users", Route.REGISTER)
        check(Method.POST, "/api/users/login", Route.LOGIN)
        check(Method.GET, "/api/user", Route.USER_GET)
        check(Method.PUT, "/api/user", Route.USER_PUT)
        check(Method.GET, "/api/profiles/conformance_user2", Route.PROFILE, "conformance_user2")
        check(Method.POST, "/api/profiles/bob/follow", Route.FOLLOW, "bob")
        check(Method.DELETE, "/api/profiles/bob/follow", Route.UNFOLLOW, "bob")
        check(Method.GET, "/api/articles", Route.LIST)
        check(Method.GET, "/api/articles/feed", Route.FEED)
        check(Method.POST, "/api/articles", Route.ARTICLE_CREATE)
        check(Method.GET, "/api/articles/a-slug-1", Route.ARTICLE_GET, "a-slug-1")
        check(Method.PUT, "/api/articles/a-slug-1", Route.ARTICLE_PUT, "a-slug-1")
        check(Method.DELETE, "/api/articles/a-slug-1", Route.ARTICLE_DELETE, "a-slug-1")
        check(Method.POST, "/api/articles/a-slug-1/favorite", Route.FAVORITE, "a-slug-1")
        check(Method.DELETE, "/api/articles/a-slug-1/favorite", Route.UNFAVORITE, "a-slug-1")
        check(Method.GET, "/api/articles/a-slug-1/comments", Route.COMMENTS_GET, "a-slug-1")
        check(Method.POST, "/api/articles/a-slug-1/comments", Route.COMMENT_CREATE, "a-slug-1")
        check(Method.DELETE, "/api/articles/a-slug-1/comments/25093", Route.COMMENT_DELETE, "a-slug-1", 25093)
        check(Method.GET, "/api/tags", Route.TAGS)
    }

    @Test
    fun feedIsOnlyGet() {
        // Like Go's ServeMux: other methods on /api/articles/feed address the article whose slug is "feed".
        check(Method.PUT, "/api/articles/feed", Route.ARTICLE_PUT, "feed")
        check(Method.DELETE, "/api/articles/feed", Route.ARTICLE_DELETE, "feed")
        check(Method.GET, "/api/articles/feed/comments", Route.COMMENTS_GET, "feed")
    }

    @Test
    fun commentIdNotAnInteger() {
        // Routed (so auth is checked first), id -1 = 404 in the handler.
        check(Method.DELETE, "/api/articles/s/comments/abc", Route.COMMENT_DELETE, "s", -1)
        check(Method.DELETE, "/api/articles/s/comments/99999999999999999999", Route.COMMENT_DELETE, "s", -1)
        check(Method.DELETE, "/api/articles/s/comments/-1", Route.COMMENT_DELETE, "s", -1)
        check(Method.DELETE, "/api/articles/s/comments/%31%32", Route.COMMENT_DELETE, "s", 12)
    }

    @Test
    fun wrongMethodIs404() {
        for ((m, p) in listOf(
            Method.GET to "/api/users", Method.GET to "/api/users/login", Method.POST to "/api/user",
            Method.DELETE to "/api/user", Method.PUT to "/api/profiles/bob", Method.GET to "/api/profiles/bob/follow",
            Method.PUT to "/api/articles", Method.DELETE to "/api/articles", Method.POST to "/api/articles/feed",
            Method.POST to "/api/articles/s", Method.GET to "/api/articles/s/favorite",
            Method.PUT to "/api/articles/s/comments", Method.GET to "/api/articles/s/comments/1",
            Method.POST to "/api/tags", Method.OTHER to "/api/tags", Method.OTHER to "/api/articles",
        )) assertEquals(Route.NOT_FOUND, route(m, p), "$m $p")
    }

    @Test
    fun unknownPathsAre404() {
        for (p in listOf(
            "/", "", "/api", "/api/", "/apis/tags", "/api/tag", "/api/tags/", "/api/tags/x", "/api//tags",
            "/api/articles/", "/api/articles//comments", "/api/articles/s/comments/", "/api/articles/s/x",
            "/api/articles/s/comments/1/x", "/api/profiles", "/api/profiles/", "/api/profiles/bob/x",
            "/api/profiles/bob/follow/x", "/api/users/x", "/api/user/x", "/API/tags", "/api/Tags", "tags",
        )) {
            for (m in listOf(Method.GET, Method.POST, Method.PUT, Method.DELETE)) {
                assertEquals(Route.NOT_FOUND, route(m, p), "$m $p")
            }
        }
    }

    @Test
    fun keysArePercentDecoded() {
        check(Method.GET, "/api/profiles/no%5Fsuch%5Fuser", Route.PROFILE, "no_such_user")
        check(Method.GET, "/api/articles/a%2Fb", Route.ARTICLE_GET, "a/b")
        check(Method.GET, "/api/profiles/a+b", Route.PROFILE, "a+b") // '+' is literal in paths
        check(Method.GET, "/api/profiles/%C3%BCber", Route.PROFILE, "über")
    }

    @Test
    fun undecodableKeysAre404() {
        for (p in listOf(
            "/api/profiles/a%00b", "/api/profiles/%zz", "/api/articles/%FF", "/api/articles/x%", "/api/articles/%C3/comments",
        )) assertEquals(Route.NOT_FOUND, route(Method.GET, p), p)
        assertEquals(Route.NOT_FOUND, route(Method.DELETE, "/api/articles/a%00/comments/1"))
    }
}
