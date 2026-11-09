package conduit.adapters.outbound.postgres.jooq.comment;

import static conduit.generated.postgres.jooq.tables.Articles.ARTICLES;
import static conduit.generated.postgres.jooq.tables.Comments.COMMENTS;

import conduit.contracts.comment.CommentRepository;
import conduit.domain.Comment;
import conduit.errors.NotFound;
import org.jooq.DSLContext;

public final class JooqCommentRepository implements CommentRepository {
    private final DSLContext sql;

    public JooqCommentRepository(DSLContext sql) {
        this.sql = sql;
    }

    @Override
    public Comment comment(String slug, long id) {
        var row = sql.select(COMMENTS.ID, COMMENTS.ARTICLE_ID, COMMENTS.AUTHOR_ID, COMMENTS.BODY)
            .from(COMMENTS).join(ARTICLES).on(ARTICLES.ID.eq(COMMENTS.ARTICLE_ID))
            .where(COMMENTS.ID.eq(id).and(ARTICLES.SLUG.eq(slug))).forUpdate().of(COMMENTS)
            .fetchOne();
        if (row == null) {
            throw new NotFound("Not found");
        }
        return Comment.reconstitute(new Comment.Props(row.get(COMMENTS.ID),
            row.get(COMMENTS.ARTICLE_ID), row.get(COMMENTS.AUTHOR_ID), row.get(COMMENTS.BODY)));
    }

    @Override
    public Comment insertComment(Comment comment) {
        long id = sql.insertInto(COMMENTS).set(COMMENTS.ARTICLE_ID, comment.articleId())
            .set(COMMENTS.AUTHOR_ID, comment.authorId()).set(COMMENTS.BODY, comment.body())
            .returningResult(COMMENTS.ID).fetchSingle().value1();
        return Comment.reconstitute(
            new Comment.Props(id, comment.articleId(), comment.authorId(), comment.body()));
    }

    @Override
    public void deleteComment(long id) {
        sql.deleteFrom(COMMENTS).where(COMMENTS.ID.eq(id)).execute();
    }
}
