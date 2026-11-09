package conduit.usecases.commands;

import conduit.contracts.UnitOfWork;
import conduit.contracts.article.ArticleReader;
import conduit.contracts.article.readmodel.ArticleDetails;

public final class UnfavoriteArticle {
    private final ArticleReader reader;
    private final UnitOfWork uow;

    public UnfavoriteArticle(ArticleReader reader, UnitOfWork uow) {
        this.reader = reader;
        this.uow = uow;
    }

    public ArticleDetails execute(long viewer, String slug) {
        var articleId = uow.run(tx -> {
            var id = tx.articles().articleId(slug);
            tx.favorites().remove(id, viewer);
            return id;
        });
        return reader.byId(viewer, articleId);
    }
}
