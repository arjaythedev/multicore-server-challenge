package conduit.adapters.inbound.http.user.handlers;

import static conduit.adapters.inbound.http.HttpSupport.body;
import static conduit.adapters.inbound.http.HttpSupport.send;

import com.fasterxml.jackson.databind.ObjectMapper;
import conduit.errors.InvalidInput;
import conduit.usecases.commands.Login;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;
import java.io.IOException;
import java.util.Map;

public final class LoginHandler {
    private final Login login;
    private final ObjectMapper json;

    public LoginHandler(Login login, ObjectMapper json) {
        this.login = login;
        this.json = json;
    }

    public void handle(ServerRequest request, ServerResponse response) throws IOException {
        var credentials = parse(body(request, Request.class));
        var user = login.execute(credentials);
        send(response, json, 200, Map.of("user", user));
    }

    record Request(
        Login.Request user
    ) {
    }

    static Login.Request parse(Request input) {
        if (input.user() == null) {
            throw new InvalidInput("Expected a user object");
        }
        return input.user();
    }
}
