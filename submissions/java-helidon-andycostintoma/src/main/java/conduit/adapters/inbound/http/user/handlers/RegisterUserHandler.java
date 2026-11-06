package conduit.adapters.inbound.http.user.handlers;

import static conduit.adapters.inbound.http.HttpSupport.body;
import static conduit.adapters.inbound.http.HttpSupport.send;

import com.fasterxml.jackson.databind.ObjectMapper;
import conduit.errors.InvalidInput;
import conduit.usecases.commands.RegisterUser;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;
import java.io.IOException;
import java.util.Map;

public final class RegisterUserHandler {
    private final RegisterUser registerUser;
    private final ObjectMapper json;

    public RegisterUserHandler(RegisterUser registerUser, ObjectMapper json) {
        this.registerUser = registerUser;
        this.json = json;
    }

    public void handle(ServerRequest request, ServerResponse response) throws IOException {
        var registration = parse(body(request, Request.class));
        var user = registerUser.execute(registration);
        send(response, json, 201, Map.of("user", user));
    }

    record Request(
        RegisterUser.Request user
    ) {
    }

    static RegisterUser.Request parse(Request input) {
        if (input.user() == null) {
            throw new InvalidInput("Expected a user object");
        }
        return input.user();
    }
}
