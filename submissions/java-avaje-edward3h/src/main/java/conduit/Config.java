package conduit;

import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;

import javax.sql.DataSource;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;

import io.avaje.inject.Bean;
import io.avaje.inject.Factory;
import io.avaje.jsonb.Jsonb;
import jakarta.inject.Named;
import org.jspecify.annotations.Nullable;

/**
 * Configuration comes from the environment only (DATABASE_URL, JWT_SECRET, HOST, PORT), plus DB_POOL_SIZE
 * from start.sh. Every stack reads the same DATABASE_URL (postgres://user:pass@host:port/db); JDBC wants
 * jdbc:postgresql://host:port/db plus separate credentials, so it is translated here.
 */
@Factory
class Config {

    @Bean
    @Named("default")
    DataSource dataSource() {
        URI uri = URI.create(env("DATABASE_URL", null));
        HikariConfig config = new HikariConfig();
        config.setJdbcUrl("jdbc:postgresql://" + (uri.getHost() == null ? "localhost" : uri.getHost()) + ":"
                + (uri.getPort() == -1 ? 5432 : uri.getPort())
                + uri.getRawPath() + (uri.getRawQuery() == null ? "" : "?" + uri.getRawQuery()));
        if (uri.getRawUserInfo() != null) {
            String[] parts = uri.getRawUserInfo().split(":", 2);
            config.setUsername(URLDecoder.decode(parts[0], StandardCharsets.UTF_8));
            if (parts.length > 1) {
                config.setPassword(URLDecoder.decode(parts[1], StandardCharsets.UTF_8));
            }
        }
        config.setMaximumPoolSize(Integer.parseInt(env("DB_POOL_SIZE", "10")));
        config.setConnectionTimeout(5000);
        return new HikariDataSource(config);
    }

    /** bio and image are JSON null when the column is NULL: nulls must be written, not omitted. */
    @Bean
    Jsonb jsonb() {
        return Jsonb.builder().serializeNulls(true).build();
    }

    @Bean
    Jwt jwt(Jsonb jsonb) {
        return new Jwt(env("JWT_SECRET", null), jsonb);
    }

    static String env(String name, @Nullable String fallback) {
        String value = System.getenv(name);
        if (value == null || value.isEmpty()) {
            if (fallback == null) {
                throw new IllegalStateException("missing environment variable " + name);
            }
            return fallback;
        }
        return value;
    }
}
