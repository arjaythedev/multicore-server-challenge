package conduit.adapters.inbound.http.article.handlers;

import conduit.contracts.article.readmodel.ArticleDetails;

record ArticleResponse(
    ArticleDetails article
) {
}
