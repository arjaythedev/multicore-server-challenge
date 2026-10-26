package conduit.reads;

import static conduit.ArticleSql.ARTICLE;
import static conduit.ArticleSql.FAVORITED;
import static conduit.ArticleSql.FOLLOWING;
import static conduit.ArticleSql.REQUEST;
import static conduit.ArticleSql.TOTAL;

import conduit.ArticleSql;
import conduit.Exchange;
import conduit.db.Row;
import conduit.json.JsonWriter;
import conduit.json.Keys;

/**
 * GET /api/articles (global, ?tag=, ?author=, ?favorited=) and GET /api/articles/feed: a page of articles, newest
 * first, and the capped count. One statement answers the whole batch in four steps:
 *
 * <ol>
 *   <li>page: each request's page of article ids, walking an index and stopping after limit + offset entries
 *       (the page is cut before anything is joined, so skipped rows cost an index step only);</li>
 *   <li>m: the viewer-independent part of every distinct article on those pages (tags, favorites count, author),
 *       read and sent once per article even when many requests show it, as the first page of the global list
 *       always is;</li>
 *   <li>n: the capped count, once per distinct filter value (or once per request for feeds);</li>
 *   <li>the request rows: which articles each request shows, with that viewer's favorited/following flags.</li>
 * </ol>
 *
 * Rows are laid out as in {@link ArticleSql#sharedArticles}. A request with an empty page gets one row with a NULL
 * article id, so that it still gets its count.
 */
final class ArticleListRead extends BatchedRead<ArticleBatch> {

    /** The global list: the primary key walked backwards. */
    static ArticleListRead global(int maxBatch) {
        return new ArticleListRead("list", maxBatch,
                "SELECT a.id FROM articles a ORDER BY a.id DESC LIMIT r.lim OFFSET r.off",
                // whether a 1000th article exists, read from the primary key in id order (old, all-visible pages):
                // cheaper than counting 1000 rows. The exact count is only needed below 1000.
                "SELECT CASE WHEN EXISTS (SELECT 1 FROM articles a ORDER BY a.id OFFSET 999) THEN 1000"
                        + " ELSE (SELECT count(*) FROM articles) END AS total",
                Counted.ONCE, ArticleSql.following("r.viewer", "m.author_id"));
    }

    static ArticleListRead byTag(int maxBatch) {
        return new ArticleListRead("tag", maxBatch,
                "SELECT at.article_id AS id FROM article_tags at"
                        + " WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.key)"
                        + " ORDER BY at.article_id DESC LIMIT r.lim OFFSET r.off",
                // Tags are popular (every seeded tag has over 1000 articles), so first ask whether a 1000th row
                // exists, which is cheaper than counting 1000 rows; count exactly only below that.
                "SELECT k.key, CASE WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = t.id"
                        + "                        ORDER BY at.article_id OFFSET 999) THEN 1000"
                        + "   ELSE (SELECT count(*) FROM article_tags at WHERE at.tag_id = t.id) END AS total"
                        + " FROM (SELECT DISTINCT key FROM r) k"
                        + " LEFT JOIN LATERAL (SELECT t.id FROM tags t WHERE t.name = k.key OFFSET 0) t ON true",
                Counted.PER_KEY, ArticleSql.following("r.viewer", "m.author_id"));
    }

    static ArticleListRead byAuthor(int maxBatch) {
        return new ArticleListRead("author", maxBatch,
                "SELECT a.id FROM articles a"
                        + " WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = r.key)"
                        + " ORDER BY a.id DESC LIMIT r.lim OFFSET r.off",
                perKey("SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = k.key)"),
                Counted.PER_KEY, ArticleSql.following("r.viewer", "m.author_id"));
    }

    static ArticleListRead favoritedBy(int maxBatch) {
        return new ArticleListRead("favorited", maxBatch,
                "SELECT f.article_id AS id FROM favorites f"
                        + " WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = r.key)"
                        + " ORDER BY f.article_id DESC LIMIT r.lim OFFSET r.off",
                perKey("SELECT 1 FROM favorites f WHERE f.user_id = (SELECT u.id FROM users u WHERE u.username = k.key)"),
                Counted.PER_KEY, ArticleSql.following("r.viewer", "m.author_id"));
    }

    /**
     * The viewer's feed: the newest limit + offset articles of each followed author, merged. Every author on the
     * page is followed by the viewer (same snapshot), so following is simply true.
     */
    static ArticleListRead feed(int maxBatch) {
        return new ArticleListRead("feed", maxBatch,
                "SELECT x.id FROM follows fo CROSS JOIN LATERAL ("
                        + "   SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id"
                        + "    ORDER BY a2.id DESC LIMIT r.lim + r.off) x"
                        + " WHERE fo.follower_id = r.viewer ORDER BY x.id DESC LIMIT r.lim OFFSET r.off",
                // The followees as an array: one index scan of articles_author_idx covers them all. Most users
                // follow prolific authors, so first ask whether a 1000th article exists (cheaper than counting
                // 1000 rows), and count exactly only below that.
                "SELECT r.i, CASE WHEN EXISTS (SELECT 1 FROM articles a WHERE a.author_id = ANY (f.followees) OFFSET 999)"
                        + "   THEN 1000"
                        + "   ELSE (SELECT count(*) FROM articles a WHERE a.author_id = ANY (f.followees)) END AS total"
                        + " FROM r CROSS JOIN LATERAL (SELECT ARRAY(SELECT fo.followee_id FROM follows fo"
                        + "                             WHERE fo.follower_id = r.viewer) AS followees OFFSET 0) f",
                Counted.PER_REQUEST, "true");
    }

    private enum Counted { ONCE, PER_KEY, PER_REQUEST }

    /** The capped count of {@code rows} for each distinct filter value k.key of the batch. */
    private static String perKey(String rows) {
        return "SELECT k.key, (SELECT count(*) FROM (" + rows + " LIMIT 1000) s) AS total"
                + " FROM (SELECT DISTINCT key FROM r) k";
    }

    private ArticleListRead(String name, int maxBatch, String pageIds, String counts, Counted counted, String following) {
        super(name, sql(pageIds, counts, counted, following), maxBatch);
    }

    private static String sql(String pageIds, String counts, Counted counted, String following) {
        String countJoin = switch (counted) {
            case ONCE -> "CROSS JOIN n";
            case PER_KEY -> "JOIN n ON n.key = r.key";
            case PER_REQUEST -> "JOIN n ON n.i = r.i";
        };
        return "WITH r AS MATERIALIZED (SELECT * FROM " + REQUESTS + "),"
                // The outer LIMIT 100 changes nothing (limit is at most 100) but bounds the planner's estimate: a
                // generic plan guesses that "LIMIT r.lim" returns 10% of the table, and would size every hash table
                // of the statement for millions of rows (megabytes allocated per execution).
                + " page AS MATERIALIZED (SELECT r.i, p.id FROM r CROSS JOIN LATERAL ("
                + "   SELECT * FROM (" + pageIds + ") ids LIMIT 100) p),"
                + " m AS MATERIALIZED ("
                + "   SELECT m.* FROM (SELECT DISTINCT id FROM page) d " + ArticleSql.lateralArticle("a.id = d.id", false) + "),"
                + " n AS MATERIALIZED (" + counts + ")"
                + ArticleSql.sharedArticles(false,
                        "r.i, n.total, " + ArticleSql.favorited("r.viewer", "p.id") + ", " + following + ", p.id",
                        "FROM r " + countJoin + " LEFT JOIN page p ON p.i = r.i LEFT JOIN m ON m.id = p.id");
    }

    @Override
    protected ArticleBatch newBatch(int count) {
        return new ArticleBatch(count);
    }

    /** A shared article, or one article of a request's page (article id NULL: the page is empty). */
    @Override
    protected void onRow(ArticleBatch batch, Exchange[] requests, int count, Row row) {
        if (row.isNull(REQUEST)) {
            batch.addArticle(row, ARTICLE, false);
            return;
        }
        ArticleBatch.Page page = batch.pageFor(row.getInt(REQUEST));
        page.total = row.getLong(TOTAL);
        if (!row.isNull(ARTICLE)) page.add(row.getLong(ARTICLE), row.getBoolean(FAVORITED), row.getBoolean(FOLLOWING));
    }

    /** {"articles": [...newest first...], "articlesCount": n} */
    @Override
    protected void finish(ArticleBatch batch, Exchange[] requests, int count) {
        answerEach(requests, count, i -> {
            ArticleBatch.Page page = batch.pageFor(i);
            page.sortNewestFirst();
            JsonWriter json = requests[i].json();
            json.beginObject().key(Keys.ARTICLES).beginArray();
            for (int k = 0; k < page.size; k++) batch.writeArticle(json, page, k);
            json.endArray().key(Keys.ARTICLES_COUNT).value(page.total).endObject();
            requests[i].respond(200);
        });
    }

    @Override
    protected void release(ArticleBatch batch) {
        batch.release();
    }
}
