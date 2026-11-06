package conduit.adapters.inbound.http;

import static conduit.adapters.inbound.http.HttpSupport.error;

import com.fasterxml.jackson.databind.ObjectMapper;
import conduit.errors.AppException;
import conduit.errors.Forbidden;
import conduit.errors.InvalidInput;
import conduit.errors.NotFound;
import conduit.errors.Unauthenticated;
import conduit.errors.Conflict;
import io.helidon.http.HeaderNames;
import io.helidon.http.HttpException;
import io.helidon.webserver.WebServer;
import io.helidon.webserver.http.HttpRouting;
import java.time.Duration;
import java.util.function.Consumer;

public final class HttpServer {
    public static WebServer create(ObjectMapper json, Consumer<HttpRouting.Builder> configure,
        String host, int port) {
        return WebServer.builder().host(host).port(port)
            .idleConnectionTimeout(Duration.ofMinutes(5)).routing(routes -> {
                configure.accept(routes);
                routes.error(AppException.class, (_, response, failure) -> {
                    int code = switch (failure) {
                        case InvalidInput _,Conflict _ -> 422;
                        case Unauthenticated _ -> 401;
                        case Forbidden _ -> 403;
                        case NotFound _ -> 404;
                    };
                    error(response, json, code, failure.getMessage());
                }).error(HttpException.class, (_, response, failure) -> {
                    failure.headers().forEach(response::header);
                    if (!failure.keepAlive()) {
                        response.header(HeaderNames.CONNECTION, "close");
                    }
                    error(response, json, failure.status().code(), "Request rejected");
                }).error(Exception.class, (_, response, failure) -> {
                    System.getLogger(HttpServer.class.getName()).log(System.Logger.Level.ERROR,
                        "Request failed", failure);
                    error(response, json, 500, "Internal server error");
                });
            }).build();
    }
}
