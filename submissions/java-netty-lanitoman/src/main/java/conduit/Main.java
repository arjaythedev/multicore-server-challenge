package conduit;

import conduit.db.DatabaseUrl;
import conduit.db.FirstRowQuery;
import conduit.db.PgConnection;
import conduit.db.PgPool;
import conduit.db.Statement;
import conduit.http.HttpServer;
import conduit.reads.BatchedRead;
import conduit.reads.ReadDispatcher;
import conduit.reads.Reads;
import conduit.security.BCrypt;
import conduit.security.Jwt;
import conduit.security.PasswordWorkers;
import conduit.writes.Writes;
import io.netty.channel.EventLoopGroup;
import java.util.List;

/**
 * The Conduit API server. Configured by DATABASE_URL, JWT_SECRET, HOST and PORT; the optional settings below have
 * defaults tuned for the 8-core benchmark box, where this process shares the CPUs with Postgres.
 */
public final class Main {
    private Main() {
    }

    public static void main(String[] args) throws Exception {
        if (args.length > 0 && args[0].equals("--print-sql")) {
            Reads.define(64);
            Writes.defineStatements();
            Statement.describeAll().forEach(System.out::println);
            return;
        }
        Logging.install();
        DatabaseUrl database = DatabaseUrl.parse(required("DATABASE_URL"));
        Jwt.init(required("JWT_SECRET"));
        String host = setting("HOST", "127.0.0.1");
        int port = Integer.parseInt(setting("PORT", "3000"));

        int httpThreads = Integer.parseInt(setting("HTTP_THREADS", "2"));
        int postgresThreads = Integer.parseInt(setting("PG_THREADS", "2"));       // 0: share the HTTP event loops
        int readConnections = Integer.parseInt(setting("DB_READ_CONNS", "10"));
        int writeConnections = Integer.parseInt(setting("DB_WRITE_CONNS", "16"));
        int maxBatch = Integer.parseInt(setting("BATCH_MAX", "64"));
        int bcryptThreads = Integer.parseInt(setting("BCRYPT_THREADS", "2"));
        // At ~27 logins/s (100,000 users) a 400 ms window fills a six-hash batch about 98% of the time
        int bcryptWindowMillis = Integer.parseInt(setting("BCRYPT_BATCH_WINDOW_MS", "400"));
        int bcryptNice = Integer.parseInt(setting("BCRYPT_NICE", "10"));
        // Client connections at most: the file descriptor limit, less a reserve (beyond it, accepting waits)
        int maxConnections = Integer.parseInt(setting("MAX_CONNECTIONS", String.valueOf(HttpServer.defaultMaxConnections())));

        // Session settings only (rule 2). Generic plans: every statement here plans as well generically as with its
        // parameters, so planning per execution is skipped. No JIT and no parallel workers for these short queries.
        String postgresOptions = setting("DB_OPTIONS",
                "-c plan_cache_mode=force_generic_plan -c jit=off -c max_parallel_workers_per_gather=0");

        String bcrypt = BCrypt.start();                        // self-test; the C kernel if it was built and agrees
        PasswordWorkers.start(bcryptThreads, bcryptWindowMillis, bcryptNice);
        EventLoopGroup httpLoops = Transport.newEventLoopGroup(httpThreads, "http");
        EventLoopGroup postgresLoops = postgresThreads > 0 ? Transport.newEventLoopGroup(postgresThreads, "pg") : httpLoops;

        // The database's collation decides whether tag lists are sorted by Postgres or by us, and so the SQL.
        Statement collation = Statement.define(ArticleSql.COLLATION);
        PgConnection startup = PgConnection.open(postgresLoops, database, postgresOptions, "startup").join();
        FirstRowQuery collationQuery = new FirstRowQuery(collation);
        startup.submit(collationQuery);
        String[] locale = collationQuery.result().join();
        startup.close();
        ArticleSql.serverSortsTags = ArticleSql.isCodePointOrder(locale[0], locale[1], locale[2]);

        // Every statement must be defined before the connections open: each connection prepares all of them.
        List<BatchedRead<?>> reads = Reads.define(maxBatch);
        Writes.defineStatements();

        PgPool readPool = PgPool.open(postgresLoops, database, postgresOptions, readConnections, "read");
        PgPool writePool = PgPool.open(postgresLoops, database, postgresOptions, writeConnections, "write");
        ReadDispatcher.start(readPool.connections(), reads);
        Writes.start(writePool);

        HttpServer.start(httpLoops, host, port, maxConnections);
        System.out.printf("conduit listening on %s:%d (%s, %d http + %d postgres threads, %d read + %d write connections,"
                        + " batches up to %d, %d bcrypt threads at nice %d, bcrypt in %s, tags sorted by %s,"
                        + " up to %d client connections)%n",
                host, port, Transport.name(), httpThreads, postgresThreads, readConnections, writeConnections, maxBatch,
                bcryptThreads, bcryptNice, bcrypt, ArticleSql.serverSortsTags ? "the server" : "Postgres", maxConnections);
        Thread.currentThread().join();
    }

    private static String required(String name) {
        String value = System.getenv(name);
        if (value == null || value.isEmpty()) throw new IllegalStateException(name + " is not set");
        return value;
    }

    private static String setting(String name, String defaultValue) {
        String value = System.getenv(name);
        return value == null || value.isEmpty() ? defaultValue : value;
    }
}
