module dev.mccue.jdk.httpserver.realworld {
    /// Password hash + salt (bcrypt)
    requires org.bouncycastle.provider;
    /// Database connection pooling
    requires com.zaxxer.hikari;
    /// JDBC extensions
    requires dev.mccue.jdbc;
    /// JSON support for jdk.httpserver
    requires dev.mccue.jdk.httpserver.json;
    /// Basic router
    requires dev.mccue.jdk.httpserver.regexrouter;
    /// JSON library
    requires dev.mccue.json;
    /// Parse query params
    requires dev.mccue.urlparameters;
    /// Load .env files
    requires io.github.cdimascio.dotenv.java;
    /// JDBC
    requires java.sql;
    /// HTTP server
    requires jdk.httpserver;
    /// IDE Friendly Annotations
    requires org.jetbrains.annotations;
    /// Logging Facade
    requires org.slf4j;
    /// Postgres Driver
    requires org.postgresql.jdbc;
    /// Jetty backing implementation
    requires org.eclipse.jetty.http.spi;
    /// Jetty server configuration (idle timeout, threads)
    requires org.eclipse.jetty.server;
    /// JWT signing and verification
    requires com.auth0.jwt;

    exports dev.mccue.jdk.httpserver.realworld;
}