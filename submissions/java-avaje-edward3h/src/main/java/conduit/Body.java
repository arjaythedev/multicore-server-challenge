package conduit;

import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.function.Function;

import org.jspecify.annotations.Nullable;

/**
 * Checks on the request records in {@link Requests}, which the generated routes bind from the body whatever the
 * Content-Type. Jsonb rejects a value of the wrong JSON type (no coercing {"body": 123} to "123"), and reads a
 * missing or null field as null. Anything malformed, missing or blank is a 422.
 */
final class Body {

    private Body() {
    }

    /** The wrapper object ({@code user}, {@code article}, ...) of a request; 422 when the body or the wrapper is null. */
    static <R, T> T inner(@Nullable R root, Function<R, @Nullable T> wrapper, String key) {
        @Nullable T value = root == null ? null : wrapper.apply(root);
        if (value == null) {
            throw ApiException.invalid(key + " must be an object");
        }
        return value;
    }

    /** A required non-empty string field. */
    static String required(@Nullable String value, String field) {
        if (value == null || value.isEmpty()) {
            throw ApiException.invalid(field + " can't be blank");
        }
        return value;
    }

    /** An optional non-empty string field: null when absent or JSON null; 422 when empty. */
    static @Nullable String optionalNonEmpty(@Nullable String value, String field) {
        if (value != null && value.isEmpty()) {
            throw ApiException.invalid(field + " can't be blank");
        }
        return value;
    }

    /** An optional array of non-empty strings: empty when absent or null. */
    static List<String> stringList(@Nullable List<@Nullable String> value, String field) {
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
    static long parseUint(@Nullable String s) {
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
