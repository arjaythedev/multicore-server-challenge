package conduit.adapters.outbound.security;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import com.auth0.jwt.JWT;
import com.auth0.jwt.algorithms.Algorithm;
import conduit.errors.Unauthenticated;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import org.junit.jupiter.api.Test;

class JwtTokensTest {
    private static final String SECRET = "test-secret";
    private final JwtTokens tokens = new JwtTokens(SECRET, Clock.systemUTC());

    @Test
    void issuesHs256WithStringSubjectAndThirtyDayLifetime() {
        var encoded = tokens.issue(42);
        var decoded = JWT.decode(encoded);

        assertEquals("HS256", decoded.getAlgorithm());
        assertEquals("42", decoded.getSubject());
        assertEquals(Duration.ofDays(30),
            Duration.between(decoded.getIssuedAtAsInstant(), decoded.getExpiresAtAsInstant()));
        assertEquals(42L, tokens.verify(encoded));
    }

    @Test
    void rejectsWrongSignatureAndAlgorithm() {
        reject(JWT.create().withSubject("42").withExpiresAt(Instant.now().plusSeconds(60))
            .sign(Algorithm.HMAC256("other-secret")));
        reject(JWT.create().withSubject("42").withExpiresAt(Instant.now().plusSeconds(60))
            .sign(Algorithm.HMAC512(SECRET)));
        reject(JWT.create().withSubject("42").withExpiresAt(Instant.now().plusSeconds(60))
            .sign(Algorithm.none()));
    }

    @Test
    void requiresNonNullFutureExpiration() {
        reject(JWT.create().withSubject("42").sign(Algorithm.HMAC256(SECRET)));
        reject(JWT.create().withSubject("42").withNullClaim("exp").sign(Algorithm.HMAC256(SECRET)));
        reject(JWT.create().withSubject("42").withExpiresAt(Instant.now().minusSeconds(1))
            .sign(Algorithm.HMAC256(SECRET)));
    }

    @Test
    void requiresPositiveDecimalStringSubjectWithinBigintRange() {
        for (var subject : new String[]{"", "abc", "0", "-1", "9223372036854775808"}) {
            reject(JWT.create().withSubject(subject).withExpiresAt(Instant.now().plusSeconds(60))
                .sign(Algorithm.HMAC256(SECRET)));
        }
        reject(JWT.create().withClaim("sub", 42).withExpiresAt(Instant.now().plusSeconds(60))
            .sign(Algorithm.HMAC256(SECRET)));
        reject(JWT.create().withExpiresAt(Instant.now().plusSeconds(60))
            .sign(Algorithm.HMAC256(SECRET)));
    }

    @Test
    void rejectsMalformedToken() {
        reject("not-a-jwt");
    }

    private void reject(String token) {
        assertThrows(Unauthenticated.class, () -> tokens.verify(token));
    }
}
