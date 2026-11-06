package conduit.usecases.queries;

import conduit.contracts.article.ArticleReader;
import conduit.contracts.article.readmodel.ArticlePage;
import conduit.errors.InvalidInput;

public final class ListArticles {
    private final ArticleReader reader;

    public ListArticles(ArticleReader reader) {
        this.reader = reader;
    }

    public ArticlePage execute(long viewer, int limit, long offset, String tag, String author,
        String favorited) {
        if (limit < 1 || limit > 100 || offset < 0) {
            throw new InvalidInput("Invalid pagination");
        }
        return reader.list(viewer, limit, offset, nonEmpty(tag), nonEmpty(author),
            nonEmpty(favorited));
    }

    private static String nonEmpty(String value) {
        return value == null || value.isEmpty() ? null : value;
    }
}
