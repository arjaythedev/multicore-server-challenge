package conduit.adapters.inbound.http.article.handlers;

import static conduit.adapters.inbound.http.HttpSupport.token;
import static conduit.adapters.inbound.http.HttpSupport.send;

import com.fasterxml.jackson.databind.ObjectMapper;
import conduit.usecases.queries.Authenticate;
import conduit.usecases.queries.ListArticles;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;
import java.io.IOException;

public final class ListArticlesHandler {
    private final ListArticles listArticles;
    private final Authenticate auth;
    private final ObjectMapper json;

    public ListArticlesHandler(ListArticles listArticles, Authenticate auth, ObjectMapper json) {
        this.listArticles = listArticles;
        this.auth = auth;
        this.json = json;
    }

    public void handle(ServerRequest request, ServerResponse response) throws IOException {
        var session = auth.execute(token(request), false);
        var page = ArticlePagination.parse(query(request, "limit"), query(request, "offset"));
        var result = listArticles.execute(session.userId(), page.limit(), page.offset(),
            query(request, "tag"), query(request, "author"), query(request, "favorited"));
        send(response, json, 200, new PageResponse(result.articles(), result.articlesCount()));
    }

    private static String query(ServerRequest request, String name) {
        return request.query().first(name).orElse(null);
    }
}
