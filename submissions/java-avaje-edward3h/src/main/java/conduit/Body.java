package conduit;

import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.concurrent.ConcurrentHashMap;

import io.helidon.webserver.http.ServerRequest;
import io.avaje.jsonb.JsonType;
import io.avaje.jsonb.Jsonb;
import jakarta.inject.Singleton;

/**
 * Request bodies are read whatever the Content-Type, after auth has run. Jsonb rejects a value of the wrong JSON
 * type (no coercing {"body": 123} to "123"), and reads a missing or null field as null. Anything malformed, missing
 * or blank is a 422.
 */
@Singleton
final class Body {

    private final Jsonb jsonb;
    private final ConcurrentHashMap<Class<?>, JsonType<?>> types = new ConcurrentHashMap<>();

    Body(Jsonb jsonb) {
        this.jsonb = jsonb;
    }

    /** The request body bound to {@code type}; 422 if it isn't valid JSON of that shape. */
    @SuppressWarnings("unchecked")
    <T> T read(ServerRequest req, Class<T> type) {
        JsonType<T> json = (JsonType<T>) types.computeIfAbsent(type, jsonb::type);
        try {
            T root = json.fromJson(req.content().as(byte[].class));
            if (root == null) {
                throw ApiException.invalid("body must be a JSON object");
            }
            return root;
        } catch (ApiException ex) {
            throw ex;
        } catch (RuntimeException ex) {
            throw ApiException.invalid("malformed JSON body");
        }
    }

    /** The wrapper object ({@code user}, {@code article}, ...); 422 when absent or null. */
    static <T> T object(T value, String key) {
        if (value == null) {
            throw ApiException.invalid(key + " must be an object");
        }
        return value;
    }

    /** A required non-empty string field. */
    static String required(String value, String field) {
        if (value == null || value.isEmpty()) {
            throw ApiException.invalid(field + " can't be blank");
        }
        return value;
    }

    /** An optional non-empty string field: null when absent or JSON null; 422 when empty. */
    static String optionalNonEmpty(String value, String field) {
        if (value != null && value.isEmpty()) {
            throw ApiException.invalid(field + " can't be blank");
        }
        return value;
    }

    /** An optional array of non-empty strings: empty when absent or null. */
    static List<String> stringList(List<String> value, String field) {
        if (value == null) {
            return List.of();
        }
        for (String s : value) {
            if (s == null || s.isEmpty()) {
                throw ApiException.invalid(field + " must contain non-empty strings");
            }
        }
        return value;
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
