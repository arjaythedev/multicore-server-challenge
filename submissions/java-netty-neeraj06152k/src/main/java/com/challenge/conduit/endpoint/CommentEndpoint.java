package com.challenge.conduit.endpoint;

import com.challenge.conduit.db.PostgresClient;
import com.challenge.conduit.http.RequestContext;
import com.challenge.conduit.json.JsonReader;
import com.challenge.conduit.json.JsonStreamer;
import io.netty.buffer.ByteBuf;
import io.netty.handler.codec.http.HttpResponseStatus;
import io.vertx.sqlclient.Row;
import io.vertx.sqlclient.Tuple;

/**
 * Single Responsibility: Comments endpoints:
 * - GET    /api/articles/:slug/comments (List comments)
 * - POST   /api/articles/:slug/comments (Create comment)
 * - DELETE /api/articles/:slug/comments/:id (Delete comment)
 */
public final class CommentEndpoint {

    // Single round-trip comments list query that simultaneously validates article existence
    public static final String COMMENTS_LIST_SINGLE_ROUNDTRIP_SQL = """
        SELECT a.id AS article_exists_id,
               c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
               EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following
          FROM articles a
          LEFT JOIN comments c ON c.article_id = a.id
          LEFT JOIN users u ON u.id = c.author_id
         WHERE a.slug = $2
         ORDER BY c.created_at DESC, c.id DESC
         LIMIT 100
    """;

    private static final String INSERT_COMMENT_SINGLE_TRIP_SQL = """
        WITH a AS (
            SELECT id FROM articles WHERE slug = $1
        ),
        c AS (
            INSERT INTO comments (article_id, author_id, body)
            SELECT id, $2, $3 FROM a
            RETURNING id, body, created_at, updated_at, author_id
        )
        SELECT a.id AS article_id, c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
               false AS following
          FROM a
          LEFT JOIN c ON true
          LEFT JOIN users u ON u.id = c.author_id
    """;

    private static final String DELETE_COMMENT_SINGLE_TRIP_SQL = """
        WITH target AS (
            SELECT c.id, c.author_id
              FROM comments c
              JOIN articles a ON a.id = c.article_id
             WHERE c.id = $1 AND a.slug = $2
        ),
        del AS (
            DELETE FROM comments
             WHERE id IN (SELECT id FROM target WHERE author_id = $3)
        )
        SELECT author_id FROM target
    """;

    public static void handleListComments(RequestContext req, PostgresClient pgClient, String slug) {
        pgClient.ffmBatchEngine().submitComment(req, slug, req.viewerId());
    }

    public static void handleCreateComment(RequestContext req, PostgresClient pgClient, String slug) {
        if (req.viewerId() == 0) {
            ByteBuf errBuf = req.alloc();
            JsonStreamer.writeError(errBuf, "missing or invalid authorization token");
            req.send(HttpResponseStatus.UNAUTHORIZED, errBuf);
            return;
        }

        JsonReader.CommentCreateRequest cr = JsonReader.parseCommentCreate(req.request().content());
        if (!cr.valid()) {
            ByteBuf errBuf = req.alloc();
            JsonStreamer.writeError(errBuf, "Invalid comment body");
            req.send(HttpResponseStatus.UNPROCESSABLE_ENTITY, errBuf);
            return;
        }

        pgClient.preparedQuery(INSERT_COMMENT_SINGLE_TRIP_SQL, Tuple.of(slug, req.viewerId(), cr.body())).onComplete(ar -> {
            if (ar.succeeded() && ar.result().size() > 0) {
                Row row = ar.result().iterator().next();
                if (row.getValue("id") != null) {
                    ByteBuf buf = req.alloc();
                    JsonStreamer.writeComment(buf, row, false);
                    req.send(HttpResponseStatus.CREATED, buf);
                } else {
                    ByteBuf errBuf = req.alloc();
                    JsonStreamer.writeError(errBuf, "Failed to create comment");
                    req.send(HttpResponseStatus.INTERNAL_SERVER_ERROR, errBuf);
                }
            } else {
                ByteBuf errBuf = req.alloc();
                JsonStreamer.writeError(errBuf, "Article not found");
                req.send(HttpResponseStatus.NOT_FOUND, errBuf);
            }
        });
    }

    public static void handleDeleteComment(RequestContext req, PostgresClient pgClient, String slug, String idStr) {
        if (req.viewerId() == 0) {
            ByteBuf errBuf = req.alloc();
            JsonStreamer.writeError(errBuf, "missing or invalid authorization token");
            req.send(HttpResponseStatus.UNAUTHORIZED, errBuf);
            return;
        }

        long commentId;
        try {
            commentId = Long.parseLong(idStr);
        } catch (NumberFormatException e) {
            ByteBuf errBuf = req.alloc();
            JsonStreamer.writeError(errBuf, "Invalid comment ID");
            req.send(HttpResponseStatus.NOT_FOUND, errBuf);
            return;
        }

        pgClient.preparedQuery(DELETE_COMMENT_SINGLE_TRIP_SQL, Tuple.of(commentId, slug, req.viewerId())).onComplete(ar -> {
            if (ar.succeeded() && ar.result().size() > 0) {
                long authorId = ar.result().iterator().next().getLong("author_id");
                if (authorId != req.viewerId()) {
                    ByteBuf errBuf = req.alloc();
                    JsonStreamer.writeError(errBuf, "Forbidden");
                    req.send(HttpResponseStatus.FORBIDDEN, errBuf);
                } else {
                    ByteBuf buf = req.alloc();
                    req.send(HttpResponseStatus.NO_CONTENT, buf);
                }
            } else {
                ByteBuf errBuf = req.alloc();
                JsonStreamer.writeError(errBuf, "Comment not found");
                req.send(HttpResponseStatus.NOT_FOUND, errBuf);
            }
        });
    }
}
