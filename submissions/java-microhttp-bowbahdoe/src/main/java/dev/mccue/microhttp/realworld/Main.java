package dev.mccue.microhttp.realworld;

import dev.mccue.json.Json;
import dev.mccue.json.JsonDecodeException;
import dev.mccue.json.JsonReadException;
import dev.mccue.microhttp.handler.DelegatingHandler;
import dev.mccue.microhttp.json.JsonResponse;
import io.github.cdimascio.dotenv.Dotenv;
import io.vertx.core.Vertx;
import io.vertx.pgclient.PgBuilder;
import io.vertx.pgclient.PgConnectOptions;
import io.vertx.sqlclient.PoolOptions;
import org.microhttp.EventLoop;
import org.microhttp.OptionsBuilder;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.concurrent.Executors;

public final class Main {
    private static final Logger LOG =
            LoggerFactory.getLogger(Main.class);

    private Main() {

    }

    public void start() throws Exception {
        var env = Dotenv.configure()
                .ignoreIfMissing()
                .load();

        // DATABASE_URL is postgres://user:pass@host:port/db
        var databaseUrl = URI.create(env.get("DATABASE_URL"));
        var connectOptions = new PgConnectOptions()
                .setHost(databaseUrl.getHost())
                .setPort(databaseUrl.getPort() == -1 ? 5432 : databaseUrl.getPort())
                .setDatabase(databaseUrl.getRawPath().substring(1))
                // Parse and plan each statement once per connection, not once per request.
                .setCachePreparedStatements(true);
        if (databaseUrl.getRawUserInfo() != null) {
            var userInfo = databaseUrl.getRawUserInfo().split(":", 2);
            connectOptions.setUser(URLDecoder.decode(userInfo[0], StandardCharsets.UTF_8));
            if (userInfo.length == 2) {
                connectOptions.setPassword(URLDecoder.decode(userInfo[1], StandardCharsets.UTF_8));
            }
        }
        int poolSize;
        try {
            poolSize = Integer.parseInt(env.get("DB_POOL_SIZE"));
        } catch (NumberFormatException e) {
            poolSize = 16;
        }
        // A pipelined client: it sends the next statement on a connection without waiting for the previous
        // one's result, so a few connections are shared by every request in flight.
        var db = PgBuilder.client()
                .with(new PoolOptions().setMaxSize(poolSize))
                .connectingTo(connectOptions)
                .using(Vertx.vertx())
                .build();

        var host = env.get("HOST", "127.0.0.1");
        int port;
        try {
            port = Integer.parseInt(env.get("PORT"));
        } catch (NumberFormatException e) {
            port = 3000;
        }

        var rootHandler = new DelegatingHandler(
                new RealWorldAPI(db, env.get("JWT_SECRET")).handlers(),
                new JsonResponse(404, Json.objectBuilder()
                        .put("errors", Json.objectBuilder()
                                .put("body", Json.arrayBuilder()
                                        .add(Json.of("not found")))))
        );

        // microhttp's event loops must never block, so every request (blocking JDBC) runs on its own virtual thread.
        var executor = Executors.newVirtualThreadPerTaskExecutor();
        var eventLoop = new EventLoop(
                OptionsBuilder.newBuilder()
                        .withHost(host)
                        .withPort(port)
                        .withAcceptLength(8192)
                        // Idle keep-alive connections stay open longer than Nginx's 60s upstream keep-alive
                        // and a user's longest think time.
                        .withRequestTimeout(Duration.ofMinutes(5))
                        .build(),
                (request, callback) -> executor.execute(() -> {
                    try {
                        callback.accept(rootHandler.handle(request).intoResponse());
                    } catch (JsonReadException | JsonDecodeException e) {
                        callback.accept(new JsonResponse(422, Json.objectBuilder()
                                .put("errors", Json.objectBuilder()
                                        .put("body", Json.arrayBuilder()
                                                .add(Json.of("invalid body")))))
                                .intoResponse());
                    } catch (Exception e) {
                        LOG.error(
                                "Unhandled exception while handling {} {}",
                                request.method(),
                                request.uri(),
                                e
                        );
                        callback.accept(new JsonResponse(500, Json.objectBuilder()
                                .put("errors", Json.objectBuilder()
                                        .put("body", Json.arrayBuilder()
                                                .add(Json.of("internal error")))))
                                .intoResponse());
                    }
                })
        );

        eventLoop.start();
        LOG.info("Listening on {}:{}", host, port);
        eventLoop.join();
    }

    public static void main(String[] args) throws Exception {
        new Main().start();
    }
}
