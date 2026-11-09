package conduit.adapters.inbound.http.user.handlers;

import static conduit.adapters.inbound.http.HttpSupport.token;
import static conduit.adapters.inbound.http.HttpSupport.send;

import com.fasterxml.jackson.databind.ObjectMapper;
import conduit.usecases.queries.Authenticate;
import conduit.usecases.queries.GetProfile;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;
import java.io.IOException;
import java.util.Map;

public final class GetProfileHandler {
    private final GetProfile getProfile;
    private final Authenticate auth;
    private final ObjectMapper json;

    public GetProfileHandler(GetProfile getProfile, Authenticate auth, ObjectMapper json) {
        this.getProfile = getProfile;
        this.auth = auth;
        this.json = json;
    }

    public void handle(ServerRequest request, ServerResponse response) throws IOException {
        var session = auth.execute(token(request), false);
        var profile = getProfile.execute(request.path().pathParameters().get("username"),
            session.userId());
        send(response, json, 200, Map.of("profile", profile));
    }
}
