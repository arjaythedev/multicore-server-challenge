package conduit.adapters.inbound.http.article.handlers;

import static conduit.adapters.inbound.http.HttpSupport.token;
import static conduit.adapters.inbound.http.HttpSupport.send;

import com.fasterxml.jackson.databind.ObjectMapper;
import conduit.usecases.commands.UnfavoriteArticle;
import conduit.usecases.queries.Authenticate;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;
import java.io.IOException;

public final class UnfavoriteArticleHandler {
    private final UnfavoriteArticle unfavoriteArticle;
    private final Authenticate auth;
    private final ObjectMapper json;

    public UnfavoriteArticleHandler(UnfavoriteArticle unfavoriteArticle, Authenticate auth,
        ObjectMapper json) {
        this.unfavoriteArticle = unfavoriteArticle;
        this.auth = auth;
        this.json = json;
    }

    public void handle(ServerRequest request, ServerResponse response) throws IOException {
        var session = auth.execute(token(request), true);
        var article = unfavoriteArticle.execute(session.userId(),
            request.path().pathParameters().get("slug"));
        send(response, json, 200, new ArticleResponse(article));
    }
}
