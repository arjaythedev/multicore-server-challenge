package conduit.usecases.queries;

import conduit.contracts.article.ArticleReader;
import conduit.contracts.article.readmodel.ArticlePage;
import conduit.errors.InvalidInput;

public final class ListFeed {
    private final ArticleReader reader;

    public ListFeed(ArticleReader reader) {
        this.reader = reader;
    }

    public ArticlePage execute(long viewer, int limit, long offset) {
        if (limit < 1 || limit > 100 || offset < 0) {
            throw new InvalidInput("Invalid pagination");
        }
        return reader.feed(viewer, limit, offset);
    }
}
