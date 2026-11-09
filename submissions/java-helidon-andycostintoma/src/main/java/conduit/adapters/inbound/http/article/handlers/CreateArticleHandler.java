package conduit.adapters.inbound.http.article.handlers;

import static conduit.adapters.inbound.http.HttpSupport.token;
import static conduit.adapters.inbound.http.HttpSupport.body;
import static conduit.adapters.inbound.http.HttpSupport.send;

import com.fasterxml.jackson.databind.ObjectMapper;
import conduit.errors.InvalidInput;
import conduit.usecases.commands.CreateArticle;
import conduit.usecases.queries.Authenticate;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;
import java.io.IOException;

public final class CreateArticleHandler {
    private final CreateArticle createArticle;
    private final Authenticate auth;
    private final ObjectMapper json;

    public CreateArticleHandler(CreateArticle createArticle, Authenticate auth, ObjectMapper json) {
        this.createArticle = createArticle;
        this.auth = auth;
        this.json = json;
    }

    public void handle(ServerRequest request, ServerResponse response) throws IOException {
        var session = auth.execute(token(request), true);
        var input = parse(body(request, Request.class));
        var article = createArticle.execute(session.userId(), input);
        send(response, json, 201, new ArticleResponse(article));
    }

    record Request(
        CreateArticle.Request article
    ) {
    }

    static CreateArticle.Request parse(Request input) {
        if (input.article() == null) {
            throw new InvalidInput("Expected an article object");
        }
        return input.article();
    }
}
