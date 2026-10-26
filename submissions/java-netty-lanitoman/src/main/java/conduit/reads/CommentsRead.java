package conduit.reads;

import conduit.Exchange;
import conduit.db.Row;
import conduit.json.JsonWriter;
import conduit.json.Keys;
import conduit.json.Render;
import io.netty.buffer.ByteBufAllocator;
import java.util.Arrays;
import java.util.HashMap;

/**
 * GET /api/articles/:slug/comments: the newest 100 comments of an article, with each author's profile as the viewer
 * sees it. The comments of each distinct article of the batch are read, sent and rendered once ("shared" rows); each
 * request gets one row with its article's id and the viewer's followees (about twenty index entries), and every
 * comment's author is checked against those. A request whose article doesn't exist gets no row (404).
 *
 * <p>Rows: i, article id, followees, then (comment) id, body, created_at, updated_at, username, bio, image,
 * author_id. Shared rows have a NULL i and followees; request rows have NULL comment columns.
 */
final class CommentsRead extends BatchedRead<CommentsRead.Batch> {
    private static final int REQUEST = 0, ARTICLE_ID = 1, FOLLOWEES = 2, COMMENT = 3, CREATED_AT = 5, AUTHOR_ID = 10;

    private static final String SQL = "WITH r AS MATERIALIZED (SELECT * FROM " + REQUESTS + "),"
            + " a AS MATERIALIZED ("
            + "   SELECT k.key, a.id FROM (SELECT DISTINCT key FROM r) k"
            + "    CROSS JOIN LATERAL (SELECT a.id FROM articles a WHERE a.slug = k.key OFFSET 0) a),"
            + " c AS MATERIALIZED ("
            + "   SELECT a.id AS article_id, x.* FROM a CROSS JOIN LATERAL ("
            + "     SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, c.author_id"
            + "       FROM comments c JOIN users u ON u.id = c.author_id"
            + "      WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) x)"
            + " SELECT NULL::int4 AS i, c.article_id, NULL::int8[] AS followees,"
            + "        c.id, c.body, c.created_at, c.updated_at, c.username, c.bio, c.image, c.author_id"
            + "   FROM c"
            + " UNION ALL"
            + " SELECT r.i, a.id, ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.viewer),"
            + "        NULL::int8, NULL::text, NULL::timestamptz, NULL::timestamptz, NULL::text, NULL::text, NULL::text,"
            + "        NULL::int8"
            + "   FROM r JOIN a ON a.key = r.key";

    CommentsRead(int maxBatch) {
        super("comments", SQL, maxBatch);
    }

    /** The comments of one article: rendered fragments (up to the author's "following") and how to order them. */
    private static final class ArticleComments {
        long[] createdAt = new long[8];
        long[] ids = new long[8];
        long[] authorIds = new long[8];
        long[] fragments = new long[8];               // offset << 32 | length in the batch's fragment buffer
        int size;
        boolean sorted;

        void add(long created, long id, long authorId, long fragment) {
            if (size == ids.length) {
                createdAt = Arrays.copyOf(createdAt, size * 2);
                ids = Arrays.copyOf(ids, size * 2);
                authorIds = Arrays.copyOf(authorIds, size * 2);
                fragments = Arrays.copyOf(fragments, size * 2);
            }
            createdAt[size] = created;
            ids[size] = id;
            authorIds[size] = authorId;
            fragments[size] = fragment;
            size++;
            sorted = false;
        }

        /** Newest first: created_at DESC, id DESC, as the API orders comments (insertion sort, at most 100). */
        void sortNewestFirst() {
            if (sorted) return;
            for (int i = 1; i < size; i++) {
                long c = createdAt[i], id = ids[i], author = authorIds[i], fragment = fragments[i];
                int j = i - 1;
                for (; j >= 0 && (createdAt[j] < c || (createdAt[j] == c && ids[j] < id)); j--) {
                    createdAt[j + 1] = createdAt[j];
                    ids[j + 1] = ids[j];
                    authorIds[j + 1] = authorIds[j];
                    fragments[j + 1] = fragments[j];
                }
                createdAt[j + 1] = c;
                ids[j + 1] = id;
                authorIds[j + 1] = author;
                fragments[j + 1] = fragment;
            }
            sorted = true;
        }
    }

    /** One batch: the comments of each article, and per request its article and the viewer's followees. */
    static final class Batch {
        final JsonWriter fragments = new JsonWriter(ByteBufAllocator.DEFAULT, 16 * 1024);
        final HashMap<Long, ArticleComments> commentsByArticle = new HashMap<>();
        final long[] articleOfRequest;
        final long[][] followeesOfRequest;                 // sorted; null: the request's article doesn't exist

        Batch(int count) {
            articleOfRequest = new long[count];
            followeesOfRequest = new long[count][];
        }
    }

    @Override
    protected Batch newBatch(int count) {
        return new Batch(count);
    }

    @Override
    protected void onRow(Batch batch, Exchange[] requests, int count, Row row) {
        if (row.isNull(REQUEST)) {
            int start = batch.fragments.position();
            batch.fragments.startFragment();
            Render.commentOpen(batch.fragments, row, COMMENT);
            long fragment = ((long) start << 32) | (batch.fragments.position() - start);
            batch.commentsByArticle.computeIfAbsent(row.getLong(ARTICLE_ID), id -> new ArticleComments())
                    .add(row.getTimestampMicros(CREATED_AT), row.getLong(COMMENT), row.getLong(AUTHOR_ID), fragment);
            return;
        }
        int index = row.getInt(REQUEST);
        long[] followees = row.getLongArray(FOLLOWEES);
        Arrays.sort(followees);
        batch.articleOfRequest[index] = row.getLong(ARTICLE_ID);
        batch.followeesOfRequest[index] = followees;
    }

    /** {"comments": [...]}, each author's "following" from the viewer's followees. */
    @Override
    protected void finish(Batch batch, Exchange[] requests, int count) {
        answerEach(requests, count, i -> {
            long[] followees = batch.followeesOfRequest[i];
            if (followees == null) {
                requests[i].respondError(404, "article not found");
                return;
            }
            JsonWriter json = requests[i].json();
            json.beginObject().key(Keys.COMMENTS).beginArray();
            ArticleComments comments = batch.commentsByArticle.get(batch.articleOfRequest[i]);
            if (comments != null) {
                comments.sortNewestFirst();
                for (int k = 0; k < comments.size; k++) {
                    long fragment = comments.fragments[k];
                    json.openFragment(batch.fragments.buffer(), (int) (fragment >>> 32), (int) fragment);
                    Render.commentClose(json, Arrays.binarySearch(followees, comments.authorIds[k]) >= 0);
                }
            }
            json.endArray().endObject();
            requests[i].respond(200);
        });
    }

    @Override
    protected void release(Batch batch) {
        batch.fragments.release();
    }
}
