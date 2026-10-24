package conduit;

import io.avaje.jex.http.Context;
import jakarta.inject.Singleton;

/**
 * {@code Authorization: Token <jwt>} (an empty header counts as absent). {@link #user} makes auth required
 * (missing or invalid token: 401); {@link #viewer} makes it optional (no header: viewer 0; a header
 * that is present but invalid: 401). Called first in each handler, so auth runs before anything else.
 */
@Singleton
final class Auth {

    /** Authenticated caller: user id and the token they presented. */
    record User(long id, String token) {
    }

    private static final String PREFIX = "Token ";

    private final Jwt jwt;

    Auth(Jwt jwt) {
        this.jwt = jwt;
    }

    User user(Context ctx) {
        String token = token(ctx);
        if (token == null) {
            throw ApiException.unauthorized();
        }
        return new User(verify(token), token);
    }

    /** The caller's user id, or 0 when anonymous. */
    long viewer(Context ctx) {
        String token = token(ctx);
        return token == null ? 0 : verify(token);
    }

    private long verify(String token) {
        long id = jwt.verify(token);
        if (id == 0) {
            throw ApiException.unauthorized();
        }
        return id;
    }

    private static String token(Context ctx) {
        String header = ctx.header("Authorization");
        if (header == null || header.isEmpty()) {
            return null;
        }
        if (!header.startsWith(PREFIX) || header.length() == PREFIX.length()) {
            throw ApiException.unauthorized();
        }
        return header.substring(PREFIX.length());
    }
}
