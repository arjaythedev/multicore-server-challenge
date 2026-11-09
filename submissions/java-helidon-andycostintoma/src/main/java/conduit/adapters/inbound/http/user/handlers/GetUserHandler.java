package conduit.adapters.inbound.http.user.handlers;

import static conduit.adapters.inbound.http.HttpSupport.token;
import static conduit.adapters.inbound.http.HttpSupport.send;

import com.fasterxml.jackson.databind.ObjectMapper;
import conduit.usecases.queries.Authenticate;
import conduit.usecases.queries.GetUser;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;
import java.io.IOException;
import java.util.Map;

public final class GetUserHandler {
    private final GetUser getUser;
    private final Authenticate auth;
    private final ObjectMapper json;

    public GetUserHandler(GetUser getUser, Authenticate auth, ObjectMapper json) {
        this.getUser = getUser;
        this.auth = auth;
        this.json = json;
    }

    public void handle(ServerRequest request, ServerResponse response) throws IOException {
        var session = auth.execute(token(request), true);
        var user = getUser.execute(session.userId(), session.token());
        send(response, json, 200, Map.of("user", user));
    }
}
