package conduit.adapters.outbound.postgres.jooq.follow;

import static conduit.generated.postgres.jooq.tables.Follows.FOLLOWS;

import conduit.contracts.follow.FollowStore;
import org.jooq.DSLContext;

public final class JooqFollowStore implements FollowStore {
    private final DSLContext sql;

    public JooqFollowStore(DSLContext sql) {
        this.sql = sql;
    }

    @Override
    public void add(long follower, long followee) {
        sql.insertInto(FOLLOWS).set(FOLLOWS.FOLLOWER_ID, follower)
            .set(FOLLOWS.FOLLOWEE_ID, followee).onConflictDoNothing().execute();
    }

    @Override
    public void remove(long follower, long followee) {
        sql.deleteFrom(FOLLOWS).where(FOLLOWS.FOLLOWER_ID.eq(follower))
            .and(FOLLOWS.FOLLOWEE_ID.eq(followee)).execute();
    }
}
