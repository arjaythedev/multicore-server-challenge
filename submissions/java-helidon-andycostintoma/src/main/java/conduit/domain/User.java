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

    public record Input(
        String username,
        String email,
        String password
    ) {
    }

    public record UpdateInput(
        String username,
        String email,
        String password,
        String bio,
        String image
    ) {
        public UpdateInput {
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

    public static User register(Input input, UnaryOperator<String> hash) {
        requireUsername(input.username());
        requireEmail(input.email());
        requirePassword(input.password());
        return new User(new Props(0, input.username(), input.email(), hash.apply(input.password()),
            null, null));
    }

    public static User reconstitute(Props props) {
        return new User(props);
    }

    public User update(UpdateInput changes, String passwordHash) {
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

    private User(Props props) {
        this.id = props.id();
        this.username = props.username();
        this.email = props.email();
        this.passwordHash = props.passwordHash();
        this.bio = props.bio();
        this.image = props.image();
    }
}
