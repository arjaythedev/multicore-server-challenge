package dev.mccue.jdk.httpserver.realworld;

import com.auth0.jwt.JWT;
import com.auth0.jwt.JWTVerifier;
import com.auth0.jwt.algorithms.Algorithm;
import com.auth0.jwt.exceptions.JWTVerificationException;
import com.sun.net.httpserver.HttpExchange;
import dev.mccue.jdbc.SQLFragment;
import dev.mccue.jdbc.SettableParameter;
import dev.mccue.jdbc.UncheckedSQLException;
import dev.mccue.jdk.httpserver.Body;
import dev.mccue.jdk.httpserver.HttpExchanges;
import dev.mccue.jdk.httpserver.json.JsonBody;
import dev.mccue.jdk.httpserver.regexrouter.RegexRouter;
import dev.mccue.jdk.httpserver.regexrouter.RouteParams;
import dev.mccue.json.*;
import dev.mccue.urlparameters.UrlParameters;
import org.bouncycastle.crypto.generators.OpenBSDBCrypt;
import org.jetbrains.annotations.Nullable;

import javax.sql.DataSource;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Duration;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.*;

import static dev.mccue.json.JsonDecoder.*;

public final class RealWorldAPI {
    private final DataSource db;
    private final Algorithm jwtAlgorithm;
    private final JWTVerifier jwtVerifier;

    RealWorldAPI(DataSource db, String jwtSecret) {
        this.db = db;
        this.jwtAlgorithm = Algorithm.HMAC256(Objects.requireNonNull(jwtSecret, "JWT_SECRET is required"));
        // HS256 only, signature and exp checked on every request.
        this.jwtVerifier = JWT.require(jwtAlgorithm)
                .withClaimPresence("exp")
                .build();
    }

    /// An Authorization header that is present but isn't a valid token. 401, even where auth is optional.
    static final class InvalidTokenException extends RuntimeException {
    }

    /// A request that is well-formed JSON but breaks a rule (empty field, bad limit, ...). 422.
    static final class UnprocessableException extends RuntimeException {
        UnprocessableException(String message) {
            super(message);
        }
    }

    @Nullable String getPresentedToken(HttpExchange exchange) {
        var authHeader = exchange.getRequestHeaders().getFirst("Authorization");
        if (authHeader == null) {
            return null;
        }
        if (!authHeader.startsWith("Token ")) {
            throw new InvalidTokenException();
        }
        return authHeader.substring("Token ".length()).trim();
    }

    /// The user id from the token, or null if there is no Authorization header.
    @Nullable Long getUserId(HttpExchange exchange) {
        var token = getPresentedToken(exchange);
        if (token == null) {
            return null;
        }
        try {
            var sub = jwtVerifier.verify(token).getClaim("sub").asString();
            if (sub == null || sub.isEmpty() || !sub.chars().allMatch(c -> c >= '0' && c <= '9')) {
                throw new InvalidTokenException();
            }
            return Long.parseLong(sub);
        } catch (JWTVerificationException | NumberFormatException e) {
            throw new InvalidTokenException();
        }
    }

    String getToken(long userId) {
        var now = Instant.now().truncatedTo(ChronoUnit.SECONDS);
        return JWT.create()
                .withSubject(Long.toString(userId))
                .withIssuedAt(now)
                .withExpiresAt(now.plus(Duration.ofDays(30)))
                .sign(jwtAlgorithm);
    }

    void sendError(HttpExchange exchange, int status, String message) throws IOException {
        HttpExchanges.sendResponse(
                exchange,
                status,
                JsonBody.of(
                        Json.objectBuilder()
                                .put("errors", Json.objectBuilder()
                                        .put("body", Json.arrayBuilder()
                                                .add(message)))
                )
        );
    }

    /// Sends JSON text that Postgres already built, as is.
    void sendJson(HttpExchange exchange, int status, String json) throws IOException {
        exchange.getResponseHeaders().put("Content-Type", List.of("application/json"));
        HttpExchanges.sendResponse(exchange, status, Body.of(json));
    }

    void unauthenticated(HttpExchange exchange) throws IOException {
        sendError(exchange, 401, "unauthenticated");
    }

    void notFound(HttpExchange exchange) throws IOException {
        sendError(exchange, 404, "not found");
    }

    void forbidden(HttpExchange exchange) throws IOException {
        sendError(exchange, 403, "forbidden");
    }

    /// A JSON string that isn't empty.
    static JsonDecoder<String> nonEmptyString(String message) {
        return json -> {
            var value = string(json);
            if (value.isEmpty()) {
                throw JsonDecodeException.of(message, json);
            }
            return value;
        };
    }

    static JsonObject.Builder userJson(ResultSet rs, String token) throws SQLException {
        return Json.objectBuilder()
                .put("email", rs.getString("email"))
                .put("token", token)
                .put("username", rs.getString("username"))
                .put("bio", rs.getString("bio"))
                .put("image", rs.getString("image"));
    }

    // RFC 3339 in UTC, exactly three (truncated) fractional digits
    private static SQLFragment timestamp(String column) {
        return SQLFragment.join("", List.of(
                SQLFragment.of("to_char("),
                SQLFragment.of(column),
                SQLFragment.of(" AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"')")
        ));
    }

    /// An Article as JSON, for a row of articles JOIN users, as the viewer sees it.
    private static SQLFragment articleJson(boolean includeBody, long viewer) {
        var parts = new ArrayList<SQLFragment>();
        parts.add(SQLFragment.of("""
                json_build_object(
                    'slug', articles.slug,
                    'title', articles.title,
                    'description', articles.description,
                """));
        if (includeBody) {
            parts.add(SQLFragment.of("""
                        'body', articles.body,
                    """));
        }
        parts.add(SQLFragment.of("""
                    'tagList', ARRAY(SELECT tags.name FROM article_tags JOIN tags ON tags.id = article_tags.tag_id
                                      WHERE article_tags.article_id = articles.id ORDER BY tags.name),
                    'createdAt',\s"""));
        parts.add(timestamp("articles.created_at"));
        parts.add(SQLFragment.of("""
                ,
                    'updatedAt',\s"""));
        parts.add(timestamp("articles.updated_at"));
        parts.add(SQLFragment.of("""
                ,
                    'favorited', EXISTS (SELECT 1 FROM favorites WHERE favorites.article_id = articles.id AND favorites.user_id = ?),
                    'favoritesCount', (SELECT count(*) FROM favorites WHERE favorites.article_id = articles.id),
                    'author', json_build_object(
                        'username', users.username,
                        'bio', users.bio,
                        'image', users.image,
                        'following', EXISTS (SELECT 1 FROM follows WHERE follows.follower_id = ? AND follows.followee_id = articles.author_id)
                    )
                )""", List.of(viewer, viewer)));
        return SQLFragment.join("", parts);
    }

    /// One row per article: its id (for ordering) and its JSON.
    private static SQLFragment articleListSelect(long viewer) {
        return SQLFragment.join("", List.of(
                SQLFragment.of("SELECT articles.id, "),
                articleJson(false, viewer),
                SQLFragment.of("""
                         AS article
                          FROM articles
                          JOIN users ON users.id = articles.author_id
                        """)
        ));
    }

    /// {"article": Article}.
    private static SQLFragment articleFullSelect(long viewer) {
        return SQLFragment.join("", List.of(
                SQLFragment.of("SELECT json_build_object('article', "),
                articleJson(true, viewer),
                SQLFragment.of("""
                        )
                          FROM articles
                          JOIN users ON users.id = articles.author_id
                        """)
        ));
    }

    /// The slug text for a title (the article id is appended separately).
    private static SQLFragment slugify(@Nullable String title) {
        return SQLFragment.of(
                "trim(both '-' from lower(regexp_replace(?, '[^A-Za-z0-9]+', '-', 'g')))",
                List.of(SettableParameter.ofString(title))
        );
    }

    /// {"article": Article} for the article with this id, or null if there isn't one.
    @Nullable String findArticle(Connection conn, long viewer, long articleId) throws SQLException {
        try (var stmt = SQLFragment.join("", List.of(
                articleFullSelect(viewer),
                SQLFragment.of("WHERE articles.id = ?", List.of(articleId))
        )).prepareStatement(conn)) {
            var rs = stmt.executeQuery();
            return rs.next() ? rs.getString(1) : null;
        }
    }

    /// The id of the article with this slug, or null.
    @Nullable Long articleIdForSlug(Connection conn, String slug) throws SQLException {
        try (var stmt = conn.prepareStatement("SELECT id FROM articles WHERE slug = ?")) {
            stmt.setString(1, slug);
            var rs = stmt.executeQuery();
            return rs.next() ? rs.getLong("id") : null;
        }
    }

    /// {"articles": [...], "articlesCount": n} from a page of articleListSelect rows and a capped count,
    /// both in one statement.
    static SQLFragment articleList(SQLFragment page, SQLFragment count) {
        return SQLFragment.join("", List.of(
                SQLFragment.of("""
                        SELECT json_build_object(
                            'articles', (SELECT COALESCE(json_agg(p.article ORDER BY p.id DESC), '[]'::json) FROM (
                        """),
                page,
                SQLFragment.of("""
                            ) p),
                            'articlesCount', (
                        """),
                count,
                SQLFragment.of("""
                            )
                        )
                        """)
        ));
    }

    /// A Comment as JSON, for a row of comments JOIN users.
    private static SQLFragment commentJson(SQLFragment following) {
        return SQLFragment.join("", List.of(
                SQLFragment.of("""
                        json_build_object(
                            'id', comments.id,
                            'createdAt',\s"""),
                timestamp("comments.created_at"),
                SQLFragment.of("""
                        ,
                            'updatedAt',\s"""),
                timestamp("comments.updated_at"),
                SQLFragment.of("""
                        ,
                            'body', comments.body,
                            'author', json_build_object(
                                'username', users.username,
                                'bio', users.bio,
                                'image', users.image,
                                'following',\s"""),
                following,
                SQLFragment.of("""

                            )
                        )""")
        ));
    }

    /// A query parameter that must be a plain decimal integer in [min, max].
    static int intInRange(UrlParameters urlParameters, String name, int defaultValue, int min, int max) {
        var value = urlParameters.firstValue(name).orElse(null);
        if (value == null) {
            return defaultValue;
        }
        // parseInt rejects everything else that isn't an int, but it allows a leading + or -
        if (value.isEmpty() || value.charAt(0) < '0' || value.charAt(0) > '9') {
            throw new UnprocessableException(name + " must be an int");
        }
        int parsed;
        try {
            parsed = Integer.parseInt(value);
        } catch (NumberFormatException e) {
            throw new UnprocessableException(name + " must be an int");
        }
        if (parsed < min || parsed > max) {
            throw new UnprocessableException(name + " is out of range");
        }
        return parsed;
    }

    static boolean passwordTooLong(String password) {
        return password.getBytes(StandardCharsets.UTF_8).length > 72;
    }

    private static final SecureRandom SALTS = new SecureRandom();

    /// bcrypt, cost 10.
    static String hashPassword(String password) {
        var salt = new byte[16];
        SALTS.nextBytes(salt);
        return OpenBSDBCrypt.generate("2a", password.toCharArray(), salt, 10);
    }

    /// Checks against the stored hash, at whatever cost it was made with.
    static boolean passwordMatches(String password, String hash) {
        return OpenBSDBCrypt.checkPassword(hash, password.toCharArray());
    }

    record RegisterRequest(
            String username,
            String email,
            String password
    ) {
        static RegisterRequest fromJson(Json json) {
            return field(json, "user", user -> new RegisterRequest(
                    field(user, "username", nonEmptyString("username can't be empty")),
                    field(user, "email", nonEmptyString("email can't be empty")),
                    field(user, "password", nonEmptyString("password can't be empty"))
            ));
        }
    }

    void registerHandler(HttpExchange exchange) throws IOException {
        var body = JsonBody.read(exchange, RegisterRequest::fromJson);
        if (passwordTooLong(body.password)) {
            sendError(exchange, 422, "password is too long");
            return;
        }
        var passwordHash = hashPassword(body.password);

        JsonObject.Builder user;
        try (var conn = db.getConnection();
             var stmt = conn.prepareStatement("""
                     INSERT INTO users (username, email, password_hash) VALUES (?, ?, ?)
                     RETURNING id, username, email, bio, image
                     """)) {
            stmt.setString(1, body.username);
            stmt.setString(2, body.email);
            stmt.setString(3, passwordHash);
            var rs = stmt.executeQuery();
            rs.next();
            user = userJson(rs, getToken(rs.getLong("id")));
        } catch (SQLException e) {
            if ("23505".equals(e.getSQLState())) {
                sendError(exchange, 422, "username or email already taken");
                return;
            }
            throw new UncheckedSQLException(e);
        }

        HttpExchanges.sendResponse(exchange, 201, JsonBody.of(Json.objectBuilder().put("user", user)));
    }

    record LoginRequest(String email, String password) {
        static LoginRequest fromJson(Json json) {
            return field(json, "user", user -> new LoginRequest(
                    field(user, "email", nonEmptyString("email can't be empty")),
                    field(user, "password", nonEmptyString("password can't be empty"))
            ));
        }
    }

    void loginHandler(HttpExchange exchange) throws IOException {
        var body = JsonBody.read(exchange, LoginRequest::fromJson);

        long userId;
        String passwordHash;
        JsonObject.Builder userJson = Json.objectBuilder();
        // The connection goes back to the pool before the (slow) bcrypt check.
        try (var conn = db.getConnection();
             var stmt = conn.prepareStatement("""
                     SELECT id, username, email, bio, image, password_hash FROM users WHERE email = ?
                     """)) {
            stmt.setString(1, body.email);
            var rs = stmt.executeQuery();
            if (!rs.next()) {
                sendError(exchange, 401, "invalid email or password");
                return;
            }

            userId = rs.getLong("id");
            passwordHash = rs.getString("password_hash");
            userJson
                    .put("email", rs.getString("email"))
                    .put("username", rs.getString("username"))
                    .put("bio", rs.getString("bio"))
                    .put("image", rs.getString("image"));
        } catch (SQLException e) {
            throw new UncheckedSQLException(e);
        }

        if (passwordTooLong(body.password)
            || !passwordMatches(body.password, passwordHash)) {
            sendError(exchange, 401, "invalid email or password");
            return;
        }

        userJson.put("token", getToken(userId));

        HttpExchanges.sendResponse(exchange, 200, JsonBody.of(Json.objectBuilder().put("user", userJson)));
    }

    void getCurrentUserHandler(HttpExchange exchange) throws IOException {
        var userId = getUserId(exchange);
        if (userId == null) {
            unauthenticated(exchange);
            return;
        }

        JsonObject.Builder user;
        try (var conn = db.getConnection();
             var stmt = conn.prepareStatement("""
                     SELECT id, username, email, bio, image FROM users WHERE id = ?
                     """)) {
            stmt.setLong(1, userId);
            var rs = stmt.executeQuery();
            if (!rs.next()) {
                unauthenticated(exchange);
                return;
            }
            user = userJson(rs, getPresentedToken(exchange));
        } catch (SQLException e) {
            throw new UncheckedSQLException(e);
        }

        HttpExchanges.sendResponse(exchange, 200, JsonBody.of(Json.objectBuilder().put("user", user)));
    }

    /// Fields that are absent or null are left unchanged.
    record UpdateUserRequest(
            @Nullable String email,
            @Nullable String username,
            @Nullable String password,
            @Nullable String image,
            @Nullable String bio
    ) {
        static UpdateUserRequest fromJson(Json json) {
            return field(json, "user", user -> new UpdateUserRequest(
                    optionalNullableField(user, "email", nonEmptyString("email can't be empty"), null),
                    optionalNullableField(user, "username", nonEmptyString("username can't be empty"), null),
                    optionalNullableField(user, "password", nonEmptyString("password can't be empty"), null),
                    optionalNullableField(user, "image", string(), null),
                    optionalNullableField(user, "bio", string(), null)
            ));
        }
    }

    void updateUserHandler(HttpExchange exchange) throws IOException {
        var userId = getUserId(exchange);
        if (userId == null) {
            unauthenticated(exchange);
            return;
        }
        var request = JsonBody.read(exchange, UpdateUserRequest::fromJson);

        String passwordHash = null;
        if (request.password != null) {
            if (passwordTooLong(request.password)) {
                sendError(exchange, 422, "password is too long");
                return;
            }
            passwordHash = hashPassword(request.password);
        }

        JsonObject.Builder user;
        try (var conn = db.getConnection();
             var stmt = conn.prepareStatement("""
                     UPDATE users SET email = COALESCE(?, email), username = COALESCE(?, username),
                                      password_hash = COALESCE(?, password_hash), bio = COALESCE(?, bio), image = COALESCE(?, image)
                      WHERE id = ?
                     RETURNING id, username, email, bio, image
                     """)) {
            stmt.setString(1, request.email);
            stmt.setString(2, request.username);
            stmt.setString(3, passwordHash);
            stmt.setString(4, request.bio);
            stmt.setString(5, request.image);
            stmt.setLong(6, userId);
            var rs = stmt.executeQuery();
            if (!rs.next()) {
                unauthenticated(exchange);
                return;
            }
            user = userJson(rs, getPresentedToken(exchange));
        } catch (SQLException e) {
            if ("23505".equals(e.getSQLState())) {
                sendError(exchange, 422, "username or email already taken");
                return;
            }
            throw new UncheckedSQLException(e);
        }

        HttpExchanges.sendResponse(exchange, 200, JsonBody.of(Json.objectBuilder().put("user", user)));
    }

    void getProfileHandler(HttpExchange exchange) throws IOException {
        var userId = getUserId(exchange);
        var username = RouteParams.get(exchange)
                .param("username")
                .orElseThrow();

        String profile;
        try (var conn = db.getConnection();
             var stmt = conn.prepareStatement("""
                     SELECT json_build_object('profile', json_build_object(
                                'username', users.username,
                                'bio', users.bio,
                                'image', users.image,
                                'following', EXISTS (SELECT 1 FROM follows WHERE follows.follower_id = ? AND follows.followee_id = users.id)
                            ))
                       FROM users WHERE users.username = ?
                     """)) {
            stmt.setLong(1, userId == null ? 0 : userId);
            stmt.setString(2, username);
            var rs = stmt.executeQuery();
            if (!rs.next()) {
                notFound(exchange);
                return;
            }
            profile = rs.getString(1);
        } catch (SQLException e) {
            throw new UncheckedSQLException(e);
        }

        sendJson(exchange, 200, profile);
    }

    void followUserHandler(HttpExchange exchange) throws IOException {
        followOrUnfollow(exchange, true);
    }

    void unfollowUserHandler(HttpExchange exchange) throws IOException {
        followOrUnfollow(exchange, false);
    }

    void followOrUnfollow(HttpExchange exchange, boolean follow) throws IOException {
        var userId = getUserId(exchange);
        if (userId == null) {
            unauthenticated(exchange);
            return;
        }
        var username = RouteParams.get(exchange)
                .param("username")
                .orElseThrow();

        String profile;
        try (var conn = db.getConnection()) {
            long followeeId;
            try (var stmt = conn.prepareStatement("""
                    SELECT users.id, json_build_object('profile', json_build_object(
                               'username', users.username,
                               'bio', users.bio,
                               'image', users.image,
                               'following', ?::boolean
                           ))
                      FROM users WHERE users.username = ?
                    """)) {
                stmt.setBoolean(1, follow);
                stmt.setString(2, username);
                var rs = stmt.executeQuery();
                if (!rs.next()) {
                    notFound(exchange);
                    return;
                }
                followeeId = rs.getLong(1);
                profile = rs.getString(2);
            }

            if (follow) {
                try (var stmt = conn.prepareStatement("""
                        INSERT INTO follows (follower_id, followee_id) VALUES (?, ?) ON CONFLICT DO NOTHING
                        """)) {
                    stmt.setLong(1, userId);
                    stmt.setLong(2, followeeId);
                    stmt.execute();
                }
            }
            else {
                try (var stmt = conn.prepareStatement("""
                        DELETE FROM follows WHERE follower_id = ? AND followee_id = ?
                        """)) {
                    stmt.setLong(1, userId);
                    stmt.setLong(2, followeeId);
                    stmt.execute();
                }
            }
        } catch (SQLException e) {
            throw new UncheckedSQLException(e);
        }

        sendJson(exchange, 200, profile);
    }

    void listArticlesHandler(HttpExchange exchange) throws IOException {
        var userId = getUserId(exchange);
        var urlParameters = UrlParameters.parse(exchange.getRequestURI());
        int limit = intInRange(urlParameters, "limit", 20, 1, 100);
        int offset = intInRange(urlParameters, "offset", 0, 0, Integer.MAX_VALUE);

        // Only the first of tag, author, favorited applies. An empty value counts as absent.
        var tag = urlParameters.firstValue("tag").filter(s -> !s.isEmpty()).orElse(null);
        var author = urlParameters.firstValue("author").filter(s -> !s.isEmpty()).orElse(null);
        var favorited = urlParameters.firstValue("favorited").filter(s -> !s.isEmpty()).orElse(null);

        long viewer = userId == null ? 0 : userId;
        var select = articleListSelect(viewer);

        SQLFragment page;
        SQLFragment count;
        if (tag != null) {
            page = SQLFragment.join("", List.of(select, SQLFragment.of("""
                    WHERE articles.id IN (SELECT article_tags.article_id FROM article_tags
                                    WHERE article_tags.tag_id = (SELECT tags.id FROM tags WHERE tags.name = ?)
                                    ORDER BY article_tags.article_id DESC LIMIT ? OFFSET ?)
                    """, List.of(tag, limit, offset))));
            count = SQLFragment.of("""
                    SELECT count(*) FROM (SELECT 1 FROM article_tags
                                           WHERE article_tags.tag_id = (SELECT tags.id FROM tags WHERE tags.name = ?) LIMIT 1000) s
                    """, List.of(tag));
        }
        else if (author != null) {
            page = SQLFragment.join("", List.of(select, SQLFragment.of("""
                    WHERE articles.author_id = (SELECT users.id FROM users WHERE users.username = ?)
                    ORDER BY articles.id DESC LIMIT ? OFFSET ?
                    """, List.of(author, limit, offset))));
            count = SQLFragment.of("""
                    SELECT count(*) FROM (SELECT 1 FROM articles
                                           WHERE articles.author_id = (SELECT users.id FROM users WHERE users.username = ?) LIMIT 1000) s
                    """, List.of(author));
        }
        else if (favorited != null) {
            page = SQLFragment.join("", List.of(select, SQLFragment.of("""
                    WHERE articles.id IN (SELECT favorites.article_id FROM favorites
                                    WHERE favorites.user_id = (SELECT users.id FROM users WHERE users.username = ?)
                                    ORDER BY favorites.article_id DESC LIMIT ? OFFSET ?)
                    """, List.of(favorited, limit, offset))));
            count = SQLFragment.of("""
                    SELECT count(*) FROM (SELECT 1 FROM favorites
                                           WHERE favorites.user_id = (SELECT users.id FROM users WHERE users.username = ?) LIMIT 1000) s
                    """, List.of(favorited));
        }
        else {
            page = SQLFragment.join("", List.of(select, SQLFragment.of("""
                    ORDER BY articles.id DESC LIMIT ? OFFSET ?
                    """, List.of(limit, offset))));
            count = SQLFragment.of("""
                    SELECT count(*) FROM (SELECT 1 FROM articles LIMIT 1000) s
                    """);
        }

        String articles;
        try (var conn = db.getConnection();
             var stmt = articleList(page, count).prepareStatement(conn)) {
            var rs = stmt.executeQuery();
            rs.next();
            articles = rs.getString(1);
        } catch (SQLException e) {
            throw new UncheckedSQLException(e);
        }

        sendJson(exchange, 200, articles);
    }

    void feedArticlesHandler(HttpExchange exchange) throws IOException {
        var userId = getUserId(exchange);
        if (userId == null) {
            unauthenticated(exchange);
            return;
        }
        var urlParameters = UrlParameters.parse(exchange.getRequestURI());
        int limit = intInRange(urlParameters, "limit", 20, 1, 100);
        int offset = intInRange(urlParameters, "offset", 0, 0, Integer.MAX_VALUE);

        // Each followed author contributes at most limit + offset of their newest articles.
        // (bigint, so a huge offset can't overflow)
        var page = SQLFragment.join("", List.of(
                articleListSelect(userId),
                SQLFragment.of("""
                        WHERE articles.id IN (SELECT x.id FROM follows CROSS JOIN LATERAL
                            (SELECT articles.id FROM articles WHERE articles.author_id = follows.followee_id
                              ORDER BY articles.id DESC LIMIT (?::bigint + ?::bigint)) x
                          WHERE follows.follower_id = ? ORDER BY x.id DESC LIMIT ? OFFSET ?)
                        """, List.of(limit, offset, userId, limit, offset))
        ));
        var count = SQLFragment.of("""
                SELECT count(*) FROM (SELECT 1 FROM articles
                                       WHERE articles.author_id IN (SELECT follows.followee_id FROM follows WHERE follows.follower_id = ?)
                                       LIMIT 1000) s
                """, List.of(userId));

        String articles;
        try (var conn = db.getConnection();
             var stmt = articleList(page, count).prepareStatement(conn)) {
            var rs = stmt.executeQuery();
            rs.next();
            articles = rs.getString(1);
        } catch (SQLException e) {
            throw new UncheckedSQLException(e);
        }

        sendJson(exchange, 200, articles);
    }

    void getArticleHandler(HttpExchange exchange) throws IOException {
        var userId = getUserId(exchange);
        var slug = RouteParams.get(exchange).param("slug").orElseThrow();
        long viewer = userId == null ? 0 : userId;
        String article;
        try (var conn = db.getConnection();
             var stmt = SQLFragment.join("", List.of(
                     articleFullSelect(viewer),
                     SQLFragment.of("WHERE articles.slug = ?", List.of(slug))
             )).prepareStatement(conn)) {
            var rs = stmt.executeQuery();
            if (!rs.next()) {
                notFound(exchange);
                return;
            }
            article = rs.getString(1);
        } catch (SQLException e) {
            throw new UncheckedSQLException(e);
        }

        sendJson(exchange, 200, article);
    }

    record CreateArticleRequest(
            String title,
            String description,
            String body,
            List<String> tagList
    ) {
        static CreateArticleRequest fromJson(Json json) {
            return field(json, "article", article -> new CreateArticleRequest(
                    field(article, "title", nonEmptyString("title can't be empty")),
                    field(article, "description", nonEmptyString("description can't be empty")),
                    field(article, "body", nonEmptyString("body can't be empty")),
                    optionalNullableField(article, "tagList", array(nonEmptyString("tag can't be empty")), List.of())
            ));
        }
    }

    void createArticleHandler(HttpExchange exchange) throws IOException {
        var userId = getUserId(exchange);
        if (userId == null) {
            unauthenticated(exchange);
            return;
        }

        var body = JsonBody.read(exchange, CreateArticleRequest::fromJson);

        String article;
        try (var conn = db.getConnection()) {
            long articleId;
            conn.setAutoCommit(false);
            try {
                try (var stmt = SQLFragment.join("", List.of(
                        SQLFragment.of("""
                                INSERT INTO articles (id, slug, author_id, title, description, body)
                                SELECT n.id,\s"""),
                        slugify(body.title),
                        SQLFragment.of("""
                                 || '-' || n.id, ?, ?, ?, ?
                                  FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
                                RETURNING id
                                """, List.of(userId, body.title, body.description, body.body))
                )).prepareStatement(conn)) {
                    var rs = stmt.executeQuery();
                    rs.next();
                    articleId = rs.getLong("id");
                }

                if (!body.tagList.isEmpty()) {
                    var tags = conn.createArrayOf("text", body.tagList.toArray());
                    try (var stmt = conn.prepareStatement("""
                            INSERT INTO tags (name) SELECT DISTINCT unnest(?::text[]) ON CONFLICT (name) DO NOTHING
                            """)) {
                        stmt.setArray(1, tags);
                        stmt.execute();
                    }

                    try (var stmt = conn.prepareStatement("""
                            INSERT INTO article_tags (article_id, tag_id) SELECT ?, tags.id FROM tags WHERE tags.name = ANY(?::text[])
                            """)) {
                        stmt.setLong(1, articleId);
                        stmt.setArray(2, tags);
                        stmt.execute();
                    }
                }

                conn.commit();
            } catch (SQLException | RuntimeException e) {
                conn.rollback();
                throw e;
            } finally {
                conn.setAutoCommit(true);
            }

            article = findArticle(conn, userId, articleId);
        } catch (SQLException e) {
            throw new UncheckedSQLException(e);
        }

        if (article == null) {
            notFound(exchange);
            return;
        }
        sendJson(exchange, 201, article);
    }

    /// Fields that are absent or null are left unchanged.
    record UpdateArticleRequest(
            @Nullable String title,
            @Nullable String description,
            @Nullable String body
    ) {
        static UpdateArticleRequest fromJson(Json json) {
            return field(json, "article", article -> new UpdateArticleRequest(
                    optionalNullableField(article, "title", nonEmptyString("title can't be empty"), null),
                    optionalNullableField(article, "description", nonEmptyString("description can't be empty"), null),
                    optionalNullableField(article, "body", nonEmptyString("body can't be empty"), null)
            ));
        }
    }

    void updateArticleHandler(HttpExchange exchange) throws IOException {
        var userId = getUserId(exchange);
        if (userId == null) {
            unauthenticated(exchange);
            return;
        }

        var slug = RouteParams.get(exchange).param("slug").orElseThrow();
        var body = JsonBody.read(exchange, UpdateArticleRequest::fromJson);

        String article;
        try (var conn = db.getConnection()) {
            long articleId;
            try (var stmt = conn.prepareStatement("SELECT id, author_id FROM articles WHERE slug = ?")) {
                stmt.setString(1, slug);
                var rs = stmt.executeQuery();
                if (!rs.next()) {
                    notFound(exchange);
                    return;
                }
                if (rs.getLong("author_id") != userId) {
                    forbidden(exchange);
                    return;
                }
                articleId = rs.getLong("id");
            }

            try (var stmt = SQLFragment.join("", List.of(
                    SQLFragment.of("""
                            UPDATE articles SET title = COALESCE(?, title), description = COALESCE(?, description), body = COALESCE(?, body),
                                   slug = CASE WHEN ?::text IS NULL THEN slug ELSE\s""",
                            List.of(
                                    SettableParameter.ofString(body.title),
                                    SettableParameter.ofString(body.description),
                                    SettableParameter.ofString(body.body),
                                    SettableParameter.ofString(body.title)
                            )),
                    slugify(body.title),
                    SQLFragment.of("""
                             || '-' || id END,
                                   updated_at = now()
                             WHERE id = ?
                            """, List.of(articleId))
            )).prepareStatement(conn)) {
                stmt.execute();
            }

            article = findArticle(conn, userId, articleId);
        } catch (SQLException e) {
            throw new UncheckedSQLException(e);
        }

        if (article == null) {
            notFound(exchange);
            return;
        }
        sendJson(exchange, 200, article);
    }

    void deleteArticleHandler(HttpExchange exchange) throws IOException {
        var userId = getUserId(exchange);
        if (userId == null) {
            unauthenticated(exchange);
            return;
        }
        var slug = RouteParams.get(exchange).param("slug").orElseThrow();

        try (var conn = db.getConnection()) {
            long articleId;
            try (var stmt = conn.prepareStatement("SELECT id, author_id FROM articles WHERE slug = ?")) {
                stmt.setString(1, slug);
                var rs = stmt.executeQuery();
                if (!rs.next()) {
                    notFound(exchange);
                    return;
                }
                if (rs.getLong("author_id") != userId) {
                    forbidden(exchange);
                    return;
                }
                articleId = rs.getLong("id");
            }

            try (var stmt = conn.prepareStatement("DELETE FROM articles WHERE id = ?")) {
                stmt.setLong(1, articleId);
                stmt.execute();
            }
        } catch (SQLException e) {
            throw new UncheckedSQLException(e);
        }

        HttpExchanges.sendResponse(exchange, 204, Body.empty());
    }

    record CreateCommentRequest(String body) {
        static CreateCommentRequest fromJson(Json json) {
            return field(json, "comment", comment -> new CreateCommentRequest(
                    field(comment, "body", nonEmptyString("body can't be empty"))
            ));
        }
    }

    void addCommentsToArticleHandler(HttpExchange exchange) throws IOException {
        var userId = getUserId(exchange);
        if (userId == null) {
            unauthenticated(exchange);
            return;
        }

        var slug = RouteParams.get(exchange).param("slug").orElseThrow();

        var body = JsonBody.read(exchange, CreateCommentRequest::fromJson);

        String comment;
        try (var conn = db.getConnection()) {
            var articleId = articleIdForSlug(conn, slug);
            if (articleId == null) {
                notFound(exchange);
                return;
            }

            long commentId;
            try (var stmt = conn.prepareStatement("""
                    INSERT INTO comments (article_id, author_id, body) VALUES (?, ?, ?)
                    RETURNING id
                    """)) {
                stmt.setLong(1, articleId);
                stmt.setLong(2, userId);
                stmt.setString(3, body.body);
                var rs = stmt.executeQuery();
                rs.next();
                commentId = rs.getLong("id");
            }

            try (var stmt = SQLFragment.join("", List.of(
                    SQLFragment.of("SELECT json_build_object('comment', "),
                    commentJson(SQLFragment.of("false")),
                    SQLFragment.of("""
                            )
                              FROM comments
                              JOIN users ON users.id = comments.author_id
                             WHERE comments.id = ?
                            """, List.of(commentId))
            )).prepareStatement(conn)) {
                var rs = stmt.executeQuery();
                if (!rs.next()) {
                    unauthenticated(exchange);
                    return;
                }
                comment = rs.getString(1);
            }
        } catch (SQLException e) {
            throw new UncheckedSQLException(e);
        }

        sendJson(exchange, 201, comment);
    }

    void getCommentsFromArticleHandler(HttpExchange exchange) throws IOException {
        var userId = getUserId(exchange);
        var slug = RouteParams.get(exchange).param("slug").orElseThrow();

        // No row means no article with that slug.
        String comments;
        long viewer = userId == null ? 0 : userId;
        try (var conn = db.getConnection();
             var stmt = SQLFragment.join("", List.of(
                     SQLFragment.of("""
                             SELECT json_build_object('comments', COALESCE((
                                        SELECT json_agg(x.comment ORDER BY x.created_at DESC, x.id DESC) FROM (
                                            SELECT comments.id, comments.created_at,\s"""),
                     commentJson(SQLFragment.of(
                             "EXISTS (SELECT 1 FROM follows WHERE follows.follower_id = ? AND follows.followee_id = comments.author_id)",
                             List.of(viewer)
                     )),
                     SQLFragment.of("""
                              AS comment
                                              FROM comments JOIN users ON users.id = comments.author_id
                                             WHERE comments.article_id = articles.id
                                             ORDER BY comments.created_at DESC, comments.id DESC
                                             LIMIT 100
                                        ) x
                                    ), '[]'::json))
                               FROM articles WHERE articles.slug = ?
                             """, List.of(slug))
             )).prepareStatement(conn)) {
            var rs = stmt.executeQuery();
            if (!rs.next()) {
                notFound(exchange);
                return;
            }
            comments = rs.getString(1);
        } catch (SQLException e) {
            throw new UncheckedSQLException(e);
        }

        sendJson(exchange, 200, comments);
    }

    void deleteCommentHandler(HttpExchange exchange) throws IOException {
        var userId = getUserId(exchange);
        if (userId == null) {
            unauthenticated(exchange);
            return;
        }
        var routeParams = RouteParams.get(exchange);
        var slug = routeParams.param("slug").orElseThrow();
        long commentId;
        try {
            commentId = Long.parseLong(routeParams.param("commentId").orElseThrow());
        } catch (NumberFormatException e) {
            notFound(exchange);
            return;
        }

        try (var conn = db.getConnection()) {
            try (var stmt = conn.prepareStatement("""
                    SELECT comments.author_id FROM comments JOIN articles ON articles.id = comments.article_id
                     WHERE comments.id = ? AND articles.slug = ?
                    """)) {
                stmt.setLong(1, commentId);
                stmt.setString(2, slug);
                var rs = stmt.executeQuery();
                if (!rs.next()) {
                    notFound(exchange);
                    return;
                }
                if (rs.getLong("author_id") != userId) {
                    forbidden(exchange);
                    return;
                }
            }

            try (var stmt = conn.prepareStatement("DELETE FROM comments WHERE id = ?")) {
                stmt.setLong(1, commentId);
                stmt.execute();
            }
        } catch (SQLException e) {
            throw new UncheckedSQLException(e);
        }

        HttpExchanges.sendResponse(exchange, 204, Body.empty());
    }

    void favoriteArticleHandler(HttpExchange exchange) throws IOException {
        favoriteOrUnfavorite(exchange, true);
    }

    void unfavoriteArticleHandler(HttpExchange exchange) throws IOException {
        favoriteOrUnfavorite(exchange, false);
    }

    void favoriteOrUnfavorite(HttpExchange exchange, boolean favorite) throws IOException {
        var userId = getUserId(exchange);
        if (userId == null) {
            unauthenticated(exchange);
            return;
        }

        var slug = RouteParams.get(exchange).param("slug").orElseThrow();

        String article;
        try (var conn = db.getConnection()) {
            var articleId = articleIdForSlug(conn, slug);
            if (articleId == null) {
                notFound(exchange);
                return;
            }

            if (favorite) {
                try (var stmt = conn.prepareStatement("""
                        INSERT INTO favorites (user_id, article_id) VALUES (?, ?) ON CONFLICT DO NOTHING
                        """)) {
                    stmt.setLong(1, userId);
                    stmt.setLong(2, articleId);
                    stmt.execute();
                }
            }
            else {
                try (var stmt = conn.prepareStatement("""
                        DELETE FROM favorites WHERE user_id = ? AND article_id = ?
                        """)) {
                    stmt.setLong(1, userId);
                    stmt.setLong(2, articleId);
                    stmt.execute();
                }
            }

            article = findArticle(conn, userId, articleId);
        } catch (SQLException e) {
            throw new UncheckedSQLException(e);
        }

        if (article == null) {
            notFound(exchange);
            return;
        }
        sendJson(exchange, 200, article);
    }

    void getTagsHandler(HttpExchange exchange) throws IOException {
        var tags = Json.arrayBuilder();
        try (var conn = db.getConnection();
             var stmt = conn.prepareStatement("""
                     SELECT name FROM tags ORDER BY name
                     """)) {
            var rs = stmt.executeQuery();
            while (rs.next()) {
                tags.add(Json.of(rs.getString("name")));
            }
        } catch (SQLException e) {
            throw new UncheckedSQLException(e);
        }

        HttpExchanges.sendResponse(exchange, 200, JsonBody.of(Json.objectBuilder().put("tags", tags)));
    }

    public void register(RegexRouter.Builder builder) {
        builder
                .post("/api/users", this::registerHandler)
                .post("/api/users/login", this::loginHandler)
                .get("/api/user", this::getCurrentUserHandler)
                .put("/api/user", this::updateUserHandler)
                .get("/api/profiles/(?<username>[^/]+)", this::getProfileHandler)
                .post("/api/profiles/(?<username>[^/]+)/follow", this::followUserHandler)
                .delete("/api/profiles/(?<username>[^/]+)/follow", this::unfollowUserHandler)
                .get("/api/articles", this::listArticlesHandler)
                .get("/api/articles/feed", this::feedArticlesHandler)
                .get("/api/articles/(?<slug>[^/]+)", this::getArticleHandler)
                .post("/api/articles", this::createArticleHandler)
                .put("/api/articles/(?<slug>[^/]+)", this::updateArticleHandler)
                .delete("/api/articles/(?<slug>[^/]+)", this::deleteArticleHandler)
                .post("/api/articles/(?<slug>[^/]+)/comments", this::addCommentsToArticleHandler)
                .get("/api/articles/(?<slug>[^/]+)/comments", this::getCommentsFromArticleHandler)
                .delete("/api/articles/(?<slug>[^/]+)/comments/(?<commentId>[^/]+)", this::deleteCommentHandler)
                .post("/api/articles/(?<slug>[^/]+)/favorite", this::favoriteArticleHandler)
                .delete("/api/articles/(?<slug>[^/]+)/favorite", this::unfavoriteArticleHandler)
                .get("/api/tags", this::getTagsHandler);
    }
}
