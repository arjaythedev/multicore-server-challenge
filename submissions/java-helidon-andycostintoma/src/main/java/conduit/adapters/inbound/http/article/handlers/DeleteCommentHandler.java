package conduit.adapters.inbound.http.article.handlers;

import static conduit.adapters.inbound.http.HttpSupport.token;
import static conduit.adapters.inbound.http.HttpSupport.send;

import com.fasterxml.jackson.databind.ObjectMapper;
import conduit.errors.NotFound;
import conduit.usecases.commands.DeleteComment;
import conduit.usecases.queries.Authenticate;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;
import java.io.IOException;

public final class DeleteCommentHandler {
    private final DeleteComment deleteComment;
    private final Authenticate auth;
    private final ObjectMapper json;

    public DeleteCommentHandler(DeleteComment deleteComment, Authenticate auth, ObjectMapper json) {
        this.deleteComment = deleteComment;
        this.auth = auth;
        this.json = json;
    }

    public void handle(ServerRequest request, ServerResponse response) throws IOException {
        var session = auth.execute(token(request), true);
        var id = commentId(request.path().pathParameters().get("id"));
        deleteComment.execute(session.userId(), request.path().pathParameters().get("slug"), id);
        send(response, json, 204, null);
    }

    static long commentId(String raw) {
        boolean negative = raw != null && raw.startsWith("-");
        String value = digits(negative ? raw.substring(1) : raw);
        if (value == null
            || exceeds(value, negative ? "9223372036854775808" : "9223372036854775807")) {
            throw new NotFound("Comment not found");
        }
        return Long.parseLong(negative ? "-" + value : value);
    }

    private static String digits(String raw) {
        if (raw == null || !raw.matches("[0-9]+")) {
            return null;
        }
        return raw.replaceFirst("^0+(?!$)", "");
    }

    private static boolean exceeds(String value, String maximum) {
        return value.length() > maximum.length()
            || value.length() == maximum.length() && value.compareTo(maximum) > 0;
    }
}
