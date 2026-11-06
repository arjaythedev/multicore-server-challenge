package conduit.adapters.inbound.http.user.handlers;

import static conduit.adapters.inbound.http.HttpSupport.token;
import static conduit.adapters.inbound.http.HttpSupport.send;

import com.fasterxml.jackson.databind.ObjectMapper;
import conduit.usecases.commands.UnfollowUser;
import conduit.usecases.queries.Authenticate;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;
import java.io.IOException;
import java.util.Map;

public final class UnfollowUserHandler {
    private final UnfollowUser unfollowUser;
    private final Authenticate auth;
    private final ObjectMapper json;

    public UnfollowUserHandler(UnfollowUser unfollowUser, Authenticate auth, ObjectMapper json) {
        this.unfollowUser = unfollowUser;
        this.auth = auth;
        this.json = json;
    }

    public void handle(ServerRequest request, ServerResponse response) throws IOException {
        var session = auth.execute(token(request), true);
        var profile = unfollowUser.execute(request.path().pathParameters().get("username"),
            session.userId());
        send(response, json, 200, Map.of("profile", profile));
    }
}
