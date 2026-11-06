package conduit.usecases.queries;

import conduit.contracts.article.ArticleReader;
import conduit.contracts.article.readmodel.ArticleDetails;

public final class GetArticle {
    private final ArticleReader reader;

    public GetArticle(ArticleReader reader) {
        this.reader = reader;
    }

    public ArticleDetails execute(long viewer, String slug) {
        return reader.bySlug(viewer, slug);
    }
}
