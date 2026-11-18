package conduit.pg;

import java.util.concurrent.Executor;
import java.util.function.Consumer;

/**
 * One or more statements sent together and ended by a single Sync, so they run as one implicit transaction: they
 * see each other's writes, and an error anywhere rolls all of them back and skips the rest. The callback runs on
 * the given executor (the request's event loop) once Postgres has answered ReadyForQuery, which for writes means
 * after the commit.
 */
public final class Query {
    private static final int MAX = 4;

    final Stmt[] stmts = new Stmt[MAX];
    final Object[][] params = new Object[MAX][];
    final Rows[] rows = new Rows[MAX];
    int n;
    /** Index of the statement whose results the reader is receiving. */
    int cur;

    /** SQLSTATE of the error that ended this query, or null. */
    public String sqlState;
    public String error;

    private final Executor executor;
    private final Consumer<Query> done;

    public Query(Executor executor, Consumer<Query> done) {
        this.executor = executor;
        this.done = done;
    }

    public Query add(Stmt s, Object... p) {
        if (p.length != s.types.length) throw new IllegalArgumentException("wrong parameter count for " + s.sql);
        stmts[n] = s;
        params[n] = p;
        rows[n] = new Rows();
        n++;
        return this;
    }

    /** The number of statements. */
    public int size() {
        return n;
    }

    public Rows rows(int i) {
        return rows[i];
    }

    public boolean failed() {
        return sqlState != null;
    }

    void fail(String state, String msg) {
        if (sqlState == null) {
            sqlState = state;
            error = msg;
        }
    }

    void complete() {
        executor.execute(() -> done.accept(this));
    }
}
