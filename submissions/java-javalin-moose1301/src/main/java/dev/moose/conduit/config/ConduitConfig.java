package dev.moose.conduit.config;

import lombok.Getter;

import java.util.Objects;

@Getter
public class ConduitConfig {

    private final String databaseUrl;
    private final String jwtSecret;
    private final String host;
    private final int port;
    private final int cores;

    private final int readLanes;
    private final long readWindowMicros;
    private final int readMaxBatch;

    private final int writeConnections;

    private final int bcryptThreads;
    private final long bcryptWindowMillis;
    private final int bcryptNice;

    private final int selectors;
    private final int httpThreads;
    private final long idleTimeoutMillis;

    private ConduitConfig() {
        this.cores = Runtime.getRuntime().availableProcessors();
        this.databaseUrl = Objects.requireNonNull(System.getenv("DATABASE_URL"), "DATABASE_URL is required");
        this.jwtSecret = Objects.requireNonNull(System.getenv("JWT_SECRET"), "JWT_SECRET is required");
        this.host = environment("HOST", "127.0.0.1");
        this.port = Integer.parseInt(environment("PORT", "3000"));

        this.readLanes = Integer.parseInt(environment("READ_LANES", Integer.toString(this.cores)));
        this.readWindowMicros = Long.parseLong(environment("READ_WINDOW_US", "40000"));
        this.readMaxBatch = Integer.parseInt(environment("READ_MAX", "4096"));

        this.writeConnections = Integer.parseInt(environment("WRITE_CONNS", "16"));

        this.bcryptThreads = Integer.parseInt(environment("BCRYPT_THREADS", "2"));
        this.bcryptWindowMillis = Long.parseLong(environment("BCRYPT_WINDOW_MS", "250"));
        this.bcryptNice = Integer.parseInt(environment("BCRYPT_NICE", "5"));

        this.selectors = Integer.parseInt(environment("SELECTORS", Integer.toString(Math.max(2, this.cores / 2))));
        this.httpThreads = Integer.parseInt(environment("HTTP_THREADS", Integer.toString(Math.max(32, this.cores * 4))));
        this.idleTimeoutMillis = Long.parseLong(environment("IDLE_TIMEOUT_MS", "300000"));
    }

    public static ConduitConfig fromEnvironment() {
        return new ConduitConfig();
    }

    private static String environment(String name, String fallback) {
        final String value = System.getenv(name);
        if (value == null || value.isEmpty()) {
            return fallback;
        }
        return value;
    }

}
