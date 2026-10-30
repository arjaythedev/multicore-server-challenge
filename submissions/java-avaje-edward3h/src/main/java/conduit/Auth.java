package conduit;

import io.helidon.http.HeaderNames;
import io.helidon.webserver.http.ServerRequest;
import jakarta.inject.Singleton;
import org.jspecify.annotations.Nullable;

/**
 * {@code Authorization: Token <jwt>} (an empty header counts as absent). {@link AuthFilter} calls
 * {@link #authenticate} before routing, so a bad token is a 401 before the body is read; handlers then read the
 * caller with {@link #user} (auth required) or {@link #viewer} (auth optional).
 */
@Singleton
final class Auth {

    /** Authenticated caller: user id and the token they presented. */
    record User(long id, String token) {}

    private static final String PREFIX = "Token ";
    private static final String CALLER = "conduit.caller";

    private final Jwt jwt;

    Auth(Jwt jwt) {
        this.jwt = jwt;
    }

    /**
     * Verifies the token, if there is one, and records the caller on the request. A token that is present but
     * invalid is a 401; so is a missing token when {@code required}.
     */
    void authenticate(ServerRequest req, boolean required) {
        String token = token(req);
        if (token == null) {
            if (required) {
                throw ApiException.unauthorized();
            }
            return;
        }
        long id = jwt.verify(token);
        if (id == 0) {
            throw ApiException.unauthorized();
        }
        req.context().register(CALLER, new User(id, token));
    }

    /** The authenticated caller; 401 if {@link #authenticate} didn't find one. */
    User user(ServerRequest req) {
        return req.context().get(CALLER, User.class).orElseThrow(ApiException::unauthorized);
    }

    /** The caller's user id, or 0 when anonymous. */
    long viewer(ServerRequest req) {
        return req.context().get(CALLER, User.class).map(User::id).orElse(0L);
    }

    private static @Nullable String token(ServerRequest req) {
        String header = req.headers().first(HeaderNames.AUTHORIZATION).orElse(null);
        if (header == null || header.isEmpty()) {
            return null;
        }
        if (!header.startsWith(PREFIX) || header.length() == PREFIX.length()) {
            throw ApiException.unauthorized();
        }
        return header.substring(PREFIX.length());
    }
}
