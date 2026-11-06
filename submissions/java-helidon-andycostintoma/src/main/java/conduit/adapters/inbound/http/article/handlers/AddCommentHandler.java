package conduit.adapters.inbound.http.article.handlers;

import static conduit.adapters.inbound.http.HttpSupport.token;
import static conduit.adapters.inbound.http.HttpSupport.body;
import static conduit.adapters.inbound.http.HttpSupport.send;

import com.fasterxml.jackson.databind.ObjectMapper;
import conduit.contracts.article.readmodel.CommentView;
import conduit.errors.InvalidInput;
import conduit.usecases.commands.AddComment;
import conduit.usecases.queries.Authenticate;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;
import java.io.IOException;
import java.util.Map;

public final class AddCommentHandler {
    private final AddComment addComment;
    private final Authenticate auth;
    private final ObjectMapper json;

    public AddCommentHandler(AddComment addComment, Authenticate auth, ObjectMapper json) {
        this.addComment = addComment;
        this.auth = auth;
        this.json = json;
    }

    public void handle(ServerRequest request, ServerResponse response) throws IOException {
        var session = auth.execute(token(request), true);
        var text = parse(body(request, Request.class));
        var comment = addComment.execute(session.userId(),
            request.path().pathParameters().get("slug"), text);
        send(response, json, 201, Map.of("comment", new Response(comment)));
    }

    record Request(
        CommentBody comment
    ) {
    }

    record CommentBody(
        String body
    ) {
    }

    record Response(
        CommentView comment
    ) {
    }

    static String parse(Request input) {
        if (input.comment() == null) {
            throw new InvalidInput("Expected a comment object");
        }
        return input.comment().body();
    }
}
