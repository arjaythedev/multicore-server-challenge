package com.challenge.conduit.endpoint;

import com.challenge.conduit.db.PostgresClient;
import com.challenge.conduit.http.FastHttpParser;
import com.challenge.conduit.http.RequestContext;
import com.challenge.conduit.json.JsonReader;
import com.challenge.conduit.json.JsonStreamer;
import io.netty.buffer.ByteBuf;
import io.netty.handler.codec.http.HttpResponseStatus;
import io.vertx.core.CompositeFuture;
import io.vertx.core.Future;
import io.vertx.core.Promise;
import io.vertx.sqlclient.Row;
import io.vertx.sqlclient.RowSet;
import io.vertx.sqlclient.Tuple;

import java.util.List;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Single Responsibility: Articles endpoints:
 * - GET    /api/articles (List articles with filter)
 * - GET    /api/articles/feed (Personal feed)
 * - GET    /api/articles/:slug (Single article)
 * - POST   /api/articles (Create article)
 * - PUT    /api/articles/:slug (Update article)
 * - DELETE /api/articles/:slug (Delete article)
 */
public final class ArticleEndpoint {

    public static final String ARTICLE_LIST_SELECT = """
        SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
               ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
                      WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
               (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
               EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
               u.username, u.bio, u.image,
               EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
          FROM articles a
          JOIN users u ON u.id = a.author_id
    """;

    public static final String ARTICLE_FULL_SELECT = """
        SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
               ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
                      WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
               (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
               EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
               u.username, u.bio, u.image,
               EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
          FROM articles a
          JOIN users u ON u.id = a.author_id
    """;

    // Pre-compiled static SQL queries to eliminate runtime StringBuilder/String allocations in request hot paths
    private static final String DEFAULT_LIST_SQL = ARTICLE_LIST_SELECT + " ORDER BY a.id DESC LIMIT $2 OFFSET $3";
    public static final String DEFAULT_COUNT_SQL = "SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s";

    private static final String TAG_LIST_SQL = ARTICLE_LIST_SELECT +
            " WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC";
    private static final String TAG_COUNT_SQL = "SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s";

    private static final String AUTHOR_LIST_SQL = ARTICLE_LIST_SELECT +
            " WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a.id DESC LIMIT $2 OFFSET $3";
    private static final String AUTHOR_COUNT_SQL = "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s";

    private static final String FAVORITED_LIST_SQL = ARTICLE_LIST_SELECT +
            " WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC";
    private static final String FAVORITED_COUNT_SQL = "SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s";

    private static final String FEED_LIST_SQL = ARTICLE_LIST_SELECT + """
         WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL
            (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x
          WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC
    """;
    private static final String FEED_COUNT_SQL = "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s";

    public static final String GET_ARTICLE_BY_SLUG_SQL = ARTICLE_FULL_SELECT + " WHERE a.slug = $2";
    private static final String GET_ARTICLE_BY_ID_SQL = ARTICLE_FULL_SELECT + " WHERE a.id = $2";
    private static final String CHECK_ARTICLE_AUTHOR_SQL = "SELECT id, author_id FROM articles WHERE slug = $1";
    private static final String DELETE_ARTICLE_SQL = "DELETE FROM articles WHERE id = $1";

    private static final String CREATE_ARTICLE_SINGLE_TRIP_SQL = """
        WITH n AS (
            SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id
        ),
        ins_art AS (
            INSERT INTO articles (id, slug, author_id, title, description, body)
            SELECT n.id, $2 || '-' || n.id, $1, $3, $4, $5 FROM n
            RETURNING id, slug, title, description, body, created_at, updated_at, author_id
        ),
        ins_tags AS (
            INSERT INTO tags (name)
            SELECT DISTINCT unnest($6::text[])
            ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name
            RETURNING id
        ),
        ins_at AS (
            INSERT INTO article_tags (article_id, tag_id)
            SELECT (SELECT id FROM ins_art), id FROM ins_tags
        )
        SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
               ARRAY(SELECT DISTINCT unnest($6::text[]) ORDER BY 1) AS tag_list,
               0::bigint AS favorites_count,
               false AS favorited,
               u.username, u.bio, u.image,
               false AS following
          FROM ins_art a
          JOIN users u ON u.id = a.author_id
    """;

    private static final String UPDATE_ARTICLE_SINGLE_TRIP_SQL = """
        WITH target AS (
            SELECT id, author_id FROM articles WHERE slug = $1
        ),
        upd AS (
            UPDATE articles
               SET title = COALESCE($3, title),
                   description = COALESCE($4, description),
                   body = COALESCE($5, body),
                   slug = CASE WHEN $6::text IS NULL THEN slug ELSE $6 || '-' || id END,
                   updated_at = now()
             WHERE id IN (SELECT id FROM target WHERE author_id = $2)
            RETURNING *
        )
        SELECT t.author_id,
               u_id.id, u_id.slug, u_id.title, u_id.description, u_id.body, u_id.created_at, u_id.updated_at,
               ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
                      WHERE at.article_id = u_id.id ORDER BY t.name) AS tag_list,
               (SELECT count(*) FROM favorites f WHERE f.article_id = u_id.id) AS favorites_count,
               EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = u_id.id AND f.user_id = $2) AS favorited,
               u.username, u.bio, u.image,
               EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $2 AND fo.followee_id = u_id.author_id) AS following
          FROM target t
          LEFT JOIN upd u_id ON true
          LEFT JOIN users u ON u.id = u_id.author_id
    """;

    private static final String DELETE_ARTICLE_SINGLE_TRIP_SQL = """
        WITH target AS (
            SELECT id, author_id FROM articles WHERE slug = $1
        ),
        del AS (
            DELETE FROM articles WHERE id IN (SELECT id FROM target WHERE author_id = $2)
        )
        SELECT author_id FROM target
    """;

    public static void handleList(RequestContext req, PostgresClient pgClient) {
        String uri = req.request().uri();
        int limit = FastHttpParser.parseLimit(uri);
        int offset = FastHttpParser.parseOffset(uri);
        if (limit == -1 || offset == -1) {
            ByteBuf errBuf = req.alloc();
            JsonStreamer.writeError(errBuf, "Invalid limit or offset");
            req.send(HttpResponseStatus.UNPROCESSABLE_ENTITY, errBuf);
            return;
        }

        String tag = FastHttpParser.getQueryParam(uri, "tag");
        String author = FastHttpParser.getQueryParam(uri, "author");
        String favorited = FastHttpParser.getQueryParam(uri, "favorited");

        // Spec rule: If more than one filter is given, only the first in order (tag, author, favorited) applies.
        if (tag != null && !tag.isEmpty()) {
            executeListByTag(req, pgClient, tag, limit, offset);
        } else if (author != null && !author.isEmpty()) {
            executeListByAuthor(req, pgClient, author, limit, offset);
        } else if (favorited != null && !favorited.isEmpty()) {
            executeListByFavorited(req, pgClient, favorited, limit, offset);
        } else {
            executeListDefault(req, pgClient, limit, offset);
        }
    }

    private static final AtomicReference<Future<Long>> DEFAULT_COUNT_IN_FLIGHT = new AtomicReference<>();

    private static Future<Long> fetchDefaultCount(PostgresClient pgClient) {
        Future<Long> existing = DEFAULT_COUNT_IN_FLIGHT.get();
        if (existing != null) {
            return existing;
        }

        Promise<Long> promise = Promise.promise();
        Future<Long> future = promise.future();
        if (DEFAULT_COUNT_IN_FLIGHT.compareAndSet(null, future)) {
            pgClient.query(DEFAULT_COUNT_SQL).onComplete(ar -> {
                DEFAULT_COUNT_IN_FLIGHT.set(null);
                if (ar.succeeded() && ar.result().size() > 0) {
                    promise.complete(ar.result().iterator().next().getLong(0));
                } else {
                    promise.fail(ar.cause() != null ? ar.cause() : new RuntimeException("Count failed"));
                }
            });
            return future;
        } else {
            Future<Long> won = DEFAULT_COUNT_IN_FLIGHT.get();
            return won != null ? won : pgClient.query(DEFAULT_COUNT_SQL).map(rs -> rs.iterator().next().getLong(0));
        }
    }

    private static void executeListDefault(RequestContext req, PostgresClient pgClient, int limit, int offset) {
        var listFuture = pgClient.preparedQuery(DEFAULT_LIST_SQL, Tuple.of(req.viewerId(), limit, offset));
        var countFuture = fetchDefaultCount(pgClient);

        CompositeFuture.all(listFuture, countFuture).onComplete(ar -> {
            if (ar.succeeded()) {
                RowSet<Row> listRows = listFuture.result();
                long totalCount = countFuture.result();
                ByteBuf buf = req.alloc();
                JsonStreamer.writeArticlesList(buf, listRows, totalCount);
                req.send(HttpResponseStatus.OK, buf);
            } else {
                sendInternalError(req);
            }
        });
    }

    private static void executeListByTag(RequestContext req, PostgresClient pgClient, String tag, int limit, int offset) {
        var listFuture = pgClient.preparedQuery(TAG_LIST_SQL, Tuple.of(req.viewerId(), limit, offset, tag));
        var countFuture = pgClient.preparedQuery(TAG_COUNT_SQL, Tuple.of(tag));

        CompositeFuture.all(listFuture, countFuture).onComplete(ar -> {
            if (ar.succeeded()) {
                RowSet<Row> listRows = listFuture.result();
                RowSet<Row> countRows = countFuture.result();
                long totalCount = countRows.iterator().next().getLong(0);
                ByteBuf buf = req.alloc();
                JsonStreamer.writeArticlesList(buf, listRows, totalCount);
                req.send(HttpResponseStatus.OK, buf);
            } else {
                sendInternalError(req);
            }
        });
    }

    private static void executeListByAuthor(RequestContext req, PostgresClient pgClient, String author, int limit, int offset) {
        var listFuture = pgClient.preparedQuery(AUTHOR_LIST_SQL, Tuple.of(req.viewerId(), limit, offset, author));
        var countFuture = pgClient.preparedQuery(AUTHOR_COUNT_SQL, Tuple.of(author));

        CompositeFuture.all(listFuture, countFuture).onComplete(ar -> {
            if (ar.succeeded()) {
                RowSet<Row> listRows = listFuture.result();
                RowSet<Row> countRows = countFuture.result();
                long totalCount = countRows.iterator().next().getLong(0);
                ByteBuf buf = req.alloc();
                JsonStreamer.writeArticlesList(buf, listRows, totalCount);
                req.send(HttpResponseStatus.OK, buf);
            } else {
                sendInternalError(req);
            }
        });
    }

    private static void executeListByFavorited(RequestContext req, PostgresClient pgClient, String favorited, int limit, int offset) {
        var listFuture = pgClient.preparedQuery(FAVORITED_LIST_SQL, Tuple.of(req.viewerId(), limit, offset, favorited));
        var countFuture = pgClient.preparedQuery(FAVORITED_COUNT_SQL, Tuple.of(favorited));

        CompositeFuture.all(listFuture, countFuture).onComplete(ar -> {
            if (ar.succeeded()) {
                RowSet<Row> listRows = listFuture.result();
                RowSet<Row> countRows = countFuture.result();
                long totalCount = countRows.iterator().next().getLong(0);
                ByteBuf buf = req.alloc();
                JsonStreamer.writeArticlesList(buf, listRows, totalCount);
                req.send(HttpResponseStatus.OK, buf);
            } else {
                sendInternalError(req);
            }
        });
    }

    public static void handleFeed(RequestContext req, PostgresClient pgClient) {
        if (req.viewerId() == 0) {
            ByteBuf errBuf = req.alloc();
            JsonStreamer.writeError(errBuf, "missing or invalid authorization token");
            req.send(HttpResponseStatus.UNAUTHORIZED, errBuf);
            return;
        }

        String uri = req.request().uri();
        int limit = FastHttpParser.parseLimit(uri);
        int offset = FastHttpParser.parseOffset(uri);
        if (limit == -1 || offset == -1) {
            ByteBuf errBuf = req.alloc();
            JsonStreamer.writeError(errBuf, "Invalid limit or offset");
            req.send(HttpResponseStatus.UNPROCESSABLE_ENTITY, errBuf);
            return;
        }

        var listFuture = pgClient.preparedQuery(FEED_LIST_SQL, Tuple.of(req.viewerId(), limit, offset));
        var countFuture = pgClient.preparedQuery(FEED_COUNT_SQL, Tuple.of(req.viewerId()));

        CompositeFuture.all(listFuture, countFuture).onComplete(ar -> {
            if (ar.succeeded()) {
                RowSet<Row> listRows = listFuture.result();
                RowSet<Row> countRows = countFuture.result();
                long totalCount = countRows.iterator().next().getLong(0);
                ByteBuf buf = req.alloc();
                JsonStreamer.writeArticlesList(buf, listRows, totalCount);
                req.send(HttpResponseStatus.OK, buf);
            } else {
                sendInternalError(req);
            }
        });
    }

    public static void handleGetArticle(RequestContext req, PostgresClient pgClient, String slug) {
        pgClient.ffmBatchEngine().submitArticle(req, slug, req.viewerId());
    }

    public static void handleCreateArticle(RequestContext req, PostgresClient pgClient) {
        if (req.viewerId() == 0) {
            ByteBuf errBuf = req.alloc();
            JsonStreamer.writeError(errBuf, "missing or invalid authorization token");
            req.send(HttpResponseStatus.UNAUTHORIZED, errBuf);
            return;
        }

        JsonReader.ArticleCreateRequest cr = JsonReader.parseArticleCreate(req.request().content());
        if (!cr.valid()) {
            ByteBuf errBuf = req.alloc();
            JsonStreamer.writeError(errBuf, "Invalid article parameters");
            req.send(HttpResponseStatus.UNPROCESSABLE_ENTITY, errBuf);
            return;
        }

        String baseSlug = FastHttpParser.slugify(cr.title());
        List<String> tags = cr.tagList();
        String[] tagArray = (tags != null && !tags.isEmpty()) ? tags.toArray(new String[0]) : new String[0];

        pgClient.preparedQuery(CREATE_ARTICLE_SINGLE_TRIP_SQL,
                Tuple.of(req.viewerId(), baseSlug, cr.title(), cr.description(), cr.body(), (Object) tagArray)
        ).onComplete(ar -> {
            if (ar.succeeded() && ar.result().size() > 0) {
                Row row = ar.result().iterator().next();
                ByteBuf buf = req.alloc();
                JsonStreamer.writeArticle(buf, row, true);
                req.send(HttpResponseStatus.CREATED, buf);
            } else {
                sendInternalError(req);
            }
        });
    }

    public static void handleUpdateArticle(RequestContext req, PostgresClient pgClient, String slug) {
        if (req.viewerId() == 0) {
            ByteBuf errBuf = req.alloc();
            JsonStreamer.writeError(errBuf, "missing or invalid authorization token");
            req.send(HttpResponseStatus.UNAUTHORIZED, errBuf);
            return;
        }

        JsonReader.ArticleUpdateRequest ur = JsonReader.parseArticleUpdate(req.request().content());
        if (!ur.valid()) {
            ByteBuf errBuf = req.alloc();
            JsonStreamer.writeError(errBuf, "Invalid article parameters");
            req.send(HttpResponseStatus.UNPROCESSABLE_ENTITY, errBuf);
            return;
        }

        String title = ur.hasTitle() ? ur.title() : null;
        String description = ur.hasDescription() ? ur.description() : null;
        String body = ur.hasBody() ? ur.body() : null;
        String baseSlug = title != null ? FastHttpParser.slugify(title) : null;

        pgClient.preparedQuery(UPDATE_ARTICLE_SINGLE_TRIP_SQL,
                Tuple.of(slug, req.viewerId(), title, description, body, baseSlug)
        ).onComplete(ar -> {
            if (ar.succeeded() && ar.result().size() > 0) {
                Row row = ar.result().iterator().next();
                long authorId = row.getLong("author_id");
                if (authorId != req.viewerId()) {
                    ByteBuf errBuf = req.alloc();
                    JsonStreamer.writeError(errBuf, "Forbidden");
                    req.send(HttpResponseStatus.FORBIDDEN, errBuf);
                } else {
                    ByteBuf buf = req.alloc();
                    JsonStreamer.writeArticle(buf, row, true);
                    req.send(HttpResponseStatus.OK, buf);
                }
            } else {
                ByteBuf errBuf = req.alloc();
                JsonStreamer.writeError(errBuf, "Article not found");
                req.send(HttpResponseStatus.NOT_FOUND, errBuf);
            }
        });
    }

    public static void handleDeleteArticle(RequestContext req, PostgresClient pgClient, String slug) {
        if (req.viewerId() == 0) {
            ByteBuf errBuf = req.alloc();
            JsonStreamer.writeError(errBuf, "missing or invalid authorization token");
            req.send(HttpResponseStatus.UNAUTHORIZED, errBuf);
            return;
        }

        pgClient.preparedQuery(DELETE_ARTICLE_SINGLE_TRIP_SQL, Tuple.of(slug, req.viewerId())).onComplete(ar -> {
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
                JsonStreamer.writeError(errBuf, "Article not found");
                req.send(HttpResponseStatus.NOT_FOUND, errBuf);
            }
        });
    }

    public static void sendArticleById(RequestContext req, PostgresClient pgClient, long articleId, HttpResponseStatus status) {
        pgClient.preparedQuery(GET_ARTICLE_BY_ID_SQL, Tuple.of(req.viewerId(), articleId)).onComplete(ar -> {
            if (ar.succeeded() && ar.result().size() > 0) {
                Row row = ar.result().iterator().next();
                ByteBuf buf = req.alloc();
                JsonStreamer.writeArticle(buf, row, true);
                req.send(status, buf);
            } else {
                ByteBuf errBuf = req.alloc();
                JsonStreamer.writeError(errBuf, "Article not found");
                req.send(HttpResponseStatus.NOT_FOUND, errBuf);
            }
        });
    }

    private static void sendInternalError(RequestContext req) {
        ByteBuf errBuf = req.alloc();
        JsonStreamer.writeError(errBuf, "Internal database query error");
        req.send(HttpResponseStatus.INTERNAL_SERVER_ERROR, errBuf);
    }
}
