package dev.mccue.vertx.realworld;

import io.vertx.core.DeploymentOptions;
import io.vertx.core.Vertx;
import io.vertx.core.VertxOptions;
import io.vertx.core.http.HttpServerOptions;
import io.vertx.pgclient.PgBuilder;
import io.vertx.pgclient.PgConnectOptions;
import io.vertx.sqlclient.PoolOptions;
import io.vertx.sqlclient.SqlClient;

import java.lang.System.Logger.Level;
import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Objects;

public final class Main {
    private static final System.Logger LOG = System.getLogger(Main.class.getName());

    private Main() {
    }

    private static String env(String name, String defaultValue) {
        var value = System.getenv(name);
        return value == null || value.isEmpty() ? defaultValue : value;
    }

    public static void main(String[] args) throws Exception {
        int cores = Runtime.getRuntime().availableProcessors();
        // Event loops, each with its own HTTP server and Postgres clients. The cores they leave free are Postgres's.
        int eventLoops = Integer.parseInt(env("EVENT_LOOPS", Integer.toString(cores)));

        // DATABASE_URL is postgres://user:pass@host:port/db
        var databaseUrl = URI.create(Objects.requireNonNull(System.getenv("DATABASE_URL"), "DATABASE_URL is required"));
        var connectOptions = new PgConnectOptions()
                .setHost(databaseUrl.getHost())
                .setPort(databaseUrl.getPort() == -1 ? 5432 : databaseUrl.getPort())
                .setDatabase(databaseUrl.getRawPath().substring(1))
                // Each statement is parsed once per connection, and planned once: a generic plan is as good as a
                // custom one for all of these statements. No JIT, parallel workers or Memoize: they only add
                // overhead to small queries.
                .setCachePreparedStatements(true)
                .addProperty("plan_cache_mode", "force_generic_plan")
                .addProperty("jit", "off")
                .addProperty("max_parallel_workers_per_gather", "0")
                .addProperty("enable_memoize", "off");
        if (databaseUrl.getRawUserInfo() != null) {
            var userInfo = databaseUrl.getRawUserInfo().split(":", 2);
            connectOptions.setUser(URLDecoder.decode(userInfo[0], StandardCharsets.UTF_8));
            if (userInfo.length == 2) {
                connectOptions.setPassword(URLDecoder.decode(userInfo[1], StandardCharsets.UTF_8));
            }
        }

        // Read lanes (see Lanes): READ_LANES connections that take turns gathering reads for READ_WINDOW_US.
        // READ_LANES=0 turns them off: then every read is its own statement on its event loop's connections.
        int readLanes = Integer.parseInt(env("READ_LANES", Integer.toString(cores)));
        long readWindow = Long.parseLong(env("READ_WINDOW_US", "10000"));
        int readMax = Integer.parseInt(env("READ_MAX", "4096"));

        // Per event loop: pipelined connections for reads (with lanes, only the rare reads after a write that
        // matched nothing), and separate ones for writes, so no read waits behind a commit's WAL flush.
        int readConnections = Integer.parseInt(env("DB_READ_CONNS", "1"));
        int writeConnections = Integer.parseInt(env("DB_WRITE_CONNS", "1"));
        // Each bcrypt thread hashes four passwords at a time; a thread waits up to BCRYPT_WINDOW_MS to fill its four.
        // Logins and sign-ups are a fraction of a percent of requests, so one thread: the other cores serve the rest.
        int bcryptThreads = Integer.parseInt(env("BCRYPT_THREADS", "1"));
        long bcryptWindow = Long.parseLong(env("BCRYPT_WINDOW_MS", "100"));

        var host = env("HOST", "127.0.0.1");
        int port = Integer.parseInt(env("PORT", "3000"));
        var jwt = new Jwt(Objects.requireNonNull(System.getenv("JWT_SECRET"), "JWT_SECRET is required"));

        var vertx = Vertx.vertx(new VertxOptions()
                .setPreferNativeTransport(true)
                .setEventLoopPoolSize(eventLoops));
        var passwords = new Passwords(bcryptThreads, bcryptWindow);
        var lanes = readLanes > 0 ? new Lanes(vertx, connectOptions, readLanes, readWindow, readMax) : null;

        var serverOptions = new HttpServerOptions()
                .setHost(host)
                .setPort(port)
                .setAcceptBacklog(8192)
                .setTcpNoDelay(true)
                // Idle keep-alive connections stay open longer than Nginx's 60s upstream keep-alive
                // and a user's longest think time.
                .setIdleTimeout(300);

        // One server per event loop, each with its own Postgres clients. A request is parsed, queried and answered
        // on the one thread: the clients created here complete on this verticle's event loop.
        vertx.deployVerticle(
                () -> context -> {
                    // One client per read connection: a pooled client sends everything down one pipelined
                    // connection while it isn't full, and Readers spreads statements over them instead.
                    var readClients = new ArrayList<SqlClient>();
                    for (int i = 0; i < readConnections; i++) {
                        readClients.add(PgBuilder.client()
                                .with(new PoolOptions().setMaxSize(1))
                                .connectingTo(connectOptions)
                                .using(vertx)
                                .build());
                    }
                    var reads = new Readers(readClients);
                    var writes = PgBuilder.client()
                            .with(new PoolOptions().setMaxSize(writeConnections))
                            .connectingTo(connectOptions)
                            .using(vertx)
                            .build();
                    var api = new Api(reads, writes, jwt, passwords, lanes);
                    return vertx.createHttpServer(serverOptions)
                            .requestHandler(api::handle)
                            .listen()
                            .map(server -> (Void) null);
                },
                new DeploymentOptions().setInstances(eventLoops)
        ).await();

        LOG.log(Level.INFO, "Listening on " + host + ":" + port + " (native transport: " + vertx.isNativeTransportEnabled() + ")");
    }
}
