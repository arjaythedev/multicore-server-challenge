package conduit.wiring;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;

final class Database {
    static HikariDataSource open(String databaseUrl, int poolSize) {
        return new HikariDataSource(poolConfig(databaseUrl, poolSize));
    }

    static HikariConfig poolConfig(String databaseUrl, int poolSize) {
        var uri = URI.create(databaseUrl);
        if (!("postgres".equals(uri.getScheme()) || "postgresql".equals(uri.getScheme()))
            || uri.getHost() == null || uri.getRawPath() == null || uri.getRawPath().length() < 2
            || uri.getFragment() != null) {
            throw new IllegalArgumentException(
                "DATABASE_URL must be a postgres:// or postgresql:// database URL");
        }
        var authority = uri.getRawAuthority();
        var userInfo = uri.getRawUserInfo();
        if (userInfo != null) {
            authority = authority.substring(userInfo.length() + 1);
        }
        var jdbcUrl = "jdbc:postgresql://" + authority + uri.getRawPath();
        if (uri.getRawQuery() != null) {
            jdbcUrl += "?" + uri.getRawQuery();
        }
        var config = new HikariConfig();
        config.setJdbcUrl(jdbcUrl);
        if (userInfo != null) {
            var credentials = userInfo.split(":", 2);
            config.setUsername(decode(credentials[0]));
            if (credentials.length == 2) {
                config.setPassword(decode(credentials[1]));
            }
        }
        config.setPoolName("conduit");
        config.setMaximumPoolSize(poolSize);
        config.setConnectionTimeout(2_000);
        config.setInitializationFailTimeout(10_000);
        config.addDataSourceProperty("tcpKeepAlive", "true");
        // Avoid JIT and parallel-worker startup costs for short OLTP queries.
        config.addDataSourceProperty("options", "-c jit=off -c max_parallel_workers_per_gather=0");
        return config;
    }

    private static String decode(String value) {
        return URLDecoder.decode(value.replace("+", "%2B"), StandardCharsets.UTF_8);
    }
}
