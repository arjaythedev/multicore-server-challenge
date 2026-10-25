package conduit;

import java.nio.charset.StandardCharsets;

import org.jspecify.annotations.Nullable;

/** Helpers the request records' constraints can't express: password length in bytes and unsigned integers. */
final class Body {

    private Body() {
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
