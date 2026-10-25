package conduit;

import io.avaje.http.api.Controller;
import io.avaje.http.api.Filter;
import io.helidon.webserver.http.FilterChain;
import io.helidon.webserver.http.RoutingRequest;
import io.helidon.webserver.http.RoutingResponse;

/**
 * Authenticates every request before routing, so an auth failure comes before the body is bound (and before a 422).
 * What each route needs is declared on the controller method with {@link Access} and looked up in {@link AccessTable}.
 */
@Controller
final class AuthFilter {

    private final Auth auth;
    private final AccessTable access;

    AuthFilter(Auth auth, AccessTable access) {
        this.auth = auth;
        this.access = access;
    }

    @Filter
    void filter(FilterChain chain, RoutingRequest req, RoutingResponse res) {
        Access.Level level = access.level(req.prologue().method().text(), req.path().rawPath());
        if (level != Access.Level.NONE) {
            auth.authenticate(req, level == Access.Level.REQUIRED);
        }
        chain.proceed();
    }
}
