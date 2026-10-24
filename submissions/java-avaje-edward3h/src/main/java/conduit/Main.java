package conduit;

import java.time.Duration;
import java.util.List;

import io.avaje.inject.BeanScope;
import io.helidon.http.HeaderNames;
import io.helidon.http.Status;
import io.helidon.webserver.WebServer;
import io.helidon.webserver.http.HttpFeature;
import io.helidon.webserver.http.HttpRouting;

public class Main {

    public static void main(String[] args) {
        BeanScope scope = BeanScope.builder().build();
        List<HttpFeature> features = scope.list(HttpFeature.class);
        io.avaje.jsonb.JsonType<Dto.Errors> errors = scope.get(io.avaje.jsonb.Jsonb.class).type(Dto.Errors.class);

        HttpRouting.Builder routing = HttpRouting.builder();
        features.forEach(routing::addFeature);
        routing.error(ApiException.class, (req, res, ex) -> res.status(Status.create(ex.status))
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
                .connectionConfig(c -> c.readTimeout(Duration.ofSeconds(75)))
                .addRouting(routing)
                .build()
                .start();
    }
}
