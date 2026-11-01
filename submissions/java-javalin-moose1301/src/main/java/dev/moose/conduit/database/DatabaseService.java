package dev.moose.conduit.database;

import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.Properties;

public class DatabaseService {

    private final String jdbcUrl;
    private final Properties properties = new Properties();

    public DatabaseService(String databaseUrl) {
        final URI uri = URI.create(databaseUrl);
        final int port = uri.getPort() == -1 ? 5432 : uri.getPort();
        this.jdbcUrl = "jdbc:postgresql://" + uri.getHost() + ":" + port + uri.getRawPath();
        if (uri.getRawUserInfo() != null) {
            final String[] credentials = uri.getRawUserInfo().split(":", 2);
            this.properties.setProperty("user", URLDecoder.decode(credentials[0], StandardCharsets.UTF_8));
            if (credentials.length == 2) {
                this.properties.setProperty("password", URLDecoder.decode(credentials[1], StandardCharsets.UTF_8));
            }
        }
        this.properties.setProperty("prepareThreshold", "1");
        this.properties.setProperty("preparedStatementCacheQueries", "512");
        this.properties.setProperty("tcpKeepAlive", "true");
        this.properties.setProperty("ApplicationName", "conduit-javalin");
        this.properties.setProperty("options", "-c plan_cache_mode=force_generic_plan -c jit=off"
                + " -c max_parallel_workers_per_gather=0 -c enable_memoize=off -c synchronous_commit=on");
    }

    public Connection connect() throws SQLException {
        final Connection connection = DriverManager.getConnection(this.jdbcUrl, this.properties);
        connection.setAutoCommit(true);
        return connection;
    }

}
