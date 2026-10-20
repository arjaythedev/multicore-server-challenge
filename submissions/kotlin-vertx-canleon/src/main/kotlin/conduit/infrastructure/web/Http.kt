package conduit.infrastructure.web

import io.netty.handler.codec.http.HttpResponseStatus
import io.vertx.core.http.HttpHeaders
import io.vertx.ext.web.Router
import io.vertx.ext.web.RoutingContext
import io.vertx.ext.web.handler.BodyHandler
import io.vertx.ext.web.handler.HttpException
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.Json
import org.slf4j.LoggerFactory
import conduit.domain.article.ArticleList
import conduit.domain.shared.DomainException
import conduit.domain.shared.ForbiddenException
import conduit.domain.shared.NotFoundException
import conduit.domain.shared.UnauthorizedException
import conduit.domain.shared.ValidationException

// ---- JSON ----

/** Strings must be JSON strings, unknown fields are ignored. */
val json = Json { ignoreUnknownKeys = true }

private const val JSON_CONTENT_TYPE = "application/json; charset=UTF-8"

/** Reads the request body for POST and PUT routes: in memory, at most 1 MB (413 beyond), no file uploads. */
val bodyHandler: BodyHandler = BodyHandler.create(false).setBodyLimit(1024L * 1024L)

/** The body as [T], whatever the Content-Type; malformed or the wrong shape is a 422. */
inline fun <reified T> RoutingContext.receiveJson(): T {
    try {
        return json.decodeFromString<T>(body().asString() ?: "")
    } catch (exception: Exception) {
        throw ValidationException("malformed JSON body")
    }
}

fun <T> RoutingContext.respondJson(serializer: KSerializer<T>, value: T, status: HttpResponseStatus = HttpResponseStatus.OK) {
    response()
        .setStatusCode(status.code())
        .putHeader(HttpHeaders.CONTENT_TYPE, JSON_CONTENT_TYPE)
        .end(json.encodeToString(serializer, value))
}

fun RoutingContext.respondJson(value: UserResponse, status: HttpResponseStatus = HttpResponseStatus.OK) {
    respondJson(UserResponse.serializer(), value, status)
}

fun RoutingContext.respondJson(value: ProfileResponse) {
    respondJson(ProfileResponse.serializer(), value)
}

fun RoutingContext.respondJson(value: ArticleResponse, status: HttpResponseStatus = HttpResponseStatus.OK) {
    respondJson(ArticleResponse.serializer(), value, status)
}

fun RoutingContext.respondJson(value: ArticleList) {
    respondJson(ArticleListSerializer, value)
}

fun RoutingContext.respondJson(value: CommentResponse, status: HttpResponseStatus = HttpResponseStatus.OK) {
    respondJson(CommentResponse.serializer(), value, status)
}

fun RoutingContext.respondJson(value: CommentsResponse) {
    respondJson(CommentsResponse.serializer(), value)
}

fun RoutingContext.respondJson(value: TagsResponse) {
    respondJson(TagsResponse.serializer(), value)
}

fun RoutingContext.respondNoContent() {
    response().setStatusCode(HttpResponseStatus.NO_CONTENT.code()).end()
}

fun RoutingContext.respondError(status: HttpResponseStatus, message: String) {
    respondJson(ErrorResponse.serializer(), ErrorResponse(ErrorBody(listOf(message))), status)
}

// ---- errors ----

private val log = LoggerFactory.getLogger("conduit.web")

private fun DomainException.status(): HttpResponseStatus {
    return when (this) {
        is NotFoundException -> HttpResponseStatus.NOT_FOUND
        is ForbiddenException -> HttpResponseStatus.FORBIDDEN
        is ValidationException -> HttpResponseStatus.UNPROCESSABLE_ENTITY
        is UnauthorizedException -> HttpResponseStatus.UNAUTHORIZED
    }
}

/** Every error as {"errors": {"body": [message]}}. */
fun Router.errorResponses() {
    route().failureHandler { context ->
        val failure = context.failure()
        when {
            context.response().ended() -> {}
            failure is DomainException -> context.respondError(failure.status(), failure.message ?: "error")
            failure is HttpException -> {
                val status = HttpResponseStatus.valueOf(failure.statusCode)
                context.respondError(status, status.reasonPhrase().lowercase())
            }
            failure != null -> {
                log.error("unhandled", failure)
                context.respondError(HttpResponseStatus.INTERNAL_SERVER_ERROR, "internal server error")
            }
            // a status without an exception, e.g. 401 from the authentication handlers or 413 from the body handler
            else -> {
                val status = HttpResponseStatus.valueOf(context.statusCode())
                context.respondError(status, status.reasonPhrase().lowercase())
            }
        }
    }
    // a path that can't be decoded (malformed percent-encoding)
    errorHandler(HttpResponseStatus.BAD_REQUEST.code()) { context -> context.respondError(HttpResponseStatus.BAD_REQUEST, "bad request") }
    // unknown path, or a known path with another method: 404 (no 405)
    errorHandler(HttpResponseStatus.NOT_FOUND.code()) { context -> context.respondError(HttpResponseStatus.NOT_FOUND, "not found") }
    errorHandler(HttpResponseStatus.METHOD_NOT_ALLOWED.code()) { context -> context.respondError(HttpResponseStatus.NOT_FOUND, "not found") }
}

// ---- parameters ----

/** ASCII digits only (no sign, no spaces) that fit in a Long; -1 otherwise. */
fun parseUnsignedLong(text: String?): Long {
    if (text.isNullOrEmpty()) return -1
    for (character in text) {
        if (character < '0' || character > '9') return -1
    }
    return text.toLongOrNull() ?: -1
}

/** An integer query parameter: [default] when absent, -1 when present but not a non-negative Int (even empty). */
fun RoutingContext.intQueryParameter(name: String, default: Int): Int {
    val value = parseUnsignedLong(rawQueryParameter(name) ?: return default)
    return if (value in 0..Int.MAX_VALUE) value.toInt() else -1
}

/** A query parameter; empty counts as absent. */
fun RoutingContext.queryParameter(name: String): String? {
    val value = rawQueryParameter(name)
    return if (value.isNullOrEmpty()) null else value
}

/** A malformed percent-encoding in the query string is the client's error: 400. */
private fun RoutingContext.rawQueryParameter(name: String): String? {
    try {
        return queryParams()[name]
    } catch (exception: IllegalArgumentException) {
        throw HttpException(HttpResponseStatus.BAD_REQUEST.code(), exception)
    }
}

fun RoutingContext.pathParameter(name: String): String {
    return pathParam(name)
}
