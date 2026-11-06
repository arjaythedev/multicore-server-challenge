package conduit.wiring;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.util.Map;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

class ConfigTest {
    private static final String DATABASE_URL = "postgres://localhost/conduit";

    @Test
    void requiresDatabaseUrl() {
        assertThrows(IllegalArgumentException.class, () -> Config.from(Map.of()));
    }

    @ParameterizedTest
    @ValueSource(strings = {"", " ", "\t\n"})
    void rejectsBlankDatabaseUrl(String databaseUrl) {
        assertThrows(IllegalArgumentException.class,
            () -> Config.from(Map.of("DATABASE_URL", databaseUrl)));
    }

    @Test
    void defaultsHostAndPort() {
        var config = Config.from(Map.of("DATABASE_URL", DATABASE_URL));

        assertEquals(DATABASE_URL, config.databaseUrl());
        assertEquals("127.0.0.1", config.host());
        assertEquals(3000, config.port());
    }

    @Test
    void usesExplicitValues() {
        var databaseUrl = "postgresql://alice:secret@db:5433/production?sslmode=require";
        var config = Config
            .from(Map.of("DATABASE_URL", databaseUrl, "HOST", "0.0.0.0", "PORT", "8080"));

        assertEquals(databaseUrl, config.databaseUrl());
        assertEquals("0.0.0.0", config.host());
        assertEquals(8080, config.port());
    }

    @ParameterizedTest
    @ValueSource(strings = {"", " ", "\t\n"})
    void rejectsBlankHost(String host) {
        assertThrows(IllegalArgumentException.class,
            () -> Config.from(Map.of("DATABASE_URL", DATABASE_URL, "HOST", host)));
    }

    @ParameterizedTest
    @ValueSource(ints = {1, 65535})
    void acceptsPortBoundaries(int port) {
        var config = Config
            .from(Map.of("DATABASE_URL", DATABASE_URL, "PORT", Integer.toString(port)));

        assertEquals(port, config.port());
    }

    @ParameterizedTest
    @ValueSource(strings = {"-1", "0", "65536", "2147483647", "-2147483648"})
    void rejectsOutOfRangePort(String port) {
        assertThrows(IllegalArgumentException.class,
            () -> Config.from(Map.of("DATABASE_URL", DATABASE_URL, "PORT", port)));
    }

    @ParameterizedTest
    @ValueSource(strings = {"", " ", "abc", "3000.0", "1e3", " 3000", "3000 ", "2147483648"})
    void rejectsNonIntegerPort(String port) {
        assertThrows(IllegalArgumentException.class,
            () -> Config.from(Map.of("DATABASE_URL", DATABASE_URL, "PORT", port)));
    }
}
