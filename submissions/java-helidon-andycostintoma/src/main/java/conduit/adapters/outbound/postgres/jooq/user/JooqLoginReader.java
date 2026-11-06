package conduit.adapters.outbound.postgres.jooq.user;

import static conduit.generated.postgres.jooq.tables.Users.USERS;

import conduit.contracts.user.LoginReader;
import conduit.contracts.user.readmodel.LoginUser;
import org.jooq.DSLContext;

public final class JooqLoginReader implements LoginReader {
    private final DSLContext sql;

    public JooqLoginReader(DSLContext sql) {
        this.sql = sql;
    }

    @Override
    public LoginUser byEmail(String email) {
        var row = sql.select(USERS.ID, USERS.EMAIL, USERS.PASSWORD_HASH, USERS.USERNAME, USERS.BIO,
            USERS.IMAGE).from(USERS).where(USERS.EMAIL.eq(email)).fetchOne();
        return row == null
            ? null
            : new LoginUser(row.get(USERS.ID), row.get(USERS.EMAIL), row.get(USERS.PASSWORD_HASH),
                row.get(USERS.USERNAME), row.get(USERS.BIO), row.get(USERS.IMAGE));
    }
}
