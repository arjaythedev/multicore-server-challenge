package conduit;

import io.avaje.http.api.ValidationException;
import io.avaje.inject.BeanScope;
import io.avaje.json.JsonException;
import io.avaje.jsonb.JsonType;
import io.helidon.http.HeaderNames;
import io.helidon.http.HttpException;
import io.helidon.http.Status;
import io.helidon.webserver.WebServer;
import io.helidon.webserver.http.HttpFeature;
import io.helidon.webserver.http.HttpRouting;
import io.helidon.webserver.http.ServerResponse;
import java.time.Duration;
import java.util.List;
import java.util.stream.Collectors;
import org.jspecify.annotations.Nullable;

public class Main {

    @SuppressWarnings("resource") // the scope lives as long as the server
    static void main() {
        BeanScope scope = BeanScope.builder().build();
        List<HttpFeature> features = scope.list(HttpFeature.class);
        JsonType<Dto.Errors> errors = scope.get(io.avaje.jsonb.Jsonb.class).type(Dto.Errors.class);

        HttpRouting.Builder routing = HttpRouting.builder();
        features.forEach(routing::addFeature);
        routing.error(ApiException.class, (_, res, ex) -> send(res, errors, ex.status, ex.getMessage()));
        routing.error(JsonException.class, (_, res, _) -> send(res, errors, 422, "malformed JSON body"));
        routing.error(
                ValidationException.class,
                (_, res, ex) -> send(
                        res,
                        errors,
                        422,
                        ex.getErrors().stream()
                                .map(v -> v.getPath() + " " + v.getMessage())
                                .collect(Collectors.joining("; "))));
        routing.error(
                HttpException.class,
                (_, res, ex) -> send(res, errors, ex.status().code(), ex.getMessage()));
        routing.error(Exception.class, (_, res, ex) -> {
            ex.printStackTrace();
            send(res, errors, 500, "internal server error");
        });

        // Helidon runs every request on a virtual thread. The read timeout also bounds an idle keep-alive connection:
        // keep it above Nginx's 60 s upstream keep-alive.
        WebServer.builder()
                .host(Config.env("HOST", "127.0.0.1"))
                .port(Integer.parseInt(Config.env("PORT", "3000")))
                .backlog(1024)
                // without this a response written in two pieces (headers, then a larger body) waits for the
                // client's delayed ACK: about 40 ms on the list endpoints
                .connectionOptions(o -> o.readTimeout(Duration.ofSeconds(75)).tcpNoDelay(true))
                .addRouting(routing)
                .build()
                .start();
    }

    /** An error response: {"errors":{"body":[message]}} with the status. */
    private static void send(ServerResponse res, JsonType<Dto.Errors> errors, int status, @Nullable String message) {
        res.status(Status.create(status))
                .header(HeaderNames.CONTENT_TYPE, "application/json")
                .send(errors.toJson(Dto.Errors.of(message)));
    }
}
