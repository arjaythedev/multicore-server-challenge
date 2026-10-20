package conduit.infrastructure.web

import io.ktor.http.ContentType
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.ApplicationCall
import io.ktor.server.application.log
import io.ktor.server.plugins.BadRequestException
import io.ktor.server.plugins.PayloadTooLargeException
import io.ktor.server.plugins.statuspages.StatusPagesConfig
import io.ktor.server.request.receive
import io.ktor.server.response.respondText
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.Json
import conduit.domain.article.ArticleList
import conduit.domain.shared.DomainException
import conduit.domain.shared.ForbiddenException
import conduit.domain.shared.NotFoundException
import conduit.domain.shared.UnauthorizedException
import conduit.domain.shared.ValidationException

// ---- JSON ----

/** Strings must be JSON strings, unknown fields are ignored. */
val json = Json { ignoreUnknownKeys = true }

/** Request bodies are read into memory; larger ones are refused with 413 (see Main.kt's RequestBodyLimit). */
const val MAX_BODY_BYTES = 1024L * 1024L

/** The body as [T], whatever the Content-Type; malformed or the wrong shape is a 422. */
suspend inline fun <reified T> ApplicationCall.receiveJson(): T {
    // read first: a body over MAX_BODY_BYTES throws PayloadTooLargeException (413), not a 422
    val body = receive<ByteArray>().decodeToString()
    try {
        return json.decodeFromString<T>(body)
    } catch (exception: Exception) {
        throw ValidationException("malformed JSON body")
    }
}

suspend fun <T> ApplicationCall.respondJson(serializer: KSerializer<T>, value: T, status: HttpStatusCode = HttpStatusCode.OK) {
    respondText(json.encodeToString(serializer, value), ContentType.Application.Json, status)
}

suspend fun ApplicationCall.respondJson(value: UserResponse, status: HttpStatusCode = HttpStatusCode.OK) {
    respondJson(UserResponse.serializer(), value, status)
}

suspend fun ApplicationCall.respondJson(value: ProfileResponse) {
    respondJson(ProfileResponse.serializer(), value)
}

suspend fun ApplicationCall.respondJson(value: ArticleResponse, status: HttpStatusCode = HttpStatusCode.OK) {
    respondJson(ArticleResponse.serializer(), value, status)
}

suspend fun ApplicationCall.respondJson(value: ArticleList) {
    respondJson(ArticleListSerializer, value)
}

suspend fun ApplicationCall.respondJson(value: CommentResponse, status: HttpStatusCode = HttpStatusCode.OK) {
    respondJson(CommentResponse.serializer(), value, status)
}

suspend fun ApplicationCall.respondJson(value: CommentsResponse) {
    respondJson(CommentsResponse.serializer(), value)
}

suspend fun ApplicationCall.respondJson(value: TagsResponse) {
    respondJson(TagsResponse.serializer(), value)
}

suspend fun ApplicationCall.respondError(status: HttpStatusCode, message: String) {
    respondJson(ErrorResponse.serializer(), ErrorResponse(ErrorBody(listOf(message))), status)
}

// ---- errors ----

private fun DomainException.status(): HttpStatusCode {
    return when (this) {
        is NotFoundException -> HttpStatusCode.NotFound
        is ForbiddenException -> HttpStatusCode.Forbidden
        is ValidationException -> HttpStatusCode.UnprocessableEntity
        is UnauthorizedException -> HttpStatusCode.Unauthorized
    }
}

/** Every error as {"errors": {"body": [message]}}. */
fun StatusPagesConfig.errorResponses() {
    exception<DomainException> { call, exception -> call.respondError(exception.status(), exception.message ?: "error") }
    exception<PayloadTooLargeException> { call, _ -> call.respondError(HttpStatusCode.PayloadTooLarge, "request entity too large") }
    // e.g. a malformed percent-encoding in the query string
    exception<BadRequestException> { call, _ -> call.respondError(HttpStatusCode.BadRequest, "bad request") }
    exception<Throwable> { call, exception ->
        call.application.log.error("unhandled", exception)
        call.respondError(HttpStatusCode.InternalServerError, "internal server error")
    }
    // unknown path, or a known path with another method: 404 (no 405)
    status(HttpStatusCode.NotFound, HttpStatusCode.MethodNotAllowed) { call, _ ->
        call.respondError(HttpStatusCode.NotFound, "not found")
    }
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
fun ApplicationCall.intQueryParameter(name: String, default: Int): Int {
    val value = parseUnsignedLong(request.queryParameters[name] ?: return default)
    return if (value in 0..Int.MAX_VALUE) value.toInt() else -1
}

/** A query parameter; empty counts as absent. */
fun ApplicationCall.queryParameter(name: String): String? {
    val value = request.queryParameters[name]
    return if (value.isNullOrEmpty()) null else value
}

fun ApplicationCall.pathParameter(name: String): String {
    return parameters[name]!!
}
