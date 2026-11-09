package conduit.adapters.inbound.http.article.handlers;

import conduit.contracts.article.readmodel.ArticleSummary;
import java.util.List;

record PageResponse(
    List<ArticleSummary> articles,
    long articlesCount
) {
}
