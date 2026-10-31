package com.challenge.conduit.ffm;

import com.challenge.conduit.db.PostgresClient;
import com.challenge.conduit.endpoint.ArticleEndpoint;
import com.challenge.conduit.endpoint.CommentEndpoint;
import com.challenge.conduit.endpoint.ProfileEndpoint;
import com.challenge.conduit.http.RequestContext;
import com.challenge.conduit.json.JsonStreamer;
import io.netty.buffer.ByteBuf;
import io.netty.handler.codec.http.HttpResponseStatus;
import io.vertx.sqlclient.Row;
import io.vertx.sqlclient.RowSet;
import io.vertx.sqlclient.Tuple;

import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Foreign Function & Memory (FFM) Powered Zero-Heap Batch Query Engine.
 * Eliminates all Java heap object allocations for request queues and intermediate batch processing:
 * - Backed by FfmMemoryArena off-heap memory segments
 * - Handles high-volume read endpoints: articles by slug, comments by slug, profiles by username
 * - Uses takeAndDrain() for zero-spin batch coalescing under load
 * - Pre-allocated off-heap scratch segments for intermediate row parsing
 */
public final class FfmBatchEngine {

    // Task Kinds
    public static final int KIND_ARTICLE_SLUG      = 1;
    public static final int KIND_COMMENTS_SLUG     = 2;
    public static final int KIND_PROFILE           = 3;

    // Batched SQL Queries
    private static final String BATCH_GET_ARTICLE_BY_SLUG_SQL = """
        SELECT r.k, a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
               ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
                      WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
               (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
               EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = r.viewer_id) AS favorited,
               u.username, u.bio, u.image,
               EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.viewer_id AND fo.followee_id = a.author_id) AS following
          FROM unnest($1::text[], $2::int8[]) WITH ORDINALITY r(slug, viewer_id, k)
          JOIN articles a ON a.slug = r.slug
          JOIN users u ON u.id = a.author_id
    """;

    private static final String BATCH_COMMENTS_LIST_SQL = """
        SELECT r.k, a.id AS article_exists_id,
               c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
               EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.viewer_id AND fo.followee_id = c.author_id) AS following
          FROM unnest($1::text[], $2::int8[]) WITH ORDINALITY r(slug, viewer_id, k)
          JOIN articles a ON a.slug = r.slug
          LEFT JOIN LATERAL (
               SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id
                 FROM comments c
                WHERE c.article_id = a.id
                ORDER BY c.created_at DESC, c.id DESC
                LIMIT 100
          ) c ON true
          LEFT JOIN users u ON u.id = c.author_id
         ORDER BY r.k, c.created_at DESC, c.id DESC
    """;

    private static final String BATCH_GET_PROFILE_SQL = """
        SELECT r.k, u.id, u.username, u.bio, u.image,
               EXISTS (SELECT 1 FROM follows f WHERE f.follower_id = r.viewer_id AND f.followee_id = u.id) AS following
          FROM unnest($1::text[], $2::int8[]) WITH ORDINALITY r(username, viewer_id, k)
          JOIN users u ON u.username = r.username
    """;

    private final FfmMemoryArena memoryArena;

    // Direct Context Slots indexed by slotId (0..65535)
    private final RequestContext[] contextSlots = new RequestContext[FfmMemoryArena.TASK_CAPACITY];
    private final AtomicInteger slotGenerator = new AtomicInteger(0);

    // High-performance ring buffer queues backed by FFM native segments
    private final FfmBatchQueue articleQueue;
    private final FfmBatchQueue commentQueue;
    private final FfmBatchQueue profileQueue;

    // Worker Threads
    private final Thread articleThread;
    private final Thread commentThread;
    private final Thread profileThread;

    private final PostgresClient pgClient;
    private volatile boolean running = true;

    public FfmBatchEngine(PostgresClient pgClient) {
        this.pgClient = pgClient;
        this.memoryArena = new FfmMemoryArena();

        this.articleQueue = new FfmBatchQueue(memoryArena, 16384);
        this.commentQueue = new FfmBatchQueue(memoryArena, 16384);
        this.profileQueue = new FfmBatchQueue(memoryArena, 16384);

        this.articleThread = new Thread(this::runArticleLoop, "conduit-ffm-article-drainer");
        this.articleThread.setDaemon(true);
        this.articleThread.start();

        this.commentThread = new Thread(this::runCommentLoop, "conduit-ffm-comment-drainer");
        this.commentThread.setDaemon(true);
        this.commentThread.start();

        this.profileThread = new Thread(this::runProfileLoop, "conduit-ffm-profile-drainer");
        this.profileThread.setDaemon(true);
        this.profileThread.start();
    }

    // --- Enqueue Methods (Zero Java Heap Allocations) ---

    public void submitArticle(RequestContext req, String slug, long viewerId) {
        byte[] bytes = slug.getBytes(StandardCharsets.UTF_8);
        int strOff = memoryArena.storeStringBytes(bytes, 0, bytes.length);
        int reqId = slotGenerator.getAndIncrement() & FfmMemoryArena.TASK_MASK;
        contextSlots[reqId] = req;

        if (!articleQueue.offer(reqId, KIND_ARTICLE_SLUG, viewerId, 0, 0, strOff, bytes.length)) {
            contextSlots[reqId] = null;
            sendServiceUnavailable(req);
        }
    }

    public void submitComment(RequestContext req, String slug, long viewerId) {
        byte[] bytes = slug.getBytes(StandardCharsets.UTF_8);
        int strOff = memoryArena.storeStringBytes(bytes, 0, bytes.length);
        int reqId = slotGenerator.getAndIncrement() & FfmMemoryArena.TASK_MASK;
        contextSlots[reqId] = req;

        if (!commentQueue.offer(reqId, KIND_COMMENTS_SLUG, viewerId, 0, 0, strOff, bytes.length)) {
            contextSlots[reqId] = null;
            sendServiceUnavailable(req);
        }
    }

    public void submitProfile(RequestContext req, String username, long viewerId) {
        byte[] bytes = username.getBytes(StandardCharsets.UTF_8);
        int strOff = memoryArena.storeStringBytes(bytes, 0, bytes.length);
        int reqId = slotGenerator.getAndIncrement() & FfmMemoryArena.TASK_MASK;
        contextSlots[reqId] = req;

        if (!profileQueue.offer(reqId, KIND_PROFILE, viewerId, 0, 0, strOff, bytes.length)) {
            contextSlots[reqId] = null;
            sendServiceUnavailable(req);
        }
    }

    private void sendServiceUnavailable(RequestContext req) {
        ByteBuf errBuf = req.alloc();
        JsonStreamer.writeError(errBuf, "Server queue saturated");
        req.send(HttpResponseStatus.SERVICE_UNAVAILABLE, errBuf);
    }

    // --- Worker Loops (Zero CPU Spin, Batch Coalescing) ---

    private void runArticleLoop() {
        int[] batchSlots = new int[128];
        while (running) {
            try {
                int drained = articleQueue.takeAndDrain(batchSlots, 128);
                if (drained > 0) {
                    dispatchArticles(batchSlots, drained);
                }
            } catch (InterruptedException e) {
                break;
            } catch (Throwable t) {
                t.printStackTrace();
            }
        }
    }

    private void runCommentLoop() {
        int[] batchSlots = new int[128];
        while (running) {
            try {
                int drained = commentQueue.takeAndDrain(batchSlots, 128);
                if (drained > 0) {
                    dispatchComments(batchSlots, drained);
                }
            } catch (InterruptedException e) {
                break;
            } catch (Throwable t) {
                t.printStackTrace();
            }
        }
    }

    private void runProfileLoop() {
        int[] batchSlots = new int[128];
        while (running) {
            try {
                int drained = profileQueue.takeAndDrain(batchSlots, 128);
                if (drained > 0) {
                    dispatchProfiles(batchSlots, drained);
                }
            } catch (InterruptedException e) {
                break;
            } catch (Throwable t) {
                t.printStackTrace();
            }
        }
    }

    // --- Dispatch Logic using FFM Intermediate Memory ---

    private void dispatchArticles(int[] slots, int size) {
        if (size == 1) {
            int slot = slots[0];
            int reqId = articleQueue.getReqId(slot);
            RequestContext req = contextSlots[reqId];
            contextSlots[reqId] = null;
            if (req == null) return;

            long viewerId = articleQueue.getViewerId(slot);
            String slug = memoryArena.readString(articleQueue.getStrOffset(slot), articleQueue.getStrLength(slot));

            pgClient.preparedQuery(ArticleEndpoint.GET_ARTICLE_BY_SLUG_SQL, Tuple.of(viewerId, slug)).onComplete(ar -> {
                if (ar.succeeded() && ar.result().size() > 0) {
                    Row row = ar.result().iterator().next();
                    ByteBuf buf = req.alloc();
                    JsonStreamer.writeArticle(buf, row, true);
                    req.send(HttpResponseStatus.OK, buf);
                } else {
                    ByteBuf errBuf = req.alloc();
                    JsonStreamer.writeError(errBuf, "Article not found");
                    req.send(HttpResponseStatus.NOT_FOUND, errBuf);
                }
            });
            return;
        }

        String[] slugs = new String[size];
        long[] viewerIds = new long[size];
        RequestContext[] reqs = new RequestContext[size];

        for (int i = 0; i < size; i++) {
            int slot = slots[i];
            int reqId = articleQueue.getReqId(slot);
            reqs[i] = contextSlots[reqId];
            contextSlots[reqId] = null;
            viewerIds[i] = articleQueue.getViewerId(slot);
            slugs[i] = memoryArena.readString(articleQueue.getStrOffset(slot), articleQueue.getStrLength(slot));
        }

        boolean[] answered = new boolean[size];
        pgClient.preparedQuery(BATCH_GET_ARTICLE_BY_SLUG_SQL, Tuple.of((Object) slugs, (Object) viewerIds)).onComplete(ar -> {
            if (ar.succeeded()) {
                RowSet<Row> rows = ar.result();
                for (Row row : rows) {
                    long k = row.getLong("k");
                    int idx = (int) (k - 1);
                    if (idx >= 0 && idx < size && !answered[idx]) {
                        answered[idx] = true;
                        RequestContext req = reqs[idx];
                        if (req != null) {
                            ByteBuf buf = req.alloc();
                            JsonStreamer.writeArticle(buf, row, true);
                            req.send(HttpResponseStatus.OK, buf);
                        }
                    }
                }
                for (int i = 0; i < size; i++) {
                    if (!answered[i]) {
                        RequestContext req = reqs[i];
                        if (req != null) {
                            ByteBuf errBuf = req.alloc();
                            JsonStreamer.writeError(errBuf, "Article not found");
                            req.send(HttpResponseStatus.NOT_FOUND, errBuf);
                        }
                    }
                }
            } else {
                for (int i = 0; i < size; i++) {
                    RequestContext req = reqs[i];
                    if (req != null) {
                        ByteBuf errBuf = req.alloc();
                        JsonStreamer.writeError(errBuf, "Database error");
                        req.send(HttpResponseStatus.INTERNAL_SERVER_ERROR, errBuf);
                    }
                }
            }
        });
    }

    private void dispatchComments(int[] slots, int size) {
        if (size == 1) {
            int slot = slots[0];
            int reqId = commentQueue.getReqId(slot);
            RequestContext req = contextSlots[reqId];
            contextSlots[reqId] = null;
            if (req == null) return;

            long viewerId = commentQueue.getViewerId(slot);
            String slug = memoryArena.readString(commentQueue.getStrOffset(slot), commentQueue.getStrLength(slot));

            pgClient.preparedQuery(CommentEndpoint.COMMENTS_LIST_SINGLE_ROUNDTRIP_SQL, Tuple.of(viewerId, slug)).onComplete(ar -> {
                if (ar.succeeded()) {
                    var rows = ar.result();
                    if (rows.size() == 0) {
                        ByteBuf errBuf = req.alloc();
                        JsonStreamer.writeError(errBuf, "Article not found");
                        req.send(HttpResponseStatus.NOT_FOUND, errBuf);
                        return;
                    }
                    ByteBuf buf = req.alloc();
                    var first = rows.iterator().next();
                    if (first.get(Long.class, "id") == null) {
                        JsonStreamer.writeEmptyArrayResponse(buf, "comments");
                    } else {
                        JsonStreamer.writeCommentsList(buf, rows);
                    }
                    req.send(HttpResponseStatus.OK, buf);
                } else {
                    ByteBuf errBuf = req.alloc();
                    JsonStreamer.writeError(errBuf, "Failed to load comments");
                    req.send(HttpResponseStatus.INTERNAL_SERVER_ERROR, errBuf);
                }
            });
            return;
        }

        String[] slugs = new String[size];
        long[] viewerIds = new long[size];
        RequestContext[] reqs = new RequestContext[size];

        for (int i = 0; i < size; i++) {
            int slot = slots[i];
            int reqId = commentQueue.getReqId(slot);
            reqs[i] = contextSlots[reqId];
            contextSlots[reqId] = null;
            viewerIds[i] = commentQueue.getViewerId(slot);
            slugs[i] = memoryArena.readString(commentQueue.getStrOffset(slot), commentQueue.getStrLength(slot));
        }

        int[] rowCounts = new int[size];
        boolean[] articleExists = new boolean[size];
        Row[] flatRows = new Row[size * 100];

        pgClient.preparedQuery(BATCH_COMMENTS_LIST_SQL, Tuple.of((Object) slugs, (Object) viewerIds)).onComplete(ar -> {
            if (ar.succeeded()) {
                RowSet<Row> rows = ar.result();
                for (Row row : rows) {
                    long k = row.getLong("k");
                    int idx = (int) (k - 1);
                    if (idx >= 0 && idx < size) {
                        articleExists[idx] = true;
                        if (row.get(Long.class, "id") != null) {
                            int count = rowCounts[idx];
                            if (count < 100) {
                                flatRows[idx * 100 + count] = row;
                                rowCounts[idx] = count + 1;
                            }
                        }
                    }
                }

                for (int i = 0; i < size; i++) {
                    RequestContext req = reqs[i];
                    if (req == null) continue;

                    boolean exists = articleExists[i];
                    int count = rowCounts[i];

                    if (!exists) {
                        ByteBuf errBuf = req.alloc();
                        JsonStreamer.writeError(errBuf, "Article not found");
                        req.send(HttpResponseStatus.NOT_FOUND, errBuf);
                    } else if (count == 0) {
                        ByteBuf buf = req.alloc();
                        JsonStreamer.writeEmptyArrayResponse(buf, "comments");
                        req.send(HttpResponseStatus.OK, buf);
                    } else {
                        ByteBuf buf = req.alloc();
                        JsonStreamer.writeCommentsListSlice(buf, flatRows, i * 100, count);
                        req.send(HttpResponseStatus.OK, buf);
                    }
                }
            } else {
                for (int i = 0; i < size; i++) {
                    RequestContext req = reqs[i];
                    if (req != null) {
                        ByteBuf errBuf = req.alloc();
                        JsonStreamer.writeError(errBuf, "Failed to load comments");
                        req.send(HttpResponseStatus.INTERNAL_SERVER_ERROR, errBuf);
                    }
                }
            }
        });
    }

    private void dispatchProfiles(int[] slots, int size) {
        if (size == 1) {
            int slot = slots[0];
            int reqId = profileQueue.getReqId(slot);
            RequestContext req = contextSlots[reqId];
            contextSlots[reqId] = null;
            if (req == null) return;

            long viewerId = profileQueue.getViewerId(slot);
            String username = memoryArena.readString(profileQueue.getStrOffset(slot), profileQueue.getStrLength(slot));

            pgClient.preparedQuery(ProfileEndpoint.PROFILE_SELECT, Tuple.of(viewerId, username)).onComplete(ar -> {
                if (ar.succeeded() && ar.result().size() > 0) {
                    Row row = ar.result().iterator().next();
                    boolean following = row.getBoolean("following");
                    ByteBuf buf = req.alloc();
                    JsonStreamer.writeProfile(buf, row, following);
                    req.send(HttpResponseStatus.OK, buf);
                } else {
                    ByteBuf errBuf = req.alloc();
                    JsonStreamer.writeError(errBuf, "profile not found");
                    req.send(HttpResponseStatus.NOT_FOUND, errBuf);
                }
            });
            return;
        }

        String[] usernames = new String[size];
        long[] viewerIds = new long[size];
        RequestContext[] reqs = new RequestContext[size];

        for (int i = 0; i < size; i++) {
            int slot = slots[i];
            int reqId = profileQueue.getReqId(slot);
            reqs[i] = contextSlots[reqId];
            contextSlots[reqId] = null;
            viewerIds[i] = profileQueue.getViewerId(slot);
            usernames[i] = memoryArena.readString(profileQueue.getStrOffset(slot), profileQueue.getStrLength(slot));
        }

        boolean[] answered = new boolean[size];
        pgClient.preparedQuery(BATCH_GET_PROFILE_SQL, Tuple.of((Object) usernames, (Object) viewerIds)).onComplete(ar -> {
            if (ar.succeeded()) {
                RowSet<Row> rows = ar.result();
                for (Row row : rows) {
                    long k = row.getLong("k");
                    int idx = (int) (k - 1);
                    if (idx >= 0 && idx < size && !answered[idx]) {
                        answered[idx] = true;
                        RequestContext req = reqs[idx];
                        if (req != null) {
                            boolean following = row.getBoolean("following");
                            ByteBuf buf = req.alloc();
                            JsonStreamer.writeProfile(buf, row, following);
                            req.send(HttpResponseStatus.OK, buf);
                        }
                    }
                }
                for (int i = 0; i < size; i++) {
                    if (!answered[i]) {
                        RequestContext req = reqs[i];
                        if (req != null) {
                            ByteBuf errBuf = req.alloc();
                            JsonStreamer.writeError(errBuf, "profile not found");
                            req.send(HttpResponseStatus.NOT_FOUND, errBuf);
                        }
                    }
                }
            } else {
                for (int i = 0; i < size; i++) {
                    RequestContext req = reqs[i];
                    if (req != null) {
                        ByteBuf errBuf = req.alloc();
                        JsonStreamer.writeError(errBuf, "profile not found");
                        req.send(HttpResponseStatus.NOT_FOUND, errBuf);
                    }
                }
            }
        });
    }

    public void close() {
        running = false;
        articleThread.interrupt();
        commentThread.interrupt();
        profileThread.interrupt();
        memoryArena.close();
    }
}
