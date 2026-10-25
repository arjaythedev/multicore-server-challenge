package conduit;

import io.avaje.http.api.Controller;
import io.avaje.http.api.Filter;
import io.helidon.common.uri.UriPath;
import io.helidon.http.Method;
import io.helidon.webserver.http.FilterChain;
import io.helidon.webserver.http.RoutingRequest;
import io.helidon.webserver.http.RoutingResponse;

/**
 * Authenticates every request before routing, so an auth failure comes before the body is bound (and before a 422).
 * Auth is required unless the route is listed in {@link #requirement}, so a new endpoint under /api is protected by
 * default (and an unknown /api path without a token is a 401, not a 404).
 */
@Controller
final class AuthFilter {

    private enum Requirement { NONE, OPTIONAL, REQUIRED }

    private final Auth auth;

    AuthFilter(Auth auth) {
        this.auth = auth;
    }

    @Filter
    void filter(FilterChain chain, RoutingRequest req, RoutingResponse res) {
        Requirement requirement = requirement(req.prologue().method(), req.path().rawPath());
        if (requirement != Requirement.NONE) {
            auth.authenticate(req, requirement == Requirement.REQUIRED);
        }
        chain.proceed();
    }

    /** NONE: the token is ignored. OPTIONAL: anonymous is fine, a bad token isn't. REQUIRED: everything else. */
    private static Requirement requirement(Method method, String path) {
        if (!path.startsWith("/api/")) {
            return Requirement.NONE;
        }
        if (method == Method.POST && (path.equals("/api/users") || path.equals("/api/users/login"))
                || method == Method.GET && path.equals("/api/tags")) {
            return Requirement.NONE;
        }
        if (method != Method.GET) {
            return Requirement.REQUIRED;
        }
        String[] segments = path.split("/");   // "", "api", ...
        boolean optional = switch (segments.length) {
            case 3 -> segments[2].equals("articles");
            case 4 -> segments[2].equals("profiles")
                    || segments[2].equals("articles") && !segments[3].equals("feed");
            case 5 -> segments[2].equals("articles") && segments[4].equals("comments");
            default -> false;
        };
        return optional ? Requirement.OPTIONAL : Requirement.REQUIRED;
    }
}
