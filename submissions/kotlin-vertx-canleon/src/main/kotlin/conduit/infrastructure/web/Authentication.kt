package conduit.infrastructure.web

import com.auth0.jwt.JWTVerifier
import com.auth0.jwt.exceptions.JWTVerificationException
import io.netty.handler.codec.http.HttpResponseStatus
import io.vertx.core.Handler
import io.vertx.core.http.HttpHeaders
import io.vertx.ext.web.RoutingContext
import conduit.domain.shared.UnauthorizedException

/** The authenticated caller and the token they presented (GET/PUT /api/user echo it back). */
class UserPrincipal(val id: Long, val token: String)

private const val PRINCIPAL = "conduit.principal"
private const val PREFIX = "Token "

/**
 * `Authorization: Token <jwt>` (RealWorld's scheme, not Bearer), checked with java-jwt on every request: HS256
 * signature, alg and exp. Put in front of a route's handler: [required] or [optional].
 * No or an empty header: no credentials (401 on required routes, anonymous on optional ones). Any other scheme, an
 * invalid token or a non-string `sub`: invalid credentials, so 401 even on optional routes.
 */
class TokenAuthentication(private val verifier: JWTVerifier) {

    /** Auth required: a missing or invalid token gives 401. */
    val required: Handler<RoutingContext> = Handler { context -> authenticate(context, optional = false) }

    /** Auth optional: no header is anonymous, an invalid one gives 401. */
    val optional: Handler<RoutingContext> = Handler { context -> authenticate(context, optional = true) }

    private fun authenticate(context: RoutingContext, optional: Boolean) {
        val header = context.request().getHeader(HttpHeaders.AUTHORIZATION)
        if (header.isNullOrEmpty()) {
            if (optional) context.next() else context.fail(HttpResponseStatus.UNAUTHORIZED.code())
            return
        }
        val principal = if (header.startsWith(PREFIX)) principalOf(header.substring(PREFIX.length)) else null
        if (principal == null) {
            context.fail(HttpResponseStatus.UNAUTHORIZED.code())
            return
        }
        context.put(PRINCIPAL, principal)
        context.next()
    }

    /** The caller, or null if the token is invalid. `sub` must be a JSON string of digits (asString() is null for a number). */
    private fun principalOf(token: String): UserPrincipal? {
        try {
            val id = parseUnsignedLong(verifier.verify(token).getClaim("sub").asString())
            return if (id > 0) UserPrincipal(id, token) else null
        } catch (exception: JWTVerificationException) {
            return null
        }
    }
}

/** Behind [TokenAuthentication.required]. */
val RoutingContext.user: UserPrincipal
    get() {
        return get<UserPrincipal>(PRINCIPAL) ?: throw UnauthorizedException()
    }

/** Behind [TokenAuthentication.optional]: the caller's id, or 0 when anonymous. */
val RoutingContext.viewerId: Long
    get() {
        return get<UserPrincipal>(PRINCIPAL)?.id ?: 0
    }
