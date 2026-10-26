package conduit.db;

/**
 * One round trip to Postgres: the statements a query binds and executes, ended by one Sync. Postgres runs them in
 * one implicit transaction and answers with rows and command completions numbered by statement (0, 1, ...), then
 * ReadyForQuery, which completes the query. After an error Postgres skips the rest of the query, so
 * {@link #onDone} receives the first error, if any.
 *
 * <p>The callbacks run on the connection's event loop thread, in order, exactly once per query for onDone.
 */
public abstract class PgQuery {
    /** Writes Bind/Execute pairs and a final Sync. */
    public abstract void write(MessageWriter out);

    /** A row of the statement with the given index within this query. */
    public void onRow(int statementIndex, Row row) {
    }

    /** A CommandComplete tag such as "DELETE 1" or "INSERT 0 1". */
    public void onCommandComplete(int statementIndex, String tag) {
    }

    /** The query is finished (committed, unless error is not null). */
    public abstract void onDone(PgError error);
}
