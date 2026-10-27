package dev.mccue.vertx.realworld;

import dev.mccue.json.Json;
import dev.mccue.json.JsonDecodeException;
import dev.mccue.json.JsonDecoder;
import dev.mccue.json.JsonReadException;
import io.vertx.core.Future;
import io.vertx.core.buffer.Buffer;
import io.vertx.core.http.HttpHeaders;
import io.vertx.core.http.HttpMethod;
import io.vertx.core.http.HttpServerRequest;
import io.vertx.pgclient.PgException;
import io.vertx.sqlclient.Row;
import io.vertx.sqlclient.RowSet;
import io.vertx.sqlclient.SqlClient;
import io.vertx.sqlclient.Tuple;
import org.jspecify.annotations.Nullable;

import java.lang.System.Logger.Level;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

import static dev.mccue.json.JsonDecoder.*;

/// The 19 endpoints. Everything runs on the event loop that received the request: handlers are Future chains,
/// and this event loop's own Postgres clients complete them on this same thread.
final class Api {
    private static final System.Logger LOG = System.getLogger(Api.class.getName());
    private static final CharSequence APPLICATION_JSON = HttpHeaders.createOptimized("application/json");

    private final Readers reads;
    private final SqlClient writes;
    private final Jwt jwt;
    private final Passwords passwords;
    // Reads in large batches (see Lanes), or null when READ_LANES=0.
    private final @Nullable Lanes lanes;

    Api(Readers reads, SqlClient writes, Jwt jwt, Passwords passwords, @Nullable Lanes lanes) {
        this.reads = reads;
        this.writes = writes;
        this.jwt = jwt;
        this.passwords = passwords;
        this.lanes = lanes;
    }

    // ---------- plumbing ----------

    /// A response: a status and a JSON body (null for an empty one).
    record Reply(int status, @Nullable Buffer body) {
    }

    /// An Authorization header that is present but isn't a valid token. 401, even where auth is optional.
    static final class InvalidTokenException extends RuntimeException {
    }

    /// Well-formed JSON that breaks a rule, or a bad query parameter. 422.
    static final class UnprocessableException extends RuntimeException {
        UnprocessableException(String message) {
            super(message);
        }
    }

    void handle(HttpServerRequest request) {
        Future<Reply> reply;
        try {
            reply = route(request);
        } catch (RuntimeException e) {
            reply = Future.failedFuture(e);
        }
        reply.onComplete(result -> send(request, result.succeeded() ? result.result() : failure(request, result.cause())));
    }

    private static void send(HttpServerRequest request, Reply reply) {
        var response = request.response().setStatusCode(reply.status());
        if (reply.body() == null) {
            response.end();
        }
        else {
            response.putHeader(HttpHeaders.CONTENT_TYPE, APPLICATION_JSON).end(reply.body());
        }
    }

    private static Reply failure(HttpServerRequest request, Throwable cause) {
        return switch (cause) {
            case InvalidTokenException e -> unauthenticated();
            case UnprocessableException e -> error(422, e.getMessage());
            case JsonReadException e -> error(422, "invalid body");
            case JsonDecodeException e -> error(422, "invalid body");
            default -> {
                LOG.log(Level.ERROR, "Unhandled exception while handling " + request.method() + " " + request.uri(), cause);
                yield error(500, "internal error");
            }
        };
    }

    private Future<Reply> route(HttpServerRequest request) {
        var path = request.path();
        if (!path.startsWith("/api/")) {
            return Future.succeededFuture(notFound());
        }
        var parts = path.substring("/api/".length()).split("/", -1);
        var method = request.method();
        return switch (parts.length) {
            case 1 -> switch (parts[0]) {
                case "tags" -> method == HttpMethod.GET ? tags() : notFoundLater();
                case "user" -> method == HttpMethod.GET ? currentUser(request)
                        : method == HttpMethod.PUT ? updateUser(request) : notFoundLater();
                case "users" -> method == HttpMethod.POST ? register(request) : notFoundLater();
                case "articles" -> method == HttpMethod.GET ? listArticles(request)
                        : method == HttpMethod.POST ? createArticle(request) : notFoundLater();
                default -> notFoundLater();
            };
            case 2 -> switch (parts[0]) {
                case "users" -> parts[1].equals("login") && method == HttpMethod.POST ? login(request) : notFoundLater();
                case "profiles" -> method == HttpMethod.GET ? profile(request, decode(parts[1])) : notFoundLater();
                case "articles" -> {
                    if (parts[1].equals("feed") && method == HttpMethod.GET) {
                        yield feed(request);
                    }
                    var slug = decode(parts[1]);
                    yield method == HttpMethod.GET ? article(request, slug)
                            : method == HttpMethod.PUT ? updateArticle(request, slug)
                            : method == HttpMethod.DELETE ? deleteArticle(request, slug) : notFoundLater();
                }
                default -> notFoundLater();
            };
            case 3 -> switch (parts[0]) {
                case "profiles" -> parts[2].equals("follow") && method == HttpMethod.POST ? follow(request, decode(parts[1]), true)
                        : parts[2].equals("follow") && method == HttpMethod.DELETE ? follow(request, decode(parts[1]), false)
                        : notFoundLater();
                case "articles" -> parts[2].equals("comments") && method == HttpMethod.GET ? comments(request, decode(parts[1]))
                        : parts[2].equals("comments") && method == HttpMethod.POST ? addComment(request, decode(parts[1]))
                        : parts[2].equals("favorite") && method == HttpMethod.POST ? favorite(request, decode(parts[1]), true)
                        : parts[2].equals("favorite") && method == HttpMethod.DELETE ? favorite(request, decode(parts[1]), false)
                        : notFoundLater();
                default -> notFoundLater();
            };
            case 4 -> parts[0].equals("articles") && parts[2].equals("comments") && method == HttpMethod.DELETE
                    ? deleteComment(request, decode(parts[1]), parts[3])
                    : notFoundLater();
            default -> notFoundLater();
        };
    }

    /// Decodes %XX escapes in a path segment ('+' stays a '+').
    private static String decode(String segment) {
        return segment.indexOf('%') == -1 ? segment : URLDecoder.decode(segment.replace("+", "%2B"), StandardCharsets.UTF_8);
    }

    private static Reply json(int status, Out out) {
        return new Reply(status, out.toBuffer());
    }

    private static Reply error(int status, String message) {
        return json(status, new Out().open().key("errors").open().key("body").openArray().string(message).closeArray().close().close());
    }

    static Reply unauthenticated() {
        return error(401, "unauthenticated");
    }

    static Reply notFound() {
        return error(404, "not found");
    }

    private static Future<Reply> notFoundLater() {
        return Future.succeededFuture(notFound());
    }

    private static Reply forbidden() {
        return error(403, "forbidden");
    }

    private static @Nullable Row firstRow(RowSet<Row> rows) {
        var iterator = rows.iterator();
        return iterator.hasNext() ? iterator.next() : null;
    }

    private static boolean isUniqueViolation(Throwable e) {
        return e instanceof PgException pg && "23505".equals(pg.getSqlState());
    }

    private static <T> Future<T> readBody(HttpServerRequest request, JsonDecoder<T> decoder) {
        return request.body().map(body -> decoder.decode(Json.readString(body.toString(StandardCharsets.UTF_8))));
    }

    /// A JSON string that isn't empty.
    private static JsonDecoder<String> nonEmptyString(String message) {
        return json -> {
            var value = string(json);
            if (value.isEmpty()) {
                throw JsonDecodeException.of(message, json);
            }
            return value;
        };
    }

    /// A query parameter that must be a plain decimal integer in [min, max].
    private static int intInRange(HttpServerRequest request, String name, int defaultValue, int min, int max) {
        var value = request.getParam(name);
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

    private static @Nullable String nonEmptyParam(HttpServerRequest request, String name) {
        var value = request.getParam(name);
        return value == null || value.isEmpty() ? null : value;
    }

    private static @Nullable String presentedToken(HttpServerRequest request) {
        var authorization = request.getHeader(HttpHeaders.AUTHORIZATION);
        if (authorization == null) {
            return null;
        }
        if (!authorization.startsWith("Token ")) {
            throw new InvalidTokenException();
        }
        return authorization.substring("Token ".length()).trim();
    }

    /// The user id from the token, or null if there is no Authorization header.
    private @Nullable Long userId(HttpServerRequest request) {
        var token = presentedToken(request);
        if (token == null) {
            return null;
        }
        var userId = jwt.verify(token);
        if (userId == null) {
            throw new InvalidTokenException();
        }
        return userId;
    }

    /// The viewer id as the SQL wants it: 0 when anonymous (no user has id 0).
    private long viewer(HttpServerRequest request) {
        var userId = userId(request);
        return userId == null ? 0 : userId;
    }

    // ---------- JSON shapes ----------

    /// An Article from article columns starting at column `start` (see Sql).
    private static void writeArticle(Out out, Row row, int start, boolean includeBody) {
        out.open()
                .key("slug").string(row.getString(start + 1))
                .key("title").string(row.getString(start + 2))
                .key("description").string(row.getString(start + 3));
        int i = start + 4;
        if (includeBody) {
            out.key("body").string(row.getString(i));
            i++;
        }
        out.key("tagList").openArray();
        for (var tag : row.getArrayOfStrings(i + 2)) {
            out.string(tag);
        }
        out.closeArray()
                .key("createdAt").timestamp(row.getOffsetDateTime(i))
                .key("updatedAt").timestamp(row.getOffsetDateTime(i + 1))
                .key("favorited").bool(row.getBoolean(i + 4))
                .key("favoritesCount").number(row.getLong(i + 3))
                .key("author").open()
                    .key("username").string(row.getString(i + 5))
                    .key("bio").string(row.getString(i + 6))
                    .key("image").string(row.getString(i + 7))
                    .key("following").bool(row.getBoolean(i + 8))
                .close()
                .close();
    }

    private static Reply articleReply(int status, Row row) {
        return articleReply(status, row, 0);
    }

    private static Reply articleReply(int status, Row row, int start) {
        var out = new Out().open().key("article");
        writeArticle(out, row, start, true);
        return json(status, out.close());
    }

    /// {"articles": [...], "articlesCount": n} from (count, article columns...) rows, the count at `start`.
    /// Newest first: sorted here by article id rather than relying on the order rows arrive in.
    private static Reply articleList(Iterable<Row> rows, int start) {
        long count = 0;
        var page = new ArrayList<Row>();
        for (var row : rows) {
            count = row.getLong(start);
            if (row.getValue(start + 1) != null) {
                page.add(row);
            }
        }
        page.sort(Comparator.comparingLong((Row row) -> row.getLong(start + 1)).reversed());
        var out = new Out().open().key("articles").openArray();
        for (var row : page) {
            writeArticle(out, row, start + 1, false);
        }
        return json(200, out.closeArray().key("articlesCount").number(count).close());
    }

    /// {"user": User} from (id, username, email, bio, image).
    private static Reply userReply(int status, Row row, String token) {
        return userReply(status, row, token, 0);
    }

    private static Reply userReply(int status, Row row, String token, int start) {
        return json(status, new Out().open().key("user").open()
                .key("email").string(row.getString(start + 2))
                .key("token").string(token)
                .key("username").string(row.getString(start + 1))
                .key("bio").string(row.getString(start + 3))
                .key("image").string(row.getString(start + 4))
                .close().close());
    }

    private static Reply profileReply(Row row, boolean following) {
        return profileReply(row, following, 0);
    }

    private static Reply profileReply(Row row, boolean following, int start) {
        return json(200, new Out().open().key("profile").open()
                .key("username").string(row.getString(start))
                .key("bio").string(row.getString(start + 1))
                .key("image").string(row.getString(start + 2))
                .key("following").bool(following)
                .close().close());
    }

    // ---------- users ----------

    record RegisterRequest(String username, String email, String password) {
        static RegisterRequest fromJson(dev.mccue.json.Json json) {
            return field(json, "user", user -> new RegisterRequest(
                    field(user, "username", nonEmptyString("username can't be empty")),
                    field(user, "email", nonEmptyString("email can't be empty")),
                    field(user, "password", nonEmptyString("password can't be empty"))
            ));
        }
    }

    private Future<Reply> register(HttpServerRequest request) {
        return readBody(request, RegisterRequest::fromJson).compose(body -> {
            if (Passwords.tooLong(body.password())) {
                return Future.succeededFuture(error(422, "password is too long"));
            }
            return passwords.hash(body.password(), request)
                    .compose(hash -> writes.preparedQuery(Sql.USER_INSERT)
                            .execute(Tuple.of(body.username(), body.email(), hash)))
                    .map(rows -> {
                        var row = rows.iterator().next();
                        return userReply(201, row, jwt.issue(row.getLong(0)));
                    })
                    .recover(e -> isUniqueViolation(e)
                            ? Future.succeededFuture(error(422, "username or email already taken"))
                            : Future.failedFuture(e));
        });
    }

    record LoginRequest(String email, String password) {
        static LoginRequest fromJson(dev.mccue.json.Json json) {
            return field(json, "user", user -> new LoginRequest(
                    field(user, "email", nonEmptyString("email can't be empty")),
                    field(user, "password", nonEmptyString("password can't be empty"))
            ));
        }
    }

    private Future<Reply> login(HttpServerRequest request) {
        if (lanes != null) {
            return readBody(request, LoginRequest::fromJson).compose(body ->
                    lanes.<Lanes.@Nullable Credentials>read(new Lanes.Read.Login(body.email()), 0).compose(account -> {
                        if (account == null) {
                            return Future.succeededFuture(error(401, "invalid email or password"));
                        }
                        return passwords.matches(body.password(), account.passwordHash(), request).map(matches -> matches
                                ? json(200, new Out().open().key("user").open()
                                        .key("email").string(account.email())
                                        .key("token").string(jwt.issue(account.id()))
                                        .key("username").string(account.username())
                                        .key("bio").string(account.bio())
                                        .key("image").string(account.image())
                                        .close().close())
                                : error(401, "invalid email or password"));
                    }));
        }
        return readBody(request, LoginRequest::fromJson).compose(body ->
                reads.execute(Sql.USER_BY_EMAIL, Tuple.of(body.email())).compose(rows -> {
                    var row = firstRow(rows);
                    if (row == null) {
                        return Future.succeededFuture(error(401, "invalid email or password"));
                    }
                    return passwords.matches(body.password(), row.getString(5), request).map(matches -> matches
                            ? userReply(200, row, jwt.issue(row.getLong(0)))
                            : error(401, "invalid email or password"));
                }));
    }

    private Future<Reply> currentUser(HttpServerRequest request) {
        var userId = userId(request);
        if (userId == null) {
            return Future.succeededFuture(unauthenticated());
        }
        var token = presentedToken(request);
        if (lanes != null) {
            return lanes.read(new Lanes.Read.CurrentUser(userId, token), userId);
        }
        return reads.execute(Sql.USER_BY_ID, Tuple.of(userId)).map(rows -> {
            var row = firstRow(rows);
            return row == null ? unauthenticated() : userReply(200, row, token);
        });
    }

    /// Fields that are absent or null are left unchanged.
    record UpdateUserRequest(
            @Nullable String email,
            @Nullable String username,
            @Nullable String password,
            @Nullable String image,
            @Nullable String bio
    ) {
        static UpdateUserRequest fromJson(dev.mccue.json.Json json) {
            return field(json, "user", user -> new UpdateUserRequest(
                    optionalNullableField(user, "email", nonEmptyString("email can't be empty"), null),
                    optionalNullableField(user, "username", nonEmptyString("username can't be empty"), null),
                    optionalNullableField(user, "password", nonEmptyString("password can't be empty"), null),
                    optionalNullableField(user, "image", string(), null),
                    optionalNullableField(user, "bio", string(), null)
            ));
        }
    }

    private Future<Reply> updateUser(HttpServerRequest request) {
        var userId = userId(request);
        if (userId == null) {
            return Future.succeededFuture(unauthenticated());
        }
        var token = presentedToken(request);
        return readBody(request, UpdateUserRequest::fromJson).compose(body -> {
            Future<@Nullable String> passwordHash;
            if (body.password() == null) {
                passwordHash = Future.succeededFuture(null);
            }
            else if (Passwords.tooLong(body.password())) {
                return Future.succeededFuture(error(422, "password is too long"));
            }
            else {
                passwordHash = passwords.hash(body.password(), request).map(hash -> hash);
            }
            return passwordHash
                    .compose(hash -> writes.preparedQuery(Sql.USER_UPDATE)
                            .execute(Tuple.of(userId, body.email(), body.username(), hash, body.bio(), body.image())))
                    .map(rows -> {
                        var row = firstRow(rows);
                        return row == null ? unauthenticated() : userReply(200, row, token);
                    })
                    .recover(e -> isUniqueViolation(e)
                            ? Future.succeededFuture(error(422, "username or email already taken"))
                            : Future.failedFuture(e));
        });
    }

    // ---------- profiles ----------

    private Future<Reply> profile(HttpServerRequest request, String username) {
        long viewer = viewer(request);
        if (lanes != null) {
            return lanes.read(new Lanes.Read.Profile(username), viewer);
        }
        return reads.execute(Sql.PROFILE, Tuple.of(viewer, username)).map(rows -> {
            var row = firstRow(rows);
            return row == null ? notFound() : profileReply(row, row.getBoolean(3));
        });
    }

    private Future<Reply> follow(HttpServerRequest request, String username, boolean follow) {
        var userId = userId(request);
        if (userId == null) {
            return Future.succeededFuture(unauthenticated());
        }
        return writes.preparedQuery(follow ? Sql.FOLLOW : Sql.UNFOLLOW).execute(Tuple.of(userId, username)).map(rows -> {
            var row = firstRow(rows);
            return row == null ? notFound() : profileReply(row, follow);
        });
    }

    // ---------- articles ----------

    private Future<Reply> listArticles(HttpServerRequest request) {
        long viewer = viewer(request);
        int limit = intInRange(request, "limit", 20, 1, 100);
        int offset = intInRange(request, "offset", 0, 0, Integer.MAX_VALUE);

        // Only the first of tag, author, favorited applies. An empty value counts as absent.
        var tag = nonEmptyParam(request, "tag");
        var author = nonEmptyParam(request, "author");
        var favorited = nonEmptyParam(request, "favorited");

        if (lanes != null) {
            Lanes.Read read;
            if (tag != null) {
                read = new Lanes.Read.ByTag(tag, limit, offset);
            }
            else if (author != null) {
                read = new Lanes.Read.ByAuthor(author, limit, offset);
            }
            else if (favorited != null) {
                read = new Lanes.Read.Favorited(favorited, limit, offset);
            }
            else {
                read = new Lanes.Read.Global(limit, offset);
            }
            return lanes.read(read, viewer);
        }
        Future<RowSet<Row>> rows;
        if (tag != null) {
            rows = reads.execute(Sql.LIST_BY_TAG, Tuple.of(viewer, limit, offset, tag));
        }
        else if (author != null) {
            rows = reads.execute(Sql.LIST_BY_AUTHOR, Tuple.of(viewer, limit, offset, author));
        }
        else if (favorited != null) {
            rows = reads.execute(Sql.LIST_FAVORITED, Tuple.of(viewer, limit, offset, favorited));
        }
        else {
            rows = reads.execute(Sql.LIST_ALL, Tuple.of(viewer, limit, offset));
        }
        return rows.map(result -> articleList(result, 0));
    }

    private Future<Reply> feed(HttpServerRequest request) {
        var userId = userId(request);
        if (userId == null) {
            return Future.succeededFuture(unauthenticated());
        }
        int limit = intInRange(request, "limit", 20, 1, 100);
        int offset = intInRange(request, "offset", 0, 0, Integer.MAX_VALUE);
        if (lanes != null) {
            return lanes.read(new Lanes.Read.Feed(limit, offset), userId);
        }
        return reads.execute(Sql.FEED, Tuple.of(userId, limit, offset)).map(result -> articleList(result, 0));
    }

    private Future<Reply> article(HttpServerRequest request, String slug) {
        long viewer = viewer(request);
        if (lanes != null) {
            return lanes.read(new Lanes.Read.Article(slug), viewer);
        }
        return reads.execute(Sql.ARTICLE_BY_SLUG, Tuple.of(viewer, slug)).map(rows -> {
            var row = firstRow(rows);
            return row == null ? notFound() : articleReply(200, row);
        });
    }

    record CreateArticleRequest(String title, String description, String body, List<String> tagList) {
        static CreateArticleRequest fromJson(dev.mccue.json.Json json) {
            return field(json, "article", article -> new CreateArticleRequest(
                    field(article, "title", nonEmptyString("title can't be empty")),
                    field(article, "description", nonEmptyString("description can't be empty")),
                    field(article, "body", nonEmptyString("body can't be empty")),
                    optionalNullableField(article, "tagList", array(nonEmptyString("tag can't be empty")), List.of())
            ));
        }
    }

    private Future<Reply> createArticle(HttpServerRequest request) {
        var userId = userId(request);
        if (userId == null) {
            return Future.succeededFuture(unauthenticated());
        }
        return readBody(request, CreateArticleRequest::fromJson).compose(body -> {
            var tags = body.tagList().toArray(new String[0]);
            // The tags go in first, as their own statement, so the article statement's snapshot sees them.
            // A tag left behind by a failed article insert is harmless.
            Future<?> tagsInserted = tags.length == 0
                    ? Future.succeededFuture()
                    : writes.preparedQuery(Sql.TAGS_INSERT).execute(Tuple.of(tags));
            return tagsInserted
                    .compose(done -> writes.preparedQuery(Sql.ARTICLE_INSERT)
                            .execute(Tuple.of(userId, body.title(), body.description(), body.body(), tags)))
                    .map(rows -> articleReply(201, rows.iterator().next()));
        });
    }

    /// Fields that are absent or null are left unchanged.
    record UpdateArticleRequest(@Nullable String title, @Nullable String description, @Nullable String body) {
        static UpdateArticleRequest fromJson(dev.mccue.json.Json json) {
            return field(json, "article", article -> new UpdateArticleRequest(
                    optionalNullableField(article, "title", nonEmptyString("title can't be empty"), null),
                    optionalNullableField(article, "description", nonEmptyString("description can't be empty"), null),
                    optionalNullableField(article, "body", nonEmptyString("body can't be empty"), null)
            ));
        }
    }

    private Future<Reply> updateArticle(HttpServerRequest request, String slug) {
        var userId = userId(request);
        if (userId == null) {
            return Future.succeededFuture(unauthenticated());
        }
        return readBody(request, UpdateArticleRequest::fromJson).compose(body ->
                writes.preparedQuery(Sql.ARTICLE_UPDATE)
                        .execute(Tuple.of(userId, slug, body.title(), body.description(), body.body()))
                        .compose(rows -> {
                            var row = firstRow(rows);
                            return row != null
                                    ? Future.succeededFuture(articleReply(200, row))
                                    : notFoundOrForbidden(Sql.ARTICLE_EXISTS, Tuple.of(slug));
                        }));
    }

    private Future<Reply> deleteArticle(HttpServerRequest request, String slug) {
        var userId = userId(request);
        if (userId == null) {
            return Future.succeededFuture(unauthenticated());
        }
        return writes.preparedQuery(Sql.ARTICLE_DELETE).execute(Tuple.of(slug, userId)).compose(rows ->
                rows.size() > 0
                        ? Future.succeededFuture(new Reply(204, null))
                        : notFoundOrForbidden(Sql.ARTICLE_EXISTS, Tuple.of(slug)));
    }

    /// After a write that matched nothing: 403 if the thing exists (it wasn't the viewer's), 404 if it doesn't.
    private Future<Reply> notFoundOrForbidden(String existsSql, Tuple parameters) {
        return reads.execute(existsSql, parameters).map(rows -> rows.size() > 0 ? forbidden() : notFound());
    }

    private Future<Reply> favorite(HttpServerRequest request, String slug, boolean favorite) {
        var userId = userId(request);
        if (userId == null) {
            return Future.succeededFuture(unauthenticated());
        }
        return writes.preparedQuery(favorite ? Sql.FAVORITE : Sql.UNFAVORITE).execute(Tuple.of(userId, slug)).map(rows -> {
            var row = firstRow(rows);
            return row == null ? notFound() : articleReply(200, row);
        });
    }

    // ---------- comments ----------

    private Future<Reply> comments(HttpServerRequest request, String slug) {
        long viewer = viewer(request);
        if (lanes != null) {
            return lanes.read(new Lanes.Read.Comments(slug), viewer);
        }
        return reads.execute(Sql.COMMENTS, Tuple.of(viewer, slug)).map(rows -> commentList(rows, 0));
    }

    /// {"comments": [...]} from (article id, comment id, body, created_at, updated_at, username, bio, image,
    /// following) rows starting at column `start`. No rows: no such article. Newest first: sorted here rather than
    /// relying on the order rows arrive in.
    private static Reply commentList(Iterable<Row> rows, int start) {
        var comments = new ArrayList<Row>();
        boolean article = false;
        for (var row : rows) {
            article = true;
            if (row.getValue(start + 1) != null) {
                comments.add(row);
            }
        }
        if (!article) {
            return notFound();
        }
        comments.sort(Comparator.comparing((Row row) -> row.getOffsetDateTime(start + 3))
                .thenComparingLong(row -> row.getLong(start + 1))
                .reversed());
        var out = new Out().open().key("comments").openArray();
        for (var row : comments) {
            out.open()
                    .key("id").number(row.getLong(start + 1))
                    .key("createdAt").timestamp(row.getOffsetDateTime(start + 3))
                    .key("updatedAt").timestamp(row.getOffsetDateTime(start + 4))
                    .key("body").string(row.getString(start + 2))
                    .key("author").open()
                        .key("username").string(row.getString(start + 5))
                        .key("bio").string(row.getString(start + 6))
                        .key("image").string(row.getString(start + 7))
                        .key("following").bool(row.getBoolean(start + 8))
                    .close()
                    .close();
        }
        return json(200, out.closeArray().close());
    }

    record CreateCommentRequest(String body) {
        static CreateCommentRequest fromJson(dev.mccue.json.Json json) {
            return field(json, "comment", comment -> new CreateCommentRequest(
                    field(comment, "body", nonEmptyString("body can't be empty"))
            ));
        }
    }

    private Future<Reply> addComment(HttpServerRequest request, String slug) {
        var userId = userId(request);
        if (userId == null) {
            return Future.succeededFuture(unauthenticated());
        }
        return readBody(request, CreateCommentRequest::fromJson).compose(body ->
                writes.preparedQuery(Sql.COMMENT_INSERT).execute(Tuple.of(userId, slug, body.body())).map(rows -> {
                    var row = firstRow(rows);
                    if (row == null) {
                        return notFound();
                    }
                    return json(201, new Out().open().key("comment").open()
                            .key("id").number(row.getLong(0))
                            .key("createdAt").timestamp(row.getOffsetDateTime(2))
                            .key("updatedAt").timestamp(row.getOffsetDateTime(3))
                            .key("body").string(row.getString(1))
                            .key("author").open()
                                .key("username").string(row.getString(4))
                                .key("bio").string(row.getString(5))
                                .key("image").string(row.getString(6))
                                .key("following").bool(false)
                            .close()
                            .close().close());
                }));
    }

    private Future<Reply> deleteComment(HttpServerRequest request, String slug, String commentIdText) {
        var userId = userId(request);
        if (userId == null) {
            return Future.succeededFuture(unauthenticated());
        }
        long commentId;
        try {
            commentId = Long.parseLong(commentIdText);
        } catch (NumberFormatException e) {
            return notFoundLater();
        }
        return writes.preparedQuery(Sql.COMMENT_DELETE).execute(Tuple.of(commentId, slug, userId)).compose(rows ->
                rows.size() > 0
                        ? Future.succeededFuture(new Reply(204, null))
                        : notFoundOrForbidden(Sql.COMMENT_EXISTS, Tuple.of(commentId, slug)));
    }

    // ---------- tags ----------

    private Future<Reply> tags() {
        if (lanes != null) {
            return lanes.read(new Lanes.Read.Tags(), 0);
        }
        return reads.execute(Sql.TAGS, Tuple.tuple()).map(rows -> {
            var out = new Out().open().key("tags").openArray();
            for (var row : rows) {
                out.string(row.getString(0));
            }
            return json(200, out.closeArray().close());
        });
    }
}
