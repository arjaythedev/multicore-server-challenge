package conduit;

import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;

import io.avaje.http.api.Delete;
import io.avaje.http.api.Get;
import io.avaje.http.api.Post;
import io.avaje.http.api.Put;
import jakarta.inject.Singleton;

/**
 * The {@link Access} level of every route, read once from the controllers' annotations. The filter runs before
 * Helidon has matched a route, so this matches the request path against the route templates itself, without
 * allocating. Of the templates that match, the one with the most literal segments wins, so
 * {@code /api/articles/feed} beats {@code /api/articles/{slug}}.
 */
@Singleton
final class AccessTable {

    /** A route template: {@code segments} holds the literal text of each segment, or null for a {name} parameter. */
    private record Route(String method, String[] segments, Access.Level level, int literals) {

        boolean matches(String requestMethod, String path) {
            if (!method.equals(requestMethod)) {
                return false;
            }
            int length = path.length() > 1 && path.charAt(path.length() - 1) == '/' ? path.length() - 1 : path.length();
            int pos = 1;
            for (int i = 0; i < segments.length; i++) {
                if (pos > length) {
                    return false;
                }
                int end = path.indexOf('/', pos);
                if (end < 0 || end > length) {
                    end = length;
                }
                String literal = segments[i];
                if (literal == null ? end == pos : end - pos != literal.length() || !path.startsWith(literal, pos)) {
                    return false;
                }
                pos = end + 1;
            }
            return pos == length + 1;
        }
    }

    private final List<Route> routes = new ArrayList<>();

    AccessTable(List<ApiController> controllers) {
        for (ApiController controller : controllers) {
            for (Method m : controller.getClass().getDeclaredMethods()) {
                Access access = m.getAnnotation(Access.class);
                Access.Level level = access == null ? Access.Level.REQUIRED : access.value();
                add("GET", m.getAnnotation(Get.class) == null ? null : m.getAnnotation(Get.class).value(), level);
                add("POST", m.getAnnotation(Post.class) == null ? null : m.getAnnotation(Post.class).value(), level);
                add("PUT", m.getAnnotation(Put.class) == null ? null : m.getAnnotation(Put.class).value(), level);
                add("DELETE", m.getAnnotation(Delete.class) == null ? null : m.getAnnotation(Delete.class).value(), level);
            }
        }
    }

    private void add(String method, String template, Access.Level level) {
        if (template == null) {
            return;
        }
        String[] parts = template.substring(1).split("/");
        String[] segments = new String[parts.length];
        int literals = 0;
        for (int i = 0; i < parts.length; i++) {
            if (!parts[i].startsWith("{")) {
                segments[i] = parts[i];
                literals++;
            }
        }
        routes.add(new Route(method, segments, level, literals));
    }

    /** The level for a request; {@link Access.Level#NONE} when no route matches, as it gets a 404 anyway. */
    Access.Level level(String method, String path) {
        Route best = null;
        for (Route route : routes) {
            if (route.matches(method, path) && (best == null || route.literals > best.literals)) {
                best = route;
            }
        }
        return best == null ? Access.Level.NONE : best.level;
    }
}
