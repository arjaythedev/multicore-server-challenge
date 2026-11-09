package conduit.adapters.outbound.postgres.jooq.article;

import static conduit.generated.postgres.jooq.tables.ArticleTags.ARTICLE_TAGS;
import static conduit.generated.postgres.jooq.tables.Articles.ARTICLES;
import static conduit.generated.postgres.jooq.tables.Tags.TAGS;

import conduit.contracts.article.ArticleRepository;
import conduit.domain.Article;
import conduit.errors.NotFound;
import java.time.OffsetDateTime;
import java.util.List;
import org.jooq.DSLContext;
import org.jooq.impl.DSL;

public final class JooqArticleRepository implements ArticleRepository {
    private final DSLContext sql;

    public JooqArticleRepository(DSLContext sql) {
        this.sql = sql;
    }

    @Override
    public long nextArticleId() {
        return sql
            .select(DSL.field("nextval(pg_get_serial_sequence('articles', 'id'))", Long.class))
            .fetchSingle().value1();
    }

    @Override
    public long articleId(String slug) {
        var id = sql.select(ARTICLES.ID).from(ARTICLES).where(ARTICLES.SLUG.eq(slug))
            .fetchOne(ARTICLES.ID);
        if (id == null) {
            throw missing();
        }
        return id;
    }

    @Override
    public Article article(String slug) {
        var r = sql.selectFrom(ARTICLES).where(ARTICLES.SLUG.eq(slug)).forUpdate().fetchOne();
        if (r == null) {
            throw missing();
        }
        return Article.reconstitute(
            new Article.Props(r.get(ARTICLES.ID), r.get(ARTICLES.AUTHOR_ID), r.get(ARTICLES.SLUG),
                r.get(ARTICLES.TITLE), r.get(ARTICLES.DESCRIPTION), r.get(ARTICLES.BODY)));
    }

    @Override
    public void insert(Article article, List<String> tags) {
        sql.insertInto(ARTICLES).set(ARTICLES.ID, article.id())
            .set(ARTICLES.AUTHOR_ID, article.authorId()).set(ARTICLES.SLUG, article.slug())
            .set(ARTICLES.TITLE, article.title()).set(ARTICLES.DESCRIPTION, article.description())
            .set(ARTICLES.BODY, article.body()).execute();
        if (!tags.isEmpty()) {
            var insert = sql.insertInto(TAGS, TAGS.NAME);
            for (var tag : tags.stream().sorted().toList()) {
                insert = insert.values(tag);
            }
            insert.onConflict(TAGS.NAME).doNothing().execute();
            sql.insertInto(ARTICLE_TAGS, ARTICLE_TAGS.ARTICLE_ID, ARTICLE_TAGS.TAG_ID)
                .select(
                    DSL.select(DSL.val(article.id()), TAGS.ID).from(TAGS).where(TAGS.NAME.in(tags)))
                .execute();
        }
    }

    @Override
    public void update(Article article) {
        sql.update(ARTICLES).set(ARTICLES.TITLE, article.title())
            .set(ARTICLES.DESCRIPTION, article.description()).set(ARTICLES.BODY, article.body())
            .set(ARTICLES.SLUG, article.slug())
            .set(ARTICLES.UPDATED_AT, DSL.field("statement_timestamp()", OffsetDateTime.class))
            .where(ARTICLES.ID.eq(article.id())).execute();
    }

    @Override
    public void deleteArticle(long id) {
        sql.deleteFrom(ARTICLES).where(ARTICLES.ID.eq(id)).execute();
    }

    private static NotFound missing() {
        return new NotFound("Not found");
    }
}
