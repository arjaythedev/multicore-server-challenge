package conduit.adapters.outbound.postgres.jooq.user;

import static conduit.generated.postgres.jooq.tables.Follows.FOLLOWS;
import static conduit.generated.postgres.jooq.tables.Users.USERS;

import conduit.contracts.user.UserReader;
import conduit.contracts.user.readmodel.UserDetails;
import conduit.contracts.user.readmodel.UserProfile;
import org.jooq.DSLContext;
import org.jooq.impl.DSL;

public final class JooqUserReader implements UserReader {
    private final DSLContext sql;

    public JooqUserReader(DSLContext sql) {
        this.sql = sql;
    }

    @Override
    public UserDetails byId(long id) {
        var row = sql.select(USERS.ID, USERS.EMAIL, USERS.USERNAME, USERS.BIO, USERS.IMAGE)
            .from(USERS).where(USERS.ID.eq(id)).fetchOne();
        return row == null
            ? null
            : new UserDetails(row.get(USERS.ID), row.get(USERS.EMAIL), row.get(USERS.USERNAME),
                row.get(USERS.BIO), row.get(USERS.IMAGE));
    }

    @Override
    public UserProfile profile(String username, long viewer) {
        var following = DSL.exists(DSL.selectOne().from(FOLLOWS)
            .where(FOLLOWS.FOLLOWER_ID.eq(viewer)).and(FOLLOWS.FOLLOWEE_ID.eq(USERS.ID)))
            .as("following");
        var row = sql.select(USERS.USERNAME, USERS.BIO, USERS.IMAGE, following).from(USERS)
            .where(USERS.USERNAME.eq(username)).fetchOne();
        return row == null
            ? null
            : new UserProfile(row.get(USERS.USERNAME), row.get(USERS.BIO), row.get(USERS.IMAGE),
                row.get(following));
    }
}
