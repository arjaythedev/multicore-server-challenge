package conduit;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import io.helidon.webserver.http.ServerRequest;
import io.avaje.jsonb.JsonType;
import io.avaje.jsonb.Jsonb;
import jakarta.inject.Singleton;

/**
 * Request bodies are read as a JSON tree whatever the Content-Type, after auth has run. Strings must be
 * JSON strings (no coercing {"body": 123} to "123"). Anything malformed is a 422.
 */
@Singleton
final class Body {

    private final JsonType<Object> type;

    Body(Jsonb jsonb) {
        this.type = jsonb.type(Object.class);
    }

    /** The object under {@code key} in the request body; 422 if the body isn't {"key": {...}}. */
    @SuppressWarnings("unchecked")
    Map<String, Object> object(ServerRequest req, String key) {
        Object root;
        try {
            root = type.fromJson(req.content().as(byte[].class));
        } catch (RuntimeException ex) {
            throw ApiException.invalid("malformed JSON body");
        }
        if (!(root instanceof Map<?, ?> map)) {
            throw ApiException.invalid("body must be a JSON object");
        }
        if (!(map.get(key) instanceof Map<?, ?> inner)) {
            throw ApiException.invalid(key + " must be an object");
        }
        return (Map<String, Object>) inner;
    }

    /** A required non-empty string field. */
    static String required(Map<String, Object> obj, String field) {
        String s = optional(obj, field);
        if (s == null || s.isEmpty()) {
            throw ApiException.invalid(field + " can't be blank");
        }
        return s;
    }

    /** An optional non-empty string field: null when absent or JSON null; 422 when empty or not a string. */
    static String optionalNonEmpty(Map<String, Object> obj, String field) {
        String s = optional(obj, field);
        if (s != null && s.isEmpty()) {
            throw ApiException.invalid(field + " can't be blank");
        }
        return s;
    }

    /** An optional string field: null when absent or JSON null; 422 when it isn't a string. */
    static String optional(Map<String, Object> obj, String field) {
        Object v = obj.get(field);
        if (v == null) {
            return null;
        }
        if (!(v instanceof String s)) {
            throw ApiException.invalid(field + " must be a string");
        }
        return s;
    }

    /** An optional array of non-empty strings: empty when absent or null. */
    static List<String> stringList(Map<String, Object> obj, String field) {
        Object v = obj.get(field);
        if (v == null) {
            return List.of();
        }
        if (!(v instanceof List<?> list)) {
            throw ApiException.invalid(field + " must be an array");
        }
        List<String> out = new ArrayList<>(list.size());
        for (Object e : list) {
            if (!(e instanceof String s) || s.isEmpty()) {
                throw ApiException.invalid(field + " must contain non-empty strings");
            }
            out.add(s);
        }
        return out;
    }

    /** bcrypt only hashes the first 72 bytes; longer passwords are refused: 422. */
    static String hashable(String password) {
        if (password.getBytes(StandardCharsets.UTF_8).length > 72) {
            throw ApiException.invalid("password is too long");
        }
        return password;
    }

    /** ASCII digits only (no sign, no spaces) that fit in a long; -1 otherwise. */
    static long parseUint(String s) {
        if (s == null || s.isEmpty()) {
            return -1;
        }
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c < '0' || c > '9') {
                return -1;
            }
        }
        try {
            return Long.parseLong(s);
        } catch (NumberFormatException ex) {
            return -1;
        }
    }
}
