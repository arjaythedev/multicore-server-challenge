package conduit.adapters.inbound.http.user.handlers;

import static conduit.adapters.inbound.http.HttpSupport.token;
import static conduit.adapters.inbound.http.HttpSupport.send;

import com.fasterxml.jackson.databind.ObjectMapper;
import conduit.usecases.commands.FollowUser;
import conduit.usecases.queries.Authenticate;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;
import java.io.IOException;
import java.util.Map;

public final class FollowUserHandler {
    private final FollowUser followUser;
    private final Authenticate auth;
    private final ObjectMapper json;

    public FollowUserHandler(FollowUser followUser, Authenticate auth, ObjectMapper json) {
        this.followUser = followUser;
        this.auth = auth;
        this.json = json;
    }

    public void handle(ServerRequest request, ServerResponse response) throws IOException {
        var session = auth.execute(token(request), true);
        var profile = followUser.execute(request.path().pathParameters().get("username"),
            session.userId());
        send(response, json, 200, Map.of("profile", profile));
    }
}
