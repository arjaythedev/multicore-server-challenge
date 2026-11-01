package conduit;

import conduit.api.Api;
import conduit.auth.Bcrypt;
import conduit.auth.Jwt;
import conduit.net.EventLoop;
import conduit.pg.PgConfig;
import conduit.pg.PgPool;

import java.net.InetSocketAddress;
import java.net.StandardSocketOptions;
import java.nio.channels.ServerSocketChannel;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

/**
 * Starts the server: database pools, the bcrypt pool, then the event loops on HOST:PORT.
 *
 * <p>Environment: DATABASE_URL, JWT_SECRET, HOST, PORT (the challenge's runtime contract), plus tuning knobs
 * LOOPS (event-loop threads), DB_READ (read connections), DB_WRITE (write connections) and BCRYPT_THREADS.
 */
public final class Main {
    public static void main(String[] args) throws Exception {
        String dbUrl = env("DATABASE_URL", "postgres://conduit:conduit@127.0.0.1:5432/conduit");
        String secret = System.getenv("JWT_SECRET");
        if (secret == null || secret.isEmpty()) throw new IllegalStateException("JWT_SECRET is not set");
        String host = env("HOST", "0.0.0.0");
        int port = Integer.parseInt(env("PORT", "80"));
        int cpus = Runtime.getRuntime().availableProcessors();
        int loops = Integer.parseInt(env("LOOPS", String.valueOf(Math.min(8, cpus))));
        int dbRead = Integer.parseInt(env("DB_READ", "24"));
        int dbWrite = Integer.parseInt(env("DB_WRITE", "4"));
        int bcryptThreads = Integer.parseInt(env("BCRYPT_THREADS", "3"));

        Jwt.init(secret);
        Bcrypt.hash("warm-up"); // computes the Blowfish constants and warms the JIT before traffic
        Api.declareStatements();
        PgConfig cfg = PgConfig.parse(dbUrl);
        PgPool read = new PgPool(cfg, "read", dbRead, 30_000);
        PgPool write = new PgPool(cfg, "write", dbWrite, 30_000);

        ThreadPoolExecutor bcrypt = new ThreadPoolExecutor(bcryptThreads, bcryptThreads, 0, TimeUnit.SECONDS,
                new ArrayBlockingQueue<>(10_000), r -> {
                    Thread t = new Thread(r, "bcrypt");
                    t.setDaemon(true);
                    return t;
                });
        Api api = new Api(read, write, bcrypt);

        ServerSocketChannel listener = ServerSocketChannel.open();
        listener.setOption(StandardSocketOptions.SO_REUSEADDR, true);
        listener.bind(new InetSocketAddress(host, port), 65_535);
        listener.configureBlocking(false);
        for (int i = 0; i < loops; i++) new EventLoop(i, listener, api).start();
        System.err.printf("listening on %s:%d with %d loops, %d read + %d write DB connections, %d bcrypt threads%n",
                host, port, loops, dbRead, dbWrite, bcryptThreads);
    }

    private static String env(String name, String def) {
        String v = System.getenv(name);
        return v == null || v.isEmpty() ? def : v;
    }
}
