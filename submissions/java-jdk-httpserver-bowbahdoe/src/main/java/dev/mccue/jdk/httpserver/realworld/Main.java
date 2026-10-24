package dev.mccue.jdk.httpserver.realworld;

import com.sun.net.httpserver.HttpServer;
import com.zaxxer.hikari.HikariDataSource;
import dev.mccue.jdk.httpserver.HttpExchanges;
import dev.mccue.jdk.httpserver.json.JsonBody;
import dev.mccue.jdk.httpserver.regexrouter.RegexRouter;
import dev.mccue.json.Json;
import dev.mccue.json.JsonDecodeException;
import dev.mccue.json.JsonReadException;
import io.github.cdimascio.dotenv.Dotenv;
import org.eclipse.jetty.http.spi.JettyHttpServerProvider;
import org.eclipse.jetty.server.Server;
import org.eclipse.jetty.server.ServerConnector;
import org.eclipse.jetty.server.handler.ContextHandlerCollection;
import org.eclipse.jetty.util.thread.QueuedThreadPool;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.net.InetSocketAddress;
import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
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
        var db = new HikariDataSource();
        db.setDriverClassName("org.postgresql.Driver");
        db.setJdbcUrl("jdbc:postgresql://" + databaseUrl.getHost()
                      + ":" + (databaseUrl.getPort() == -1 ? 5432 : databaseUrl.getPort())
                      + databaseUrl.getRawPath());
        if (databaseUrl.getRawUserInfo() != null) {
            var userInfo = databaseUrl.getRawUserInfo().split(":", 2);
            db.setUsername(URLDecoder.decode(userInfo[0], StandardCharsets.UTF_8));
            if (userInfo.length == 2) {
                db.setPassword(URLDecoder.decode(userInfo[1], StandardCharsets.UTF_8));
            }
        }
        int poolSize;
        try {
            poolSize = Integer.parseInt(env.get("DB_POOL_SIZE"));
        } catch (NumberFormatException e) {
            poolSize = 80;
        }
        db.setMaximumPoolSize(poolSize);
        db.setMinimumIdle(poolSize);
        // Parse and plan each statement once per connection, not once per request.
        db.addDataSourceProperty("prepareThreshold", "1");

        var host = env.get("HOST", "127.0.0.1");
        int port;
        try {
            port = Integer.parseInt(env.get("PORT"));
        } catch (NumberFormatException e) {
            port = 3000;
        }

        // The Jetty server behind jdk.httpserver, set up here so that idle keep-alive connections
        // stay open longer than Nginx's 60s upstream keep-alive and a user's longest think time.
        // Jetty's selectors stay on platform threads; every request (blocking JDBC) runs on its own virtual thread.
        var threadPool = new QueuedThreadPool();
        threadPool.setName("http");
        threadPool.setVirtualThreadsExecutor(Executors.newVirtualThreadPerTaskExecutor());
        var jetty = new Server(threadPool);
        jetty.setHandler(new ContextHandlerCollection(true));
        var connector = new ServerConnector(jetty);
        connector.setHost(host);
        connector.setPort(port);
        connector.setIdleTimeout(300_000);
        connector.setAcceptQueueSize(8192);
        jetty.addConnector(connector);
        JettyHttpServerProvider.setServer(jetty);

        var server = HttpServer.create(
                new InetSocketAddress(host, port),
                0
        );

        var routerBuilder = RegexRouter.builder()
                .errorHandler((throwable, httpExchange) -> {
                    if (throwable instanceof JsonReadException
                        || throwable instanceof JsonDecodeException) {
                        HttpExchanges.sendResponse(httpExchange, 422, JsonBody.of(
                                Json.objectBuilder()
                                        .put("errors", Json.objectBuilder()
                                                .put("body", Json.arrayBuilder()
                                                        .add(Json.of("invalid body"))))));
                        return;
                    }
                    if (throwable instanceof RealWorldAPI.UnprocessableException) {
                        HttpExchanges.sendResponse(httpExchange, 422, JsonBody.of(
                                Json.objectBuilder()
                                        .put("errors", Json.objectBuilder()
                                                .put("body", Json.arrayBuilder()
                                                        .add(Json.of(throwable.getMessage()))))));
                        return;
                    }
                    if (throwable instanceof RealWorldAPI.InvalidTokenException) {
                        HttpExchanges.sendResponse(httpExchange, 401, JsonBody.of(
                                Json.objectBuilder()
                                        .put("errors", Json.objectBuilder()
                                                .put("body", Json.arrayBuilder()
                                                        .add(Json.of("unauthenticated"))))));
                        return;
                    }
                    LOG.error(
                            "Unhandled exception while handling {} {}",
                            httpExchange.getRequestMethod(),
                            httpExchange.getRequestURI(),
                            throwable
                    );
                    HttpExchanges.sendResponse(httpExchange, 500, JsonBody.of(
                            Json.objectBuilder()
                                    .put("errors", Json.objectBuilder()
                                            .put("body", Json.arrayBuilder()
                                                    .add(Json.of("internal error"))))));
                })
                .notFoundHandler(exchange ->
                        HttpExchanges.sendResponse(exchange, 404, JsonBody.of(
                                Json.objectBuilder()
                                        .put("errors", Json.objectBuilder()
                                                .put("body", Json.arrayBuilder()
                                                        .add(Json.of("not found"))))
                        )));

        new RealWorldAPI(db, env.get("JWT_SECRET")).register(routerBuilder);

        var router = routerBuilder.build();

        server.createContext("/", router);

        jetty.start();
        LOG.info("Listening on {}:{}", host, port);
        jetty.join();
    }

    public static void main(String[] args) throws Exception {
        new Main().start();
    }
}
