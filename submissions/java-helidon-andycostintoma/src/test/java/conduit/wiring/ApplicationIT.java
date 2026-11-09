package conduit.wiring;

import static conduit.generated.postgres.jooq.Tables.ARTICLES;
import static conduit.generated.postgres.jooq.Tables.COMMENTS;
import static conduit.generated.postgres.jooq.Tables.FAVORITES;
import static conduit.generated.postgres.jooq.Tables.FOLLOWS;
import static conduit.generated.postgres.jooq.Tables.TAGS;
import static conduit.generated.postgres.jooq.Tables.USERS;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.ObjectMapper;
import conduit.adapters.outbound.postgres.jooq.JooqUnitOfWork;
import conduit.adapters.outbound.postgres.jooq.article.JooqArticleReader;
import conduit.domain.Article;
import conduit.domain.Comment;
import conduit.domain.User;
import conduit.errors.Conflict;
import conduit.errors.Forbidden;
import conduit.errors.NotFound;
import conduit.usecases.commands.AddComment;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.sql.DriverManager;
import java.util.List;
import java.util.function.Consumer;
import org.jooq.DSLContext;
import org.jooq.SQLDialect;
import org.jooq.impl.DSL;
import org.jooq.impl.SQLDataType;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.testcontainers.postgresql.PostgreSQLContainer;

class ApplicationIT {
    private static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer(
        "postgres:18.6-bookworm").withDatabaseName("conduit").withUsername("postgres")
        .withPassword("postgres").withInitScript("schema.sql").withCommand("postgres");
    private static final ObjectMapper JSON = new ObjectMapper();
    private static Application application;
    private static HttpClient http;

    @BeforeAll
    static void start() throws Exception {
        POSTGRES.start();
        try {
            execute("CREATE ROLE conduit LOGIN PASSWORD 'conduit'");
            execute("GRANT USAGE ON SCHEMA public TO conduit");
            execute(
                "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO conduit");
            execute("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO conduit");
            var databaseUrl = "postgresql://conduit:conduit@" + POSTGRES.getHost() + ":"
                + POSTGRES.getMappedPort(5432) + "/conduit";
            application = Application.start(new Config(databaseUrl, "127.0.0.1", 0));
            http = HttpClient.newHttpClient();
        } catch (Exception | Error failure) {
            POSTGRES.stop();
            throw failure;
        }
    }

    @AfterAll
    static void stop() {
        try {
            if (http != null) {
                http.close();
            }
            if (application != null) {
                application.close();
            }
        } finally {
            POSTGRES.stop();
        }
    }

    @BeforeEach
    void clearTags() throws Exception {
        execute(sql -> sql.truncate(TAGS).cascade().execute());
    }

    @Test
    void returnsEmptyTagsWithoutAuthentication() throws Exception {
        var response = get("/api/tags");

        assertEquals(200, response.statusCode());
        assertTrue(response.headers().firstValue("content-type").orElseThrow()
            .startsWith("application/json"));
        assertEquals(JSON.readTree("{\"tags\":[]}"), JSON.readTree(response.body()));
    }

    @Test
    void returnsSortedTagsAndReadsCommittedChangesOnEveryRequest() throws Exception {
        execute(sql -> sql.insertInto(TAGS, TAGS.NAME).values("zebra").values("apple").execute());
        assertEquals(JSON.readTree("{\"tags\":[\"apple\",\"zebra\"]}"),
            JSON.readTree(get("/api/tags").body()));

        execute(sql -> sql.insertInto(TAGS, TAGS.NAME).values("middle").execute());

        assertEquals(JSON.readTree("{\"tags\":[\"apple\",\"middle\",\"zebra\"]}"),
            JSON.readTree(get("/api/tags").body()));
    }

    @Test
    void returnsInternalErrorWithoutLeakingDatabaseDetails() throws Exception {
        execute("REVOKE SELECT ON tags FROM conduit");
        try {
            var response = get("/api/tags");

            assertEquals(500, response.statusCode());
            assertEquals(JSON.readTree("{\"errors\":{\"body\":[\"Internal server error\"]}}"),
                JSON.readTree(response.body()));
            assertFalse(response.body().contains("permission denied"));
        } finally {
            execute("GRANT SELECT ON tags TO conduit");
        }
    }

    @Test
    void returnsNotFoundForUnknownRoutes() throws Exception {
        assertEquals(404, get("/api/unknown").statusCode());
    }

    @Test
    void rejectsNonObjectAndTrailingJsonDocuments() throws Exception {
        for (var body : List.of("null", "[]", "{}", "{\"user\":null}", "{\"user\":[]}",
            "{\"user\":true}",
            "{\"user\":{\"username\":42,\"email\":\"email\",\"password\":\"secret\"}}",
            """
                {"user":{"username":"trailing-json","email":"trailing@example.com","password":"secret"}} null
                """)) {
            var response = http
                .send(
                    HttpRequest
                        .newBuilder(
                            URI.create("http://127.0.0.1:" + application.port() + "/api/users"))
                        .POST(HttpRequest.BodyPublishers.ofString(body)).build(),
                    HttpResponse.BodyHandlers.ofString());
            assertEquals(422, response.statusCode(), body);
            assertTrue(JSON.readTree(response.body()).path("errors").path("body").isArray());
        }
    }

    @Test
    void rejectsMalformedRequestFieldsAndAuthenticatesBeforeParsingProtectedBodies()
        throws Exception {
        var registration = http.send(HttpRequest
            .newBuilder(URI.create("http://127.0.0.1:" + application.port() + "/api/users"))
            .POST(HttpRequest.BodyPublishers.ofString(
                """
                    {"user":{"username":"request-shape","email":"request-shape@example.com","password":"secret"}}
                    """))
            .build(), HttpResponse.BodyHandlers.ofString());
        assertEquals(201, registration.statusCode());
        var token = JSON.readTree(registration.body()).path("user").path("token").textValue();
        record InvalidBody(
            String method,
            String path,
            String body
        ) {
        }
        var cases = List.of(new InvalidBody("PUT", "/api/user", "{\"user\":{\"bio\":123}}"),
            new InvalidBody("PUT", "/api/user", "{\"user\":{\"image\":true}}"),
            new InvalidBody("PUT", "/api/user", "{\"user\":{}} null"),
            new InvalidBody("POST", "/api/articles",
                """
                    {"article":{"title":"Title","description":"Description","body":"Body","tagList":[123]}}
                    """),
            new InvalidBody("POST", "/api/articles",
                """
                    {"article":{"title":"Title","description":"Description","body":"Body","tagList":[true]}}
                    """),
            new InvalidBody("POST", "/api/articles",
                """
                    {"article":{"title":"Title","description":"Description","body":"Body","tagList":[null]}}
                    """),
            new InvalidBody("PUT", "/api/articles/missing", "{\"article\":{\"title\":123}}"),
            new InvalidBody("POST", "/api/articles/missing/comments",
                "{\"comment\":{\"body\":null}}"),
            new InvalidBody("POST", "/api/articles/missing/comments",
                "{\"comment\":{\"body\":true}}"),
            new InvalidBody("POST", "/api/articles/missing/comments",
                "{\"comment\":{\"body\":\"text\"}} {}"));
        for (var invalid : cases) {
            var uri = URI.create("http://127.0.0.1:" + application.port() + invalid.path());
            var authenticated = http
                .send(
                    HttpRequest.newBuilder(uri).header("Authorization", "Token " + token)
                        .method(invalid.method(),
                            HttpRequest.BodyPublishers.ofString(invalid.body()))
                        .build(),
                    HttpResponse.BodyHandlers.ofString());
            assertEquals(422, authenticated.statusCode(), invalid.path() + " " + invalid.body());
            assertTrue(JSON.readTree(authenticated.body()).path("errors").path("body").isArray());

            var anonymous = http.send(HttpRequest.newBuilder(uri)
                .method(invalid.method(), HttpRequest.BodyPublishers.ofString("not JSON")).build(),
                HttpResponse.BodyHandlers.ofString());
            assertEquals(401, anonymous.statusCode(), invalid.path());
        }
    }

    @Test
    void rejectedTransactionRollsBackEarlierWrites() throws Exception {
        try (var connection = DriverManager.getConnection(POSTGRES.getJdbcUrl(),
            POSTGRES.getUsername(), POSTGRES.getPassword())) {
            var sql = DSL.using(connection, SQLDialect.POSTGRES);
            var unit = new JooqUnitOfWork(sql);
            assertThrows(Forbidden.class, () -> unit.run(repositories -> {
                repositories.users().insert(User.reconstitute(new User.Props(0, "rolled-back",
                    "rolled-back@example.com", "hash", null, null)));
                throw new Forbidden("Rejected after write");
            }));
            assertEquals(0, sql.fetchCount(USERS, USERS.USERNAME.eq("rolled-back")));
            unit.run(repositories -> repositories.users().insert(User.reconstitute(
                new User.Props(0, "committed", "committed@example.com", "hash", null, null))));
            assertEquals(1, sql.fetchCount(USERS, USERS.USERNAME.eq("committed")));
        }
    }

    @Test
    void unexpectedTransactionFailureRollsBackAndPropagatesOriginalException() throws Exception {
        try (var connection = DriverManager.getConnection(POSTGRES.getJdbcUrl(),
            POSTGRES.getUsername(), POSTGRES.getPassword())) {
            var sql = DSL.using(connection, SQLDialect.POSTGRES);
            var failure = new IllegalStateException("Unexpected infrastructure failure");
            assertSame(failure, assertThrows(IllegalStateException.class,
                () -> new JooqUnitOfWork(sql).run(repositories -> {
                    repositories.users().insert(User.reconstitute(new User.Props(0, "rolled-back",
                        "rolled-back@example.com", "hash", null, null)));
                    throw failure;
                })));
            assertEquals(0, sql.fetchCount(USERS, USERS.USERNAME.eq("rolled-back")));
        }
    }

    @Test
    void knownUniqueConflictBecomesTypedFailureAfterRollingBackEarlierWrites() throws Exception {
        try (var connection = DriverManager.getConnection(POSTGRES.getJdbcUrl(),
            POSTGRES.getUsername(), POSTGRES.getPassword())) {
            var sql = DSL.using(connection, SQLDialect.POSTGRES);
            sql.insertInto(USERS, USERS.USERNAME, USERS.EMAIL, USERS.PASSWORD_HASH)
                .values("conflict-test", "conflict-test@example.com", "hash").execute();
            var uow = new JooqUnitOfWork(sql);
            var thrown = assertThrows(Conflict.class, () -> uow.run(repository -> {
                repository.users().insert(User.reconstitute(new User.Props(0, "conflict-before",
                    "before@example.com", "hash", null, null)));
                repository.users().insert(User.reconstitute(new User.Props(0, "conflict-test",
                    "duplicate@example.com", "hash", null, null)));
                return null;
            }));
            assertEquals("Username or email already exists", thrown.getMessage());
            assertEquals(0, sql.fetchCount(USERS, USERS.USERNAME.eq("conflict-before")));
        }
    }

    @Test
    void knownSaveConflictRollsBackEarlierWrites() throws Exception {
        try (var connection = DriverManager.getConnection(POSTGRES.getJdbcUrl(),
            POSTGRES.getUsername(), POSTGRES.getPassword())) {
            var sql = DSL.using(connection, SQLDialect.POSTGRES);
            sql.insertInto(USERS, USERS.USERNAME, USERS.EMAIL, USERS.PASSWORD_HASH)
                .values("save-conflict-target", "save-conflict@example.com", "hash").execute();
            var thrown = assertThrows(Conflict.class,
                () -> new JooqUnitOfWork(sql).run(repositories -> {
                    var user = repositories.users().insert(User.reconstitute(new User.Props(0,
                        "save-conflict-before", "save-before@example.com", "hash", null, null)));
                    repositories.users().save(user.update(
                        new User.UpdateInput(null, "save-conflict@example.com", null, null, null),
                        null));
                    return null;
                }));
            assertEquals("Username or email already exists", thrown.getMessage());
            assertEquals(0, sql.fetchCount(USERS, USERS.USERNAME.eq("save-conflict-before")));
            assertEquals(1, sql.fetchCount(USERS, USERS.USERNAME.eq("save-conflict-target")));
        }
    }

    @Test
    void userAndFollowShareOneRollbackBoundary() throws Exception {
        try (var connection = DriverManager.getConnection(POSTGRES.getJdbcUrl(),
            POSTGRES.getUsername(), POSTGRES.getPassword())) {
            var sql = DSL.using(connection, SQLDialect.POSTGRES);
            long followee = sql.insertInto(USERS, USERS.USERNAME, USERS.EMAIL, USERS.PASSWORD_HASH)
                .values("follow-rollback-target", "follow-target@example.com", "hash")
                .returningResult(USERS.ID).fetchSingle().value1();
            var failure = new Forbidden("Rejected after follow");
            assertThrows(Forbidden.class, () -> new JooqUnitOfWork(sql).run(repositories -> {
                var follower = repositories.users().insert(User.reconstitute(new User.Props(0,
                    "follow-rollback-user", "follow-user@example.com", "hash", null, null)));
                repositories.follows().add(follower.id(), followee);
                throw failure;
            }));
            assertEquals(0, sql.fetchCount(USERS, USERS.USERNAME.eq("follow-rollback-user")));
            assertEquals(0, sql.fetchCount(FOLLOWS, FOLLOWS.FOLLOWEE_ID.eq(followee)));
        }
    }

    @Test
    void allRepositoriesShareOneRollbackBoundary() throws Exception {
        try (var connection = DriverManager.getConnection(POSTGRES.getJdbcUrl(),
            POSTGRES.getUsername(), POSTGRES.getPassword())) {
            var sql = DSL.using(connection, SQLDialect.POSTGRES);
            long author = sql.insertInto(USERS, USERS.USERNAME, USERS.EMAIL, USERS.PASSWORD_HASH)
                .values("shared-rollback", "shared-rollback@example.com", "hash")
                .returningResult(USERS.ID).fetchSingle().value1();
            var failure = new Forbidden("Rejected after related writes");
            assertThrows(Forbidden.class, () -> new JooqUnitOfWork(sql).run(repositories -> {
                var user = repositories.users().insert(User.reconstitute(new User.Props(0,
                    "all-rollback-user", "all-rollback@example.com", "hash", null, null)));
                repositories.follows().add(user.id(), author);
                long id = repositories.articles().nextArticleId();
                repositories.articles().insert(Article.reconstitute(new Article.Props(id, user.id(),
                    "shared-rollback", "title", "description", "body")), List.of());
                repositories.comments().insertComment(Comment
                    .reconstitute(new Comment.Props(0, id, user.id(), "shared-rollback-comment")));
                repositories.favorites().add(id, author);
                throw failure;
            }));

            assertEquals(0, sql.fetchCount(USERS, USERS.USERNAME.eq("all-rollback-user")));
            assertEquals(0, sql.fetchCount(FOLLOWS, FOLLOWS.FOLLOWEE_ID.eq(author)));
            assertEquals(0, sql.fetchCount(ARTICLES, ARTICLES.SLUG.eq("shared-rollback")));
            assertEquals(0, sql.fetchCount(COMMENTS, COMMENTS.BODY.eq("shared-rollback-comment")));
            assertEquals(0, sql.fetchCount(FAVORITES, FAVORITES.USER_ID.eq(author)));
        }
    }

    @Test
    void commentProjectionIsLoadedFromCommittedPersistence() throws Exception {
        try (var connection = DriverManager.getConnection(POSTGRES.getJdbcUrl(),
            POSTGRES.getUsername(), POSTGRES.getPassword())) {
            var sql = DSL.using(connection, SQLDialect.POSTGRES);
            long author = sql.insertInto(USERS, USERS.USERNAME, USERS.EMAIL, USERS.PASSWORD_HASH)
                .values("comment-projection", "comment-projection@example.com", "hash")
                .returningResult(USERS.ID).fetchSingle().value1();
            sql.insertInto(ARTICLES, ARTICLES.SLUG, ARTICLES.AUTHOR_ID, ARTICLES.TITLE,
                ARTICLES.DESCRIPTION, ARTICLES.BODY)
                .values("comment-projection", author, "title", "description", "body").execute();
            var reader = new JooqArticleReader(sql);
            var view = new AddComment(reader, new JooqUnitOfWork(sql)).execute(author,
                "comment-projection", "persisted comment");
            assertTrue(view.id() > 0);
            assertEquals("persisted comment", view.body());
            assertEquals("comment-projection", view.author().username());
            assertFalse(view.author().following());
            assertTrue(view.createdAt().matches(".*\\.\\d{3}Z"));
            assertEquals(view.createdAt(), view.updatedAt());
            var thrown = assertThrows(NotFound.class,
                () -> reader.comment(author, "wrong-slug", view.id()));
            assertEquals("Not found", thrown.getMessage());
            try (var observer = DriverManager.getConnection(POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(), POSTGRES.getPassword())) {
                assertEquals("persisted comment",
                    DSL.using(observer, SQLDialect.POSTGRES).select(COMMENTS.BODY).from(COMMENTS)
                        .where(COMMENTS.ID.eq(view.id())).fetchSingle().value1());
            }
        }
    }

    @Test
    void creatingCommentReturnsTheCommentWithoutAnExtraWrapper() throws Exception {
        var base = "http://127.0.0.1:" + application.port();
        var registration = http.send(HttpRequest.newBuilder(URI.create(base + "/api/users"))
            .POST(HttpRequest.BodyPublishers.ofString(
                """
                    {"user":{"username":"comment-response","email":"comment-response@example.com","password":"secret"}}
                    """))
            .build(), HttpResponse.BodyHandlers.ofString());
        assertEquals(201, registration.statusCode());
        var token = JSON.readTree(registration.body()).path("user").path("token").asText();

        var article = http.send(HttpRequest.newBuilder(URI.create(base + "/api/articles"))
            .header("Authorization", "Token " + token).POST(HttpRequest.BodyPublishers.ofString("""
                {"article":{"title":"Comment response","description":"Description","body":"Body"}}
                """)).build(), HttpResponse.BodyHandlers.ofString());
        assertEquals(201, article.statusCode());
        var slug = JSON.readTree(article.body()).path("article").path("slug").asText();

        var response = http.send(HttpRequest
            .newBuilder(URI.create(base + "/api/articles/" + slug + "/comments"))
            .header("Authorization", "Token " + token).POST(HttpRequest.BodyPublishers.ofString("""
                {"comment":{"body":"hello"}}
                """)).build(), HttpResponse.BodyHandlers.ofString());
        assertEquals(201, response.statusCode());
        var comment = JSON.readTree(response.body()).path("comment");
        assertEquals("hello", comment.path("body").asText());
        assertEquals("comment-response", comment.path("author").path("username").asText());
        assertTrue(comment.path("id").asLong() > 0);
        assertEquals(5, comment.size());
    }

    @Test
    void articleUpdateTimestampUsesUpdateStatementNotTransactionStart() throws Exception {
        try (var connection = DriverManager.getConnection(POSTGRES.getJdbcUrl(),
            POSTGRES.getUsername(), POSTGRES.getPassword())) {
            var sql = DSL.using(connection, SQLDialect.POSTGRES);
            long author = sql.insertInto(USERS, USERS.USERNAME, USERS.EMAIL, USERS.PASSWORD_HASH)
                .values("timestamp-test", "timestamp-test@example.com", "hash")
                .returningResult(USERS.ID).fetchSingle().value1();
            sql.insertInto(ARTICLES, ARTICLES.SLUG, ARTICLES.AUTHOR_ID, ARTICLES.TITLE,
                ARTICLES.DESCRIPTION, ARTICLES.BODY)
                .values("timestamp-test", author, "title", "description", "body").execute();
            sql.transaction(configuration -> {
                var transaction = DSL.using(configuration);
                var started = transaction.select(DSL.currentOffsetDateTime()).fetchSingle()
                    .value1();
                transaction.select(DSL.function("pg_sleep", SQLDataType.OTHER, DSL.val(0.03)))
                    .execute();
                new JooqUnitOfWork(transaction).run(repositories -> {
                    var article = repositories.articles().article("timestamp-test").update(author,
                        new Article.UpdateInput(null, null, "new body"));
                    repositories.articles().update(article);
                    return article;
                });
                var updated = transaction.select(ARTICLES.UPDATED_AT).from(ARTICLES)
                    .where(ARTICLES.SLUG.eq("timestamp-test")).fetchSingle().value1();
                assertTrue(updated.isAfter(started.plusNanos(20_000_000)));
            });
        }
    }

    private static HttpResponse<String> get(String path) throws Exception {
        return http.send(HttpRequest
            .newBuilder(URI.create("http://127.0.0.1:" + application.port() + path)).GET().build(),
            HttpResponse.BodyHandlers.ofString());
    }

    private static void execute(String sql) throws Exception {
        try (
            var connection = DriverManager.getConnection(POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(), POSTGRES.getPassword());
            var statement = connection.createStatement()) {
            statement.execute(sql);
        }
    }

    private static void execute(Consumer<DSLContext> statement) throws Exception {
        try (var connection = DriverManager.getConnection(POSTGRES.getJdbcUrl(),
            POSTGRES.getUsername(), POSTGRES.getPassword())) {
            statement.accept(DSL.using(connection, SQLDialect.POSTGRES));
        }
    }
}
