package conduit.app

import conduit.http.Exchange
import conduit.http.Method
import conduit.json.JsonWriter
import conduit.util.ByteBuf
import kotlin.coroutines.Continuation
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.startCoroutine
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Records the answer. Only paths that answer before Db/Jwt/JSON are exercised here (other tracks are stubs). */
private class FakeExchange(
    override val method: Method,
    override val path: String,
    override val query: String? = null,
    override val authorization: String? = null,
    override val body: ByteArray = ByteArray(0),
) : Exchange() {
    override val out = ByteBuf(64)
    override val json = JsonWriter(out)
    var status = 0
    var answers = 0
    override fun send(status: Int) { this.status = status; answers++ }
    override fun sendEmpty(status: Int) { this.status = status; answers++ }
    override fun sendError(status: Int, message: String) {
        assertTrue(message.isNotEmpty())
        this.status = status; answers++
    }
}

class AppTest {
    private fun run(ex: FakeExchange): Int {
        var done = false
        val block: suspend () -> Unit = { App.handle(ex) }
        block.startCoroutine(Continuation(EmptyCoroutineContext) { it.getOrThrow(); done = true })
        assertTrue(done, "${ex.method} ${ex.path} suspended")
        assertEquals(1, ex.answers, "${ex.method} ${ex.path} must be answered exactly once")
        return ex.status
    }

    private fun status(m: Method, p: String, q: String? = null, auth: String? = null) =
        run(FakeExchange(m, p, q, auth))

    @Test
    fun unknownRoutesAre404() {
        assertEquals(404, status(Method.GET, "/api/tags/"))
        assertEquals(404, status(Method.GET, "/api/nope"))
        assertEquals(404, status(Method.DELETE, "/api/articles"))
        assertEquals(404, status(Method.OTHER, "/api/tags"))
        assertEquals(404, status(Method.GET, "/api/profiles/%00", auth = "Token x"))
    }

    @Test
    fun requiredAuthWithoutAValidHeaderIs401() {
        val required = listOf(
            Method.GET to "/api/user", Method.PUT to "/api/user", Method.POST to "/api/profiles/u/follow",
            Method.DELETE to "/api/profiles/u/follow", Method.GET to "/api/articles/feed", Method.POST to "/api/articles",
            Method.PUT to "/api/articles/s", Method.DELETE to "/api/articles/s", Method.POST to "/api/articles/s/favorite",
            Method.DELETE to "/api/articles/s/favorite", Method.POST to "/api/articles/s/comments",
            Method.DELETE to "/api/articles/s/comments/1", Method.DELETE to "/api/articles/s/comments/abc",
        )
        for ((m, p) in required) {
            assertEquals(401, status(m, p), "$m $p without a header")
            assertEquals(401, status(m, p, auth = "Bearer a.b.c"), "$m $p with Bearer")
            assertEquals(401, status(m, p, auth = "a.b.c"), "$m $p without a scheme")
        }
    }

    @Test
    fun optionalAuthWithAnInvalidHeaderIs401() {
        for ((m, p) in listOf(
            Method.GET to "/api/profiles/u", Method.GET to "/api/articles", Method.GET to "/api/articles/s",
            Method.GET to "/api/articles/s/comments",
        )) assertEquals(401, status(m, p, auth = "Bearer a.b.c"), "$m $p")
    }

    @Test
    fun badListParamsAre422ForAnonymousViewers() {
        for (q in listOf("limit=0", "limit=101", "limit=", "offset=-1", "offset=99999999999999999999", "limit=%2B5")) {
            assertEquals(422, status(Method.GET, "/api/articles", q), q)
        }
    }
}
