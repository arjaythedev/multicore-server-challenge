package conduit.reads;

import conduit.Exchange;
import conduit.db.MessageWriter;
import conduit.db.PgConnection;
import conduit.db.PgError;
import conduit.db.PgQuery;
import conduit.db.Row;
import java.util.List;

/**
 * Decides when batches go out. There is no timer: requests wait in their kind's queue only while every read
 * connection is busy. As soon as a connection is free, the kind whose oldest request has waited longest sends
 * everything it has queued (up to its maximum batch size) as one statement on that connection.
 *
 * <p>At low load each batch holds one request and nothing waits. Under load, requests queue while the connections
 * are busy, so batches grow by themselves exactly when batching pays off, and no request ever waits behind a long
 * statement on a connection: each connection runs one statement at a time.
 */
public final class ReadDispatcher {
    private static final Object LOCK = new Object();
    private static PgConnection[] connections;
    private static boolean[] busy;
    private static List<BatchedRead<?>> kinds;

    private ReadDispatcher() {
    }

    public static void start(PgConnection[] readConnections, List<BatchedRead<?>> allKinds) {
        connections = readConnections;
        busy = new boolean[readConnections.length];
        kinds = allKinds;
    }

    static void submit(BatchedRead<?> kind, Exchange exchange) {
        synchronized (LOCK) {
            exchange.queuedAt = System.nanoTime();
            kind.waiting.addLast(exchange);
        }
        sendWhatCanBeSent();
    }

    /** Fills every free connection with a batch, oldest waiting request first. */
    private static void sendWhatCanBeSent() {
        while (true) {
            Batch<?> batch;
            synchronized (LOCK) {
                BatchedRead<?> kind = longestWaitingKind();
                if (kind == null) return;
                int connection = freeConnection();
                if (connection < 0) return;
                busy[connection] = true;
                batch = new Batch<>(kind, connection);
                while (batch.count < kind.maxBatch && !kind.waiting.isEmpty()) {
                    batch.requests[batch.count++] = kind.waiting.pollFirst();
                }
            }
            connections[batch.connection].submit(batch);
        }
    }

    private static BatchedRead<?> longestWaitingKind() {
        BatchedRead<?> best = null;
        long oldest = Long.MAX_VALUE;
        for (BatchedRead<?> kind : kinds) {
            Exchange first = kind.waiting.peekFirst();
            if (first == null) continue;
            if (best == null || first.queuedAt - oldest < 0) {
                oldest = first.queuedAt;
                best = kind;
            }
        }
        return best;
    }

    private static int freeConnection() {
        for (int i = 0; i < busy.length; i++) if (!busy[i] && connections[i].isUsable()) return i;
        return -1;
    }

    /** One statement for a batch of requests of the same kind. */
    private static final class Batch<B> extends PgQuery {
        final BatchedRead<B> kind;
        final int connection;
        final Exchange[] requests;
        int count;
        /** The kind's state for this batch, created when the statement is written (on the connection's thread). */
        private B state;

        Batch(BatchedRead<B> kind, int connection) {
            this.kind = kind;
            this.connection = connection;
            this.requests = new Exchange[kind.maxBatch];
        }

        @Override
        public void write(MessageWriter out) {
            state = kind.newBatch(count);
            kind.writeBatch(out, requests, count);
        }

        @Override
        public void onRow(int statementIndex, Row row) {
            kind.onRow(state, requests, count, row);
        }

        @Override
        public void onDone(PgError error) {
            // free the connection first: the next batch goes out before these responses are written
            synchronized (LOCK) {
                busy[connection] = false;
            }
            sendWhatCanBeSent();
            try {
                if (error == null) kind.finish(state, requests, count);
                else kind.fail(requests, count, error);
            } finally {
                if (state != null) kind.release(state);   // null when the connection was lost before sending
            }
        }
    }
}
