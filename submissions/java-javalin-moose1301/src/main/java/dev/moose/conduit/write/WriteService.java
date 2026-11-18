package dev.moose.conduit.write;

import dev.moose.conduit.auth.JwtService;
import dev.moose.conduit.config.ConduitConfig;
import dev.moose.conduit.database.DatabaseService;
import dev.moose.conduit.database.DatabaseSession;
import dev.moose.conduit.http.HttpReply;
import dev.moose.conduit.http.render.ResponseRenderer;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executor;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class WriteService {

    private static final Logger LOGGER = LoggerFactory.getLogger(WriteService.class);
    private static final String UNIQUE_VIOLATION = "23505";


    @FunctionalInterface
    private interface Work {
        HttpReply run(DatabaseSession session) throws SQLException;
    }

    private final ExecutorService writers;
    private final ThreadLocal<DatabaseSession> sessions;
    private final Executor responder;
    private final JwtService jwtService;

    public WriteService(DatabaseService databaseService, ConduitConfig config, Executor responder, JwtService jwtService) {
        this.writers = Executors.newFixedThreadPool(config.getWriteConnections(),
                Thread.ofPlatform().name("writer-", 0).daemon().factory());
        this.sessions = ThreadLocal.withInitial(() -> new DatabaseSession(databaseService));
        this.responder = responder;
        this.jwtService = jwtService;
    }

    public CompletableFuture<HttpReply> register(String username, String email, String passwordHash) {
        return submit(session -> {
            try (ResultSet row = session.query(WriteSql.USER_INSERT, username, email, passwordHash)) {
                row.next();
                return ResponseRenderer.user(201, row.getString(3), this.jwtService.issue(row.getLong(1)), row.getString(2),
                        row.getString(4), row.getString(5));
            }
        });
    }

    public CompletableFuture<HttpReply> updateUser(long viewer, String token, String email, String username, String passwordHash,
                                        String bio, String image) {
        return submit(session -> {
            try (ResultSet row = session.query(WriteSql.USER_UPDATE, email, username, passwordHash, bio, image, viewer)) {
                if (!row.next()) {
                    return HttpReply.UNAUTHORIZED;
                }
                return ResponseRenderer.user(200, row.getString(3), token, row.getString(2), row.getString(4), row.getString(5));
            }
        });
    }

    public CompletableFuture<HttpReply> follow(long viewer, String username, boolean following) {
        return submit(session -> {
            try (ResultSet row = session.query(following ? WriteSql.FOLLOW : WriteSql.UNFOLLOW, username, viewer)) {
                if (!row.next()) {
                    return HttpReply.NOT_FOUND;
                }
                return ResponseRenderer.profile(row.getString(1), row.getString(2), row.getString(3), following);
            }
        });
    }

    public CompletableFuture<HttpReply> createArticle(long viewer, String title, String description, String body, List<String> tags) {
        return submit(session -> {
            final String[] tagArray = tags.toArray(String[]::new);
            session.begin();
            try {
                if (tagArray.length > 0) {
                    session.update(WriteSql.TAGS_INSERT, session.texts(tagArray));
                }
                final HttpReply reply;
                try (ResultSet row = session.query(WriteSql.ARTICLE_INSERT, viewer, title, description, body, session.texts(tagArray))) {
                    row.next();
                    reply = ResponseRenderer.article(201, row, 0);
                }
                session.commit();
                return reply;
            } catch (SQLException | RuntimeException exception) {
                session.rollbackQuietly();
                throw exception;
            }
        });
    }

    public CompletableFuture<HttpReply> updateArticle(long viewer, String slug, String title, String description, String body) {
        return submit(session -> {
            try (ResultSet row = session.query(WriteSql.ARTICLE_UPDATE, viewer, slug, title, description, body)) {
                if (!row.next()) {
                    return HttpReply.NOT_FOUND;
                }
                if (row.getLong(1) != viewer) {
                    return HttpReply.FORBIDDEN;
                }
                return ResponseRenderer.article(200, row, 1);
            }
        });
    }

    public CompletableFuture<HttpReply> deleteArticle(long viewer, String slug) {
        return submit(session -> {
            try (ResultSet row = session.query(WriteSql.ARTICLE_DELETE, viewer, slug)) {
                if (!row.next()) {
                    return HttpReply.NOT_FOUND;
                }
                if (row.getLong(1) != viewer) {
                    return HttpReply.FORBIDDEN;
                }
                return HttpReply.NO_CONTENT;
            }
        });
    }

    public CompletableFuture<HttpReply> favorite(long viewer, String slug, boolean favorited) {
        return submit(session -> {
            try (ResultSet row = session.query(favorited ? WriteSql.FAVORITE : WriteSql.UNFAVORITE, viewer, slug)) {
                if (!row.next()) {
                    return HttpReply.NOT_FOUND;
                }
                return ResponseRenderer.article(200, row, 0);
            }
        });
    }

    public CompletableFuture<HttpReply> createComment(long viewer, String slug, String body) {
        return submit(session -> {
            try (ResultSet row = session.query(WriteSql.COMMENT_INSERT, viewer, body, slug)) {
                if (!row.next()) {
                    return HttpReply.NOT_FOUND;
                }
                return ResponseRenderer.comment(row);
            }
        });
    }

    public CompletableFuture<HttpReply> deleteComment(long viewer, String slug, long commentId) {
        return submit(session -> {
            try (ResultSet row = session.query(WriteSql.COMMENT_DELETE, viewer, commentId, slug)) {
                if (!row.next()) {
                    return HttpReply.NOT_FOUND;
                }
                if (row.getLong(1) != viewer) {
                    return HttpReply.FORBIDDEN;
                }
                return HttpReply.NO_CONTENT;
            }
        });
    }

    private CompletableFuture<HttpReply> submit(Work work) {
        final CompletableFuture<HttpReply> future = new CompletableFuture<>();
        this.writers.execute(() -> {
            final HttpReply reply = execute(work);
            this.responder.execute(() -> future.complete(reply));
        });
        return future;
    }

    private HttpReply execute(Work work) {
        final DatabaseSession session = this.sessions.get();
        try {
            return work.run(session);
        } catch (SQLException exception) {
            if (UNIQUE_VIOLATION.equals(exception.getSQLState())) {
                return HttpReply.TAKEN;
            }
            LOGGER.error("Write failed", exception);
            session.reset();
            return HttpReply.INTERNAL;
        } catch (RuntimeException exception) {
            LOGGER.error("Write failed", exception);
            session.reset();
            return HttpReply.INTERNAL;
        }
    }

}
