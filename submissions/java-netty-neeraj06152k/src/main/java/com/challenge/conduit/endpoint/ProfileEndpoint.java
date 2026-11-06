package com.challenge.conduit.endpoint;

import com.challenge.conduit.db.PostgresClient;
import com.challenge.conduit.http.RequestContext;
import com.challenge.conduit.json.JsonStreamer;
import io.netty.buffer.ByteBuf;
import io.netty.handler.codec.http.HttpResponseStatus;
import io.vertx.sqlclient.Row;
import io.vertx.sqlclient.Tuple;

/**
 * Single Responsibility: Profiles endpoints:
 * - GET    /api/profiles/:username (Get profile)
 * - POST   /api/profiles/:username/follow (Follow user)
 * - DELETE /api/profiles/:username/follow (Unfollow user)
 */
public final class ProfileEndpoint {

    public static final String PROFILE_SELECT = """
        SELECT u.id, u.username, u.bio, u.image,
               EXISTS (SELECT 1 FROM follows f WHERE f.follower_id = $1 AND f.followee_id = u.id) AS following
          FROM users u
         WHERE u.username = $2
    """;

    // Single-trip atomic follow CTE
    private static final String FOLLOW_CTE = """
        WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),
             f AS (INSERT INTO follows (follower_id, followee_id)
                   SELECT $1, id FROM u ON CONFLICT DO NOTHING)
        SELECT u.id, u.username, u.bio, u.image FROM u
    """;

    // Single-trip atomic unfollow CTE
    private static final String UNFOLLOW_CTE = """
        WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),
             f AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id IN (SELECT id FROM u))
        SELECT u.id, u.username, u.bio, u.image FROM u
    """;

    public static void handleGetProfile(RequestContext req, PostgresClient pgClient, String username) {
        pgClient.ffmBatchEngine().submitProfile(req, username, req.viewerId());
    }

    public static void handleFollow(RequestContext req, PostgresClient pgClient, String username) {
        if (req.viewerId() == 0) {
            ByteBuf errBuf = req.alloc();
            JsonStreamer.writeError(errBuf, "missing or invalid authorization token");
            req.send(HttpResponseStatus.UNAUTHORIZED, errBuf);
            return;
        }

        pgClient.preparedQuery(FOLLOW_CTE, Tuple.of(req.viewerId(), username)).onComplete(ar -> {
            if (ar.succeeded() && ar.result().size() > 0) {
                Row userRow = ar.result().iterator().next();
                ByteBuf buf = req.alloc();
                JsonStreamer.writeProfile(buf, userRow, true);
                req.send(HttpResponseStatus.OK, buf);
            } else {
                ByteBuf errBuf = req.alloc();
                JsonStreamer.writeError(errBuf, "Profile not found");
                req.send(HttpResponseStatus.NOT_FOUND, errBuf);
            }
        });
    }

    public static void handleUnfollow(RequestContext req, PostgresClient pgClient, String username) {
        if (req.viewerId() == 0) {
            ByteBuf errBuf = req.alloc();
            JsonStreamer.writeError(errBuf, "missing or invalid authorization token");
            req.send(HttpResponseStatus.UNAUTHORIZED, errBuf);
            return;
        }

        pgClient.preparedQuery(UNFOLLOW_CTE, Tuple.of(req.viewerId(), username)).onComplete(ar -> {
            if (ar.succeeded() && ar.result().size() > 0) {
                Row userRow = ar.result().iterator().next();
                ByteBuf buf = req.alloc();
                JsonStreamer.writeProfile(buf, userRow, false);
                req.send(HttpResponseStatus.OK, buf);
            } else {
                ByteBuf errBuf = req.alloc();
                JsonStreamer.writeError(errBuf, "Profile not found");
                req.send(HttpResponseStatus.NOT_FOUND, errBuf);
            }
        });
    }
}
