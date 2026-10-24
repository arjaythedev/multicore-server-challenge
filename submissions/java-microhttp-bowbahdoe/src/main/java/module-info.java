module dev.mccue.microhttp.realworld {
    /// Password hash + salt (bcrypt)
    requires org.bouncycastle.provider;
    /// SQLFragment, for building statements out of parts
    requires dev.mccue.jdbc;
    /// Handler and route matching for microhttp
    requires dev.mccue.microhttp.handler;
    /// JSON responses for microhttp
    requires dev.mccue.microhttp.json;
    /// JSON library
    requires dev.mccue.json;
    /// Parse query params
    requires dev.mccue.urlparameters;
    /// Load .env files
    requires io.github.cdimascio.dotenv.java;
    /// HTTP server
    requires org.microhttp;
    /// IDE Friendly Annotations
    requires org.jetbrains.annotations;
    /// Logging Facade
    requires org.slf4j;
    /// Postgres client (pipelined, non-blocking), awaited from virtual threads
    requires io.vertx.core;
    requires io.vertx.sql.client;
    requires io.vertx.sql.client.pg;
    /// SCRAM-SHA-256 authentication, which vertx-pg-client only requires statically
    requires com.ongres.scram.client;
    /// JWT signing and verification
    requires com.auth0.jwt;

    exports dev.mccue.microhttp.realworld;
}
