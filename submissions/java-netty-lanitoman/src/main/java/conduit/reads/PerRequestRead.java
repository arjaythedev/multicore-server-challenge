package conduit.reads;

import conduit.Exchange;
import conduit.db.Row;

/** A batched read whose rows each belong to one request (the row's first column is the request's index). */
abstract class PerRequestRead extends BatchedRead<Void> {
    PerRequestRead(String name, String sql, int maxBatch) {
        super(name, sql, maxBatch);
    }

    @Override
    protected final Void newBatch(int count) {
        return null;
    }

    @Override
    protected final void onRow(Void batch, Exchange[] requests, int count, Row row) {
        int index = row.getInt(0);
        if (index >= 0 && index < count) onRow(requests[index], row);
    }

    @Override
    protected final void finish(Void batch, Exchange[] requests, int count) {
        answerEach(requests, count, i -> finish(requests[i]));
    }

    /** A result row for this request. */
    protected abstract void onRow(Exchange exchange, Row row);

    /** All rows are in: send this request's response. */
    protected abstract void finish(Exchange exchange);
}
