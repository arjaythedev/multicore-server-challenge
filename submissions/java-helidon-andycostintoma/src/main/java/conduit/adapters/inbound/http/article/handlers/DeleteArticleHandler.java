package conduit.adapters.inbound.http.article.handlers;

import static conduit.adapters.inbound.http.HttpSupport.token;
import static conduit.adapters.inbound.http.HttpSupport.send;

import com.fasterxml.jackson.databind.ObjectMapper;
import conduit.usecases.commands.DeleteArticle;
import conduit.usecases.queries.Authenticate;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;
import java.io.IOException;

public final class DeleteArticleHandler {
    private final DeleteArticle deleteArticle;
    private final Authenticate auth;
    private final ObjectMapper json;

    public DeleteArticleHandler(DeleteArticle deleteArticle, Authenticate auth, ObjectMapper json) {
        this.deleteArticle = deleteArticle;
        this.auth = auth;
        this.json = json;
    }

    public void handle(ServerRequest request, ServerResponse response) throws IOException {
        var session = auth.execute(token(request), true);
        deleteArticle.execute(session.userId(), request.path().pathParameters().get("slug"));
        send(response, json, 204, null);
    }
}
