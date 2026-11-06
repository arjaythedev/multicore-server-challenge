package conduit.adapters.outbound.postgres.jooq.article;

import static conduit.generated.postgres.jooq.tables.ArticleTags.ARTICLE_TAGS;
import static conduit.generated.postgres.jooq.tables.Articles.ARTICLES;
import static conduit.generated.postgres.jooq.tables.Comments.COMMENTS;
import static conduit.generated.postgres.jooq.tables.Favorites.FAVORITES;
import static conduit.generated.postgres.jooq.tables.Follows.FOLLOWS;
import static conduit.generated.postgres.jooq.tables.Tags.TAGS;
import static conduit.generated.postgres.jooq.tables.Users.USERS;

import conduit.adapters.outbound.postgres.jooq.comment.CommentMapper;
import conduit.contracts.article.readmodel.ArticleDetails;
import conduit.contracts.article.readmodel.ArticlePage;
import conduit.contracts.article.ArticleReader;
import conduit.contracts.article.readmodel.ArticleSummary;
import conduit.contracts.article.readmodel.CommentView;
import conduit.contracts.article.readmodel.ProfileView;
import conduit.errors.NotFound;
import java.time.OffsetDateTime;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeFormatterBuilder;
import java.time.temporal.ChronoUnit;
import java.util.Arrays;
import java.util.List;
import org.jooq.Condition;
import org.jooq.DSLContext;
import org.jooq.Field;
import org.jooq.Record;
import org.jooq.SelectJoinStep;
import org.jooq.impl.DSL;

public final class JooqArticleReader implements ArticleReader {
    private static final DateTimeFormatter TIMESTAMP = new DateTimeFormatterBuilder()
        .appendInstant(3).toFormatter();
    private final DSLContext sql;

    public JooqArticleReader(DSLContext sql) {
        this.sql = sql;
    }

    @Override
    public ArticlePage list(long viewer, int limit, long offset, String tag, String author,
        String favorited) {
        Condition condition = DSL.noCondition();
        long count;
        if (tag != null) {
            var tagId = DSL.select(TAGS.ID).from(TAGS).where(TAGS.NAME.eq(tag));
            condition = ARTICLES.ID.in(DSL.select(ARTICLE_TAGS.ARTICLE_ID).from(ARTICLE_TAGS)
                .where(ARTICLE_TAGS.TAG_ID.eq(tagId)).orderBy(ARTICLE_TAGS.ARTICLE_ID.desc())
                .limit(limit).offset(offset));
            var page = listed(viewer, condition, null, 0);
            count = sql.fetchCount(DSL.selectOne().from(ARTICLE_TAGS)
                .where(ARTICLE_TAGS.TAG_ID.eq(tagId)).limit(1000));
            return new ArticlePage(page, count);
        } else if (author != null) {
            condition = ARTICLES.AUTHOR_ID
                .eq(DSL.select(USERS.ID).from(USERS).where(USERS.USERNAME.eq(author)));
        } else if (favorited != null) {
            var userId = DSL.select(USERS.ID).from(USERS).where(USERS.USERNAME.eq(favorited));
            condition = ARTICLES.ID.in(
                DSL.select(FAVORITES.ARTICLE_ID).from(FAVORITES).where(FAVORITES.USER_ID.eq(userId))
                    .orderBy(FAVORITES.ARTICLE_ID.desc()).limit(limit).offset(offset));
            var page = listed(viewer, condition, null, 0);
            count = sql.fetchCount(
                DSL.selectOne().from(FAVORITES).where(FAVORITES.USER_ID.eq(userId)).limit(1000));
            return new ArticlePage(page, count);
        }
        var page = listed(viewer, condition, limit, offset);
        count = sql.fetchCount(DSL.selectOne().from(ARTICLES).where(condition).limit(1000));
        return new ArticlePage(page, count);
    }

    @Override
    public ArticlePage feed(long viewer, int limit, long offset) {
        // Preserve the reference lateral top-N plan, which bounds work per followed
        // author.
        Condition pageCondition = DSL.condition(
            "{0} in (select x.id from follows fo cross join lateral "
                + "(select a2.id from articles a2 where a2.author_id = fo.followee_id order by a2.id desc limit {1}) x "
                + "where fo.follower_id = {2} order by x.id desc limit {3} offset {4})",
            ARTICLES.ID, DSL.val(offset > Long.MAX_VALUE - limit ? Long.MAX_VALUE : offset + limit),
            DSL.val(viewer), DSL.val(limit), DSL.val(offset));
        var page = listed(viewer, pageCondition, null, 0);
        var follows = DSL.select(FOLLOWS.FOLLOWEE_ID).from(FOLLOWS)
            .where(FOLLOWS.FOLLOWER_ID.eq(viewer));
        long count = sql.fetchCount(
            DSL.selectOne().from(ARTICLES).where(ARTICLES.AUTHOR_ID.in(follows)).limit(1000));
        return new ArticlePage(page, count);
    }

    @Override
    public ArticleDetails bySlug(long viewer, String slug) {
        return full(select(viewer, true).where(ARTICLES.SLUG.eq(slug)).fetchOne());
    }

    @Override
    public ArticleDetails byId(long viewer, long id) {
        return full(select(viewer, true).where(ARTICLES.ID.eq(id)).fetchOne());
    }

    @Override
    public List<CommentView> comments(long viewer, String slug) {
        var articleId = sql.select(ARTICLES.ID).from(ARTICLES).where(ARTICLES.SLUG.eq(slug))
            .fetchOne(ARTICLES.ID);
        if (articleId == null) {
            throw missing();
        }
        return selectComments(viewer).where(COMMENTS.ARTICLE_ID.eq(articleId))
            .orderBy(COMMENTS.CREATED_AT.desc(), COMMENTS.ID.desc()).limit(100)
            .fetch(CommentMapper::toView);
    }

    @Override
    public CommentView comment(long viewer, String slug, long id) {
        var row = selectComments(viewer).join(ARTICLES).on(ARTICLES.ID.eq(COMMENTS.ARTICLE_ID))
            .where(COMMENTS.ID.eq(id).and(ARTICLES.SLUG.eq(slug))).fetchOne();
        if (row == null) {
            throw new NotFound("Not found");
        }
        return CommentMapper.toView(row);
    }

    private SelectJoinStep<Record> selectComments(long viewer) {
        var following = COMMENTS.AUTHOR_ID.ne(viewer)
            .and(DSL.exists(DSL.selectOne().from(FOLLOWS).where(
                FOLLOWS.FOLLOWER_ID.eq(viewer).and(FOLLOWS.FOLLOWEE_ID.eq(COMMENTS.AUTHOR_ID)))));
        return sql
            .select(List.of(COMMENTS.ID, COMMENTS.BODY, COMMENTS.CREATED_AT, COMMENTS.UPDATED_AT,
                USERS.USERNAME, USERS.BIO, USERS.IMAGE, DSL.field(following).as("following")))
            .from(COMMENTS).join(USERS).on(USERS.ID.eq(COMMENTS.AUTHOR_ID));
    }

    private List<ArticleSummary> listed(long viewer, Condition condition, Integer limit,
        long offset) {
        var query = select(viewer, false).where(condition).orderBy(ARTICLES.ID.desc());
        var rows = limit == null ? query.fetch() : query.limit(limit).offset(offset).fetch();
        return rows.map(r -> new ArticleSummary(r.get(ARTICLES.SLUG), r.get(ARTICLES.TITLE),
            r.get(ARTICLES.DESCRIPTION), tags(r), timestamp(r.get(ARTICLES.CREATED_AT)),
            timestamp(r.get(ARTICLES.UPDATED_AT)), r.get("favorited", Boolean.class),
            r.get("favorites_count", Long.class), profile(r)));
    }

    private SelectJoinStep<Record> select(long viewer, boolean full) {
        var at = ARTICLE_TAGS.as("at");
        Field<String[]> tags = DSL.array(DSL.select(TAGS.NAME).from(at).join(TAGS)
            .on(TAGS.ID.eq(at.TAG_ID)).where(at.ARTICLE_ID.eq(ARTICLES.ID)).orderBy(TAGS.NAME))
            .as("tag_list");
        var count = DSL.selectCount().from(FAVORITES).where(FAVORITES.ARTICLE_ID.eq(ARTICLES.ID))
            .asField("favorites_count");
        var favorited = DSL
            .field(DSL.exists(DSL.selectOne().from(FAVORITES)
                .where(FAVORITES.ARTICLE_ID.eq(ARTICLES.ID).and(FAVORITES.USER_ID.eq(viewer)))))
            .as("favorited");
        var following = DSL
            .field(DSL.exists(DSL.selectOne().from(FOLLOWS).where(
                FOLLOWS.FOLLOWER_ID.eq(viewer).and(FOLLOWS.FOLLOWEE_ID.eq(ARTICLES.AUTHOR_ID)))))
            .as("following");
        java.util.ArrayList<Field<?>> fields = new java.util.ArrayList<>(
            List.of(ARTICLES.ID, ARTICLES.SLUG, ARTICLES.TITLE, ARTICLES.DESCRIPTION,
                ARTICLES.CREATED_AT, ARTICLES.UPDATED_AT, tags, count, favorited, USERS.USERNAME,
                USERS.BIO, USERS.IMAGE, following));
        if (full)
            fields.add(ARTICLES.BODY);
        return sql.select(fields).from(ARTICLES).join(USERS).on(USERS.ID.eq(ARTICLES.AUTHOR_ID));
    }

    private static ArticleDetails full(Record r) {
        if (r == null) {
            throw missing();
        }
        return new ArticleDetails(r.get(ARTICLES.SLUG), r.get(ARTICLES.TITLE),
            r.get(ARTICLES.DESCRIPTION), r.get(ARTICLES.BODY), tags(r),
            timestamp(r.get(ARTICLES.CREATED_AT)), timestamp(r.get(ARTICLES.UPDATED_AT)),
            r.get("favorited", Boolean.class), r.get("favorites_count", Long.class), profile(r));
    }

    private static ProfileView profile(Record r) {
        return new ProfileView(r.get(USERS.USERNAME), r.get(USERS.BIO), r.get(USERS.IMAGE),
            r.get("following", Boolean.class));
    }

    private static List<String> tags(Record r) {
        return List.copyOf(Arrays.asList(r.get("tag_list", String[].class)));
    }

    private static String timestamp(OffsetDateTime time) {
        return TIMESTAMP.format(time.toInstant().truncatedTo(ChronoUnit.MILLIS));
    }

    private static NotFound missing() {
        return new NotFound("Article not found");
    }
}
