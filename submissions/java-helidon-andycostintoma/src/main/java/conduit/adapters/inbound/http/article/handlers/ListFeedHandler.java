package conduit.adapters.inbound.http.article.handlers;

import static conduit.adapters.inbound.http.HttpSupport.token;
import static conduit.adapters.inbound.http.HttpSupport.send;

import com.fasterxml.jackson.databind.ObjectMapper;
import conduit.usecases.queries.Authenticate;
import conduit.usecases.queries.ListFeed;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;
import java.io.IOException;

public final class ListFeedHandler {
    private final ListFeed listFeed;
    private final Authenticate auth;
    private final ObjectMapper json;

    public ListFeedHandler(ListFeed listFeed, Authenticate auth, ObjectMapper json) {
        this.listFeed = listFeed;
        this.auth = auth;
        this.json = json;
    }

    public void handle(ServerRequest request, ServerResponse response) throws IOException {
        var session = auth.execute(token(request), true);
        var page = ArticlePagination.parse(request.query().first("limit").orElse(null),
            request.query().first("offset").orElse(null));
        var result = listFeed.execute(session.userId(), page.limit(), page.offset());
        send(response, json, 200, new PageResponse(result.articles(), result.articlesCount()));
    }
}
