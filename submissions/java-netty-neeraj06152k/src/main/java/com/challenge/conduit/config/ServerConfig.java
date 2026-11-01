package com.challenge.conduit.config;

import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.util.Properties;

/**
 * Single Responsibility: Externalized Server Configuration.
 * Loads defaults from config.properties file, with runtime override from environment variables.
 * Allows repository owners and operators to adjust tuning parameters without recompiling.
 */
public record ServerConfig(
        String host,
        int port,
        int soBacklog,
        boolean tcpNoDelay,
        boolean soKeepAlive,
        boolean soReusePort,
        int maxInitialLineLength,
        int maxHeaderSize,
        int maxChunkSize,
        int maxContentLength,
        String databaseUrl,
        int dbPoolMaxSize,
        int dbPipeliningLimit,
        boolean dbCachePreparedStatements,
        String jwtSecret,
        int jwtExpirationDays,
        int bcryptCost,
        int nettyWorkerThreads,
        int bcryptWorkerThreads,
        int bcryptRingBufferSize
) {
    public static ServerConfig load() {
        Properties props = new Properties();

        // 1. Try to load from external config.properties
        File configFile = new File("config.properties");
        if (configFile.exists() && configFile.canRead()) {
            try (InputStream in = new FileInputStream(configFile)) {
                props.load(in);
            } catch (Exception ignored) {
            }
        }

        // 2. Resolve values with precedence: Environment Variable > Properties File > Default

        String host = getEnvOrProp(props, "HOST", "server.host", "0.0.0.0");
        int port = getIntEnvOrProp(props, "PORT", "server.port", 3000);
        int soBacklog = getIntProp(props, "server.so_backlog", 65535);
        boolean tcpNoDelay = getBoolProp(props, "server.tcp_nodelay", true);
        boolean soKeepAlive = getBoolProp(props, "server.so_keepalive", true);
        boolean soReusePort = getBoolProp(props, "server.so_reuseport", true);

        int maxInitialLineLength = getIntProp(props, "server.http.max_initial_line_length", 4096);
        int maxHeaderSize = getIntProp(props, "server.http.max_header_size", 8192);
        int maxChunkSize = getIntProp(props, "server.http.max_chunk_size", 8192);
        int maxContentLength = getIntProp(props, "server.http.max_content_length", 65536);

        String databaseUrl = getEnvOrProp(props, "DATABASE_URL", "db.url", "postgres://conduit:conduit@127.0.0.1:5432/conduit");
        int dbPoolMaxSize = getIntProp(props, "db.pool.max_size", 90);
        int dbPipeliningLimit = getIntProp(props, "db.pipelining_limit", 64);
        boolean dbCachePreparedStatements = getBoolProp(props, "db.cache_prepared_statements", true);

        String jwtSecret = getEnvOrProp(props, "JWT_SECRET", "security.jwt.secret", "multicore-server-challenge");
        int jwtExpirationDays = getIntProp(props, "security.jwt.expiration_days", 30);
        int bcryptCost = getIntProp(props, "security.bcrypt.cost", 10);

        int availableCores = Runtime.getRuntime().availableProcessors();
        int nettyWorkerThreads = getIntProp(props, "concurrency.netty.worker_threads", 0);
        if (nettyWorkerThreads <= 0) {
            nettyWorkerThreads = availableCores;
        }

        int bcryptWorkerThreads = getIntProp(props, "concurrency.bcrypt.worker_threads", 4);
        if (bcryptWorkerThreads <= 0) {
            bcryptWorkerThreads = Math.max(2, availableCores / 2);
        }

        int bcryptRingBufferSize = getIntProp(props, "concurrency.bcrypt.ring_buffer_size", 2048);

        return new ServerConfig(
                host,
                port,
                soBacklog,
                tcpNoDelay,
                soKeepAlive,
                soReusePort,
                maxInitialLineLength,
                maxHeaderSize,
                maxChunkSize,
                maxContentLength,
                databaseUrl,
                dbPoolMaxSize,
                dbPipeliningLimit,
                dbCachePreparedStatements,
                jwtSecret,
                jwtExpirationDays,
                bcryptCost,
                nettyWorkerThreads,
                bcryptWorkerThreads,
                bcryptRingBufferSize
        );
    }

    private static String getEnvOrProp(Properties props, String envKey, String propKey, String defaultVal) {
        String envVal = System.getenv(envKey);
        if (envVal != null && !envVal.isEmpty()) {
            return envVal;
        }
        return props.getProperty(propKey, defaultVal);
    }

    private static int getIntEnvOrProp(Properties props, String envKey, String propKey, int defaultVal) {
        String val = getEnvOrProp(props, envKey, propKey, String.valueOf(defaultVal));
        try {
            return Integer.parseInt(val);
        } catch (NumberFormatException e) {
            return defaultVal;
        }
    }

    private static int getIntProp(Properties props, String propKey, int defaultVal) {
        String val = props.getProperty(propKey);
        if (val == null) return defaultVal;
        try {
            return Integer.parseInt(val.trim());
        } catch (NumberFormatException e) {
            return defaultVal;
        }
    }

    private static boolean getBoolProp(Properties props, String propKey, boolean defaultVal) {
        String val = props.getProperty(propKey);
        if (val == null) return defaultVal;
        return Boolean.parseBoolean(val.trim());
    }
}
