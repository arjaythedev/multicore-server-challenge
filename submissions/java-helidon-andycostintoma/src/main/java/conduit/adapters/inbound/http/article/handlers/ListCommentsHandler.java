package conduit.adapters.inbound.http.article.handlers;

import static conduit.adapters.inbound.http.HttpSupport.token;
import static conduit.adapters.inbound.http.HttpSupport.send;

import com.fasterxml.jackson.databind.ObjectMapper;
import conduit.usecases.queries.Authenticate;
import conduit.usecases.queries.ListComments;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;
import java.io.IOException;
import java.util.Map;

public final class ListCommentsHandler {
    private final ListComments listComments;
    private final Authenticate auth;
    private final ObjectMapper json;

    public ListCommentsHandler(ListComments listComments, Authenticate auth, ObjectMapper json) {
        this.listComments = listComments;
        this.auth = auth;
        this.json = json;
    }

    public void handle(ServerRequest request, ServerResponse response) throws IOException {
        var session = auth.execute(token(request), false);
        var comments = listComments.execute(session.userId(),
            request.path().pathParameters().get("slug"));
        send(response, json, 200, Map.of("comments", comments));
    }
}
