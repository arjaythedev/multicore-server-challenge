package conduit.adapters.outbound.postgres.jooq.user;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;

import conduit.domain.User;
import conduit.errors.Conflict;
import java.sql.SQLException;
import org.jooq.SQLDialect;
import org.jooq.exception.DataAccessException;
import org.jooq.impl.DSL;
import org.jooq.tools.jdbc.MockConnection;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.postgresql.util.PSQLException;
import org.postgresql.util.ServerErrorMessage;

class JooqUserRepositoryTest {
    private final User user = User
        .reconstitute(new User.Props(1, "alice", "alice@example.com", "hash", null, null));

    @ParameterizedTest
    @ValueSource(strings = {"insert", "save"})
    void knownUniqueConstraintsReturnConflict(String operation) {
        for (var constraint : new String[]{"users_username_key", "users_email_key"}) {
            var repository = failingRepository(databaseFailure("23505", "users", constraint));
            var thrown = assertThrows(Conflict.class, () -> write(repository, operation));
            assertEquals("Username or email already exists", thrown.getMessage());
        }
    }

    @ParameterizedTest
    @ValueSource(strings = {"insert", "save"})
    void unexpectedDatabaseFailuresPreserveIdentity(String operation) {
        var failures = new DataAccessException[]{databaseFailure("23505", "users", "users_pkey"),
                databaseFailure("23505", "articles", "users_username_key"),
                databaseFailure("23514", "users", "users_email_key"),
                databaseFailure("08006", "users", "users_username_key"),
                new DataAccessException("duplicate", new SQLException("duplicate", "23505")),
                new DataAccessException("malformed",
                    new PSQLException(new ServerErrorMessage("SERROR\0C23505\0Mfailure\0\0"))),
                new DataAccessException("missing table",
                    new PSQLException(new ServerErrorMessage(
                        "SERROR\0C23505\0Mfailure\0nusers_username_key\0\0"))),
                new DataAccessException("missing constraint",
                    new PSQLException(
                        new ServerErrorMessage("SERROR\0C23505\0Mfailure\0tusers\0\0"))),
                new DataAccessException("unavailable", new SQLException("unavailable", "08006"))};
        for (var failure : failures) {
            var repository = failingRepository(failure);
            assertSame(failure,
                assertThrows(DataAccessException.class, () -> write(repository, operation)));
        }
    }

    @ParameterizedTest
    @ValueSource(strings = {"insert", "save"})
    void unexpectedExceptionsPreserveIdentity(String operation) {
        var failure = new IllegalStateException("unexpected");
        var repository = failingRepository(failure);
        assertSame(failure,
            assertThrows(IllegalStateException.class, () -> write(repository, operation)));
    }

    @ParameterizedTest
    @ValueSource(strings = {"byId", "byUsername"})
    void readsNeverTranslateUserConflicts(String operation) {
        var failure = databaseFailure("23505", "users", "users_username_key");
        var repository = failingRepository(failure);
        assertSame(failure, assertThrows(DataAccessException.class, () -> {
            if (operation.equals("byId")) {
                repository.byId(user.id());
            } else {
                repository.byUsername(user.username());
            }
        }));
    }

    private void write(JooqUserRepository repository, String operation) {
        if (operation.equals("insert")) {
            repository.insert(user);
        } else {
            repository.save(user);
        }
    }

    private static JooqUserRepository failingRepository(RuntimeException failure) {
        var connection = new MockConnection(_ -> {
            throw failure;
        });
        return new JooqUserRepository(DSL.using(connection, SQLDialect.POSTGRES));
    }

    private static DataAccessException databaseFailure(String state, String table,
        String constraint) {
        var detail = new ServerErrorMessage(
            "SERROR\0C" + state + "\0Mfailure\0t" + table + "\0n" + constraint + "\0\0");
        return new DataAccessException("database failure", new PSQLException(detail));
    }
}
