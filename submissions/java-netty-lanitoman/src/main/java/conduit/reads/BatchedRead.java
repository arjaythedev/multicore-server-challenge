package conduit.reads;

import conduit.Exchange;
import conduit.db.MessageWriter;
import conduit.db.PgError;
import conduit.db.Row;
import conduit.db.Statement;
import java.util.ArrayDeque;

/**
 * A kind of read (an article by slug, a page of the global list, ...) whose requests are answered in batches: the
 * requests that queued up while earlier statements were in Postgres are sent together as ONE statement. Their
 * parameters go in as five parallel arrays, which the SQL turns back into one row per request:
 *
 * <pre>
 *   unnest($1::int4[], $2::int8[], $3::text[], $4::int4[], $5::int8[]) AS r(i, viewer, key, lim, off)
 * </pre>
 *
 * where i is the request's position in the batch; result rows carry it so they can be routed back. A batch costs
 * Postgres one statement's overhead (protocol messages, executor start-up, snapshot, transaction) instead of one per
 * request, and work that several requests of the batch need (the same article, the same tag's count) is done once
 * within the statement. Every request still reads from Postgres while it is being served; nothing is kept from one
 * statement to the next.
 *
 * @param <B> what a kind keeps while one batch's rows arrive (e.g. the articles rendered for the batch)
 */
public abstract class BatchedRead<B> {
    /** The batch's requests as rows r(i, viewer, key, lim, off). */
    protected static final String REQUESTS =
            "unnest($1::int4[], $2::int8[], $3::text[], $4::int4[], $5::int8[]) AS r(i, viewer, key, lim, off)";

    final String name;
    final Statement statement;
    final int maxBatch;

    // guarded by ReadDispatcher's lock
    final ArrayDeque<Exchange> waiting = new ArrayDeque<>();

    protected BatchedRead(String name, String sql, int maxBatch) {
        this.name = name;
        this.statement = sql == null ? null : Statement.define(sql,
                Statement.INT4_ARRAY, Statement.INT8_ARRAY, Statement.TEXT_ARRAY, Statement.INT4_ARRAY, Statement.INT8_ARRAY);
        this.maxBatch = maxBatch;
    }

    /** Queues a request; it is sent with the next batch of this kind. */
    public void submit(Exchange exchange) {
        ReadDispatcher.submit(this, exchange);
    }

    /** Binds the statement with the requests' parameters as five arrays, one element per request. */
    protected void writeBatch(MessageWriter out, Exchange[] requests, int count) {
        out.bind(statement);
        out.beginArray(Statement.INT4);
        for (int i = 0; i < count; i++) out.arrayInt4(i);
        out.endArray();
        out.beginArray(Statement.INT8);
        for (int i = 0; i < count; i++) out.arrayInt8(requests[i].viewer);
        out.endArray();
        out.beginArray(Statement.TEXT);
        for (int i = 0; i < count; i++) out.arrayText(requests[i].key);
        out.endArray();
        out.beginArray(Statement.INT4);
        for (int i = 0; i < count; i++) out.arrayInt4(requests[i].limit);
        out.endArray();
        out.beginArray(Statement.INT8);
        for (int i = 0; i < count; i++) out.arrayInt8(requests[i].offset);
        out.endArray();
        out.execute();
        out.sync();
    }

    /** Creates the state for one batch, when it is sent. */
    protected abstract B newBatch(int count);

    /** A result row of the batch's statement. */
    protected abstract void onRow(B batch, Exchange[] requests, int count, Row row);

    /** All rows are in: answer every request of the batch. */
    protected abstract void finish(B batch, Exchange[] requests, int count);

    /** Frees what the batch holds (called after finish or a failure, whenever newBatch was called). */
    protected void release(B batch) {
    }

    /** Answers each request with {@code answer.accept(index)}; a failure answers that one request with a 500. */
    protected static void answerEach(Exchange[] requests, int count, java.util.function.IntConsumer answer) {
        for (int i = 0; i < count; i++) {
            try {
                answer.accept(i);
            } catch (RuntimeException e) {
                e.printStackTrace();
                requests[i].respondError(500, "internal error");
            }
        }
    }

    /** The statement failed: every request of the batch gets a 500. */
    final void fail(Exchange[] requests, int count, PgError error) {
        System.err.println(name + " batch failed: " + error);
        for (int i = 0; i < count; i++) requests[i].respondError(500, "internal error");
    }
}
