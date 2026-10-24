package dev.mccue.microhttp.realworld;

import com.auth0.jwt.JWT;
import com.auth0.jwt.JWTVerifier;
import com.auth0.jwt.algorithms.Algorithm;
import com.auth0.jwt.exceptions.JWTVerificationException;
import dev.mccue.jdbc.SQLFragment;
import dev.mccue.json.*;
import dev.mccue.microhttp.handler.Handler;
import dev.mccue.microhttp.handler.IntoResponse;
import dev.mccue.microhttp.handler.RouteHandler;
import dev.mccue.microhttp.json.JsonResponse;
import dev.mccue.urlparameters.UrlParameters;
import io.vertx.pgclient.PgException;
import io.vertx.sqlclient.Row;
import io.vertx.sqlclient.RowSet;
import io.vertx.sqlclient.SqlClient;
import io.vertx.sqlclient.Tuple;
import org.bouncycastle.crypto.generators.OpenBSDBCrypt;
import org.jetbrains.annotations.Nullable;
import org.microhttp.Header;
import org.microhttp.Request;
import org.microhttp.Response;

import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.time.Duration;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static dev.mccue.json.JsonDecoder.*;

public final class RealWorldAPI {
    private final SqlClient db;
    private final Algorithm jwtAlgorithm;
    private final JWTVerifier jwtVerifier;

    RealWorldAPI(SqlClient db, String jwtSecret) {
        this.db = db;
        this.jwtAlgorithm = Algorithm.HMAC256(Objects.requireNonNull(jwtSecret, "JWT_SECRET is required"));
        // HS256 only, signature and exp checked on every request.
        this.jwtVerifier = JWT.require(jwtAlgorithm)
                .withClaimPresence("exp")
                .build();
    }

    /// An Authorization header that is present but isn't a valid token. 401, even where auth is optional.
    static final class InvalidTokenException extends RuntimeException implements IntoResponse {
        @Override
        public Response intoResponse() {
            return unauthenticated().intoResponse();
        }
    }

    /// A request that is well-formed JSON but breaks a rule (empty field, bad limit, ...). 422.
    static final class UnprocessableException extends RuntimeException implements IntoResponse {
        UnprocessableException(String message) {
            super(message);
        }

        @Override
        public Response intoResponse() {
            return error(422, getMessage()).intoResponse();
        }
    }

    // The SQL is written with ? placeholders; the Postgres protocol numbers them ($1, $2, ...).
    // Each statement's text is converted once.
    private static final Map<String, String> NUMBERED_SQL = new ConcurrentHashMap<>();

    static String numberPlaceholders(String sql) {
        var numbered = new StringBuilder(sql.length() + 16);
        int next = 1;
        for (int i = 0; i < sql.length(); i++) {
            char c = sql.charAt(i);
            if (c == '?') {
                numbered.append('$').append(next++);
            }
            else {
                numbered.append(c);
            }
        }
        return numbered.toString();
    }

    /// Runs one statement. The Vert.x client pipelines it onto a shared connection; this virtual thread
    /// parks in await() until Postgres answers.
    RowSet<Row> query(String sql, Tuple parameters) {
        return db.preparedQuery(NUMBERED_SQL.computeIfAbsent(sql, RealWorldAPI::numberPlaceholders))
                .execute(parameters)
                .await();
    }

    RowSet<Row> query(SQLFragment fragment) {
        return query(fragment.sql(), Tuple.from(fragment.parameters()));
    }

    static @Nullable Row firstRow(RowSet<Row> rows) {
        var iterator = rows.iterator();
        return iterator.hasNext() ? iterator.next() : null;
    }

    static boolean isUniqueViolation(PgException e) {
        return "23505".equals(e.getSqlState());
    }

    @Nullable String getPresentedToken(Request request) {
        var authHeader = request.header("Authorization");
        if (authHeader == null) {
            return null;
        }
        if (!authHeader.startsWith("Token ")) {
            throw new InvalidTokenException();
        }
        return authHeader.substring("Token ".length()).trim();
    }

    /// The user id from the token, or null if there is no Authorization header.
    @Nullable Long getUserId(Request request) {
        var token = getPresentedToken(request);
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

    static JsonResponse error(int status, String message) {
        return new JsonResponse(
                status,
                Json.objectBuilder()
                        .put("errors", Json.objectBuilder()
                                .put("body", Json.arrayBuilder()
                                        .add(message)))
        );
    }

    static JsonResponse unauthenticated() {
        return error(401, "unauthenticated");
    }

    static JsonResponse notFound() {
        return error(404, "not found");
    }

    static JsonResponse forbidden() {
        return error(403, "forbidden");
    }

    static final IntoResponse NO_CONTENT = () -> new Response(204, "No Content", List.of(), new byte[0]);

    static <T> T readBody(Request request, JsonDecoder<T> decoder) {
        return decoder.decode(Json.readString(new String(request.body(), StandardCharsets.UTF_8)));
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

    private static final List<Header> JSON_HEADERS = List.of(new Header("Content-Type", "application/json"));

    /// Sends JSON text that Postgres already built, as is.
    static IntoResponse json(int status, String json) {
        var bytes = json.getBytes(StandardCharsets.UTF_8);
        return () -> new Response(status, status == 201 ? "Created" : "OK", JSON_HEADERS, bytes);
    }

    /// The single text column of the first row, or null if there are no rows.
    static @Nullable String firstText(RowSet<Row> rows) {
        var row = firstRow(rows);
        return row == null ? null : row.getString(0);
    }

    static JsonObject.Builder userJson(Row row, String token) {
        return Json.objectBuilder()
                .put("email", row.getString("email"))
                .put("token", token)
                .put("username", row.getString("username"))
                .put("bio", row.getString("bio"))
                .put("image", row.getString("image"));
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

    /// {"article": Article} as text.
    private static SQLFragment articleFullSelect(long viewer) {
        return SQLFragment.join("", List.of(
                SQLFragment.of("SELECT json_build_object('article', "),
                articleJson(true, viewer),
                SQLFragment.of("""
                        )::text
                          FROM articles
                          JOIN users ON users.id = articles.author_id
                        """)
        ));
    }

    /// The slug text for a title (the article id is appended separately).
    private static SQLFragment slugify(@Nullable String title) {
        return SQLFragment.of(
                "trim(both '-' from lower(regexp_replace(?, '[^A-Za-z0-9]+', '-', 'g')))",
                Collections.singletonList(title)
        );
    }

    /// {"article": Article} for the article with this id, or null if there isn't one.
    @Nullable String findArticle(long viewer, long articleId) {
        return firstText(query(SQLFragment.join("", List.of(
                articleFullSelect(viewer),
                SQLFragment.of("WHERE articles.id = ?", List.of(articleId))
        ))));
    }

    /// The id of the article with this slug, or null.
    @Nullable Long articleIdForSlug(String slug) {
        var row = firstRow(query("SELECT id FROM articles WHERE slug = ?", Tuple.of(slug)));
        return row == null ? null : row.getLong("id");
    }

    /// {"articles": [...], "articlesCount": n} from a page of articleListSelect rows and a capped count,
    /// both in one statement.
    String articleList(SQLFragment page, SQLFragment count) {
        return firstText(query(SQLFragment.join("", List.of(
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
                        )::text
                        """)
        ))));
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

    IntoResponse registerHandler(Matcher routeMatch, Request request) {
        var body = readBody(request, RegisterRequest::fromJson);
        if (passwordTooLong(body.password)) {
            return error(422, "password is too long");
        }
        var passwordHash = hashPassword(body.password);

        Row row;
        try {
            row = firstRow(query("""
                    INSERT INTO users (username, email, password_hash) VALUES (?, ?, ?)
                    RETURNING id, username, email, bio, image
                    """, Tuple.of(body.username, body.email, passwordHash)));
        } catch (PgException e) {
            if (isUniqueViolation(e)) {
                return error(422, "username or email already taken");
            }
            throw e;
        }

        return new JsonResponse(201, Json.objectBuilder().put("user", userJson(row, getToken(row.getLong("id")))));
    }

    record LoginRequest(String email, String password) {
        static LoginRequest fromJson(Json json) {
            return field(json, "user", user -> new LoginRequest(
                    field(user, "email", nonEmptyString("email can't be empty")),
                    field(user, "password", nonEmptyString("password can't be empty"))
            ));
        }
    }

    IntoResponse loginHandler(Matcher routeMatch, Request request) {
        var body = readBody(request, LoginRequest::fromJson);

        var row = firstRow(query("""
                SELECT id, username, email, bio, image, password_hash FROM users WHERE email = ?
                """, Tuple.of(body.email)));
        if (row == null) {
            return error(401, "invalid email or password");
        }

        if (passwordTooLong(body.password)
            || !passwordMatches(body.password, row.getString("password_hash"))) {
            return error(401, "invalid email or password");
        }

        return new JsonResponse(200, Json.objectBuilder().put("user", userJson(row, getToken(row.getLong("id")))));
    }

    IntoResponse getCurrentUserHandler(Matcher routeMatch, Request request) {
        var userId = getUserId(request);
        if (userId == null) {
            return unauthenticated();
        }

        var row = firstRow(query("""
                SELECT id, username, email, bio, image FROM users WHERE id = ?
                """, Tuple.of(userId)));
        if (row == null) {
            return unauthenticated();
        }

        return new JsonResponse(200, Json.objectBuilder().put("user", userJson(row, getPresentedToken(request))));
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

    IntoResponse updateUserHandler(Matcher routeMatch, Request request) {
        var userId = getUserId(request);
        if (userId == null) {
            return unauthenticated();
        }
        var body = readBody(request, UpdateUserRequest::fromJson);

        String passwordHash = null;
        if (body.password != null) {
            if (passwordTooLong(body.password)) {
                return error(422, "password is too long");
            }
            passwordHash = hashPassword(body.password);
        }

        Row row;
        try {
            row = firstRow(query("""
                    UPDATE users SET email = COALESCE(?, email), username = COALESCE(?, username),
                                     password_hash = COALESCE(?, password_hash), bio = COALESCE(?, bio), image = COALESCE(?, image)
                     WHERE id = ?
                    RETURNING id, username, email, bio, image
                    """, Tuple.of(body.email, body.username, passwordHash, body.bio, body.image, userId)));
        } catch (PgException e) {
            if (isUniqueViolation(e)) {
                return error(422, "username or email already taken");
            }
            throw e;
        }
        if (row == null) {
            return unauthenticated();
        }

        return new JsonResponse(200, Json.objectBuilder().put("user", userJson(row, getPresentedToken(request))));
    }

    IntoResponse getProfileHandler(Matcher routeMatch, Request request) {
        var userId = getUserId(request);
        var username = routeMatch.group("username");

        var profile = firstText(query("""
                SELECT json_build_object('profile', json_build_object(
                           'username', users.username,
                           'bio', users.bio,
                           'image', users.image,
                           'following', EXISTS (SELECT 1 FROM follows WHERE follows.follower_id = ? AND follows.followee_id = users.id)
                       ))::text
                  FROM users WHERE users.username = ?
                """, Tuple.of(userId == null ? 0L : userId, username)));
        if (profile == null) {
            return notFound();
        }

        return json(200, profile);
    }

    IntoResponse followUserHandler(Matcher routeMatch, Request request) {
        return followOrUnfollow(routeMatch, request, true);
    }

    IntoResponse unfollowUserHandler(Matcher routeMatch, Request request) {
        return followOrUnfollow(routeMatch, request, false);
    }

    IntoResponse followOrUnfollow(Matcher routeMatch, Request request, boolean follow) {
        var userId = getUserId(request);
        if (userId == null) {
            return unauthenticated();
        }
        var username = routeMatch.group("username");

        var row = firstRow(query("""
                SELECT users.id, json_build_object('profile', json_build_object(
                           'username', users.username,
                           'bio', users.bio,
                           'image', users.image,
                           'following', ?::boolean
                       ))::text AS profile
                  FROM users WHERE users.username = ?
                """, Tuple.of(follow, username)));
        if (row == null) {
            return notFound();
        }

        if (follow) {
            query("""
                    INSERT INTO follows (follower_id, followee_id) VALUES (?, ?) ON CONFLICT DO NOTHING
                    """, Tuple.of(userId, row.getLong("id")));
        }
        else {
            query("""
                    DELETE FROM follows WHERE follower_id = ? AND followee_id = ?
                    """, Tuple.of(userId, row.getLong("id")));
        }

        return json(200, row.getString("profile"));
    }

    IntoResponse listArticlesHandler(Matcher routeMatch, Request request) {
        var userId = getUserId(request);
        var urlParameters = UrlParameters.parse(URI.create(request.uri()));
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

        return json(200, articleList(page, count));
    }

    IntoResponse feedArticlesHandler(Matcher routeMatch, Request request) {
        var userId = getUserId(request);
        if (userId == null) {
            return unauthenticated();
        }
        var urlParameters = UrlParameters.parse(URI.create(request.uri()));
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

        return json(200, articleList(page, count));
    }

    IntoResponse getArticleHandler(Matcher routeMatch, Request request) {
        var userId = getUserId(request);
        var slug = routeMatch.group("slug");
        long viewer = userId == null ? 0 : userId;

        var article = firstText(query(SQLFragment.join("", List.of(
                articleFullSelect(viewer),
                SQLFragment.of("WHERE articles.slug = ?", List.of(slug))
        ))));
        if (article == null) {
            return notFound();
        }

        return json(200, article);
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

    IntoResponse createArticleHandler(Matcher routeMatch, Request request) {
        var userId = getUserId(request);
        if (userId == null) {
            return unauthenticated();
        }

        var body = readBody(request, CreateArticleRequest::fromJson);
        var tags = body.tagList.toArray(new String[0]);

        // The pipelined client has no connection of its own to hold a transaction on, so the article and its
        // tag links go in as one statement (Postgres runs each statement atomically). The tags themselves go in
        // first; a tag left behind by a failed article insert is harmless.
        if (tags.length > 0) {
            query("INSERT INTO tags (name) SELECT DISTINCT unnest(?::text[]) ON CONFLICT (name) DO NOTHING", Tuple.of(tags));
        }
        long articleId = query(SQLFragment.join("", List.of(
                SQLFragment.of("""
                        WITH created AS (
                            INSERT INTO articles (id, slug, author_id, title, description, body)
                            SELECT n.id,\s"""),
                slugify(body.title),
                SQLFragment.of("""
                         || '-' || n.id, ?, ?, ?, ?
                              FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
                            RETURNING id
                        ), linked AS (
                            INSERT INTO article_tags (article_id, tag_id)
                            SELECT created.id, tags.id FROM created, tags WHERE tags.name = ANY(?::text[])
                        )
                        SELECT id FROM created
                        """, List.of(userId, body.title, body.description, body.body, tags))
        ))).iterator().next().getLong("id");

        var article = findArticle(userId, articleId);
        if (article == null) {
            return notFound();
        }
        return json(201, article);
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

    IntoResponse updateArticleHandler(Matcher routeMatch, Request request) {
        var userId = getUserId(request);
        if (userId == null) {
            return unauthenticated();
        }

        var slug = routeMatch.group("slug");
        var body = readBody(request, UpdateArticleRequest::fromJson);

        var row = firstRow(query("SELECT id, author_id FROM articles WHERE slug = ?", Tuple.of(slug)));
        if (row == null) {
            return notFound();
        }
        if (row.getLong("author_id") != userId.longValue()) {
            return forbidden();
        }
        long articleId = row.getLong("id");

        query(SQLFragment.join("", List.of(
                SQLFragment.of("""
                        UPDATE articles SET title = COALESCE(?, title), description = COALESCE(?, description), body = COALESCE(?, body),
                               slug = CASE WHEN ?::text IS NULL THEN slug ELSE\s""",
                        Arrays.asList(body.title, body.description, body.body, body.title)),
                slugify(body.title),
                SQLFragment.of("""
                         || '-' || id END,
                               updated_at = now()
                         WHERE id = ?
                        """, List.of(articleId))
        )));

        var article = findArticle(userId, articleId);
        if (article == null) {
            return notFound();
        }
        return json(200, article);
    }

    IntoResponse deleteArticleHandler(Matcher routeMatch, Request request) {
        var userId = getUserId(request);
        if (userId == null) {
            return unauthenticated();
        }
        var slug = routeMatch.group("slug");

        var row = firstRow(query("SELECT id, author_id FROM articles WHERE slug = ?", Tuple.of(slug)));
        if (row == null) {
            return notFound();
        }
        if (row.getLong("author_id") != userId.longValue()) {
            return forbidden();
        }

        query("DELETE FROM articles WHERE id = ?", Tuple.of(row.getLong("id")));

        return NO_CONTENT;
    }

    record CreateCommentRequest(String body) {
        static CreateCommentRequest fromJson(Json json) {
            return field(json, "comment", comment -> new CreateCommentRequest(
                    field(comment, "body", nonEmptyString("body can't be empty"))
            ));
        }
    }

    IntoResponse addCommentsToArticleHandler(Matcher routeMatch, Request request) {
        var userId = getUserId(request);
        if (userId == null) {
            return unauthenticated();
        }

        var slug = routeMatch.group("slug");

        var body = readBody(request, CreateCommentRequest::fromJson);

        var articleId = articleIdForSlug(slug);
        if (articleId == null) {
            return notFound();
        }

        long commentId = query("""
                INSERT INTO comments (article_id, author_id, body) VALUES (?, ?, ?)
                RETURNING id
                """, Tuple.of(articleId, userId, body.body)).iterator().next().getLong("id");

        var comment = firstText(query(SQLFragment.join("", List.of(
                SQLFragment.of("SELECT json_build_object('comment', "),
                commentJson(SQLFragment.of("false")),
                SQLFragment.of("""
                        )::text
                          FROM comments
                          JOIN users ON users.id = comments.author_id
                         WHERE comments.id = ?
                        """, List.of(commentId))
        ))));
        if (comment == null) {
            return unauthenticated();
        }

        return json(201, comment);
    }

    IntoResponse getCommentsFromArticleHandler(Matcher routeMatch, Request request) {
        var userId = getUserId(request);
        var slug = routeMatch.group("slug");

        // No row means no article with that slug.
        long viewer = userId == null ? 0 : userId;
        var comments = firstText(query(SQLFragment.join("", List.of(
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
                               ), '[]'::json))::text
                          FROM articles WHERE articles.slug = ?
                        """, List.of(slug))
        ))));
        if (comments == null) {
            return notFound();
        }

        return json(200, comments);
    }

    IntoResponse deleteCommentHandler(Matcher routeMatch, Request request) {
        var userId = getUserId(request);
        if (userId == null) {
            return unauthenticated();
        }
        var slug = routeMatch.group("slug");
        long commentId;
        try {
            commentId = Long.parseLong(routeMatch.group("commentId"));
        } catch (NumberFormatException e) {
            return notFound();
        }

        var row = firstRow(query("""
                SELECT comments.author_id FROM comments JOIN articles ON articles.id = comments.article_id
                 WHERE comments.id = ? AND articles.slug = ?
                """, Tuple.of(commentId, slug)));
        if (row == null) {
            return notFound();
        }
        if (row.getLong("author_id") != userId.longValue()) {
            return forbidden();
        }

        query("DELETE FROM comments WHERE id = ?", Tuple.of(commentId));

        return NO_CONTENT;
    }

    IntoResponse favoriteArticleHandler(Matcher routeMatch, Request request) {
        return favoriteOrUnfavorite(routeMatch, request, true);
    }

    IntoResponse unfavoriteArticleHandler(Matcher routeMatch, Request request) {
        return favoriteOrUnfavorite(routeMatch, request, false);
    }

    IntoResponse favoriteOrUnfavorite(Matcher routeMatch, Request request, boolean favorite) {
        var userId = getUserId(request);
        if (userId == null) {
            return unauthenticated();
        }

        var slug = routeMatch.group("slug");

        var articleId = articleIdForSlug(slug);
        if (articleId == null) {
            return notFound();
        }

        if (favorite) {
            query("""
                    INSERT INTO favorites (user_id, article_id) VALUES (?, ?) ON CONFLICT DO NOTHING
                    """, Tuple.of(userId, articleId));
        }
        else {
            query("""
                    DELETE FROM favorites WHERE user_id = ? AND article_id = ?
                    """, Tuple.of(userId, articleId));
        }

        var article = findArticle(userId, articleId);
        if (article == null) {
            return notFound();
        }
        return json(200, article);
    }

    IntoResponse getTagsHandler(Matcher routeMatch, Request request) {
        var tags = Json.arrayBuilder();
        for (var row : query("SELECT name FROM tags ORDER BY name", Tuple.tuple())) {
            tags.add(Json.of(row.getString("name")));
        }

        return new JsonResponse(200, Json.objectBuilder().put("tags", tags));
    }

    public List<Handler> handlers() {
        return List.of(
                RouteHandler.of("POST", Pattern.compile("/api/users"), this::registerHandler),
                RouteHandler.of("POST", Pattern.compile("/api/users/login"), this::loginHandler),
                RouteHandler.of("GET", Pattern.compile("/api/user"), this::getCurrentUserHandler),
                RouteHandler.of("PUT", Pattern.compile("/api/user"), this::updateUserHandler),
                RouteHandler.of("GET", Pattern.compile("/api/profiles/(?<username>[^/]+)"), this::getProfileHandler),
                RouteHandler.of("POST", Pattern.compile("/api/profiles/(?<username>[^/]+)/follow"), this::followUserHandler),
                RouteHandler.of("DELETE", Pattern.compile("/api/profiles/(?<username>[^/]+)/follow"), this::unfollowUserHandler),
                RouteHandler.of("GET", Pattern.compile("/api/articles"), this::listArticlesHandler),
                RouteHandler.of("GET", Pattern.compile("/api/articles/feed"), this::feedArticlesHandler),
                RouteHandler.of("GET", Pattern.compile("/api/articles/(?<slug>[^/]+)"), this::getArticleHandler),
                RouteHandler.of("POST", Pattern.compile("/api/articles"), this::createArticleHandler),
                RouteHandler.of("PUT", Pattern.compile("/api/articles/(?<slug>[^/]+)"), this::updateArticleHandler),
                RouteHandler.of("DELETE", Pattern.compile("/api/articles/(?<slug>[^/]+)"), this::deleteArticleHandler),
                RouteHandler.of("POST", Pattern.compile("/api/articles/(?<slug>[^/]+)/comments"), this::addCommentsToArticleHandler),
                RouteHandler.of("GET", Pattern.compile("/api/articles/(?<slug>[^/]+)/comments"), this::getCommentsFromArticleHandler),
                RouteHandler.of("DELETE", Pattern.compile("/api/articles/(?<slug>[^/]+)/comments/(?<commentId>[^/]+)"), this::deleteCommentHandler),
                RouteHandler.of("POST", Pattern.compile("/api/articles/(?<slug>[^/]+)/favorite"), this::favoriteArticleHandler),
                RouteHandler.of("DELETE", Pattern.compile("/api/articles/(?<slug>[^/]+)/favorite"), this::unfavoriteArticleHandler),
                RouteHandler.of("GET", Pattern.compile("/api/tags"), this::getTagsHandler)
        );
    }
}
