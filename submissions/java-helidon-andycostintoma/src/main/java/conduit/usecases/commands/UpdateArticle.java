package conduit.usecases.commands;

import conduit.contracts.UnitOfWork;
import conduit.contracts.article.ArticleReader;
import conduit.contracts.article.readmodel.ArticleDetails;
import conduit.domain.Article;

public final class UpdateArticle {
    private final ArticleReader reader;
    private final UnitOfWork uow;

    public UpdateArticle(ArticleReader reader, UnitOfWork uow) {
        this.reader = reader;
        this.uow = uow;
    }

    public record Request(
        String title,
        String description,
        String body
    ) {
    }

    public ArticleDetails execute(long viewer, String slug, Request request) {
        var articleId = uow.run(tx -> {
            var article = tx.articles().article(slug).update(viewer,
                new Article.UpdateInput(request.title(), request.description(), request.body()));
            tx.articles().update(article);
            return article.id();
        });
        return reader.byId(viewer, articleId);
    }
}
