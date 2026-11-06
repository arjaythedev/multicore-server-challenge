package conduit.domain;

import conduit.errors.InvalidInput;
import java.nio.charset.StandardCharsets;
import java.util.function.UnaryOperator;

public final class User {
    private final long id;
    private final String username;
    private final String email;
    private final String passwordHash;
    private final String bio;
    private final String image;

    private User(Props props) {
        this.id = props.id();
        this.username = props.username();
        this.email = props.email();
        this.passwordHash = props.passwordHash();
        this.bio = props.bio();
        this.image = props.image();
    }

    public long id() {
        return id;
    }

    public String username() {
        return username;
    }

    public String email() {
        return email;
    }

    public String passwordHash() {
        return passwordHash;
    }

    public String bio() {
        return bio;
    }

    public String image() {
        return image;
    }

    public record Props(
        long id,
        String username,
        String email,
        String passwordHash,
        String bio,
        String image
    ) {
    }

    public record Changes(
        String username,
        String email,
        String password,
        String bio,
        String image
    ) {
        public Changes {
            if (username != null) {
                requireUsername(username);
            }
            if (email != null) {
                requireEmail(email);
            }
            if (password != null) {
                requirePassword(password);
            }
        }
    }

    public static User register(String username, String email, String password,
        UnaryOperator<String> hash) {
        requireUsername(username);
        requireEmail(email);
        requirePassword(password);
        return new User(new Props(0, username, email, hash.apply(password), null, null));
    }

    public static User reconstitute(Props props) {
        return new User(props);
    }

    public User update(Changes changes, String passwordHash) {
        return new User(new Props(id, unchanged(changes.username(), username),
            unchanged(changes.email(), email), unchanged(passwordHash, this.passwordHash),
            unchanged(changes.bio(), bio), unchanged(changes.image(), image)));
    }

    private static void requireUsername(String username) {
        if (username == null || username.isEmpty()) {
            throw new InvalidInput("username is required");
        }
    }

    private static void requireEmail(String email) {
        if (email == null || email.isEmpty()) {
            throw new InvalidInput("email is required");
        }
    }

    private static void requirePassword(String password) {
        if (password == null || password.isEmpty()) {
            throw new InvalidInput("password is required");
        }
        if (password.getBytes(StandardCharsets.UTF_8).length > 72) {
            throw new InvalidInput("Password must not exceed 72 UTF-8 bytes");
        }
    }

    private static String unchanged(String replacement, String previous) {
        return replacement == null ? previous : replacement;
    }
}
