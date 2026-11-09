package conduit.adapters.outbound.postgres.jooq;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertThrows;

import conduit.adapters.outbound.postgres.jooq.article.JooqArticleRepository;
import conduit.adapters.outbound.postgres.jooq.comment.JooqCommentRepository;
import conduit.adapters.outbound.postgres.jooq.favorite.JooqFavoriteStore;
import conduit.adapters.outbound.postgres.jooq.follow.JooqFollowStore;
import conduit.adapters.outbound.postgres.jooq.user.JooqUserRepository;
import java.sql.SQLException;
import org.jooq.SQLDialect;
import org.jooq.TransactionContext;
import org.jooq.TransactionProvider;
import org.jooq.exception.DataAccessException;
import org.jooq.impl.DSL;
import org.jooq.impl.DefaultConfiguration;
import org.junit.jupiter.api.Test;

class JooqUnitOfWorkTest {
    private final RecordingTransactions transactions = new RecordingTransactions();
    private final JooqUnitOfWork unit = new JooqUnitOfWork(
        DSL.using(new DefaultConfiguration().set(SQLDialect.POSTGRES).set(transactions)));

    @Test
    void expectedFailureRollsBackAndPreservesFailure() {
        var failure = new conduit.errors.NotFound("Profile not found");
        assertSame(failure, assertThrows(conduit.errors.NotFound.class, () -> unit.run(_ -> {
            throw failure;
        })));
        assertEquals(1, transactions.rollbacks);
        assertEquals(0, transactions.commits);
    }

    @Test
    void successCommits() {
        assertEquals("saved", unit.run(repositories -> {
            assertInstanceOf(JooqUserRepository.class, repositories.users());
            assertInstanceOf(JooqArticleRepository.class, repositories.articles());
            assertInstanceOf(JooqCommentRepository.class, repositories.comments());
            assertInstanceOf(JooqFollowStore.class, repositories.follows());
            assertInstanceOf(JooqFavoriteStore.class, repositories.favorites());
            return "saved";
        }));
        assertEquals(1, transactions.commits);
        assertEquals(0, transactions.rollbacks);
    }

    @Test
    void unexpectedDatabaseFailureRollsBackAndPropagates() {
        var failure = new DataAccessException("unavailable",
            new SQLException("unavailable", "08006"));
        assertSame(failure, assertThrows(DataAccessException.class, () -> unit.run(_ -> {
            throw failure;
        })));
        assertEquals(1, transactions.rollbacks);
        assertEquals(0, transactions.commits);
    }

    @Test
    void unexpectedExceptionRollsBackAndPreservesIdentity() {
        var failure = new IllegalStateException("unexpected");
        assertSame(failure, assertThrows(IllegalStateException.class, () -> unit.run(_ -> {
            throw failure;
        })));
        assertEquals(1, transactions.rollbacks);
        assertEquals(0, transactions.commits);
    }

    private static final class RecordingTransactions implements TransactionProvider {
        private int commits;
        private int rollbacks;

        @Override
        public void begin(TransactionContext context) {
        }

        @Override
        public void commit(TransactionContext context) {
            commits++;
        }

        @Override
        public void rollback(TransactionContext context) {
            rollbacks++;
        }
    }
}
