package conduit;

import java.time.Duration;
import java.util.List;

import io.avaje.inject.BeanScope;
import io.avaje.http.api.ValidationException;
import io.avaje.json.JsonException;
import io.avaje.jsonb.JsonType;
import io.helidon.http.HeaderNames;
import io.helidon.http.HttpException;
import io.helidon.http.Status;
import io.helidon.webserver.WebServer;
import io.helidon.webserver.http.HttpFeature;
import io.helidon.webserver.http.HttpRouting;

public class Main {

    public static void main(String[] args) {
        BeanScope scope = BeanScope.builder().build();
        List<HttpFeature> features = scope.list(HttpFeature.class);
        JsonType<Dto.Errors> errors = scope.get(io.avaje.jsonb.Jsonb.class).type(Dto.Errors.class);

        HttpRouting.Builder routing = HttpRouting.builder();
        features.forEach(routing::addFeature);
        routing.error(ApiException.class, (req, res, ex) -> res.status(Status.create(ex.status))
                .header(HeaderNames.CONTENT_TYPE, "application/json")
                .send(errors.toJson(Dto.Errors.of(ex.getMessage()))));
        routing.error(JsonException.class, (req, res, ex) -> res.status(Status.create(422))
                .header(HeaderNames.CONTENT_TYPE, "application/json")
                .send(errors.toJson(Dto.Errors.of("malformed JSON body"))));
        routing.error(ValidationException.class, (req, res, ex) -> res.status(Status.create(422))
                .header(HeaderNames.CONTENT_TYPE, "application/json")
                .send(errors.toJson(Dto.Errors.of(ex.getErrors().stream()
                        .map(v -> v.getPath() + " " + v.getMessage())
                        .collect(java.util.stream.Collectors.joining("; "))))));
        routing.error(HttpException.class, (req, res, ex) -> res.status(ex.status())
                .header(HeaderNames.CONTENT_TYPE, "application/json")
                .send(errors.toJson(Dto.Errors.of(ex.getMessage()))));
        routing.error(Exception.class, (req, res, ex) -> {
            System.err.println("unhandled: " + ex);
            res.status(Status.INTERNAL_SERVER_ERROR_500)
                    .header(HeaderNames.CONTENT_TYPE, "application/json")
                    .send(errors.toJson(Dto.Errors.of("internal server error")));
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
}
