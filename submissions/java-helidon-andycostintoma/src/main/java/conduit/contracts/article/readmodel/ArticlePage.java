package conduit.contracts.article.readmodel;

import java.util.List;

public record ArticlePage(
    List<ArticleSummary> articles,
    long articlesCount
) {
}
