package conduit.adapters.outbound.postgres.jooq.user;

import static conduit.generated.postgres.jooq.tables.Users.USERS;

import conduit.contracts.user.UserRepository;
import conduit.domain.User;
import conduit.errors.Conflict;
import org.jooq.DSLContext;
import org.jooq.Record;
import org.jooq.exception.DataAccessException;
import org.postgresql.util.PSQLException;

public final class JooqUserRepository implements UserRepository {
    private final DSLContext sql;

    public JooqUserRepository(DSLContext sql) {
        this.sql = sql;
    }

    @Override
    public User byId(long id) {
        return user(sql.selectFrom(USERS).where(USERS.ID.eq(id)).forUpdate().fetchOne());
    }

    @Override
    public User byUsername(String username) {
        return user(sql.selectFrom(USERS).where(USERS.USERNAME.eq(username)).fetchOne());
    }

    @Override
    public User insert(User user) {
        try {
            return user(sql.insertInto(USERS).set(USERS.USERNAME, user.username())
                .set(USERS.EMAIL, user.email()).set(USERS.PASSWORD_HASH, user.passwordHash())
                .returning().fetchOne());
        } catch (DataAccessException failure) {
            throw conflict(failure);
        }
    }

    @Override
    public User save(User user) {
        try {
            return user(sql.update(USERS).set(USERS.USERNAME, user.username())
                .set(USERS.EMAIL, user.email()).set(USERS.PASSWORD_HASH, user.passwordHash())
                .set(USERS.BIO, user.bio()).set(USERS.IMAGE, user.image())
                .where(USERS.ID.eq(user.id())).returning().fetchOne());
        } catch (DataAccessException failure) {
            throw conflict(failure);
        }
    }

    private static Conflict conflict(DataAccessException failure) {
        var postgres = failure.getCause(PSQLException.class);
        var detail = postgres == null ? null : postgres.getServerErrorMessage();
        if ("23505".equals(failure.sqlState()) && detail != null
            && "users".equals(detail.getTable())
            && ("users_username_key".equals(detail.getConstraint())
                || "users_email_key".equals(detail.getConstraint()))) {
            return new Conflict("Username or email already exists");
        }
        throw failure;
    }

    private static User user(Record row) {
        return row == null
            ? null
            : User.reconstitute(
                new User.Props(row.get(USERS.ID), row.get(USERS.USERNAME), row.get(USERS.EMAIL),
                    row.get(USERS.PASSWORD_HASH), row.get(USERS.BIO), row.get(USERS.IMAGE)));
    }
}
