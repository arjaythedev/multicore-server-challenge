package conduit.wiring;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

class DatabaseTest {
    @ParameterizedTest
    @ValueSource(strings = {"postgres", "postgresql"})
    void convertsPostgresSchemesToJdbc(String scheme) {
        var config = Database.poolConfig(scheme + "://db.example:5433/conduit", 24);

        assertEquals("jdbc:postgresql://db.example:5433/conduit", config.getJdbcUrl());
        assertNull(config.getUsername());
        assertNull(config.getPassword());
    }

    @Test
    void extractsCredentialsWithoutIncludingThemInJdbcUrl() {
        var config = Database.poolConfig("postgres://alice:secret@localhost/conduit", 24);

        assertEquals("jdbc:postgresql://localhost/conduit", config.getJdbcUrl());
        assertEquals("alice", config.getUsername());
        assertEquals("secret", config.getPassword());
    }

    @Test
    void decodesPercentEncodedCredentialsExactlyOnce() {
        var config = Database
            .poolConfig("postgres://al%40ice%3A%C3%A9:p%40ss%3Aword%2F%25%252B@db/conduit", 24);

        assertEquals("al@ice:é", config.getUsername());
        assertEquals("p@ss:word/%%2B", config.getPassword());
        assertEquals("jdbc:postgresql://db/conduit", config.getJdbcUrl());
    }

    @Test
    void preservesLiteralAndPercentEncodedPlusSignsInCredentials() {
        var config = Database.poolConfig("postgres://al+ice%2B:p+ass%2B@db/conduit", 24);

        assertEquals("al+ice+", config.getUsername());
        assertEquals("p+ass+", config.getPassword());
    }

    @Test
    void keepsColonsAfterTheFirstCredentialSeparatorInPassword() {
        var config = Database.poolConfig("postgres://alice:one:two@db/conduit", 24);

        assertEquals("alice", config.getUsername());
        assertEquals("one:two", config.getPassword());
    }

    @Test
    void acceptsUsernameWithoutPassword() {
        var config = Database.poolConfig("postgres://alice@db/conduit", 24);

        assertEquals("alice", config.getUsername());
        assertNull(config.getPassword());
        assertEquals("jdbc:postgresql://db/conduit", config.getJdbcUrl());
    }

    @Test
    void preservesExplicitlyEmptyPassword() {
        var config = Database.poolConfig("postgres://alice:@db/conduit", 24);

        assertEquals("alice", config.getUsername());
        assertEquals("", config.getPassword());
    }

    @Test
    void preservesIpv6AuthorityAndPort() {
        var config = Database.poolConfig("postgresql://alice:secret@[::1]:5433/conduit", 24);

        assertEquals("jdbc:postgresql://[::1]:5433/conduit", config.getJdbcUrl());
        assertEquals("alice", config.getUsername());
        assertEquals("secret", config.getPassword());
    }

    @Test
    void preservesRawDatabasePathAndQueryOptions() {
        var config = Database.poolConfig(
            "postgres://db/my%20database"
                + "?sslmode=require&applicationName=conduit%2Btest&options=-c+search_path%3Dpublic",
            24);

        assertEquals(
            "jdbc:postgresql://db/my%20database"
                + "?sslmode=require&applicationName=conduit%2Btest&options=-c+search_path%3Dpublic",
            config.getJdbcUrl());
    }

    @ParameterizedTest
    @ValueSource(strings = {"http://db/conduit", "jdbc:postgresql://db/conduit", "//db/conduit",
            "postgres:///conduit", "postgres://:5432/conduit", "postgres://bad_host/conduit",
            "postgres://db", "postgres://db/", "postgres://db/?sslmode=require",
            "postgres://db/conduit#fragment", "postgres://db/conduit#",
            "postgres://db/my database"})
    void rejectsInvalidDatabaseUrls(String databaseUrl) {
        assertThrows(IllegalArgumentException.class, () -> Database.poolConfig(databaseUrl, 24));
    }

    @Test
    void configuresBoundedPoolAndTcpKeepAliveWithoutStartingDatasource() {
        var config = Database.poolConfig("postgres://db/conduit", 24);

        assertEquals("conduit", config.getPoolName());
        assertEquals(24, config.getMaximumPoolSize());
        assertTrue(config.getMaximumPoolSize() <= 95);
        assertEquals("true", config.getDataSourceProperties().getProperty("tcpKeepAlive"));
        assertEquals(2_000L, config.getConnectionTimeout());
        assertEquals("-c jit=off -c max_parallel_workers_per_gather=0",
            config.getDataSourceProperties().getProperty("options"));
        assertEquals(10_000L, config.getInitializationFailTimeout());
    }
}
