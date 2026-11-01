package com.challenge.conduit.endpoint;

import com.challenge.conduit.db.PostgresClient;
import com.challenge.conduit.http.RequestContext;
import com.challenge.conduit.json.JsonStreamer;
import io.netty.buffer.ByteBuf;
import io.netty.handler.codec.http.HttpResponseStatus;
import io.vertx.sqlclient.Tuple;

/**
 * Single Responsibility: Article favorites endpoints:
 * - POST   /api/articles/:slug/favorite
 * - DELETE /api/articles/:slug/favorite
 */
public final class FavoriteEndpoint {

    // Single-query insertion reducing round trips: atomically favorites and returns article
    private static final String FAVORITE_SQL = """
        WITH ins AS (
            INSERT INTO favorites (user_id, article_id)
            SELECT $1, id FROM articles WHERE slug = $2
            ON CONFLICT DO NOTHING
            RETURNING 1
        ),
        a AS (
            SELECT id, slug, title, description, body, created_at, updated_at, author_id
              FROM articles
             WHERE slug = $2
        )
        SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
               ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
                      WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
               (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) + (SELECT count(*) FROM ins) AS favorites_count,
               true AS favorited,
               u.username, u.bio, u.image,
               EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
          FROM a
          JOIN users u ON u.id = a.author_id
    """;

    // Single-query deletion reducing round trips: atomically unfavorites and returns article
    private static final String UNFAVORITE_SQL = """
        WITH del AS (
            DELETE FROM favorites
             WHERE user_id = $1
               AND article_id = (SELECT id FROM articles WHERE slug = $2)
            RETURNING 1
        ),
        a AS (
            SELECT id, slug, title, description, body, created_at, updated_at, author_id
              FROM articles
             WHERE slug = $2
        )
        SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
               ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
                      WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
               (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) - (SELECT count(*) FROM del) AS favorites_count,
               false AS favorited,
               u.username, u.bio, u.image,
               EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
          FROM a
          JOIN users u ON u.id = a.author_id
    """;

    public static void handleFavorite(RequestContext req, PostgresClient pgClient, String slug) {
        if (req.viewerId() == 0) {
            ByteBuf errBuf = req.alloc();
            JsonStreamer.writeError(errBuf, "missing or invalid authorization token");
            req.send(HttpResponseStatus.UNAUTHORIZED, errBuf);
            return;
        }

        pgClient.preparedQuery(FAVORITE_SQL, Tuple.of(req.viewerId(), slug)).onComplete(ar -> {
            if (ar.succeeded() && ar.result().size() > 0) {
                var row = ar.result().iterator().next();
                ByteBuf buf = req.alloc();
                JsonStreamer.writeArticle(buf, row, true);
                req.send(HttpResponseStatus.OK, buf);
            } else {
                ByteBuf errBuf = req.alloc();
                JsonStreamer.writeError(errBuf, "Article not found");
                req.send(HttpResponseStatus.NOT_FOUND, errBuf);
            }
        });
    }

    public static void handleUnfavorite(RequestContext req, PostgresClient pgClient, String slug) {
        if (req.viewerId() == 0) {
            ByteBuf errBuf = req.alloc();
            JsonStreamer.writeError(errBuf, "missing or invalid authorization token");
            req.send(HttpResponseStatus.UNAUTHORIZED, errBuf);
            return;
        }

        pgClient.preparedQuery(UNFAVORITE_SQL, Tuple.of(req.viewerId(), slug)).onComplete(ar -> {
            if (ar.succeeded() && ar.result().size() > 0) {
                var row = ar.result().iterator().next();
                ByteBuf buf = req.alloc();
                JsonStreamer.writeArticle(buf, row, true);
                req.send(HttpResponseStatus.OK, buf);
            } else {
                ByteBuf errBuf = req.alloc();
                JsonStreamer.writeError(errBuf, "Article not found");
                req.send(HttpResponseStatus.NOT_FOUND, errBuf);
            }
        });
    }
}
