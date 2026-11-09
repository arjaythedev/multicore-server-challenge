package conduit.adapters.outbound.security;

import com.auth0.jwt.JWT;
import com.auth0.jwt.algorithms.Algorithm;
import com.auth0.jwt.exceptions.JWTVerificationException;
import com.auth0.jwt.interfaces.JWTVerifier;
import conduit.contracts.user.Tokens;
import conduit.errors.Unauthenticated;
import java.time.Clock;
import java.time.Duration;

public final class JwtTokens implements Tokens {
    private final Algorithm algorithm;
    private final JWTVerifier verifier;
    private final Clock clock;

    public JwtTokens(String secret, Clock clock) {
        this.algorithm = Algorithm.HMAC256(secret);
        this.clock = clock;
        this.verifier = JWT.require(algorithm)
            .withClaim("exp", (claim, _) -> !claim.isNull() && claim.asLong() != null)
            .ignoreIssuedAt().build();
    }

    @Override
    public String issue(long userId) {
        var now = clock.instant();
        return JWT.create().withSubject(Long.toString(userId)).withIssuedAt(now)
            .withExpiresAt(now.plus(Duration.ofDays(30))).sign(algorithm);
    }

    @Override
    public long verify(String token) {
        try {
            var decoded = verifier.verify(token);
            var subject = decoded.getClaim("sub").asString();
            var userId = subject == null ? -1 : Long.parseLong(subject);
            if (userId <= 0) {
                throw new Unauthenticated("Invalid token subject");
            }
            return userId;
        } catch (JWTVerificationException | NumberFormatException failure) {
            throw new Unauthenticated("Invalid or expired token");
        }
    }
}
