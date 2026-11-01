package conduit.writes;

import static conduit.ArticleSql.articleColumns;
import static conduit.ArticleSql.favorited;
import static conduit.ArticleSql.following;
import static conduit.ArticleSql.fullArticleFor;

import conduit.Exchange;
import conduit.RequestBody;
import conduit.db.MessageWriter;
import conduit.db.Row;
import conduit.db.Statement;
import conduit.json.Render;
import java.util.List;

/** POST /api/articles, PUT and DELETE /api/articles/:slug, POST and DELETE /api/articles/:slug/favorite. */
public final class ArticleWrites {
    /** SLUGIFY(x) from the spec: lowercase ASCII letters and digits, every other run of characters becomes '-'. */
    private static String slugify(String text) {
        return "trim(both '-' from lower(regexp_replace(" + text + ", '[^A-Za-z0-9]+', '-', 'g')))";
    }

    private static final String NEW_ARTICLE_ID = "(SELECT currval(pg_get_serial_sequence('articles', 'id')))";

    // $1 author, $2 title, $3 description, $4 body
    private static final Statement INSERT_ARTICLE = Statement.define(
            "INSERT INTO articles (id, slug, author_id, title, description, body)"
                    + " SELECT n.id, " + slugify("$2") + " || '-' || n.id, $1, $2, $3, $4"
                    + "   FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n",
            Statement.INT8, Statement.TEXT, Statement.TEXT, Statement.TEXT);

    // Only tags that don't exist yet are inserted (no sequence numbers burnt), in name order (so two concurrent
    // creates never wait for each other's tags in opposite orders).
    private static final Statement INSERT_TAGS = Statement.define(
            "INSERT INTO tags (name)"
                    + " SELECT n FROM (SELECT DISTINCT unnest($1::text[]) AS n) x"
                    + "  WHERE NOT EXISTS (SELECT 1 FROM tags t WHERE t.name = x.n)"
                    + "  ORDER BY n"
                    + " ON CONFLICT (name) DO NOTHING",
            Statement.TEXT_ARRAY);

    private static final Statement INSERT_ARTICLE_TAGS = Statement.define(
            "INSERT INTO article_tags (article_id, tag_id)"
                    + " SELECT " + NEW_ARTICLE_ID + ", t.id FROM tags t WHERE t.name = ANY ($1::text[])",
            Statement.TEXT_ARRAY);

    private static final Statement NEW_ARTICLE = Statement.define(fullArticleFor("a.id = " + NEW_ARTICLE_ID), Statement.INT8);

    // $1 viewer, $2 slug, $3 title, $4 description, $5 body; only the author's own article matches
    private static final Statement UPDATE_ARTICLE = Statement.define(
            "WITH a AS ("
                    + "   UPDATE articles SET title = COALESCE($3, title), description = COALESCE($4, description),"
                    + "          body = COALESCE($5, body),"
                    + "          slug = CASE WHEN $3::text IS NULL THEN slug ELSE " + slugify("$3") + " || '-' || id END,"
                    + "          updated_at = now()"
                    + "    WHERE slug = $2 AND author_id = $1"
                    + "   RETURNING id, slug, title, description, body, created_at, updated_at, author_id)"
                    + " SELECT " + articleColumns(true) + ", " + favorited("$1", "a.id") + ", " + following("$1", "a.author_id")
                    + "   FROM a JOIN users u ON u.id = a.author_id",
            Statement.INT8, Statement.TEXT, Statement.TEXT, Statement.TEXT, Statement.TEXT);

    private static final Statement DELETE_ARTICLE = Statement.define(
            "DELETE FROM articles WHERE slug = $2 AND author_id = $1", Statement.INT8, Statement.TEXT);

    /** After an update or delete matched nothing: does the article exist (403) or not (404)? */
    private static final Statement ARTICLE_EXISTS = Statement.define(
            "SELECT author_id FROM articles WHERE slug = $1", Statement.TEXT);

    private static final Statement FAVORITE = Statement.define(
            "INSERT INTO favorites (user_id, article_id) SELECT $1, a.id FROM articles a WHERE a.slug = $2"
                    + " ON CONFLICT DO NOTHING",
            Statement.INT8, Statement.TEXT);

    private static final Statement UNFAVORITE = Statement.define(
            "DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT a.id FROM articles a WHERE a.slug = $2)",
            Statement.INT8, Statement.TEXT);

    private static final Statement ARTICLE_BY_SLUG = Statement.define(fullArticleFor("a.slug = $2"),
            Statement.INT8, Statement.TEXT);

    private ArticleWrites() {
    }

    // ---------- create ----------

    public static void create(Exchange exchange, byte[] body) throws RequestBody.Invalid {
        RequestBody article = RequestBody.parse(body, "article");
        String title = article.required("title");
        String description = article.required("description");
        String text = article.required("body");
        List<String> tags = article.tagList();
        new CreateArticle(exchange, title, description, text, tags).submit();
    }

    /** The article, its tags and the read-back in one round trip and one transaction (committed at the Sync). */
    private static final class CreateArticle extends WriteQuery {
        private final String title, description, body;
        private final List<String> tags;

        CreateArticle(Exchange exchange, String title, String description, String body, List<String> tags) {
            super(exchange);
            this.title = title;
            this.description = description;
            this.body = body;
            this.tags = tags;
        }

        @Override
        public void write(MessageWriter out) {
            out.bind(INSERT_ARTICLE).int8(exchange.viewer).text(title).text(description).text(body).execute();
            if (!tags.isEmpty()) {
                out.bind(INSERT_TAGS).textArray(tags).execute();
                out.bind(INSERT_ARTICLE_TAGS).textArray(tags).execute();
            }
            out.bind(NEW_ARTICLE).int8(exchange.viewer).execute();
            out.sync();
        }

        @Override
        public void onRow(int statementIndex, Row row) {
            exchange.found = true;
            Render.articleResponse(exchange.json(), row, 0);
        }

        @Override
        protected void onSuccess() {
            if (exchange.found) exchange.respond(201);
            else exchange.respondError(500, "article not created");
        }
    }

    // ---------- update ----------

    public static void update(Exchange exchange, String slug, byte[] body) throws RequestBody.Invalid {
        RequestBody article = RequestBody.parse(body, "article");
        String title = article.optional("title", false);
        String description = article.optional("description", false);
        String text = article.optional("body", false);
        new UpdateArticle(exchange, slug, title, description, text).submit();
    }

    private static final class UpdateArticle extends WriteQuery {
        private final String slug, title, description, body;

        UpdateArticle(Exchange exchange, String slug, String title, String description, String body) {
            super(exchange);
            this.slug = slug;
            this.title = title;
            this.description = description;
            this.body = body;
        }

        @Override
        public void write(MessageWriter out) {
            out.bind(UPDATE_ARTICLE).int8(exchange.viewer).text(slug).text(title).text(description).text(body).execute();
            out.sync();
        }

        @Override
        public void onRow(int statementIndex, Row row) {
            exchange.found = true;
            Render.articleResponse(exchange.json(), row, 0);
        }

        @Override
        protected void onSuccess() {
            if (exchange.found) exchange.respond(200);
            else new ExplainNoMatch(exchange, slug).submit();
        }
    }

    // ---------- delete ----------

    public static void delete(Exchange exchange, String slug) {
        new DeleteArticle(exchange, slug).submit();
    }

    private static final class DeleteArticle extends WriteQuery {
        private final String slug;
        private boolean deleted;

        DeleteArticle(Exchange exchange, String slug) {
            super(exchange);
            this.slug = slug;
        }

        @Override
        public void write(MessageWriter out) {
            out.bind(DELETE_ARTICLE).int8(exchange.viewer).text(slug).execute();
            out.sync();
        }

        @Override
        public void onCommandComplete(int statementIndex, String tag) {
            deleted = !tag.equals("DELETE 0");
        }

        @Override
        protected void onSuccess() {
            if (deleted) exchange.respondNoContent();
            else new ExplainNoMatch(exchange, slug).submit();
        }
    }

    /** An update or delete of the viewer's article matched nothing: 404 if there is no such article, else 403. */
    private static final class ExplainNoMatch extends WriteQuery {
        private final String slug;

        ExplainNoMatch(Exchange exchange, String slug) {
            super(exchange);
            this.slug = slug;
        }

        @Override
        public void write(MessageWriter out) {
            out.bind(ARTICLE_EXISTS).text(slug).execute();
            out.sync();
        }

        @Override
        public void onRow(int statementIndex, Row row) {
            exchange.found = true;
        }

        @Override
        protected void onSuccess() {
            if (exchange.found) exchange.respondError(403, "only the author can change this article");
            else exchange.respondError(404, "article not found");
        }
    }

    // ---------- favorite / unfavorite ----------

    public static void favorite(Exchange exchange, String slug, boolean favorite) {
        new Favorite(exchange, slug, favorite).submit();
    }

    /**
     * The change, then the article as its own statement in the same round trip: a new statement gets a new snapshot,
     * so the count includes concurrent favorites that committed while the insert ran.
     */
    private static final class Favorite extends WriteQuery {
        private final String slug;
        private final boolean favorite;

        Favorite(Exchange exchange, String slug, boolean favorite) {
            super(exchange);
            this.slug = slug;
            this.favorite = favorite;
        }

        @Override
        public void write(MessageWriter out) {
            out.bind(favorite ? FAVORITE : UNFAVORITE).int8(exchange.viewer).text(slug).execute();
            out.bind(ARTICLE_BY_SLUG).int8(exchange.viewer).text(slug).execute();
            out.sync();
        }

        @Override
        public void onRow(int statementIndex, Row row) {
            exchange.found = true;
            Render.articleResponse(exchange.json(), row, 0);
        }

        @Override
        protected void onSuccess() {
            if (exchange.found) exchange.respond(200);
            else exchange.respondError(404, "article not found");
        }
    }
}
