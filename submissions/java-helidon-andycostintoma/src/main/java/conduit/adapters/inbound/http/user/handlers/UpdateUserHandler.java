package conduit.adapters.inbound.http.user.handlers;

import static conduit.adapters.inbound.http.HttpSupport.token;
import static conduit.adapters.inbound.http.HttpSupport.body;
import static conduit.adapters.inbound.http.HttpSupport.send;

import com.fasterxml.jackson.databind.ObjectMapper;
import conduit.errors.InvalidInput;
import conduit.usecases.commands.UpdateUser;
import conduit.usecases.queries.Authenticate;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;
import java.io.IOException;
import java.util.Map;

public final class UpdateUserHandler {
    private final UpdateUser updateUser;
    private final Authenticate auth;
    private final ObjectMapper json;

    public UpdateUserHandler(UpdateUser updateUser, Authenticate auth, ObjectMapper json) {
        this.updateUser = updateUser;
        this.auth = auth;
        this.json = json;
    }

    public void handle(ServerRequest request, ServerResponse response) throws IOException {
        var session = auth.execute(token(request), true);
        var input = parse(body(request, Request.class));
        var user = updateUser.execute(session.userId(), session.token(), input);
        send(response, json, 200, Map.of("user", user));
    }

    record Request(
        UpdateUser.Request user
    ) {
    }

    static UpdateUser.Request parse(Request input) {
        if (input.user() == null) {
            throw new InvalidInput("Expected a user object");
        }
        return input.user();
    }
}
