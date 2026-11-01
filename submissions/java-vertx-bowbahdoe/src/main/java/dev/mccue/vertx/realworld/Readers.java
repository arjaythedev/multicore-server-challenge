package dev.mccue.vertx.realworld;

import io.vertx.core.Future;
import io.vertx.sqlclient.Row;
import io.vertx.sqlclient.RowSet;
import io.vertx.sqlclient.SqlClient;
import io.vertx.sqlclient.Tuple;

import java.util.List;

/// One event loop's read connections. Each statement goes to the connection with the fewest statements in flight,
/// so they queue in the Postgres backend that will get to them soonest, and every backend has work.
///
/// Everything here runs on the one event loop that owns this instance, so there is no locking.
final class Readers {
    private final SqlClient[] connections;
    private final int[] inFlight;
    private int next = 0;

    /// Each client is one connection.
    Readers(List<SqlClient> connections) {
        this.connections = connections.toArray(new SqlClient[0]);
        this.inFlight = new int[this.connections.length];
    }

    Future<RowSet<Row>> execute(String sql, Tuple parameters) {
        // least loaded, starting the search after the last pick so ties rotate
        int n = connections.length;
        int best = next;
        for (int i = 1; i < n; i++) {
            int candidate = (next + i) % n;
            if (inFlight[candidate] < inFlight[best]) {
                best = candidate;
            }
        }
        next = (best + 1) % n;
        int chosen = best;
        inFlight[chosen]++;
        return connections[chosen].preparedQuery(sql).execute(parameters).andThen(result -> inFlight[chosen]--);
    }
}
