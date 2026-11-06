package conduit.usecases.commands;

import conduit.contracts.UnitOfWork;
import conduit.contracts.article.ArticleReader;
import conduit.contracts.article.readmodel.CommentView;
import conduit.domain.Comment;

public final class AddComment {
    private final ArticleReader reader;
    private final UnitOfWork uow;

    public AddComment(ArticleReader reader, UnitOfWork uow) {
        this.reader = reader;
        this.uow = uow;
    }

    public CommentView execute(long viewer, String slug, String body) {
        var comment = uow.run(tx -> {
            var articleId = tx.articles().articleId(slug);
            return tx.comments().insertComment(Comment.create(articleId, viewer, body));
        });
        return reader.comment(viewer, slug, comment.id());
    }
}
