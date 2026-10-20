package conduit.infrastructure.security

import com.auth0.jwt.JWT
import com.auth0.jwt.JWTVerifier
import com.auth0.jwt.algorithms.Algorithm
import conduit.domain.user.TokenIssuer
import java.time.Duration
import java.time.Instant

/** HS256 tokens: {"sub": "<user id>", "iat": now, "exp": now + 30 days}. */
class JwtTokens(secret: String) : TokenIssuer {
    private val algorithm = Algorithm.HMAC256(secret)

    /** Signature, alg = HS256, exp present and not past. Used by the web layer's authentication. */
    val verifier: JWTVerifier = JWT.require(algorithm).withClaimPresence("exp").ignoreIssuedAt().build()

    override fun issue(userId: Long): String {
        val now = Instant.now()
        return JWT.create()
            .withSubject(userId.toString())
            .withIssuedAt(now)
            .withExpiresAt(now.plus(Duration.ofDays(30)))
            .sign(algorithm)
    }
}
