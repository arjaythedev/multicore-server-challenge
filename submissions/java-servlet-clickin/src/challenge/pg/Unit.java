package challenge.pg;

import java.util.Objects;

/** Reusable request work. A unit must not be submitted twice at the same time. */
public final class Unit {
    @FunctionalInterface
    public interface Callback {
        void done(Unit unit);
    }

    public Query[] queries;
    public boolean tx;
    public boolean write;
    public final Completions owner;
    public final Callback callback;
    public volatile Unit next;
    long queuedAt;
    public String sqlState;
    public String errorMessage;
    public String bcryptPassword;
    public String bcryptHash;
    public boolean bcryptMatches;

    public Unit(Completions owner, Callback callback, boolean tx,
                boolean write, Query... queries) {
        this.owner = Objects.requireNonNull(owner);
        this.callback = Objects.requireNonNull(callback);
        this.tx = tx;
        this.write = write;
        this.queries = Objects.requireNonNull(queries);
        if (queries.length == 0 && tx) {
            throw new IllegalArgumentException("empty transaction");
        }
    }

    public void prepare(boolean tx, boolean write, Query[] queries) {
        if (queries.length == 0 && tx) {
            throw new IllegalArgumentException("empty transaction");
        }
        this.tx = tx;
        this.write = write;
        this.queries = Objects.requireNonNull(queries);
        sqlState = errorMessage = bcryptPassword = bcryptHash = null;
        bcryptMatches = false;
    }

    public void reset() {
        sqlState = errorMessage = bcryptPassword = bcryptHash = null;
        bcryptMatches = false;
        for (Query query : queries) {
            query.reset();
        }
    }
}
