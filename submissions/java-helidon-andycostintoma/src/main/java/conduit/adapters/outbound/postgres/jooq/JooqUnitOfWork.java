package conduit.adapters.outbound.postgres.jooq;

import conduit.adapters.outbound.postgres.jooq.article.JooqArticleRepository;
import conduit.adapters.outbound.postgres.jooq.comment.JooqCommentRepository;
import conduit.adapters.outbound.postgres.jooq.favorite.JooqFavoriteStore;
import conduit.adapters.outbound.postgres.jooq.follow.JooqFollowStore;
import conduit.adapters.outbound.postgres.jooq.user.JooqUserRepository;
import conduit.contracts.UnitOfWork;
import java.util.function.Function;
import org.jooq.DSLContext;
import org.jooq.impl.DSL;

public final class JooqUnitOfWork implements UnitOfWork {
    private final DSLContext sql;

    public JooqUnitOfWork(DSLContext sql) {
        this.sql = sql;
    }

    @Override
    public <T> T run(Function<Context, T> work) {
        return sql.transactionResult(configuration -> {
            var scoped = DSL.using(configuration);
            return work.apply(new Context(new JooqUserRepository(scoped),
                new JooqArticleRepository(scoped), new JooqCommentRepository(scoped),
                new JooqFollowStore(scoped), new JooqFavoriteStore(scoped)));
        });
    }
}
