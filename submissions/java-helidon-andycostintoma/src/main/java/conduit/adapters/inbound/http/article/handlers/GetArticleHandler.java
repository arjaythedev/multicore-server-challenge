package conduit.adapters.inbound.http.article.handlers;

import static conduit.adapters.inbound.http.HttpSupport.token;
import static conduit.adapters.inbound.http.HttpSupport.send;

import com.fasterxml.jackson.databind.ObjectMapper;
import conduit.usecases.queries.Authenticate;
import conduit.usecases.queries.GetArticle;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;
import java.io.IOException;

public final class GetArticleHandler {
    private final GetArticle getArticle;
    private final Authenticate auth;
    private final ObjectMapper json;

    public GetArticleHandler(GetArticle getArticle, Authenticate auth, ObjectMapper json) {
        this.getArticle = getArticle;
        this.auth = auth;
        this.json = json;
    }

    public void handle(ServerRequest request, ServerResponse response) throws IOException {
        var session = auth.execute(token(request), false);
        var article = getArticle.execute(session.userId(),
            request.path().pathParameters().get("slug"));
        send(response, json, 200, new ArticleResponse(article));
    }
}
