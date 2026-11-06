package conduit.usecases.commands;

import conduit.contracts.UnitOfWork;
import conduit.contracts.article.ArticleReader;
import conduit.contracts.article.readmodel.ArticleDetails;
import conduit.domain.Article;
import java.util.List;

public final class CreateArticle {
    private final ArticleReader reader;
    private final UnitOfWork uow;

    public CreateArticle(ArticleReader reader, UnitOfWork uow) {
        this.reader = reader;
        this.uow = uow;
    }

    public record Request(
        String title,
        String description,
        String body,
        List<String> tagList
    ) {
    }

    public ArticleDetails execute(long viewer, Request request) {
        var tags = Article.tags(request.tagList());
        var articleId = uow.run(tx -> {
            var article = Article.create(viewer, request.title(), request.description(),
                request.body(), tx.articles()::nextArticleId);
            tx.articles().insert(article, tags);
            return article.id();
        });
        return reader.byId(viewer, articleId);
    }
}
