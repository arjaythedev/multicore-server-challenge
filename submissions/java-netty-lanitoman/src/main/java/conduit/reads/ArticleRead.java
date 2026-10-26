package conduit.reads;

import static conduit.ArticleSql.ARTICLE;
import static conduit.ArticleSql.FAVORITED;
import static conduit.ArticleSql.FOLLOWING;
import static conduit.ArticleSql.REQUEST;

import conduit.ArticleSql;
import conduit.Exchange;
import conduit.db.Row;
import conduit.json.Keys;

/**
 * GET /api/articles/:slug. Popular articles are often asked for by several requests of a batch: each distinct slug's
 * article (its tags, favorites count and author) is read and sent once, and every request that asked for it gets
 * its own favorited/following flags.
 */
final class ArticleRead extends BatchedRead<ArticleBatch> {
    private static final String SQL = "WITH r AS MATERIALIZED (SELECT * FROM " + REQUESTS + "),"
            + " m AS MATERIALIZED ("
            + "   SELECT m.* FROM (SELECT DISTINCT key FROM r) k " + ArticleSql.lateralArticle("a.slug = k.key", true) + ")"
            + ArticleSql.sharedArticles(true,
                    "r.i, NULL::int8, " + ArticleSql.favorited("r.viewer", "m.id") + ", "
                            + ArticleSql.following("r.viewer", "m.author_id") + ", m.id",
                    "FROM r JOIN m ON m.slug = r.key");

    ArticleRead(int maxBatch) {
        super("article", SQL, maxBatch);
    }

    @Override
    protected ArticleBatch newBatch(int count) {
        return new ArticleBatch(count);
    }

    @Override
    protected void onRow(ArticleBatch batch, Exchange[] requests, int count, Row row) {
        if (row.isNull(REQUEST)) batch.addArticle(row, ARTICLE, true);
        else batch.pageFor(row.getInt(REQUEST)).add(row.getLong(ARTICLE), row.getBoolean(FAVORITED), row.getBoolean(FOLLOWING));
    }

    @Override
    protected void finish(ArticleBatch batch, Exchange[] requests, int count) {
        answerEach(requests, count, i -> {
            ArticleBatch.Page page = batch.page(i);
            if (page == null) {
                requests[i].respondError(404, "article not found");
                return;
            }
            requests[i].json().beginObject().key(Keys.ARTICLE);
            batch.writeArticle(requests[i].json(), page, 0);
            requests[i].json().endObject();
            requests[i].respond(200);
        });
    }

    @Override
    protected void release(ArticleBatch batch) {
        batch.release();
    }
}
