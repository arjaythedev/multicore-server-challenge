package conduit.adapters.inbound.http.article.handlers;

import static conduit.adapters.inbound.http.HttpSupport.token;
import static conduit.adapters.inbound.http.HttpSupport.body;
import static conduit.adapters.inbound.http.HttpSupport.send;

import com.fasterxml.jackson.databind.ObjectMapper;
import conduit.errors.InvalidInput;
import conduit.usecases.commands.UpdateArticle;
import conduit.usecases.queries.Authenticate;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;
import java.io.IOException;

public final class UpdateArticleHandler {
    private final UpdateArticle updateArticle;
    private final Authenticate auth;
    private final ObjectMapper json;

    public UpdateArticleHandler(UpdateArticle updateArticle, Authenticate auth, ObjectMapper json) {
        this.updateArticle = updateArticle;
        this.auth = auth;
        this.json = json;
    }

    public void handle(ServerRequest request, ServerResponse response) throws IOException {
        var session = auth.execute(token(request), true);
        var input = parse(body(request, Request.class));
        var article = updateArticle.execute(session.userId(),
            request.path().pathParameters().get("slug"), input);
        send(response, json, 200, new ArticleResponse(article));
    }

    record Request(
        UpdateArticle.Request article
    ) {
    }

    static UpdateArticle.Request parse(Request input) {
        if (input.article() == null) {
            throw new InvalidInput("Expected an article object");
        }
        return input.article();
    }
}
