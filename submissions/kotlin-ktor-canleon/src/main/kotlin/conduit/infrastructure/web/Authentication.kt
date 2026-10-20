package conduit.infrastructure.web

import com.auth0.jwt.JWTVerifier
import com.auth0.jwt.exceptions.JWTVerificationException
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.ApplicationCall
import io.ktor.server.auth.AuthenticationConfig
import io.ktor.server.auth.AuthenticationContext
import io.ktor.server.auth.AuthenticationFailedCause
import io.ktor.server.auth.AuthenticationProcedureChallenge
import io.ktor.server.auth.authenticate
import io.ktor.server.auth.principal
import io.ktor.server.routing.Route
import conduit.domain.shared.UnauthorizedException

/** The authenticated caller and the token they presented (GET/PUT /api/user echo it back). */
class UserPrincipal(val id: Long, val token: String)

private const val TOKEN_AUTH = "token"
private const val PREFIX = "Token "

/**
 * `Authorization: Token <jwt>` (RealWorld's scheme, not Bearer), checked with java-jwt on every request: HS256
 * signature, alg and exp. A generic Ktor provider instead of ktor-server-auth-jwt: that plugin validated the token
 * with a regex and parsed the payload a second time, on every request.
 * No or an empty header: no credentials (anonymous on optional routes). Any other scheme, an invalid token or a
 * non-string `sub`: invalid credentials, so 401 even on optional routes.
 */
fun AuthenticationConfig.tokenAuth(verifier: JWTVerifier) {
    provider(TOKEN_AUTH) {
        authenticate { context ->
            authenticateToken(context, verifier)
        }
    }
}

private fun authenticateToken(context: AuthenticationContext, verifier: JWTVerifier) {
    val header = context.call.request.headers[HttpHeaders.Authorization]
    if (header.isNullOrEmpty()) {
        context.challenge(TOKEN_AUTH, AuthenticationFailedCause.NoCredentials, ::respondUnauthorized)
        return
    }
    val principal = if (header.startsWith(PREFIX)) principalOf(verifier, header.substring(PREFIX.length)) else null
    if (principal == null) {
        context.challenge(TOKEN_AUTH, AuthenticationFailedCause.InvalidCredentials, ::respondUnauthorized)
        return
    }
    context.principal(TOKEN_AUTH, principal)
}

/** The caller, or null if the token is invalid. `sub` must be a JSON string of digits (asString() is null for a number). */
private fun principalOf(verifier: JWTVerifier, token: String): UserPrincipal? {
    try {
        val id = parseUnsignedLong(verifier.verify(token).getClaim("sub").asString())
        return if (id > 0) UserPrincipal(id, token) else null
    } catch (exception: JWTVerificationException) {
        return null
    }
}

private suspend fun respondUnauthorized(challenge: AuthenticationProcedureChallenge, call: ApplicationCall) {
    call.respondError(HttpStatusCode.Unauthorized, "unauthorized")
    challenge.complete()
}

/** Auth required: a missing or invalid token gives 401. */
fun Route.authenticated(build: Route.() -> Unit): Route {
    return authenticate(TOKEN_AUTH, build = build)
}

/** Auth optional: no header is anonymous, an invalid one gives 401. */
fun Route.optionalAuth(build: Route.() -> Unit): Route {
    return authenticate(TOKEN_AUTH, optional = true, build = build)
}

/** Inside [authenticated]. */
val ApplicationCall.user: UserPrincipal
    get() {
        return principal<UserPrincipal>() ?: throw UnauthorizedException()
    }

/** Inside [optionalAuth]: the caller's id, or 0 when anonymous. */
val ApplicationCall.viewerId: Long
    get() {
        return principal<UserPrincipal>()?.id ?: 0
    }
