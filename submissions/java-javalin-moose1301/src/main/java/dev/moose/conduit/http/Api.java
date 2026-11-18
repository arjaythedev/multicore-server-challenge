package dev.moose.conduit.http;

import dev.moose.conduit.Conduit;
import dev.moose.conduit.auth.JwtService;
import dev.moose.conduit.auth.password.Bcrypt;
import dev.moose.conduit.auth.password.PasswordService;
import dev.moose.conduit.http.render.ResponseRenderer;
import dev.moose.conduit.json.JsonReader;
import dev.moose.conduit.read.ReadService;
import dev.moose.conduit.write.WriteService;
import io.javalin.config.RoutesConfig;
import io.javalin.http.Context;
import jakarta.servlet.http.HttpServletResponse;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;

public class Api {

    private static final long ANONYMOUS = 0;
    private static final long INVALID = -1;
    private static final String TOKEN_PREFIX = "Token ";
    private static final Object INVALID_FIELD = new Object();

    private final ReadService readService = Conduit.get().getReadService();
    private final WriteService writeService = Conduit.get().getWriteService();
    private final PasswordService passwordService = Conduit.get().getPasswordService();
    private final JwtService jwtService = Conduit.get().getJwtService();

    public void routes(RoutesConfig routes) {
        routes.get("/api/tags", context -> this.read(context, new ReadService.Tags(), ANONYMOUS));
        routes.post("/api/users", this::register);
        routes.post("/api/users/login", this::login);
        routes.get("/api/user", this::currentUser);
        routes.put("/api/user", this::updateUser);
        routes.get("/api/profiles/{username}", this::profile);
        routes.post("/api/profiles/{username}/follow", context -> this.follow(context, true));
        routes.delete("/api/profiles/{username}/follow", context -> this.follow(context, false));
        routes.get("/api/articles", this::listArticles);
        routes.get("/api/articles/feed", this::feed);
        routes.post("/api/articles", this::createArticle);
        routes.get("/api/articles/{slug}", this::article);
        routes.put("/api/articles/{slug}", this::updateArticle);
        routes.delete("/api/articles/{slug}", this::deleteArticle);
        routes.post("/api/articles/{slug}/favorite", context -> this.favorite(context, true));
        routes.delete("/api/articles/{slug}/favorite", context -> this.favorite(context, false));
        routes.get("/api/articles/{slug}/comments", this::comments);
        routes.post("/api/articles/{slug}/comments", this::createComment);
        routes.delete("/api/articles/{slug}/comments/{id}", this::deleteComment);
        routes.exception(Exception.class, (exception, context) -> send(context, HttpReply.INTERNAL));
    }

    private void register(Context context) {
        final Map<String, Object> user = JsonReader.wrapped(context.bodyAsBytes(), "user");
        if (user == null) {
            send(context, HttpReply.INVALID);
            return;
        }

        final String username = nonEmpty(user.get("username"));
        final String email = nonEmpty(user.get("email"));
        final String password = nonEmpty(user.get("password"));
        if (username == null || email == null || password == null || Bcrypt.tooLong(password)) {
            send(context, HttpReply.INVALID);
            return;
        }

        this.respond(context, this.passwordService.hash(password)
                .thenCompose(hash -> this.writeService.register(username, email, hash)));
    }

    private void login(Context context) {
        final Map<String, Object> user = JsonReader.wrapped(context.bodyAsBytes(), "user");
        if (user == null) {
            send(context, HttpReply.INVALID);
            return;
        }

        final String email = nonEmpty(user.get("email"));
        final String password = nonEmpty(user.get("password"));
        if (email == null || password == null) {
            send(context, HttpReply.INVALID);
            return;
        }

        this.respond(context, this.readService.read(new ReadService.Login(email), ANONYMOUS).thenCompose(found -> {
            if (!(found instanceof ReadService.Credentials credentials)) {
                return CompletableFuture.completedFuture(HttpReply.UNAUTHORIZED);
            }
            return this.passwordService.matches(password, credentials.passwordHash()).thenApply(matches -> {
                if (!matches) {
                    return HttpReply.UNAUTHORIZED;
                }
                return ResponseRenderer.user(200, credentials.email(), this.jwtService.issue(credentials.id()),
                        credentials.username(), credentials.bio(), credentials.image());
            });
        }));
    }

    private void currentUser(Context context) {
        final String token = token(context);
        final long viewer = token == null ? INVALID : this.jwtService.verify(token);
        if (viewer <= 0) {
            send(context, HttpReply.UNAUTHORIZED);
            return;
        }

        this.read(context, new ReadService.CurrentUser(viewer, token), viewer);
    }

    private void updateUser(Context context) {
        final String token = token(context);
        final long viewer = token == null ? INVALID : this.jwtService.verify(token);
        if (viewer <= 0) {
            send(context, HttpReply.UNAUTHORIZED);
            return;
        }

        final Map<String, Object> user = JsonReader.wrapped(context.bodyAsBytes(), "user");
        if (user == null) {
            send(context, HttpReply.INVALID);
            return;
        }

        final Object email = optional(user.get("email"), false);
        final Object username = optional(user.get("username"), false);
        final Object password = optional(user.get("password"), false);
        final Object bio = optional(user.get("bio"), true);
        final Object image = optional(user.get("image"), true);
        if (email == INVALID_FIELD || username == INVALID_FIELD || password == INVALID_FIELD
                || bio == INVALID_FIELD || image == INVALID_FIELD) {
            send(context, HttpReply.INVALID);
            return;
        }
        if (password != null && Bcrypt.tooLong((String) password)) {
            send(context, HttpReply.INVALID);
            return;
        }

        final CompletableFuture<String> hash = password == null
                ? CompletableFuture.completedFuture(null)
                : this.passwordService.hash((String) password);
        this.respond(context, hash.thenCompose(passwordHash -> this.writeService.updateUser(viewer, token,
                (String) email, (String) username, passwordHash, (String) bio, (String) image)));
    }

    private void profile(Context context) {
        final long viewer = this.optionalViewer(context);
        if (viewer == INVALID) {
            send(context, HttpReply.UNAUTHORIZED);
            return;
        }

        this.read(context, new ReadService.Profile(context.pathParam("username")), viewer);
    }

    private void follow(Context context, boolean following) {
        final long viewer = this.requiredViewer(context);
        if (viewer == INVALID) {
            send(context, HttpReply.UNAUTHORIZED);
            return;
        }

        this.respond(context, this.writeService.follow(viewer, context.pathParam("username"), following));
    }

    private void listArticles(Context context) {
        final long viewer = this.optionalViewer(context);
        if (viewer == INVALID) {
            send(context, HttpReply.UNAUTHORIZED);
            return;
        }

        final long limit = parseNumber(context.queryParam("limit"), 20);
        final long offset = parseNumber(context.queryParam("offset"), 0);
        if (limit < 1 || limit > 100 || offset < 0) {
            send(context, HttpReply.INVALID);
            return;
        }

        final String tag = filter(context.queryParam("tag"));
        if (tag != null) {
            this.read(context, new ReadService.ByTag(tag, (int) limit, offset), viewer);
            return;
        }

        final String author = filter(context.queryParam("author"));
        if (author != null) {
            this.read(context, new ReadService.ByAuthor(author, (int) limit, offset), viewer);
            return;
        }

        final String favorited = filter(context.queryParam("favorited"));
        if (favorited != null) {
            this.read(context, new ReadService.FavoritedBy(favorited, (int) limit, offset), viewer);
            return;
        }

        this.read(context, new ReadService.Global((int) limit, offset), viewer);
    }

    private void feed(Context context) {
        final long viewer = this.requiredViewer(context);
        if (viewer == INVALID) {
            send(context, HttpReply.UNAUTHORIZED);
            return;
        }

        final long limit = parseNumber(context.queryParam("limit"), 20);
        final long offset = parseNumber(context.queryParam("offset"), 0);
        if (limit < 1 || limit > 100 || offset < 0) {
            send(context, HttpReply.INVALID);
            return;
        }

        this.read(context, new ReadService.Feed((int) limit, offset), viewer);
    }

    private void article(Context context) {
        final long viewer = this.optionalViewer(context);
        if (viewer == INVALID) {
            send(context, HttpReply.UNAUTHORIZED);
            return;
        }

        this.read(context, new ReadService.Article(context.pathParam("slug")), viewer);
    }

    private void createArticle(Context context) {
        final long viewer = this.requiredViewer(context);
        if (viewer == INVALID) {
            send(context, HttpReply.UNAUTHORIZED);
            return;
        }

        final Map<String, Object> article = JsonReader.wrapped(context.bodyAsBytes(), "article");
        if (article == null) {
            send(context, HttpReply.INVALID);
            return;
        }

        final String title = nonEmpty(article.get("title"));
        final String description = nonEmpty(article.get("description"));
        final String body = nonEmpty(article.get("body"));
        final List<String> tags = tagList(article.get("tagList"));
        if (title == null || description == null || body == null || tags == null) {
            send(context, HttpReply.INVALID);
            return;
        }

        this.respond(context, this.writeService.createArticle(viewer, title, description, body, tags));
    }

    private void updateArticle(Context context) {
        final long viewer = this.requiredViewer(context);
        if (viewer == INVALID) {
            send(context, HttpReply.UNAUTHORIZED);
            return;
        }

        final Map<String, Object> article = JsonReader.wrapped(context.bodyAsBytes(), "article");
        if (article == null) {
            send(context, HttpReply.INVALID);
            return;
        }

        final Object title = optional(article.get("title"), false);
        final Object description = optional(article.get("description"), false);
        final Object body = optional(article.get("body"), false);
        if (title == INVALID_FIELD || description == INVALID_FIELD || body == INVALID_FIELD) {
            send(context, HttpReply.INVALID);
            return;
        }

        this.respond(context, this.writeService.updateArticle(viewer, context.pathParam("slug"), (String) title,
                (String) description, (String) body));
    }

    private void deleteArticle(Context context) {
        final long viewer = this.requiredViewer(context);
        if (viewer == INVALID) {
            send(context, HttpReply.UNAUTHORIZED);
            return;
        }

        this.respond(context, this.writeService.deleteArticle(viewer, context.pathParam("slug")));
    }

    private void favorite(Context context, boolean favorited) {
        final long viewer = this.requiredViewer(context);
        if (viewer == INVALID) {
            send(context, HttpReply.UNAUTHORIZED);
            return;
        }

        this.respond(context, this.writeService.favorite(viewer, context.pathParam("slug"), favorited));
    }

    private void comments(Context context) {
        final long viewer = this.optionalViewer(context);
        if (viewer == INVALID) {
            send(context, HttpReply.UNAUTHORIZED);
            return;
        }

        this.read(context, new ReadService.Comments(context.pathParam("slug")), viewer);
    }

    private void createComment(Context context) {
        final long viewer = this.requiredViewer(context);
        if (viewer == INVALID) {
            send(context, HttpReply.UNAUTHORIZED);
            return;
        }

        final Map<String, Object> comment = JsonReader.wrapped(context.bodyAsBytes(), "comment");
        final String body = comment == null ? null : nonEmpty(comment.get("body"));
        if (body == null) {
            send(context, HttpReply.INVALID);
            return;
        }

        this.respond(context, this.writeService.createComment(viewer, context.pathParam("slug"), body));
    }

    private void deleteComment(Context context) {
        final long viewer = this.requiredViewer(context);
        if (viewer == INVALID) {
            send(context, HttpReply.UNAUTHORIZED);
            return;
        }

        final long commentId = parseNumber(context.pathParam("id"), -1);
        if (commentId < 0) {
            send(context, HttpReply.NOT_FOUND);
            return;
        }

        this.respond(context, this.writeService.deleteComment(viewer, context.pathParam("slug"), commentId));
    }

    private void read(Context context, ReadService.Read read, long viewer) {
        context.future(() -> this.readService.read(read, viewer).thenAccept(answer -> send(context, (HttpReply) answer)));
    }

    private void respond(Context context, CompletableFuture<HttpReply> reply) {
        context.future(() -> reply.thenAccept(answer -> send(context, answer)));
    }

    private long optionalViewer(Context context) {
        final String header = context.header("Authorization");
        if (header == null) {
            return ANONYMOUS;
        }
        if (!header.startsWith(TOKEN_PREFIX)) {
            return INVALID;
        }

        final long viewer = this.jwtService.verify(header.substring(TOKEN_PREFIX.length()));
        return viewer <= 0 ? INVALID : viewer;
    }

    private long requiredViewer(Context context) {
        final String token = token(context);
        if (token == null) {
            return INVALID;
        }

        final long viewer = this.jwtService.verify(token);
        return viewer <= 0 ? INVALID : viewer;
    }

    private static void send(Context context, HttpReply reply) {
        final HttpServletResponse response = context.res();
        response.setStatus(reply.status());
        if (reply.body() == null) {
            return;
        }

        response.setHeader("Content-Type", "application/json");
        response.setContentLength(reply.body().length);
        try {
            response.getOutputStream().write(reply.body());
        } catch (IOException ignored) {
        }
    }

    private static String token(Context context) {
        final String header = context.header("Authorization");
        if (header == null || !header.startsWith(TOKEN_PREFIX)) {
            return null;
        }
        return header.substring(TOKEN_PREFIX.length());
    }

    private static Object optional(Object value, boolean emptyAllowed) {
        if (value == null || value == JsonReader.NULL) {
            return null;
        }
        if (!(value instanceof String text)) {
            return INVALID_FIELD;
        }
        if (text.isEmpty() && !emptyAllowed) {
            return INVALID_FIELD;
        }
        return text;
    }

    private static String nonEmpty(Object value) {
        if (!(value instanceof String text) || text.isEmpty()) {
            return null;
        }
        return text;
    }

    private static List<String> tagList(Object value) {
        if (value == null || value == JsonReader.NULL) {
            return List.of();
        }
        if (!(value instanceof List<?> items)) {
            return null;
        }

        final List<String> tags = new ArrayList<>(items.size());
        for (final Object item : items) {
            final String tag = nonEmpty(item);
            if (tag == null) {
                return null;
            }
            tags.add(tag);
        }
        return tags;
    }

    private static String filter(String value) {
        if (value == null || value.isEmpty()) {
            return null;
        }
        return value;
    }

    private static long parseNumber(String text, long fallback) {
        if (text == null) {
            return fallback;
        }
        if (text.isEmpty()) {
            return -1;
        }

        long value = 0;
        for (int i = 0; i < text.length(); i++) {
            final char character = text.charAt(i);
            if (character < '0' || character > '9') {
                return -1;
            }
            if (value > (Long.MAX_VALUE - (character - '0')) / 10) {
                return -1;
            }
            value = value * 10 + (character - '0');
        }
        return value;
    }

}
