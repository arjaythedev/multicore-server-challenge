package conduit.writes;

import conduit.Exchange;
import conduit.db.PgError;
import conduit.db.PgPool;
import conduit.db.PgQuery;

/**
 * A request's own statements (writes and logins), sent on the write connections. These are kept apart from the
 * batched reads: a commit waits for its WAL flush, and reads queued behind it on the same connection would wait too.
 * Concurrent commits on different connections share WAL flushes (Postgres's group commit).
 */
abstract class WriteQuery extends PgQuery {
    private static PgPool pool;

    protected final Exchange exchange;

    WriteQuery(Exchange exchange) {
        this.exchange = exchange;
    }

    static void usePool(PgPool writePool) {
        pool = writePool;
    }

    final void submit() {
        pool.submit(this);
    }

    @Override
    public final void onDone(PgError error) {
        try {
            if (error == null) onSuccess();
            else onError(error);
        } catch (RuntimeException e) {
            e.printStackTrace();
            exchange.respondError(500, "internal error");
        }
    }

    /** All statements ran and were committed. */
    protected abstract void onSuccess();

    /** Unique violations (a taken username or email) are the client's fault; anything else is ours. */
    protected void onError(PgError error) {
        if (error.isUniqueViolation()) {
            exchange.respondError(422, "already taken");
        } else if (PgError.FOREIGN_KEY_VIOLATION.equals(error.sqlState)) {
            exchange.respondError(404, "not found");          // the article was deleted meanwhile
        } else {
            System.err.println(getClass().getSimpleName() + " failed: " + error);
            exchange.respondError(500, "internal error");
        }
    }
}
