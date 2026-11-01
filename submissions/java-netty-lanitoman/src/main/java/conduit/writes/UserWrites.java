package conduit.writes;

import conduit.Exchange;
import conduit.RequestBody;
import conduit.db.MessageWriter;
import conduit.db.Row;
import conduit.db.Statement;
import conduit.json.Keys;
import conduit.json.Render;
import conduit.security.BCrypt;
import conduit.security.Jwt;
import conduit.security.PasswordWorkers;
import java.nio.charset.StandardCharsets;

/** POST /api/users (register), POST /api/users/login and PUT /api/user. */
public final class UserWrites {
    private static final Statement INSERT_USER = Statement.define(
            "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)"
                    + " RETURNING id, username, email, bio, image",
            Statement.TEXT, Statement.TEXT, Statement.TEXT);

    private static final Statement USER_BY_EMAIL = Statement.define(
            "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1",
            Statement.TEXT);

    private static final Statement UPDATE_USER = Statement.define(
            "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),"
                    + " password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)"
                    + " WHERE id = $1 RETURNING id, username, email, bio, image",
            Statement.INT8, Statement.TEXT, Statement.TEXT, Statement.TEXT, Statement.TEXT, Statement.TEXT);

    private UserWrites() {
    }

    // ---------- register ----------

    public static void register(Exchange exchange, byte[] body) throws RequestBody.Invalid {
        RequestBody user = RequestBody.parse(body, "user");
        String username = user.required("username");
        String email = user.required("email");
        String password = checkLength(user.required("password"));
        BCrypt.Job hash = BCrypt.newHash(password);
        PasswordWorkers.submit(exchange, hash, () -> new InsertUser(exchange, username, email, hash.hashString()).submit());
    }

    private static final class InsertUser extends WriteQuery {
        private final String username, email, passwordHash;

        InsertUser(Exchange exchange, String username, String email, String passwordHash) {
            super(exchange);
            this.username = username;
            this.email = email;
            this.passwordHash = passwordHash;
        }

        @Override
        public void write(MessageWriter out) {
            out.bind(INSERT_USER).text(username).text(email).text(passwordHash).execute();
            out.sync();
        }

        @Override
        public void onRow(int statementIndex, Row row) {
            exchange.found = true;
            Render.userResponse(exchange.json(), row, 0, Jwt.issue(row.getLong(0)));
        }

        @Override
        protected void onSuccess() {
            if (exchange.found) exchange.respond(201);
            else exchange.respondError(500, "user not created");
        }
    }

    // ---------- login ----------

    public static void login(Exchange exchange, byte[] body) throws RequestBody.Invalid {
        RequestBody user = RequestBody.parse(body, "user");
        String email = user.required("email");
        String password = user.required("password");
        new FindUserForLogin(exchange, email, password).submit();
    }

    /** Reads the user and its password hash; the password is then checked on a bcrypt worker. */
    private static final class FindUserForLogin extends WriteQuery {
        private final String email, password;
        private long id;
        private String username, emailFound, bio, image, passwordHash;

        FindUserForLogin(Exchange exchange, String email, String password) {
            super(exchange);
            this.email = email;
            this.password = password;
        }

        @Override
        public void write(MessageWriter out) {
            out.bind(USER_BY_EMAIL).text(email).execute();
            out.sync();
        }

        @Override
        public void onRow(int statementIndex, Row row) {
            exchange.found = true;
            id = row.getLong(0);
            username = row.getString(1);
            emailFound = row.getString(2);
            bio = row.getString(3);
            image = row.getString(4);
            passwordHash = row.getString(5);
        }

        @Override
        protected void onSuccess() {
            BCrypt.Job check = exchange.found ? BCrypt.verification(password, passwordHash) : null;
            if (check == null) {
                exchange.respondError(401, "invalid email or password");
                return;
            }
            PasswordWorkers.submit(exchange, check, () -> {
                if (!check.matches()) {
                    exchange.respondError(401, "invalid email or password");
                    return;
                }
                exchange.json().beginObject().key(Keys.USER).beginObject()
                        .key(Keys.EMAIL).value(emailFound)
                        .key(Keys.TOKEN).value(Jwt.issue(id))
                        .key(Keys.USERNAME).value(username)
                        .key(Keys.BIO).value(bio)
                        .key(Keys.IMAGE).value(image)
                        .endObject().endObject();
                exchange.respond(200);
            });
        }
    }

    // ---------- update the current user ----------

    public static void update(Exchange exchange, byte[] body) throws RequestBody.Invalid {
        RequestBody user = RequestBody.parse(body, "user");
        String email = user.optional("email", false);
        String username = user.optional("username", false);
        String password = user.optional("password", false);
        String bio = user.optional("bio", true);
        String image = user.optional("image", true);
        if (password == null) {
            new UpdateUser(exchange, email, username, null, bio, image).submit();
            return;
        }
        BCrypt.Job hash = BCrypt.newHash(checkLength(password));
        PasswordWorkers.submit(exchange, hash,
                () -> new UpdateUser(exchange, email, username, hash.hashString(), bio, image).submit());
    }

    private static final class UpdateUser extends WriteQuery {
        private final String email, username, passwordHash, bio, image;

        UpdateUser(Exchange exchange, String email, String username, String passwordHash, String bio, String image) {
            super(exchange);
            this.email = email;
            this.username = username;
            this.passwordHash = passwordHash;
            this.bio = bio;
            this.image = image;
        }

        @Override
        public void write(MessageWriter out) {
            out.bind(UPDATE_USER).int8(exchange.viewer).text(email).text(username).text(passwordHash).text(bio).text(image)
                    .execute();
            out.sync();
        }

        @Override
        public void onRow(int statementIndex, Row row) {
            exchange.found = true;
            Render.userResponse(exchange.json(), row, 0, exchange.token);
        }

        @Override
        protected void onSuccess() {
            if (exchange.found) exchange.respond(200);
            else exchange.respondError(401, "unknown user");
        }
    }

    /** bcrypt only uses 72 bytes: a longer password is refused rather than silently cut. */
    private static String checkLength(String password) throws RequestBody.Invalid {
        if (password.getBytes(StandardCharsets.UTF_8).length > BCrypt.MAX_PASSWORD_BYTES) {
            throw new RequestBody.Invalid("password is longer than 72 bytes");
        }
        return password;
    }
}
