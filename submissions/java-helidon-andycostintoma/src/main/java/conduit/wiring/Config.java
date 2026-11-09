package conduit.wiring;

import java.util.Map;

public record Config(
    String databaseUrl,
    String host,
    int port,
    String jwtSecret,
    int databasePoolSize
) {
    static final int DEFAULT_DATABASE_POOL_SIZE = 24;

    public Config(String databaseUrl, String host, int port) {
        this(databaseUrl, host, port, "multicore-server-challenge", DEFAULT_DATABASE_POOL_SIZE);
    }

    public static Config from(Map<String, String> environment) {
        var databaseUrl = environment.get("DATABASE_URL");
        if (databaseUrl == null || databaseUrl.isBlank()) {
            throw new IllegalArgumentException("DATABASE_URL is required");
        }
        var host = environment.getOrDefault("HOST", "127.0.0.1");
        if (host.isBlank()) {
            throw new IllegalArgumentException("HOST must not be blank");
        }
        var port = Integer.parseInt(environment.getOrDefault("PORT", "3000"));
        if (port < 1 || port > 65535) {
            throw new IllegalArgumentException("PORT must be between 1 and 65535");
        }
        var secret = environment.getOrDefault("JWT_SECRET", "multicore-server-challenge");
        if (secret.isEmpty()) {
            throw new IllegalArgumentException("JWT_SECRET must not be empty");
        }
        var poolSize = Integer.parseInt(environment.getOrDefault("DATABASE_POOL_SIZE",
            Integer.toString(DEFAULT_DATABASE_POOL_SIZE)));
        // PostgreSQL allows 100 connections and reserves some for superusers.
        if (poolSize < 1 || poolSize > 95) {
            throw new IllegalArgumentException("DATABASE_POOL_SIZE must be between 1 and 95");
        }
        return new Config(databaseUrl, host, port, secret, poolSize);
    }
}
